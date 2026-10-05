import Foundation
import Testing
@testable import VolisleCore

@MainActor struct MountCycleClientTests {
    @Test func relaunchRetainsWritableClaimAndOffersExplicitReadOnlyRecovery() async throws {
        let store = ClientStore(), gate = DeviceOperationGate()
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096), purpose: .readWrite)
        let backend = ClientBackend(phase: .writeMounted)
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        #expect(client.canRecover && client.blocksActions)
        #expect(backend.actions == [.resolveWrite])
        #expect(store.value != nil)
        await client.recover()
        #expect(backend.actions == [.resolveWrite, .recover])
        #expect(store.value == nil && !client.blocksActions)
    }
    @Test func writableStartPersistsPurposeAndVerifiesMountBeforeClaimingSuccess() async throws {
        let backend = ClientBackend(phase: .writeMounted), store = ClientStore(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        #expect(backend.actions == [.latest, .startWrite])
        #expect(store.value?.purpose == .readWrite)
        #expect(client.isWritable(target) && client.blocksActions && client.canRecover)
        #expect(!client.needsAttention && client.lastError == nil)
        await client.recover()
        #expect(!client.isWritable(target) && store.value == nil && !client.blocksActions)
    }
    @Test func writableReplyWithMissingLiveMountCannotClaimSuccess() async {
        let backend = ClientBackend(phase: .writeMounted, verificationFails: true), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        #expect(!client.isWritable(target) && client.needsAttention && client.blocksActions)
        #expect(store.value != nil && client.canRecover)
    }
    @Test func writableLostReplyCannotBeResubmittedAsReadOnly() async {
        let backend = ClientBackend(startFailure: .timedOut), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        await client.start(target, resolver: ClientResolver(value: target))
        #expect(backend.actions == [.latest, .startWrite])
        #expect(store.value?.purpose == .readWrite && client.blocksActions)
    }
    @Test func openingFinderRechecksTheLiveMountAndRetainsRecoveryOnFailure() async throws {
        let backend = ClientBackend(phase: .writeMounted), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        #expect(client.isWritable(target))
        backend.verificationFails = true
        await #expect(throws: (any Error).self) { _ = try await client.verifiedWritableURL(for: target) }
        #expect(!client.isWritable(target) && client.canRecover && client.blocksActions)
    }
    @Test func readOnlyReplyCannotCompleteAWriteIntent() async {
        let backend = ClientBackend(), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        #expect(client.needsAttention && client.blocksActions && store.value != nil)
        #expect(!backend.verified)
    }
    @Test func ejectRequiresVerifiedRecoveryAndRetainsBarrierOnFailure() async throws {
        let backend = ClientBackend(phase: .writeMounted), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        backend.verificationFails = true
        await #expect(throws: (any Error).self) { try await client.prepareForEject(target) }
        #expect(client.blocksActions && store.value != nil)
        backend.verificationFails = false
        await client.refresh()
        // The mock's status remains mounted; exercise a successful recovery.
        try await client.prepareForEject(target)
        #expect(!client.blocksActions && store.value == nil && backend.verified)
    }
    @Test func refusedWriteReasonSurvivesLaterReconciliation() async {
        let backend = ClientBackend(), store = ClientStore()
        backend.failure = .ntfsDirty
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        await client.startWrite(target, resolver: ClientResolver(value: target))
        #expect(client.lastError == HelperDiskFailure.ntfsDirty.errorDescription && client.operation?.disk.bsdName == "disk7s1")
        // Periodic reconciliation sees the same finished operation.
        await client.refresh()
        #expect(client.lastError == HelperDiskFailure.ntfsDirty.errorDescription && client.operation?.disk.bsdName == "disk7s1")
        #expect(!client.blocksActions && !client.isBusy)
        // A later operation replaces the reason.
        backend.failure = nil
        await client.start(target, resolver: ClientResolver(value: target))
        #expect(client.lastError == nil)
    }
    @Test func refusalReasonIsRememberedAcrossRelaunchUntilALaterOperationSucceeds() async {
        // "Needs check" must stay discoverable after the app restarts, so the
        // window can keep offering "Check on This Mac…" for that disk.
        let backend = ClientBackend(), store = ClientStore()
        backend.failure = .ntfsDirty
        let first = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await first.refresh()
        let target = volume()
        await first.startWrite(target, resolver: ClientResolver(value: target))
        #expect(first.lastRefusal?.failure == .ntfsDirty && first.lastRefusal?.disk.bsdName == "disk7s1")
        let relaunched = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await relaunched.refresh()
        #expect(relaunched.lastRefusal?.failure == .ntfsDirty)
        backend.failure = nil
        await relaunched.start(target, resolver: ClientResolver(value: target))
        #expect(relaunched.lastRefusal == nil)
    }
    @Test func writeEndedBusyIsTransientSoTheCallerMayRetry() async {
        // A just-inserted disk still being mounted by macOS: the helper takes the
        // request, cannot open the device (EBUSY) and restores it unchanged.
        let backend = ClientBackend(), store = ClientStore()
        backend.failure = .busy
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        let target = volume()
        #expect(await client.startWrite(target, resolver: ClientResolver(value: target)) == false)
        #expect(!client.blocksActions && !client.isBusy && store.value == nil)
        // Any other refusal is final for the attempt.
        backend.failure = .ntfsDirty
        #expect(await client.startWrite(target, resolver: ClientResolver(value: target)) == true)
    }
    private func volume() -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb-test", mediaRegistryID: 123),
              bsdName: "disk7s1", name: "测试盘", fileSystem: "ntfs", deviceName: "USB",
              totalBytes: 4096, availableBytes: nil, mountURL: URL(filePath: "/Volumes/test"), mountState: .readOnly,
              isExternal: true, isProtected: false)
    }
    @Test func successfulCheckClearsIntentOnlyAfterLiveRestorationVerification() async throws {
        let backend = ClientBackend(), store = ClientStore(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        #expect(gate.isBusy("usb-test"))
        await client.refresh()
        #expect(!gate.isBusy("usb-test"))
        let target = volume()
        await client.start(target, resolver: ClientResolver(value: target))
        #expect(client.notice != nil)
        #expect(client.lastError == nil)
        #expect(store.value == nil)
        #expect(!gate.isBusy("usb-test"))
        #expect(backend.verified)
    }
    @Test func lostStartReplyRetainsIntentAndBlocksOtherDeviceOperations() async {
        let backend = ClientBackend(startFailure: .timedOut), store = ClientStore(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        let target = volume(); await client.start(target, resolver: ClientResolver(value: target))
        #expect(store.value != nil)
        #expect(client.needsAttention)
        #expect(gate.isBusy("usb-test"))
        #expect(throws: VolumeError.busy) { _ = try gate.acquire("another-device") }
        #expect(client.notice == nil)
    }
    @Test func relaunchQueriesSavedIDWithoutRepeatingStartOrRecovery() async throws {
        let store = ClientStore()
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        let backend = ClientBackend(phase: .needsRecovery)
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        #expect(client.needsAttention)
        #expect(backend.actions == [.resolve])
        #expect(backend.ids == [store.value?.id])
        #expect(store.value != nil)
        await client.recover()
        #expect(backend.actions == [.resolve, .recover])
        #expect(store.value == nil)
    }
    @Test func finishedReplyWithWrongLiveMountCannotUnlockOrReportSuccess() async {
        let backend = ClientBackend(verificationFails: true), store = ClientStore(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        let target = volume(); await client.start(target, resolver: ClientResolver(value: target))
        #expect(client.needsAttention)
        #expect(client.notice == nil)
        #expect(store.value != nil)
        #expect(gate.isBusy("usb-test"))
    }
    @Test func definitivePermissionRejectionDoesNotLeaveAnUnstartedDiskLocked() async {
        let backend = ClientBackend(permissionDenied: true), store = ClientStore(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        let target = volume(); await client.start(target, resolver: ClientResolver(value: target))
        #expect(client.lastError != nil)
        #expect(store.value == nil)
        #expect(!gate.isBusy("usb-test"))
        #expect(!backend.verified)
    }
    @Test func anotherOperationsReplyCannotClearTheLocalPendingIntent() async throws {
        let store = ClientStore()
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        let backend = ClientBackend(wrongID: true), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        #expect(client.needsAttention)
        #expect(store.value != nil)
        #expect(gate.isBusy("usb-test"))
        #expect(!backend.verified)
    }
    @Test func rejectionFollowedByUnavailableStatusDoesNotUnlockUnknownBackgroundWork() async {
        let backend = ClientBackend(permissionDenied: true, failSecondLatest: true)
        let client = MountCycleClient(backend: backend, store: ClientStore(), gate: DeviceOperationGate())
        await client.refresh()
        let target = volume(); await client.start(target, resolver: ClientResolver(value: target))
        #expect(client.needsAttention)
        #expect(client.blocksActions)
    }
    @Test func changedConnectionBeforeSubmissionNeverCreatesIntentOrStartsWork() async {
        let backend = ClientBackend(), store = ClientStore()
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        await client.start(volume(), resolver: ClientResolver(value: volume()))
        #expect(store.value == nil)
        #expect(backend.actions == [.latest])
        #expect(!client.blocksActions)
    }
    @Test func fileIntentSurvivesRelaunchAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileMountCycleIntentStore(directory: directory)
        let value = MountCycleIntent(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        try first.save(value)
        let second = FileMountCycleIntentStore(directory: directory)
        #expect(try second.load() == value)
        try second.clear()
        #expect(try first.load() == nil)
        let target = directory.appendingPathComponent("original")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("pending-readonly-check.json"), withDestinationURL: target)
        #expect(throws: (any Error).self) { _ = try first.load() }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
    @Test func verifiedRemovalClearsFinishedIntentWithoutClaimingDiskIsMounted() async throws {
        let store = ClientStore()
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        let client = MountCycleClient(backend: ClientBackend(originalGone: true), store: store, gate: DeviceOperationGate())
        await client.refresh()
        #expect(store.value == nil)
        #expect(!client.blocksActions)
        #expect(client.verifiedState == .disconnected)
    }
    @Test func backgroundUncertaintyDoesNotCreatePerDiskMountRecoveryActions() async {
        let store = ClientStore(); store.broken = true
        let gate = DeviceOperationGate()
        let client = MountCycleClient(backend: ClientBackend(), store: store, gate: gate)
        await client.refresh()
        #expect(client.needsAttention)
        #expect(gate.isBusy("unrelated-device"))
        #expect(!gate.requiresVerification("unrelated-device"))
    }
    @Test func lostRequestClearsOnlyAfterFenceAndCurrentOperationReconciliation() async throws {
        let store = ClientStore(), backend = ClientBackend(resolvedMissing: true)
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096), purpose: .readWrite)
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        #expect(backend.actions == [.resolveWrite, .latest])
        #expect(store.value == nil && !client.blocksActions)
        #expect(client.verifiedState == nil && !backend.verified)
        #expect(client.notice != nil)
    }
    @Test func lostFenceReplyRetainsIntentAndRetryNeverRepeatsStart() async throws {
        let store = ClientStore(), backend = ClientBackend(resolvedMissing: true)
        let saved = MountCycleIntent(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        store.value = saved; backend.resolutionFailure = .timedOut
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        #expect(store.value == saved && client.blocksActions && client.needsAttention)
        backend.resolutionFailure = nil
        await client.refresh()
        #expect(backend.actions == [.resolve, .resolve, .latest])
        #expect(store.value == nil && !client.blocksActions)
    }
    @Test func fencedRequestStillBlocksWhenLatestOperationIsUnavailable() async throws {
        let store = ClientStore(), backend = ClientBackend(resolvedMissing: true)
        store.value = .init(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096))
        backend.latestUnavailable = true
        let client = MountCycleClient(backend: backend, store: store, gate: DeviceOperationGate())
        await client.refresh()
        #expect(store.value == nil && client.blocksActions && client.needsAttention)
        #expect(client.notice == nil)
        backend.latestUnavailable = false
        await client.refresh()
        #expect(!client.blocksActions)
    }
    @Test func corruptLocalIntentCannotBeIgnoredOnStartup() async {
        let store = ClientStore(); store.broken = true
        let backend = ClientBackend(), gate = DeviceOperationGate()
        let client = MountCycleClient(backend: backend, store: store, gate: gate)
        await client.refresh()
        #expect(client.needsAttention)
        #expect(gate.isBusy("usb-test"))
        #expect(backend.actions.isEmpty)
    }
}

@MainActor private final class ClientStore: MountCycleIntentStore {
    var value: MountCycleIntent?
    var broken = false
    func load() throws -> MountCycleIntent? { if broken { throw HelperServiceError.invalidReply }; return value }
    func save(_ value: MountCycleIntent) throws { self.value = value }
    func clear() throws { value = nil }
}
private struct ClientResolver: VolumeResolver {
    let value: VolumeSnapshot
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { value }
}
@MainActor private final class ClientBackend: MountCycleClientBackend {
    let startFailure: HelperServiceError?
    var verificationFails: Bool
    let permissionDenied: Bool
    let wrongID: Bool
    let failSecondLatest: Bool
    let originalGone: Bool
    let phase: HelperMountPhase
    let resolvedMissing: Bool
    var resolutionFailure: HelperServiceError?
    var latestUnavailable = false
    /// Records finish with this failure (a refused write), and `.latest` returns the last record.
    var failure: HelperDiskFailure?
    private var last: HelperMountOperation?
    var verified = false
    var actions: [HelperMountCommand.Action] = []
    var ids: [UUID?] = []
    init(startFailure: HelperServiceError? = nil, phase: HelperMountPhase = .finished,
         verificationFails: Bool = false, permissionDenied: Bool = false, wrongID: Bool = false, failSecondLatest: Bool = false, originalGone: Bool = false, resolvedMissing: Bool = false) {
        self.resolvedMissing = resolvedMissing
        self.startFailure = startFailure; self.phase = phase; self.verificationFails = verificationFails
        self.permissionDenied = permissionDenied; self.wrongID = wrongID; self.failSecondLatest = failSecondLatest; self.originalGone = originalGone
    }
    func prepare(_ volume: VolumeSnapshot) throws -> HelperDiskRequest {
        try .init(bsdName: volume.bsdName, registryID: volume.identity.mediaRegistryID!, byteCount: 4096)
    }
    func send(_ command: HelperMountCommand) async throws -> HelperMountOperation? {
        actions.append(command.action); ids.append(command.id)
        if [.resolve, .resolveWrite].contains(command.action) {
            if let resolutionFailure { throw resolutionFailure }
            if resolvedMissing { return nil }
        }
        if command.action == .latest {
            if latestUnavailable { throw HelperServiceError.unavailable }
            if failSecondLatest && actions.filter({ $0 == .latest }).count > 1 { throw HelperServiceError.unavailable }
            return failure == nil ? nil : last
        }
        if command.action == .start || command.action == .startWrite {
            if let startFailure { throw startFailure }
            if permissionDenied { throw HelperDiskFailure.permissionDenied }
        }
        let disk = try HelperDiskRequest(bsdName: "disk7s1", registryID: 123, byteCount: 4096)
        var record = HelperMountOperation(id: wrongID ? UUID() : command.id!, disk: disk, ownerUID: 501, bootSession: "test-boot",
            phase: command.action == .recover ? .finished : phase, restoreRequired: true,
            report: .init(version: 1, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: 4096,
                bootSHA256: String(repeating: "a", count: 64), effectiveUID: 0,
                writeAccessAvailable: false, fileSystemHealthChecked: false))
        if phase == .writeMounted { record.purpose = .readWrite }
        if let failure { record.purpose = .readWrite; record.failure = failure; last = record }
        return record
    }
    func verifyWritable(_ record: HelperMountOperation) throws -> URL {
        if verificationFails { throw HelperDiskFailure.busy }
        return URL(filePath: "/private/var/run/volisle-write-mounts/" + record.id.uuidString.lowercased())
    }
    func verifyRestored(_ record: HelperMountOperation) throws -> MountCycleVerifiedState {
        if verificationFails { throw HelperDiskFailure.busy }
        verified = true
        return originalGone ? .disconnected : .readOnly
    }
    func waitForUpdate() async throws { }
}
