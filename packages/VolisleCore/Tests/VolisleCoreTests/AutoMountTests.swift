import Foundation
import Testing
@testable import VolisleCore

private func autoVolume(identity: VolumeIdentity? = nil, state: MountState = .readOnly, fileSystem: String = "ntfs") -> VolumeSnapshot {
    .init(identity: identity ?? .init(volumeUUID: "test-volume", mediaUUID: "test-media", devicePath: "test-device"),
          bsdName: "disk999s1", name: "测试", fileSystem: fileSystem, deviceName: "测试设备", totalBytes: nil, availableBytes: nil,
          mountURL: state == .unmounted ? nil : URL(filePath: "/test-only"), mountState: state, isExternal: true, isProtected: false)
}
private actor AutoResolver: VolumeResolver {
    var volume: VolumeSnapshot
    init(_ volume: VolumeSnapshot) { self.volume = volume }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { volume }
    func replace(_ volume: VolumeSnapshot) { self.volume = volume }
}
private actor AutoEngine: FileSystemAdapter {
    var available: Bool
    let fail: Bool
    var holdInspection: Bool
    var inspections = 0
    var mounts = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(available: Bool = true, fail: Bool = false, hold: Bool = false) {
        self.available = available; self.fail = fail; self.holdInspection = hold
    }
    func capability() -> EngineCapability { .init(available: available, finderReadWrite: available, reason: "仅测试替身") }
    func becomeAvailable() { available = true }
    func inspect(_ volume: VolumeSnapshot) async -> SafetyStatus {
        inspections += 1
        if holdInspection { await withCheckedContinuation { continuation = $0 } }
        return .clean
    }
    func mountReadWrite(_ volume: VolumeSnapshot) throws -> URL {
        mounts += 1
        if fail { throw VolumeError.disconnected }
        return URL(filePath: "/test-only-no-io")
    }
    func unmount(_ volume: VolumeSnapshot) {}
    // This boundary performs no OS work; acknowledgement is synchronous.
    func recoverFailedMount(_ volume: VolumeSnapshot) -> MountRecoveryDisposition { .settled }
    func release() { holdInspection = false; continuation?.resume(); continuation = nil }
}
@MainActor private func waitForCompletion(_ controller: AutoMountController) async throws {
    for _ in 0..<10_000 {
        if controller.activeConnections.isEmpty { return }
        await Task.yield()
    }
    throw VolumeError.busy
}
@MainActor private func waitForInspection(_ engine: AutoEngine) async throws {
    for _ in 0..<10_000 {
        if await engine.continuation != nil { return }
        await Task.yield()
    }
    throw VolumeError.busy
}
@MainActor struct AutoMountTests {
    @Test func aCopyRequestReopensOnlyItsDiskWithAutomaticWritingOff() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(false)
        let volume = autoVolume(), engine = AutoEngine(), request = UUID()
        let other = autoVolume(identity: .init(volumeUUID: "other", mediaUUID: "other", devicePath: "other"))
        var mounted: [UUID] = []
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { mounted.append($0.identity.connection) })
        control.writeRequest = { $0.identity == volume.identity ? request : nil }
        control.reconcile([volume, other]); try await waitForCompletion(control)
        #expect(mounted == [volume.identity.connection])
        #expect(!AutoMountPreferences(defaults: defaults).automaticEnabled)
        control.reconcile([volume, other]); try await waitForCompletion(control)
        #expect(mounted.count == 1, "a real attempt is not retried by duplicate notifications")
    }
    @Test func anExplicitNewCopyRequestGetsOneNewAttemptOnTheSameConnection() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(false)
        let volume = autoVolume(), engine = AutoEngine()
        var request = UUID(), calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; throw AutoMountReported() })
        control.writeRequest = { _ in request }
        control.reconcile([volume]); try await waitForCompletion(control)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1)
        request = UUID()  // another explicit Continue/Retry, not another notification
        control.reconcile([volume]); try await waitForCompletion(control)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 2 && !prefs.automaticEnabled)
    }
    @Test func withdrawingACopyRequestCancelsInspection() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(hold: true)
        var request: UUID? = UUID()
        let control = controller(prefs, engine, AutoResolver(volume))
        control.writeRequest = { _ in request }
        control.reconcile([volume]); try await waitForInspection(engine)
        request = nil; control.reconcile([volume])
        await engine.release(); try await waitForCompletion(control)
        #expect(await engine.mounts == 0)
    }
    @Test func aCopyRequestDoesNotOverrideDuplicateVolumeIdentity() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), duplicate = autoVolume(), engine = AutoEngine()
        let control = controller(prefs, engine, AutoResolver(volume))
        let request = UUID(); control.writeRequest = { _ in request }
        control.reconcile([volume, duplicate]); try await waitForCompletion(control)
        #expect(await engine.inspections == 0)
        #expect(await engine.mounts == 0)
    }
    @Test func aCopyOnNTFSWithoutAVolumeUUIDCanRequestItsNewConnection() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(false)
        let volume = autoVolume(identity: .init(volumeUUID: nil, mediaUUID: "partition-guid", devicePath: "usb-port", mediaRegistryID: 42))
        let engine = AutoEngine(), request = UUID()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 })
        control.writeRequest = { $0.identity.resumeKey == "media:partition-guid" ? request : nil }
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1 && !prefs.automaticEnabled)
        let duplicate = autoVolume(identity: .init(volumeUUID: nil, mediaUUID: "partition-guid", devicePath: "usb-other", mediaRegistryID: 43))
        control.reconcile([])
        control.reconcile([volume, duplicate]); try await waitForCompletion(control)
        #expect(calls == 1, "matching resume keys on two partitions must not grant task access")
    }
    @Test func dailyDefaultAndExplicitPausePersistWithoutPerDiskSetup() throws {
        let (_, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let prefs = AutoMountPreferences(defaults: defaults, defaultAutomatic: true)
        let volume = autoVolume()
        #expect(prefs.automaticEnabled && prefs.isEnabled(volume.identity))
        try prefs.setAutomaticEnabled(false)
        #expect(!AutoMountPreferences(defaults: defaults, defaultAutomatic: true).isEnabled(volume.identity))
        try prefs.setAutomaticEnabled(true)
        #expect(AutoMountPreferences(defaults: defaults).automaticEnabled)
        for data in [Data("bad".utf8), Data("{\"version\":99,\"automatic\":true,\"enabled\":[]}".utf8)] {
            defaults.set(data, forKey: "volisle.autoMount.v2")
            let corrupt = AutoMountPreferences(defaults: defaults, defaultAutomatic: true)
            #expect(corrupt.loadFailed && !corrupt.isEnabled(volume.identity))
        }
    }
    @Test func globalPauseCancelsInspectionWithoutChangingMountedVolumes() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine(hold: true)
        let control = controller(prefs, engine, AutoResolver(volume))
        control.reconcile([volume]); try await waitForInspection(engine)
        try prefs.setAutomaticEnabled(false); control.reconcile([volume])
        await engine.release(); try await waitForCompletion(control)
        #expect(await engine.mounts == 0)
    }
    @Test func helperQueueWaitsForReadinessWithoutConsumingSecondDisk() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let first = autoVolume()
        let second = autoVolume(identity: .init(volumeUUID: "second", mediaUUID: "second", devicePath: "second"))
        let engine = AutoEngine()
        var ready = true, calls: [UUID] = []
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(first), gate: DeviceOperationGate()),
            helperEnable: { volume in calls.append(volume.identity.connection); ready = false }, helperReady: { ready })
        control.reconcile([first, second]); try await waitForCompletion(control)
        #expect(calls == [first.identity.connection])
        control.reconcile([first, second]); try await waitForCompletion(control)
        #expect(calls.count == 1)
        ready = true; control.reconcile([first, second]); try await waitForCompletion(control)
        #expect(calls == [first.identity.connection, second.identity.connection])
    }
    @Test func firstSetupWaitsForHelperBeforeAttemptingExistingDisk() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var ready = false, calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 }, helperReady: { ready })
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 0)
        ready = true; control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1)
    }
    @Test func deferredHelperStartDoesNotConsumeTheConnectionAttempt() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0, deferNext = true
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; if deferNext { deferNext = false; throw AutoMountDeferred() } },
            deferralDelay: .milliseconds(20))
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1 && control.lastError == nil)
        for _ in 0..<100 where calls < 2 { try await Task.sleep(for: .milliseconds(5)) }  // delayed retry
        try await waitForCompletion(control)
        #expect(calls == 2)
        control.reconcile([volume]); try await waitForCompletion(control)   // a real attempt is still single
        #expect(calls == 2)
    }
    @Test("刚插入、系统还没挂上的盘先等系统只读挂载；挂上后立即开始")
    func justInsertedDiskWaitsForTheSystemMount() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let unmounted = autoVolume(state: .unmounted), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(unmounted), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 }, automountGrace: .seconds(30))
        control.reconcile([unmounted]); try await waitForCompletion(control)
        #expect(calls == 0, "系统的只读挂载还在进行时不开始")
        control.reconcile([autoVolume(state: .readOnly)]); try await waitForCompletion(control)
        #expect(calls == 1, "挂上后立即开始")
    }
    @Test("系统一直没有挂上的盘，等待期过后照常开始")
    func diskTheSystemNeverMountsStartsAfterTheGrace() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let unmounted = autoVolume(state: .unmounted), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(unmounted), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 }, automountGrace: .milliseconds(30))
        control.reconcile([unmounted]); try await waitForCompletion(control)
        #expect(calls == 0)
        for _ in 0..<200 where calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await waitForCompletion(control)
        #expect(calls == 1)
    }
    @Test func reportedFailureSpendsTheAttemptWithoutASecondMessage() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; throw AutoMountReported() }, deferralDelay: .milliseconds(5))
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1 && control.lastError == nil)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1, "no automatic retry for the same connection")
    }
    @Test func busyDiskIsRetriedAutomaticallyButBounded() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; throw AutoMountDeferred() }, deferralDelay: .milliseconds(5))
        control.reconcile([volume])
        for _ in 0..<200 where calls < 7 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 7)  // first try plus six delayed retries, then it stops
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 7)
    }
    @Test func stateChangesDuringTheDelayDoNotSpendRetries() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; throw AutoMountDeferred() }, deferralDelay: .seconds(30))
        control.reconcile([volume])
        for _ in 0..<100 where calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { control.reconcile([volume]); try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 1)
    }
    @Test func busyDiskSucceedsOnADelayedRetry() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; if calls < 3 { throw AutoMountDeferred() } }, deferralDelay: .milliseconds(5))
        control.reconcile([volume])
        for _ in 0..<200 where calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 3 && control.lastError == nil)
    }
    @Test func delayedRetryWaitsOutABackgroundThatIsNotReadyYet() async throws {
        // The retry wakes while the background is still busy (e.g. reconciling
        // the unplugged session); nothing else changes afterwards. It must try again.
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0, ready = true
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; if calls == 1 { ready = false; throw AutoMountDeferred() } },
            helperReady: { ready }, deferralDelay: .milliseconds(5))
        control.reconcile([volume])
        for _ in 0..<200 where calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(40))   // several retry wake-ups while not ready
        ready = true                                   // no reconcile from outside
        for _ in 0..<200 where calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 2 && control.lastError == nil)
    }
    @Test func failedHelperStartStillConsumesTheConnectionAttempt() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let volume = autoVolume(), engine = AutoEngine()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1; throw VolumeError.unsafeVolume("dirty") })
        control.reconcile([volume]); try await waitForCompletion(control)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1 && control.lastError != nil)
    }
    @Test func globalModeDoesNotTakeOverNonNTFSWritableOrAmbiguousDisks() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try prefs.setAutomaticEnabled(true)
        let engine = AutoEngine(), volume = autoVolume()
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: AutoResolver(volume), gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 })
        for volumes in [[autoVolume(fileSystem: "apfs")], [autoVolume(state: .readWrite)], [volume, autoVolume()],
                        [autoVolume(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"))]] {
            control.reconcile(volumes); try await waitForCompletion(control)
        }
        #expect(calls == 0)
    }
    @Test func globalPreferenceIncludesNewUUIDlessUSBConnection() async throws {
        let (_, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("{\"version\":2,\"automatic\":true,\"enabled\":[]}".utf8), forKey: "volisle.autoMount.v2")
        let prefs = AutoMountPreferences(defaults: defaults)
        let volume = autoVolume(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb-port", mediaRegistryID: 42))
        let engine = AutoEngine(), resolver = AutoResolver(volume)
        var calls = 0
        let control = AutoMountController(preferences: prefs, engine: engine,
            coordinator: MountCoordinator(engine: engine, resolver: resolver, gate: DeviceOperationGate()),
            helperEnable: { _ in calls += 1 })
        #expect(prefs.isEnabled(volume.identity))
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(calls == 1)
    }
    @Test func unavailableCapabilityDoesNotConsumeConnectionAttempt() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(available: false), resolver = AutoResolver(autoVolume())
        await resolver.replace(volume)
        try prefs.setEnabled(true, for: volume)
        let control = controller(prefs, engine, resolver)
        control.reconcile([volume]); try await waitForCompletion(control)
        await engine.becomeAvailable()
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(await engine.mounts == 1)
    }
    private func preferences() -> (AutoMountPreferences, UserDefaults, String) {
        let name = "VolisleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (AutoMountPreferences(defaults: defaults), defaults, name)
    }
    private func controller(_ prefs: AutoMountPreferences, _ engine: AutoEngine, _ resolver: AutoResolver) -> AutoMountController {
        AutoMountController(preferences: prefs, engine: engine,
                            coordinator: MountCoordinator(engine: engine, resolver: resolver, gate: DeviceOperationGate()))
    }
    @Test func preferencesDefaultOffAndPersistExplicitOptIn() throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume()
        #expect(!prefs.isEnabled(volume.identity))
        try prefs.setEnabled(true, for: volume)
        #expect(AutoMountPreferences(defaults: defaults).isEnabled(volume.identity))
        try prefs.setEnabled(false, for: volume)
        #expect(!AutoMountPreferences(defaults: defaults).isEnabled(volume.identity))
    }
    @Test func corruptOrFuturePreferencesNeverEnableWrites() {
        let (_, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        for data in [Data("bad".utf8), Data("{\"version\":99,\"enabled\":[]}".utf8)] {
            defaults.set(data, forKey: "volisle.autoMount.v1")
            let prefs = AutoMountPreferences(defaults: defaults)
            #expect(prefs.enabled.isEmpty && prefs.loadFailed)
        }
    }
    @Test func noOptInNeverInspectsOrMounts() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(), resolver = AutoResolver(autoVolume())
        let control = controller(prefs, engine, resolver)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(await engine.inspections == 0)
        #expect(await engine.mounts == 0)
    }
    @Test func unavailableEngineCannotBeEnabledOrUsed() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(available: false), resolver = AutoResolver(autoVolume())
        let control = controller(prefs, engine, resolver); control.reconcile([volume])
        await #expect(throws: VolumeError.engineUnavailable) { try await control.setEnabled(true, for: volume) }
        try prefs.setEnabled(true, for: volume) // persisted preference from a formerly available engine
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(await engine.inspections == 0)
        #expect(await engine.mounts == 0)
    }
    @Test func failureDoesNotRetryUntilNewConnection() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(fail: true), resolver = AutoResolver(autoVolume())
        await resolver.replace(volume)
        let control = controller(prefs, engine, resolver); control.reconcile([volume])
        try await control.setEnabled(true, for: volume); try await waitForCompletion(control)
        #expect(await engine.mounts == 1)
        #expect(control.lastError == VolumeError.disconnected.localizedDescription)
        control.reconcile([volume]); try await waitForCompletion(control)
        #expect(await engine.mounts == 1)
        control.reconcile([])
        let reconnected = autoVolume(); await resolver.replace(reconnected)
        control.reconcile([reconnected]); try await waitForCompletion(control)
        #expect(await engine.mounts == 2)
    }
    @Test func duplicatePersistentIdentityAndWritableVolumeAreSkipped() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), duplicate = autoVolume(), engine = AutoEngine()
        try prefs.setEnabled(true, for: volume)
        let control = controller(prefs, engine, AutoResolver(volume))
        control.reconcile([volume, duplicate]); try await waitForCompletion(control)
        #expect(await engine.inspections == 0)
        control.reconcile([autoVolume(identity: volume.identity, state: .readWrite)])
        try await waitForCompletion(control)
        #expect(await engine.mounts == 0)
    }
    @Test func disablingDuringInspectionPreventsMount() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(hold: true)
        try prefs.setEnabled(true, for: volume)
        let control = controller(prefs, engine, AutoResolver(volume))
        control.reconcile([volume]); try await waitForInspection(engine)
        try await control.setEnabled(false, for: volume)
        await engine.release(); try await waitForCompletion(control)
        #expect(await engine.mounts == 0)
        #expect(control.lastError == nil)
    }
    @Test func disconnectOrDuplicateDuringInspectionPreventsMount() async throws {
        for duplicate in [false, true] {
            let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
            let volume = autoVolume(), engine = AutoEngine(hold: true)
            try prefs.setEnabled(true, for: volume)
            let control = controller(prefs, engine, AutoResolver(volume))
            control.reconcile([volume]); try await waitForInspection(engine)
            control.reconcile(duplicate ? [volume, autoVolume()] : [])
            await engine.release(); try await waitForCompletion(control)
            #expect(await engine.mounts == 0)
        }
    }
    @Test func becomingWritableDuringInspectionPreventsTakeover() async throws {
        let (prefs, defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let volume = autoVolume(), engine = AutoEngine(hold: true), resolver = AutoResolver(autoVolume())
        await resolver.replace(volume)
        try prefs.setEnabled(true, for: volume)
        let control = controller(prefs, engine, resolver)
        control.reconcile([volume]); try await waitForInspection(engine)
        await resolver.replace(autoVolume(identity: volume.identity, state: .readWrite))
        await engine.release(); try await waitForCompletion(control)
        #expect(await engine.mounts == 0)
        #expect(control.lastError == VolumeError.busy.localizedDescription)
    }
}

