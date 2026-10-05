import Foundation
import Testing
@testable import VolisleCore

private func verificationVolume(identity: VolumeIdentity, state: MountState = .readOnly,
                                path: String = "/fixture-mounted", safety: SafetyStatus = .unknown) -> VolumeSnapshot {
    .init(identity: identity, bsdName: "disk999s1", name: "夹具", fileSystem: "ntfs", deviceName: "夹具",
          totalBytes: 67_108_864, availableBytes: 1024,
          mountURL: state == .unmounted ? nil : URL(filePath: path), mountState: state,
          isExternal: true, isProtected: false, safety: safety)
}

// Only the OS/engine boundary is replaced. The actual coordinator and shared
// device gate run unchanged; no disk is discovered, opened or mounted.
private actor VerificationBackend: FileSystemAdapter, VolumeResolver {
    let identity = VolumeIdentity(volumeUUID: "test", mediaUUID: "test-media", devicePath: UUID().uuidString)
    var initialState: MountState = .readOnly
    var preMountState: MountState = .readOnly
    var finalState: MountState = .readWrite
    var finalPath = "/fixture-mounted"
    var returnedURL = URL(filePath: "/fixture-mounted")
    var replaceAfterMount = false
    var finalRisk = false
    var holdVerification = false
    var verificationEntered = false
    var verificationContinuation: CheckedContinuation<Void, Never>?
    var resolveCount = 0
    var mounts = 0
    func configure(initial: MountState = .readOnly, before: MountState = .readOnly,
                   after: MountState = .readWrite, path: String = "/fixture-mounted",
                   returned: URL = URL(filePath: "/fixture-mounted"), replace: Bool = false,
                   risk: Bool = false, hold: Bool = false) {
        initialState = initial; preMountState = before; finalState = after; finalPath = path
        returnedURL = returned; replaceAfterMount = replace; finalRisk = risk; holdVerification = hold
    }
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "测试") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { .clean }
    func resolve(_ expected: VolumeIdentity) async -> VolumeSnapshot {
        resolveCount += 1
        if mounts == 0 {
            return verificationVolume(identity: identity, state: resolveCount == 1 ? initialState : preMountState)
        }
        verificationEntered = true
        if holdVerification { await withCheckedContinuation { verificationContinuation = $0 } }
        let finalIdentity = replaceAfterMount
            ? VolumeIdentity(volumeUUID: "test", mediaUUID: "test-media", devicePath: identity.devicePath)
            : identity
        return verificationVolume(identity: finalIdentity, state: finalState, path: finalPath,
                                  safety: finalRisk ? .risk("挂载后发现风险") : .unknown)
    }
    func mountReadWrite(_ volume: VolumeSnapshot) -> URL { mounts += 1; return returnedURL }
    func unmount(_ volume: VolumeSnapshot) {}
    func recoverFailedMount(_ volume: VolumeSnapshot) -> MountRecoveryDisposition {
        finalState = .readOnly; finalPath = "/fixture-mounted"
        return .settled
    }
    func releaseVerification() { holdVerification = false; verificationContinuation?.resume(); verificationContinuation = nil }
}

struct MountVerificationTests {
    @Test(arguments: [false, true])
    func callbackWithoutWritableVolumeIsNotSuccess(automatic: Bool) async {
        let backend = VerificationBackend(); await backend.configure(after: .readOnly)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.mountNotVerified) {
            try await coordinator.enableReadWrite(expected: backend.identity, automatic: automatic)
        }
    }
    @Test(arguments: [MountState.readWrite, .unknown])
    func manualRequestRejectsLiveStateThatCannotBeTakenOver(state: MountState) async {
        let backend = VerificationBackend(); await backend.configure(initial: state)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.busy) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(await backend.mounts == 0)
    }
    @Test func writableChangeDuringPreflightPreventsManualTakeover() async {
        let backend = VerificationBackend(); await backend.configure(before: .readWrite)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.busy) { try await coordinator.enableReadWrite(expected: backend.identity) }
        #expect(await backend.mounts == 0)
    }
    @Test(arguments: ["file:///different", "https://example.invalid/fixture-mounted", "file://other-host/fixture-mounted"])
    func incorrectOrRemoteCallbackPathIsRejected(path: String) async {
        let backend = VerificationBackend(); await backend.configure(returned: URL(string: path)!)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.mountNotVerified) { try await coordinator.enableReadWrite(expected: backend.identity) }
    }
    @Test func replacementAfterMountCannotBeReportedAsOriginalDisk() async {
        let backend = VerificationBackend(); await backend.configure(replace: true)
        let gate = DeviceOperationGate()
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        do {
            _ = try await coordinator.enableReadWrite(expected: backend.identity)
            Issue.record("替换后的设备不能被视为原盘挂载成功")
        } catch let error as MountRecoveryError {
            #expect(error.cause as? VolumeError == .identityChanged)
        } catch { Issue.record("未保留身份变化及待核验状态：\(error)") }
        #expect(gate.isBusy(backend.identity.devicePath))
    }
    @Test func newlyObservedRiskAfterMountIsNotReportedAsSafe() async {
        let backend = VerificationBackend(); await backend.configure(risk: true)
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.unsafeVolume("挂载后发现风险")) {
            try await coordinator.enableReadWrite(expected: backend.identity)
        }
    }
    @Test func deviceLeaseCoversFinalVerification() async throws {
        let backend = VerificationBackend(); await backend.configure(hold: true)
        let gate = DeviceOperationGate()
        let coordinator = MountCoordinator(engine: backend, resolver: backend, gate: gate)
        let identity = backend.identity
        let operation = Task { try await coordinator.enableReadWrite(expected: identity) }
        // Bounded polling only synchronizes the test with the injected callback.
        for _ in 0..<10_000 {
            if await backend.verificationEntered { break }
            await Task.yield()
        }
        #expect(await backend.verificationEntered)
        // Cancellation cannot release the lease while verification still
        // awaits a non-cancellable system result.
        operation.cancel()
        #expect(gate.isBusy(identity.devicePath))
        #expect(throws: VolumeError.busy) {
            let unexpected = try gate.acquire(identity.devicePath)
            gate.release(unexpected)
        }
        await backend.releaseVerification()
        #expect(try await operation.value == URL(filePath: "/fixture-mounted"))
        #expect(!gate.isBusy(identity.devicePath))
    }
}
