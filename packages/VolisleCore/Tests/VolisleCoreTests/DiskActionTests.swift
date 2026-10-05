import Foundation
import Testing
@testable import VolisleCore

@MainActor private final class ActionBackend: DiskActionBackend {
    var volume: VolumeSnapshot
    var calls: [String] = []
    var failure: Error?
    var afterUnmount: VolumeSnapshot?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ volume: VolumeSnapshot = actionVolume()) { self.volume = volume }
    func resolve(_ identity: VolumeIdentity) throws -> VolumeSnapshot { volume }
    func unmount(_ volume: VolumeSnapshot, wholeDevice: Bool) async throws {
        calls.append(wholeDevice ? "unmount-whole" : "unmount-volume")
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        if let afterUnmount { self.volume = afterUnmount }
    }
    func eject(_ volume: VolumeSnapshot) async throws { calls.append("eject") }
}
private func actionVolume(identity: VolumeIdentity? = nil, external: Bool = true, mounted: Bool = true) -> VolumeSnapshot {
    .init(identity: identity ?? .init(volumeUUID: "v", mediaUUID: "m", devicePath: "physical-device"),
          bsdName: "disk99s1", name: "Test", fileSystem: "ntfs", deviceName: "Test device",
          totalBytes: 100, availableBytes: 50, mountURL: mounted ? URL(filePath: "/Volumes/Test") : nil,
          mountState: mounted ? .readOnly : .unmounted, isExternal: external, isProtected: false)
}
@MainActor struct DiskActionTests {
    @Test func reconnectedDeviceClearsSafeToUnplugNotice() async throws {
        let backend = ActionBackend(); let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        try await actions.execute(.ejectDevice, on: backend.volume.identity)
        actions.reconcile(previous: [backend.volume], current: [])
        #expect(actions.notice != nil)
        actions.reconcile(previous: [], current: [actionVolume()])
        #expect(actions.notice == nil)
    }
    @Test func remountedVolumeClearsUnmountNoticeButPreservesFailure() async throws {
        let backend = ActionBackend(); let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        let mounted = backend.volume
        let unmounted = actionVolume(identity: mounted.identity, mounted: false)
        try await actions.execute(.unmountVolume, on: mounted.identity)
        actions.reconcile(previous: [mounted], current: [unmounted])
        #expect(actions.notice != nil)
        actions.reconcile(previous: [unmounted], current: [mounted])
        #expect(actions.notice == nil)
        backend.failure = DiskSystemError.busy
        await actions.perform(.ejectDevice, on: mounted.identity)
        actions.reconcile(previous: [], current: [mounted])
        #expect(actions.lastError == DiskSystemError.busy.localizedDescription)
    }
    @Test func unchangedOrRemovedOtherVolumeDoesNotEraseNotice() async throws {
        let backend = ActionBackend(); let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        try await actions.execute(.ejectDevice, on: backend.volume.identity)
        let other = actionVolume()
        actions.reconcile(previous: [other], current: [other])
        #expect(actions.notice != nil)
        actions.reconcile(previous: [other], current: [])
        #expect(actions.notice != nil)
    }
    @Test func ejectOrdersWholeUnmountBeforeEject() async throws {
        let backend = ActionBackend(); let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        try await actions.execute(.ejectDevice, on: backend.volume.identity)
        #expect(backend.calls == ["unmount-whole", "eject"])
        #expect(actions.activeDevices.isEmpty)
        #expect(actions.notice != nil)
    }
    @Test func uuidlessMBRVolumeCanEjectWithLiveRegistryBinding() async throws {
        let identity = VolumeIdentity(volumeUUID: nil, mediaUUID: nil, devicePath: "physical-device", mediaRegistryID: 123)
        let backend = ActionBackend(actionVolume(identity: identity))
        let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        try await actions.execute(.ejectDevice, on: identity)
        #expect(backend.calls == ["unmount-whole", "eject"])
    }
    @Test func singleUnmountNeverEjects() async throws {
        let backend = ActionBackend(); let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        try await actions.execute(.unmountVolume, on: backend.volume.identity)
        #expect(backend.calls == ["unmount-volume"])
    }
    @Test func busyVolumeStopsEjectionAndReleasesLock() async {
        let backend = ActionBackend(); backend.failure = DiskSystemError.busy
        let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        await actions.perform(.ejectDevice, on: backend.volume.identity)
        #expect(backend.calls == ["unmount-whole"])
        #expect(actions.lastError == DiskSystemError.busy.localizedDescription)
        #expect(actions.activeDevices.isEmpty)
        #expect(actions.notice == nil)
    }
    @Test func reconnectBetweenUnmountAndEjectIsRejected() async {
        let backend = ActionBackend(); backend.afterUnmount = actionVolume()
        let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        await actions.perform(.ejectDevice, on: backend.volume.identity)
        #expect(backend.calls == ["unmount-whole"])
        #expect(actions.lastError == VolumeError.identityChanged.localizedDescription)
    }
    @Test func internalDeviceIsNeverTouched() async {
        let backend = ActionBackend(actionVolume(external: false))
        let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        await actions.perform(.ejectDevice, on: backend.volume.identity)
        #expect(backend.calls.isEmpty)
        #expect(actions.lastError == VolumeError.protectedVolume.localizedDescription)
    }
    @Test func concurrentActionDoesNotReleaseFirstLock() async throws {
        let backend = ActionBackend(); backend.hold = true
        let actions = DiskActions(backend: backend, gate: DeviceOperationGate())
        let first = Task { try await actions.execute(.unmountVolume, on: backend.volume.identity) }
        while backend.continuation == nil { await Task.yield() }
        await #expect(throws: VolumeError.busy) { try await actions.execute(.ejectDevice, on: backend.volume.identity) }
        #expect(actions.isBusy(backend.volume))
        #expect(backend.calls == ["unmount-volume"])
        backend.continuation?.resume()
        try await first.value
        #expect(actions.activeDevices.isEmpty)
    }
    @Test func separateActionInstancesShareGate() async throws {
        let backend = ActionBackend(); backend.hold = true
        let gate = DeviceOperationGate()
        let firstActions = DiskActions(backend: backend, gate: gate)
        let secondActions = DiskActions(backend: backend, gate: gate)
        let operation = Task { try await firstActions.execute(.unmountVolume, on: backend.volume.identity) }
        while backend.continuation == nil { await Task.yield() }
        #expect(secondActions.isBusy(backend.volume))
        await #expect(throws: VolumeError.busy) { try await secondActions.execute(.ejectDevice, on: backend.volume.identity) }
        operation.cancel()
        #expect(gate.isBusy(backend.volume.deviceGroup))
        backend.continuation?.resume(); try await operation.value
        #expect(!gate.isBusy(backend.volume.deviceGroup))
    }
    @Test func mountAndEjectCannotOverlapAcrossCoordinators() async throws {
        let backend = ActionBackend(); backend.hold = true
        let gate = DeviceOperationGate(), engine = GateTestEngine()
        let actions = DiskActions(backend: backend, gate: gate)
        let mount = MountCoordinator(engine: engine, resolver: GateTestResolver(snapshot: backend.volume), gate: gate)
        let operation = Task { try await actions.execute(.unmountVolume, on: backend.volume.identity) }
        while backend.continuation == nil { await Task.yield() }
        await #expect(throws: VolumeError.busy) { try await mount.enableReadWrite(expected: backend.volume.identity) }
        #expect(await engine.mounts == 0)
        backend.continuation?.resume(); try await operation.value
        let mounting = Task { try await mount.enableReadWrite(expected: backend.volume.identity) }
        while !(await engine.entered) { await Task.yield() }
        await #expect(throws: VolumeError.busy) { try await actions.execute(.ejectDevice, on: backend.volume.identity) }
        #expect(backend.calls == ["unmount-volume"])
        mounting.cancel()
        #expect(actions.isBusy(backend.volume))
        await engine.release()
        await #expect(throws: VolumeError.disconnected) { try await mounting.value }
        #expect(!actions.isBusy(backend.volume))
    }
    @Test func staleLeaseCannotReleaseNewOperationAndOtherDevicesRemainAvailable() throws {
        let gate = DeviceOperationGate()
        let first = try gate.acquire("one"), other = try gate.acquire("two")
        gate.release(first)
        let second = try gate.acquire("one")
        gate.release(first)
        #expect(gate.isBusy("one") && gate.isBusy("two"))
        gate.release(second); gate.release(other)
        #expect(!gate.isBusy("one") && !gate.isBusy("two"))
    }
}

private struct GateTestResolver: VolumeResolver {
    let snapshot: VolumeSnapshot
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { snapshot }
}
private actor GateTestEngine: FileSystemAdapter {
    var mounts = 0
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "测试") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { .clean }
    func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL {
        mounts += 1; entered = true
        await withCheckedContinuation { continuation = $0 }
        throw VolumeError.disconnected
    }
    func unmount(_ volume: VolumeSnapshot) {}
    func recoverFailedMount(_ volume: VolumeSnapshot) -> MountRecoveryDisposition { .settled }
    func release() { continuation?.resume(); continuation = nil }
}