struct MediaIdentityTests {
    @Test func mbrPreferenceSurvivesPortAndConnectionChangesWithoutRawSerial() throws {
        let serial = "Example-USB-1234"
        let fingerprint = try #require(MediaFingerprint.usb(serial: serial, vendor: 3010, product: 8986, offset: 32768, size: 2_000_396_321_280))
        let first = VolumeIdentity(volumeUUID: "V", mediaUUID: nil, devicePath: "port-a", mediaRegistryID: 100, mediaFingerprint: fingerprint)
        let next = VolumeIdentity(volumeUUID: "V", mediaUUID: nil, devicePath: "port-b", mediaRegistryID: 101, mediaFingerprint: fingerprint)
        #expect(first.supportsCurrentOperation && first.supportsPersistentPreference)
        #expect(first != next && first.persistentKey == next.persistentKey)
        let stored = String(decoding: try JSONEncoder().encode(first.persistentKey), as: UTF8.self)
        #expect(!stored.contains(serial) && !stored.contains("port-a"))
        #expect(throws: VolumeError.identityChanged) { try WritePolicy.validateTarget(expected: first, current: autoVolume(identity: next)) }
    }
    @Test func mbrWithoutSerialAllowsCurrentConnectionButNotPersistentOptIn() {
        let identity = VolumeIdentity(volumeUUID: "V", mediaUUID: nil, devicePath: "port-a", mediaRegistryID: 100)
        #expect(identity.supportsCurrentOperation && !identity.supportsPersistentPreference)
        #expect(!VolumeIdentity(volumeUUID: "V", mediaUUID: nil, devicePath: "port-a").supportsCurrentOperation)
        #expect(!VolumeIdentity(volumeUUID: " ", mediaUUID: "M", devicePath: "port-a").supportsCurrentOperation)
    }
    @Test func unknownSerialAndChangedPartitionCannotReuseFingerprint() {
        for serial in ["", "unknown", "00000000", "1234567890", "AA\nBB"] {
            #expect(MediaFingerprint.usb(serial: serial, vendor: 1, product: 2, offset: 512, size: 1024) == nil)
        }
        let first = MediaFingerprint.usb(serial: "ABCD1234", vendor: 1, product: 2, offset: 512, size: 1024)
        #expect(first != MediaFingerprint.usb(serial: "ABCD1234", vendor: 1, product: 2, offset: 1024, size: 1024))
        #expect(first != MediaFingerprint.usb(serial: "ABCD1234", vendor: 1, product: 2, offset: 512, size: 2048))
        #expect(first != MediaFingerprint.usb(serial: "OTHER1234", vendor: 1, product: 2, offset: 512, size: 1024))
    }
    @Test func unrelatedFilesystemCannotPassSubstringMatch() {
        #expect(!autoVolume(fileSystem: "not-ntfs").isNTFS)
        #expect(autoVolume(fileSystem: "NTFS").isNTFS)
    }
}
