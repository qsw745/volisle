import Foundation
import Testing
@testable import VolisleCore

private func manualVolume(_ identity: VolumeIdentity = .init(volumeUUID: "v", mediaUUID: "m", devicePath: "fixture"),
                          state: MountState = .readOnly, path: String = "/fixture-only") -> VolumeSnapshot {
    .init(identity: identity, bsdName: "disk999s1", name: "夹具", fileSystem: "ntfs", deviceName: "夹具",
          totalBytes: 64 * 1024 * 1024, availableBytes: 1024, mountURL: URL(filePath: path),
          mountState: state, isExternal: true, isProtected: false)
}
private actor ManualBackend: FileSystemAdapter, VolumeResolver {
    var volume = manualVolume()
    var available = true
    var verify = true
    var hold = false
    var entered = false
    var mounts = 0
    var resume: CheckedContinuation<Void, Never>?
    func configure(available: Bool = true, verify: Bool = true, hold: Bool = false) {
        self.available = available; self.verify = verify; self.hold = hold
    }
    func capability() -> EngineCapability { .init(available: available, finderReadWrite: available, reason: "测试") }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { volume }
    func snapshot() -> VolumeSnapshot { volume }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { .clean }
    func mountReadWrite(_ volume: VolumeSnapshot) async -> URL {
        mounts += 1; entered = true
        if hold { await withCheckedContinuation { resume = $0 } }
        if verify { self.volume = manualVolume(volume.identity, state: .readWrite) }
        return URL(filePath: "/fixture-only")
    }
    func unmount(_ volume: VolumeSnapshot) {}
    func release() { resume?.resume(); resume = nil }
}

@MainActor struct ManualMountTests {
    private func controller(_ backend: ManualBackend) -> ManualMountController {
        .init(coordinator: MountCoordinator(engine: backend, resolver: backend, gate: DeviceOperationGate()), resolver: backend)
    }
    @Test func successRequiresSystemReadWriteState() async {
        let backend = ManualBackend()
        // Use the same real controller dependencies for discovery and mounting.
        let control = self.controller(backend)
        let volume = await backend.snapshot()
        await control.enable(volume)
        #expect(control.notice != nil && control.lastError == nil)
        #expect(control.activeDevices.isEmpty)
    }
    @Test func returnedMountPathAloneDoesNotClaimSuccess() async {
        let backend = ManualBackend(); await backend.configure(verify: false)
        let control = controller(backend)
        await control.enable(await backend.snapshot())
        #expect(control.notice == nil && control.lastError != nil)
        #expect(control.activeDevices.isEmpty)
        // No recovery implementation can confirm the simulated OS request
        // settled. The action finishing must not make the device available.
        #expect(control.isBusy(await backend.snapshot()))
    }
    @Test func unavailableEngineNeverStartsMount() async {
        let backend = ManualBackend(); await backend.configure(available: false)
        let control = controller(backend)
        await control.enable(await backend.snapshot())
        #expect(await backend.mounts == 0)
        #expect(control.notice == nil && control.lastError != nil)
    }
    @Test func duplicateClickCannotStartSecondMount() async {
        let backend = ManualBackend(); await backend.configure(hold: true)
        let control = controller(backend), volume = await backend.snapshot()
        let first = Task { await control.enable(volume) }
        while !(await backend.entered) { await Task.yield() }
        #expect(control.isBusy(volume))
        await control.enable(volume)
        #expect(await backend.mounts == 1)
        #expect(control.isBusy(volume))
        await backend.release(); await first.value
        #expect(!control.isBusy(volume))
    }
    @Test func alreadyWritableSelectionDoesNotRequestTakeover() async {
        let backend = ManualBackend()
        let volume = manualVolume((await backend.snapshot()).identity, state: .readWrite)
        let control = controller(backend)
        await control.enable(volume)
        #expect(await backend.mounts == 0)
        #expect(control.notice == nil && control.lastError != nil)
    }
    @Test func cancelBeforeStartDoesNotTouchEngine() async {
        let backend = ManualBackend()
        let volume = await backend.snapshot()
        let control = controller(backend)
        let operation = Task { await control.enable(volume) }
        operation.cancel(); await operation.value
        #expect(await backend.mounts == 0)
        #expect(control.notice == nil && control.activeDevices.isEmpty)
    }
}
