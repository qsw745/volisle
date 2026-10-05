import Foundation
import Testing
@testable import VolisleCore

struct HelperWriteLifecycleTests {
    private func journal() throws -> HelperMountJournal {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return try HelperMountJournal(directory: dir)
    }
    private func disk() throws -> HelperDiskRequest { try .init(bsdName: "disk999s1", registryID: 910, byteCount: 67108864) }
    private func wait(_ service: HelperMountCycleService, id: UUID) async throws -> HelperMountOperation {
        for _ in 0..<400 {
            let record = try await service.status(id: id, uid: 501)
            if !record.phase.running { return record }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HelperServiceError.timedOut
    }
    @Test func pendingPreparationCannotBeReportedAsNoBackgroundWork() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal)
        await backend.holdNextPreparation()
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let id = UUID(), target = try disk()
        let start = Task { try await service.startWrite(id: id, disk: target, uid: 501) }
        for _ in 0..<400 {
            if await backend.preparing { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await backend.preparing)
        await #expect(throws: (any Error).self) { _ = try await service.latest(uid: 501) }
        await backend.releasePreparation()
        _ = try await start.value
        _ = try await wait(service, id: id)
        _ = try await service.recover(id: id, uid: 501)
        _ = try await wait(service, id: id)
    }
    @Test func writableOwnershipPersistsAndPreventsNewOperationsAndRemoval() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let id = UUID()
        _ = try await service.startWrite(id: id, disk: disk(), uid: 501)
        let record = try await wait(service, id: id)
        #expect(record.phase == .writeMounted)
        #expect(record.isWrite)
        #expect(try journal.read() == record)
        #expect(await backend.state == .readWrite)
        await #expect(throws: (any Error).self) { try await service.quiesce() }
        await #expect(throws: (any Error).self) { _ = try await service.start(id: UUID(), disk: disk(), uid: 501) }
        await #expect(throws: (any Error).self) { _ = try await service.startWrite(id: UUID(), disk: disk(), uid: 502) }
        _ = try await service.startWrite(id: id, disk: disk(), uid: 501)
        #expect(await backend.writeCount == 1)
        await #expect(throws: (any Error).self) { _ = try await service.start(id: id, disk: disk(), uid: 501) }
        await #expect(throws: (any Error).self) { _ = try await service.recover(id: id, uid: 502) }
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await wait(service, id: id).phase == .finished)
        #expect(await backend.state == .readOnly)
        try await service.quiesce()
    }
    @Test func restartKeepsWritableClaimUntilExplicitOriginalRecovery() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal)
        let id = UUID()
        let original = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        _ = try await original.startWrite(id: id, disk: disk(), uid: 501)
        _ = try await wait(original, id: id)
        let restarted = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let pending = try await restarted.status(id: id, uid: 501)
        #expect(pending.phase == .needsRecovery && pending.isWrite)
        #expect(await backend.state == .readWrite)
        #expect(await backend.restoreWriteCount == 0)
        _ = try await restarted.recover(id: id, uid: 501)
        #expect(try await wait(restarted, id: id).phase == .finished)
        #expect(await backend.writeCount == 1)
        #expect(await backend.restoredID == id)
    }
    @Test func writableMountFailureAlwaysEntersWriteAwareRecovery() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal, failAfterMount: true)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let id = UUID(); _ = try await service.startWrite(id: id, disk: disk(), uid: 501)
        let result = try await wait(service, id: id)
        #expect(result.phase == .finished && result.failure != nil)
        #expect(await backend.state == .readOnly)
        #expect(await backend.restoreWriteCount == 1)
    }
    @Test func unresolvedWritableUnmountRetainsClaimAcrossRetry() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal, failRestore: true)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let id = UUID(); _ = try await service.startWrite(id: id, disk: disk(), uid: 501)
        _ = try await wait(service, id: id)
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await wait(service, id: id).phase == .needsRecovery)
        #expect(try journal.read()?.recoveryFailure == .busy)
        #expect(try journal.read()?.isWrite == true)
        await backend.allowRestore()
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await wait(service, id: id).phase == .finished)
        #expect(await backend.state == .readOnly)
        #expect(try journal.read()?.recoveryFailure == nil)
        #expect(try journal.read()?.failure == nil)
    }
    @Test func previousBootNeverClosesReusedDevice() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal)
        let id = UUID(); let original = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "old")
        _ = try await original.startWrite(id: id, disk: disk(), uid: 501)
        _ = try await wait(original, id: id)
        let restarted = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "new")
        _ = try await restarted.recover(id: id, uid: 501)
        #expect(try await wait(restarted, id: id).phase == .needsRecovery)
        #expect(await backend.restoreWriteCount == 0)
    }
    @Test func detachedDeviceRetiresWithoutTouchingReusedBSDName() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = WriteDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let id = UUID(); _ = try await service.startWrite(id: id, disk: disk(), uid: 501)
        _ = try await wait(service, id: id)
        await backend.disconnect()
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await wait(service, id: id).phase == .finished)
        #expect(await backend.restoreWriteCount == 0)
        try await service.quiesce()
    }
    @Test func writeCommandRequiresExactDeviceAndReadOnlyRecordCannotClaimWritable() throws {
        let command = HelperMountCommand(action: .startWrite, id: UUID(), disk: try disk())
        _ = try HelperMountCommand.decode(JSONEncoder().encode(command))
        #expect(throws: (any Error).self) { _ = try HelperMountCommand.decode(JSONEncoder().encode(HelperMountCommand(action: .startWrite, id: UUID()))) }
        let invalid = HelperMountOperation(id: UUID(), disk: try disk(), ownerUID: 501, bootSession: "boot", phase: .writeMounted, restoreRequired: true)
        #expect(throws: (any Error).self) { try invalid.validate() }
        let legacy = HelperMountOperation(id: UUID(), disk: try disk(), ownerUID: 501, bootSession: "boot", phase: .finished, restoreRequired: true)
        let decoded = try JSONDecoder().decode(HelperMountOperation.self, from: JSONEncoder().encode(legacy))
        #expect(!decoded.isWrite)
        try decoded.validate()
    }
}

