import Testing
import Foundation
@testable import VolisleCore

private func volume(safety: SafetyStatus = .clean, external: Bool = true, protected: Bool = false,
                    filesystem: String = "ntfs", identity: VolumeIdentity? = nil,
                    state: MountState = .unmounted, mountURL: URL? = nil) -> VolumeSnapshot {
    .init(identity: identity ?? .init(volumeUUID: "test-volume", mediaUUID: "test-media", devicePath: "test-device"),
          bsdName: "disk999s1", name: "测试替身", fileSystem: filesystem, deviceName: "测试设备",
          totalBytes: nil, availableBytes: nil, mountURL: mountURL, mountState: state,
          isExternal: external, isProtected: protected, safety: safety)
}
@Test func cleanExternalIsEligible() throws {
    let v = volume(); try WritePolicy.validate(expected: v.identity, current: v)
}
@Test func unknownSafetyMustFailClosed() {
    let v = volume(safety: .unknown)
    #expect(throws: VolumeError.safetyUnknown) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test(arguments: ["Windows 休眠", "dirty 标记", "日志异常"])
func risksRejectWrites(reason: String) {
    let v = volume(safety: .risk(reason))
    #expect(throws: VolumeError.unsafeVolume(reason)) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test func internalVolumeRejected() {
    let v = volume(external: false)
    #expect(throws: VolumeError.protectedVolume) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test func systemVolumeRejected() {
    let v = volume(protected: true)
    #expect(throws: VolumeError.protectedVolume) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test func reusedBSDNameDoesNotAuthorizeNewConnection() {
    let old = volume(), replacement = volume()
    #expect(old.bsdName == replacement.bsdName)
    #expect(throws: VolumeError.identityChanged) { try WritePolicy.validate(expected: old.identity, current: replacement) }
}
@Test func missingUUIDCannotPersistOrWrite() {
    let v = volume(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: ""))
    #expect(!v.identity.supportsPersistentPreference)
    #expect(throws: VolumeError.unstableIdentity) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test func APFSDoesNotRouteToNTFSEngine() {
    let v = volume(filesystem: "apfs")
    #expect(throws: VolumeError.unsupportedFileSystem) { try WritePolicy.validate(expected: v.identity, current: v) }
}
@Test func absentEngineNeverReturnsSuccess() async {
    let engine = UnavailableEngine(), v = volume()
    #expect(await engine.capability().available == false)
    await #expect(throws: VolumeError.engineUnavailable) { try await engine.mountReadWrite(v) }
    await #expect(throws: VolumeError.engineUnavailable) { try await engine.unmount(v) }
    let coordinator = MountCoordinator(engine: engine, resolver: FixedTestResolver(snapshot: v), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.engineUnavailable) { try await coordinator.enableReadWrite(expected: v.identity) }
}
private struct FixedTestResolver: VolumeResolver {
    let snapshot: VolumeSnapshot
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { snapshot }
}
private actor MutableTestResolver: VolumeResolver {
    var snapshots: [VolumeSnapshot]
    init(_ snapshots: [VolumeSnapshot]) { self.snapshots = snapshots }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { snapshots.removeFirst() }
}
private actor BlockingTestEngine: FileSystemAdapter {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "仅测试替身") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { volume.safety }
    func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        throw VolumeError.disconnected
    }
    func unmount(_ volume: VolumeSnapshot) throws { throw VolumeError.disconnected }
    func recoverFailedMount(_ volume: VolumeSnapshot) -> MountRecoveryDisposition { .settled }
    func release() { continuation?.resume(); continuation = nil }
}
@Test func siblingVolumesShareDeviceLockAndFailureReleasesIt() async {
    let engine = BlockingTestEngine(), first = volume(), sibling = volume()
    let coordinator = MountCoordinator(engine: engine, resolver: MutableTestResolver([first, first, sibling, first, volume(safety: .unknown, identity: first.identity)]), gate: DeviceOperationGate())
    let operation = Task { try await coordinator.enableReadWrite(expected: first.identity) }
    while !(await engine.entered) { await Task.yield() }
    await #expect(throws: VolumeError.busy) { try await coordinator.enableReadWrite(expected: sibling.identity) }
    await engine.release()
    await #expect(throws: VolumeError.disconnected) { try await operation.value }
    await #expect(throws: VolumeError.safetyUnknown) { try await coordinator.enableReadWrite(expected: first.identity) }
}
@MainActor @Test func diagnosticDoesNotIncludeSensitiveIdentifiers() {
    let discovery = DiskDiscovery()
    let result = discovery.diagnosticSummary()
    #expect(!result.contains("/Volumes/"))
    #expect(result.contains("未接入"))
    #expect(result.contains("不代表安全"))
}

