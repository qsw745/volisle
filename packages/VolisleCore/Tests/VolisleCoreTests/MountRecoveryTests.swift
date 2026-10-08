import Foundation
import Testing
@testable import VolisleCore

private func recoveryVolume(_ identity: VolumeIdentity, state: MountState = .readOnly) -> VolumeSnapshot {
    .init(identity: identity, bsdName: "disk999s1", name: "恢复夹具", fileSystem: "ntfs", deviceName: "夹具",
          totalBytes: 67_108_864, availableBytes: 1024,
          mountURL: state == .unmounted ? nil : URL(filePath: "/test-recovery"), mountState: state,
          isExternal: true, isProtected: false)
}

// An OS callback failure need not mean that the OS stopped changing the mount.
// This boundary double deliberately cannot prove that the operation settled.
private struct UnresolvedMountBackend: FileSystemAdapter, VolumeResolver {
    let identity = VolumeIdentity(volumeUUID: "v", mediaUUID: "m", devicePath: "recovery-fixture")
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "测试") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { .clean }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { recoveryVolume(self.identity) }
    func mountReadWrite(_ volume: VolumeSnapshot) throws -> URL { throw VolumeError.mountNotVerified }
    func unmount(_ volume: VolumeSnapshot) {}
}

private actor RecoveryBackend: FileSystemAdapter, VolumeResolver {
    let identity = VolumeIdentity(volumeUUID: "v", mediaUUID: "m", devicePath: "recovery-fixture")
    var observed: VolumeSnapshot?
    var started = false
    var mounts = 0
    var recoveries = 0
    var inspection: SafetyStatus = .clean
    var disposition: MountRecoveryDisposition = .settled
    var holdMount = false
    var holdRecovery = false
    var mountContinuation: CheckedContinuation<Void, Never>?
    var recoveryContinuation: CheckedContinuation<Void, Never>?
    var recoverySawCancellation = false
    var recoveryTargets: [VolumeIdentity] = []
    func configure(state: MountState = .readOnly, disposition: MountRecoveryDisposition = .settled,
                   holdMount: Bool = false, holdRecovery: Bool = false, inspection: SafetyStatus = .clean) {
        observed = recoveryVolume(identity, state: state)
        self.disposition = disposition; self.holdMount = holdMount; self.holdRecovery = holdRecovery
        self.inspection = inspection
    }
    func replaceObservation(_ value: VolumeSnapshot?) { observed = value }
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "测试") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { inspection }
    func resolve(_ expected: VolumeIdentity) throws -> VolumeSnapshot {
        if !started { return recoveryVolume(identity) }
        guard let observed else { throw VolumeError.disconnected }
        return observed
    }
    func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL {
        mounts += 1; started = true
        if holdMount { await withCheckedContinuation { mountContinuation = $0 } }
        throw VolumeError.mountNotVerified
    }
    func unmount(_ volume: VolumeSnapshot) {}
    func recoverFailedMount(_ volume: VolumeSnapshot) async -> MountRecoveryDisposition {
        recoveries += 1; recoveryTargets.append(volume.identity)
        recoverySawCancellation = Task.isCancelled
        if holdRecovery { await withCheckedContinuation { recoveryContinuation = $0 } }
        return disposition
    }
    func finishMount() { holdMount = false; mountContinuation?.resume(); mountContinuation = nil }
    func finishRecovery() { holdRecovery = false; recoveryContinuation?.resume(); recoveryContinuation = nil }
}

private func waitForBoundary(_ backend: RecoveryBackend, recovery: Bool) async -> Bool {
    for _ in 0..<10_000 {
        if recovery ? await backend.recoveryContinuation != nil : await backend.mountContinuation != nil { return true }
        await Task.yield()
    }
    return false
}