// Simulates only OS effects. Tests execute the real persisted state machine;
// every mutating boundary independently checks the journal written beforehand.
private actor WriteDisk: HelperWritableMountBackend {
    let journal: HelperMountJournal
    var state: MountState = .readOnly
    var writeCount = 0
    var restoreWriteCount = 0
    var restoredID: UUID?
    let failAfterMount: Bool
    var failRestore: Bool
    init(journal: HelperMountJournal, failAfterMount: Bool = false, failRestore: Bool = false) {
        self.journal = journal; self.failAfterMount = failAfterMount; self.failRestore = failRestore
    }
    var disconnected = false
    func disconnect() { disconnected = true }
    func originalDisconnected(_ operation: HelperMountOperation, currentBoot: String) -> Bool { disconnected }
    var hold = false
    var preparing = false
    var continuation: CheckedContinuation<Void, Never>?
    func holdNextPreparation() { hold = true }
    func releasePreparation() { hold = false; continuation?.resume(); continuation = nil }
    func prepareWrite(_ disk: HelperDiskRequest, id: UUID, uid: UInt32) async -> Bool {
        preparing = true
        if hold { await withCheckedContinuation { continuation = $0 } }
        return state == .readOnly
    }
    func prepare(_ disk: HelperDiskRequest) -> Bool { state == .readOnly }
    func unmount(_ disk: HelperDiskRequest) throws {
        guard try journal.read()?.phase == .unmounting else { throw HelperDiskFailure.invalidRequest }
        state = .unmounted
    }
    func inspect(_ disk: HelperDiskRequest) -> HelperDiskReport {
        .init(version: 1, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: disk.byteCount,
              bootSHA256: String(repeating: "a", count: 64), effectiveUID: 0, writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
    func activateWrite(_ operation: HelperMountOperation) throws {
        guard let saved = try journal.read(), saved.phase == .mountingWrite, saved.isWrite,
              saved.id == operation.id, saved.ownerUID == 501, state == .unmounted else { throw HelperDiskFailure.invalidRequest }
        state = .readWrite; writeCount += 1
        if failAfterMount { throw HelperDiskFailure.unavailable }
    }
    func restoreWrite(_ operation: HelperMountOperation) throws {
        guard let saved = try journal.read(), saved.phase == .restoring, saved.id == operation.id,
              saved.disk == operation.disk else { throw HelperDiskFailure.invalidRequest }
        restoreWriteCount += 1
        if failRestore { throw HelperDiskFailure.busy }
        restoredID = operation.id; state = operation.restoreRequired ? .readOnly : .unmounted
    }
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) throws {
        guard state != .readWrite else { throw HelperDiskFailure.busy }
        state = originallyMounted ? .readOnly : .unmounted
    }
    func allowRestore() { failRestore = false }
}