@Test func replacementDuringSafetyInspectionCannotReachMount() async {
    let original = volume(), replacement = volume()
    let engine = BlockingTestEngine()
    let coordinator = MountCoordinator(engine: engine, resolver: MutableTestResolver([original, replacement]), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.identityChanged) { try await coordinator.enableReadWrite(expected: original.identity) }
    #expect(await engine.entered == false)
}

private actor InspectingTestEngine: FileSystemAdapter {
    let result: SafetyStatus
    var inspections = 0
    var mounts = 0
    init(result: SafetyStatus) { self.result = result }
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "仅测试") }
    func inspect(_ volume: VolumeSnapshot) -> SafetyStatus { inspections += 1; return result }
    func mountReadWrite(_ volume: VolumeSnapshot) -> URL { mounts += 1; return URL(fileURLWithPath: "/test-only-no-io") }
    func unmount(_ volume: VolumeSnapshot) {}
}

@Test func unknownDiscoveryCanReachEngineInspectionButNotBypassIt() async throws {
    let snapshot = volume(safety: .unknown)
    let engine = InspectingTestEngine(result: .clean)
    let mounted = volume(safety: .unknown, identity: snapshot.identity, state: .readWrite,
                         mountURL: URL(filePath: "/test-only-no-io"))
    let coordinator = MountCoordinator(engine: engine, resolver: MutableTestResolver([snapshot, snapshot, mounted]), gate: DeviceOperationGate())
    _ = try await coordinator.enableReadWrite(expected: snapshot.identity)
    #expect(await engine.inspections == 1)
    #expect(await engine.mounts == 1)
}

@Test func engineUnknownStillRejectsWrites() async {
    let snapshot = volume(safety: .unknown)
    let engine = InspectingTestEngine(result: .unknown)
    let coordinator = MountCoordinator(engine: engine, resolver: FixedTestResolver(snapshot: snapshot), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.safetyUnknown) { try await coordinator.enableReadWrite(expected: snapshot.identity) }
    #expect(await engine.inspections == 1)
    #expect(await engine.mounts == 0)
}

@Test func engineDetectedRiskNeverReachesMount() async {
    let snapshot = volume(safety: .unknown)
    let engine = InspectingTestEngine(result: .risk("Windows 休眠"))
    let coordinator = MountCoordinator(engine: engine, resolver: FixedTestResolver(snapshot: snapshot), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.unsafeVolume("Windows 休眠")) { try await coordinator.enableReadWrite(expected: snapshot.identity) }
    #expect(await engine.mounts == 0)
}

@Test func newlyObservedRiskOverridesEarlierCleanInspection() async {
    let snapshot = volume(safety: .unknown)
    let changed = volume(safety: .risk("新出现的风险"), identity: snapshot.identity)
    let engine = InspectingTestEngine(result: .clean)
    let coordinator = MountCoordinator(engine: engine, resolver: MutableTestResolver([snapshot, changed]), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.unsafeVolume("新出现的风险")) { try await coordinator.enableReadWrite(expected: snapshot.identity) }
    #expect(await engine.mounts == 0)
}

@Test func protectedTargetCannotReachEngineInspection() async {
    let snapshot = volume(safety: .unknown, protected: true)
    let engine = InspectingTestEngine(result: .clean)
    let coordinator = MountCoordinator(engine: engine, resolver: FixedTestResolver(snapshot: snapshot), gate: DeviceOperationGate())
    await #expect(throws: VolumeError.protectedVolume) { try await coordinator.enableReadWrite(expected: snapshot.identity) }
    #expect(await engine.inspections == 0)
    #expect(await engine.mounts == 0)
}