struct MountRecoveryTests {
    /// GitHub issue #1: with one disk read-write, a second one spun "processing" forever.
    @MainActor @Test func diskWaitingForAnotherWriteSessionIsNotWorking() async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        let control = ManualMountController(coordinator: coordinator, resolver: backend)
        let waiting = recoveryVolume(backend.identity)
        let session = gate.suspendNewOperations()  // the other disk's read-write session
        #expect(control.isBusy(waiting))
        #expect(!control.isWorking(on: waiting))
        gate.resumeOperations(session)
        #expect(!control.isBusy(waiting) && !control.isWorking(on: waiting))
    }
    @MainActor @Test func manualRecheckShowsRecoveryWithoutReportingWriteSuccess() async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(disposition: .unresolved)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        let control = ManualMountController(coordinator: coordinator, resolver: backend)
        let volume = recoveryVolume(backend.identity)
        await control.enable(volume)
        #expect(control.lastError != nil && control.notice == nil)
        #expect(control.requiresVerification(volume))
        control.clearMessage()
        #expect(control.isBusy(volume))
        await control.verifyRecovery(volume)
        #expect(control.lastError != nil && control.notice == nil)
        #expect(control.requiresVerification(volume))
        await backend.configure()
        await control.verifyRecovery(volume)
        #expect(!control.isBusy(volume) && !control.requiresVerification(volume))
        #expect(control.lastError == nil && control.notice != nil)
        #expect(await backend.mounts == 1)
        #expect(control.activeDevices.isEmpty)
    }

    @Test func confirmedRemovalOfHeldResourceCanResolveOldConnectionAfterReplug() async throws {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(disposition: .unresolved)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        let replacement = VolumeIdentity(volumeUUID: "v", mediaUUID: "m", devicePath: backend.identity.devicePath)
        await backend.configure(disposition: .deviceGone)
        await backend.replaceObservation(recoveryVolume(replacement))
        #expect(try await coordinator.verifyRecovery(deviceGroup: replacement.devicePath) == .disconnected)
        #expect(await backend.recoveryTargets == [backend.identity, backend.identity])
        #expect(await backend.mounts == 1)
        #expect(!gate.isBusy(backend.identity.devicePath))
    }

    @Test(arguments: ["https://example.invalid/disk", "file://other-host/disk", "file:///", "file:///tmp/..", "file:///disk?x=1"])
    func invalidReadOnlyMountLocationCannotUnlockDevice(path: String) async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure()
        let identity = backend.identity
        await backend.replaceObservation(.init(identity: identity, bsdName: "disk999s1", name: "夹具", fileSystem: "ntfs",
            deviceName: "夹具", totalBytes: 67_108_864, availableBytes: 1024, mountURL: URL(string: path),
            mountState: .readOnly, isExternal: true, isProtected: false))
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: identity) }
        #expect(gate.isBusy(identity.devicePath))
    }

    @Test func cancellationCannotCancelCleanupOrReleaseLeaseEarly() async throws {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(holdMount: true, holdRecovery: true)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        let operation = Task { try await coordinator.enableReadWrite(expected: backend.identity) }
        let enteredMount = await waitForBoundary(backend, recovery: false)
        #expect(enteredMount)
        operation.cancel()
        await backend.finishMount()
        let enteredRecovery = await waitForBoundary(backend, recovery: true)
        #expect(enteredRecovery)
        #expect(gate.isBusy(backend.identity.devicePath))
        #expect(await backend.recoverySawCancellation == false)
        await backend.finishRecovery()
        await #expect(throws: VolumeError.mountNotVerified) { try await operation.value }
        #expect(!gate.isBusy(backend.identity.devicePath))
    }

    @Test(arguments: [MountState.readOnly, .unmounted])
    func settledFailureRequiresIndependentSafeObservation(state: MountState) async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(state: state)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: VolumeError.mountNotVerified) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(await backend.recoveries == 1)
        #expect(!gate.isBusy(backend.identity.devicePath))
    }

    @Test(arguments: [MountState.readWrite, .unknown])
    func backendAcknowledgementCannotOverrideUnsafeObservation(state: MountState) async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(state: state)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(gate.isBusy(backend.identity.devicePath))
        #expect(coordinator.requiresVerification(recoveryVolume(backend.identity)))
    }

    @Test func replacedDiskCannotValidateRecoveryAndRecoveryUsesOriginalIdentity() async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure()
        let replacement = VolumeIdentity(volumeUUID: "v", mediaUUID: "m", devicePath: backend.identity.devicePath)
        await backend.replaceObservation(recoveryVolume(replacement))
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        await #expect(throws: VolumeError.identityChanged) { try await coordinator.verifyRecovery(expected: replacement) }
        #expect(await backend.recoveryTargets == [backend.identity])
        #expect(gate.isBusy(backend.identity.devicePath))
    }

    @Test func missingDiscoveryRecordAloneDoesNotProvePhysicalDisconnection() async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure()
        await backend.replaceObservation(nil)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(gate.isBusy(backend.identity.devicePath))
    }

    @Test func explicitRecheckUnlocksOnlyAfterSettledAndNeverRetriesWriting() async throws {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(disposition: .unresolved)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        await #expect(throws: VolumeError.busy) { try await coordinator.enableReadWrite(expected: backend.identity) }
        await #expect(throws: MountRecoveryError.self) { try await coordinator.verifyRecovery(expected: backend.identity) }
        #expect(gate.isBusy(backend.identity.devicePath))
        await backend.configure()
        #expect(try await coordinator.verifyRecovery(expected: backend.identity) == .readOnly)
        #expect(!gate.isBusy(backend.identity.devicePath))
        #expect(try await coordinator.verifyRecovery(expected: backend.identity) == .nothingPending)
        #expect(await backend.mounts == 1)
        #expect(await backend.recoveries == 3)
    }

    @Test func duplicateRecheckCannotStartConcurrentRecovery() async throws {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(disposition: .unresolved)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        await backend.configure(holdRecovery: true)
        let recheck = Task { try await coordinator.verifyRecovery(expected: backend.identity) }
        #expect(await waitForBoundary(backend, recovery: true))
        await #expect(throws: VolumeError.busy) { try await coordinator.verifyRecovery(expected: backend.identity) }
        #expect(gate.isBusy(backend.identity.devicePath))
        await backend.finishRecovery()
        #expect(try await recheck.value == .readOnly)
        #expect(await backend.recoveries == 2)
    }

    @Test func preflightRefusalDoesNotStartRecoveryOrRetainLease() async {
        let backend = RecoveryBackend(), gate = DeviceOperationGate()
        await backend.configure(inspection: .risk("Windows 休眠"))
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: VolumeError.unsafeVolume("Windows 休眠")) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(await backend.mounts == 0)
        #expect(await backend.recoveries == 0)
        #expect(!gate.isBusy(backend.identity.devicePath))
    }

    @Test func uncertainMountFailureMustKeepDeviceExcluded() async {
        let backend = UnresolvedMountBackend(), gate = DeviceOperationGate()
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        await #expect(throws: (any Error).self) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(gate.isBusy(backend.identity.devicePath))
        #expect(throws: VolumeError.busy) {
            let unexpected = try gate.acquire(backend.identity.devicePath)
            gate.release(unexpected)
        }
        let other = try? gate.acquire("unrelated-device")
        #expect(other != nil)
        if let other { gate.release(other) }
    }
}
