import Foundation
import Testing
@testable import VolisleCore

struct HelperMountCycleTests {
    private func target() throws -> HelperDiskRequest {
        try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096)
    }
    private func store() throws -> HelperMountJournal {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return try .init(directory: url)
    }
    private func finish(_ service: HelperMountCycleService, id: UUID) async throws -> HelperMountOperation {
        for _ in 0..<200 {
            let record = try await service.status(id: id, uid: 501)
            if !record.phase.running { return record }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HelperServiceError.timedOut
    }
    // Removing the journal-before-unmount boundary must fail this test.
    @Test func restorationAndInspectionAreVerifiedBeforeSuccess() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        let id = UUID()
        _ = try await service.start(id: id, disk: target(), uid: 501)
        let result = try await finish(service, id: id)
        #expect(result.phase == .finished)
        #expect(result.failure == nil)
        #expect(result.report?.bootSHA256 == String(repeating: "a", count: 64))
        #expect(await backend.mounted)
        #expect(try journal.read()?.phase == .finished)
    }
    @Test func inspectionFailureStillRestoresButCannotReportSuccess() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal, inspectionFails: true)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        let id = UUID(); _ = try await service.start(id: id, disk: target(), uid: 501)
        let result = try await finish(service, id: id)
        #expect(result.phase == .finished)
        #expect(result.failure == .permissionDenied)
        #expect(result.report == nil)
        #expect(await backend.mounted)
    }
    @Test func unresolvedRestoreBlocksNewOperationsAndCanBeRechecked() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal, restoreFails: true)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        let id = UUID(); _ = try await service.start(id: id, disk: target(), uid: 501)
        #expect(try await finish(service, id: id).phase == .needsRecovery)
        await #expect(throws: (any Error).self) { _ = try await service.start(id: UUID(), disk: target(), uid: 501) }
        await backend.allowRestore()
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await finish(service, id: id).phase == .finished)
        #expect(await backend.mounted)
    }
    @Test func duplicateIDCannotRepeatUnmountOrChangeOwnerOrDisk() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        let id = UUID(); _ = try await service.start(id: id, disk: target(), uid: 501)
        _ = try await finish(service, id: id)
        _ = try await service.start(id: id, disk: target(), uid: 501)
        #expect(await backend.unmountCount == 1)
        await #expect(throws: (any Error).self) { _ = try await service.status(id: id, uid: 502) }
        await #expect(throws: (any Error).self) { _ = try await service.recover(id: id, uid: 502) }
        await #expect(throws: (any Error).self) { _ = try await service.start(id: id, disk: .init(bsdName: "disk7s1", registryID: 124, byteCount: 4096), uid: 501) }
    }
    @Test func restartedServiceNeverResumesUncertainMutationAutomatically() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let id = UUID()
        try journal.write(.init(id: id, disk: target(), ownerUID: 501, bootSession: "boot-a", phase: .inspecting, restoreRequired: true))
        let backend = CycleDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        #expect(try await service.status(id: id, uid: 501).phase == .needsRecovery)
        #expect(await backend.unmountCount == 0)
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await finish(service, id: id).phase == .finished)
        #expect(try await service.status(id: id, uid: 501).report == nil)
    }
    @Test func previousBootCannotTargetReusedDeviceIdentity() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let id = UUID()
        try journal.write(.init(id: id, disk: target(), ownerUID: 501, bootSession: "old-boot", phase: .restoring, restoreRequired: true))
        let backend = CycleDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "new-boot")
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await service.status(id: id, uid: 501).phase == .needsRecovery)
        #expect(await backend.restoreCount == 0)
    }
    @Test func quiescePreventsNewWorkDuringServiceRemoval() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        try await service.quiesce()
        await #expect(throws: (any Error).self) { _ = try await service.start(id: UUID(), disk: target(), uid: 501) }
        #expect(await backend.unmountCount == 0)
        await service.resume()
        let id = UUID(); _ = try await service.start(id: id, disk: target(), uid: 501)
        _ = try await finish(service, id: id)
    }
    @Test func brokenJournalBlocksBeforeUnmount() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        try FileManager.default.createDirectory(at: journal.directory.appendingPathComponent("operation.json"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            _ = try HelperMountCycleService(journal: journal, backend: CycleDisk(journal: journal), bootSession: "boot-a")
        }
    }
    @Test func resolvingMissingRequestPreventsLateExecutionAcrossRestart() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal), id = UUID(), disk = try target()
        let first = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        #expect(try await first.resolve(id: id, disk: disk, uid: 501, write: true) == nil)
        // The daemon restarted within the same boot: the fence holds.
        let restarted = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        await #expect(throws: (any Error).self) { _ = try await restarted.startWrite(id: id, disk: disk, uid: 501) }
        #expect(try await restarted.resolve(id: id, disk: disk, uid: 501, write: true) == nil)
        await #expect(throws: (any Error).self) { _ = try await restarted.resolve(id: id, disk: disk, uid: 502, write: true) }
        await #expect(throws: (any Error).self) { _ = try await restarted.resolve(id: id, disk: disk, uid: 501, write: false) }
        #expect(await backend.unmountCount == 0)
    }
    @Test func completedRequestCannotReplayAfterAnotherOperation() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal), first = UUID(), second = UUID()
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        _ = try await service.start(id: first, disk: target(), uid: 501)
        _ = try await finish(service, id: first)
        _ = try await service.start(id: second, disk: target(), uid: 501)
        _ = try await finish(service, id: second)
        // While its finished record is kept, asking again only returns it.
        let kept = try await service.start(id: first, disk: target(), uid: 501)
        #expect(kept.phase == .finished && kept.id == first)
        #expect(try await service.resolve(id: first, disk: target(), uid: 501, write: false) == kept)
        #expect(await backend.unmountCount == 2)
        // Once newer operations pushed the record out, its receipt still fences it.
        for _ in 0..<HelperMountCycleService.finishedKept {
            let next = UUID()
            _ = try await service.start(id: next, disk: target(), uid: 501)
            _ = try await finish(service, id: next)
        }
        await #expect(throws: (any Error).self) { _ = try await service.start(id: first, disk: target(), uid: 501) }
        #expect(try await service.resolve(id: first, disk: target(), uid: 501, write: false) == nil)
        #expect(await backend.unmountCount == 2 + HelperMountCycleService.finishedKept)
    }
    @Test func resolutionDuringPreparationCannotReleaseAnExecutingRequest() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = CycleDisk(journal: journal, pausePreparation: true), id = UUID(), disk = try target()
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        let start = Task { try await service.start(id: id, disk: disk, uid: 501) }
        await backend.waitUntilPreparing()
        await #expect(throws: HelperDiskFailure.busy) { _ = try await service.resolve(id: id, disk: disk, uid: 501, write: false) }
        await backend.releasePreparation()
        _ = try await start.value
        let done = try await finish(service, id: id)
        #expect(try await service.resolve(id: id, disk: disk, uid: 501, write: false) == done)
        #expect(await backend.unmountCount == 1)
    }
    @Test func unsafeReceiptLedgerBlocksBeforeDiskAccess() throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let outside = journal.directory.appendingPathComponent("outside")
        try Data("[]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: journal.directory.appendingPathComponent("requests.json"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            _ = try HelperMountCycleService(journal: journal, backend: CycleDisk(journal: journal), bootSession: "boot-a")
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "[]")
    }
    @Test func withdrawalProofMustMatchTheAuthenticatedRequest() throws {
        let id = UUID(), disk = try target(), command = HelperMountCommand(action: .resolveWrite, id: id, disk: disk)
        let valid = HelperMountReceipt(id: id, disk: disk, ownerUID: 501, write: true)
        #expect(try HelperRPC.decodeMountReply(JSONEncoder().encode(HelperMountReply(operation: nil, failure: nil, resolved: valid)), command: command, uid: 501) == nil)
        for receipt in [HelperMountReceipt(id: UUID(), disk: disk, ownerUID: 501, write: true),
                        .init(id: id, disk: disk, ownerUID: 502, write: true),
                        .init(id: id, disk: disk, ownerUID: 501, write: false)] {
            #expect(throws: (any Error).self) {
                _ = try HelperRPC.decodeMountReply(JSONEncoder().encode(HelperMountReply(operation: nil, failure: nil, resolved: receipt)), command: command, uid: 501)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try HelperRPC.decodeMountReply(JSONEncoder().encode(HelperMountReply(operation: nil, failure: nil)), command: command, uid: 501)
        }
        #expect(throws: (any Error).self) {
            _ = try HelperRPC.decodeMountReply(JSONEncoder().encode(HelperMountReply(operation: nil, failure: .busy, resolved: valid)), command: command, uid: 501)
        }
    }
    @Test func corruptAndDuplicateReceiptsCannotBeIgnoredAtStartup() throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let receipt = HelperMountReceipt(id: UUID(), disk: try target(), ownerUID: 501, write: false)
        let file = journal.directory.appendingPathComponent("requests.json")
        for bytes in [Data("broken".utf8), try JSONEncoder().encode([receipt, receipt])] {
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(throws: (any Error).self) {
                _ = try HelperMountCycleService(journal: journal, backend: CycleDisk(journal: journal), bootSession: "boot-a")
            }
        }
    }
    @Test func fullReceiptLedgerNeverEvictsAnOldFenceToAdmitNewWork() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let disk = try target(), id = UUID()
        _ = try HelperMountCycleService(journal: journal, backend: CycleDisk(journal: journal), bootSession: "boot-a")
        var receipts: [UUID: HelperMountReceipt] = [id: .init(id: id, disk: disk, ownerUID: 501, write: false)]
        for _ in 1..<HelperMountJournal.receiptLimit {
            let key = UUID(); receipts[key] = .init(id: key, disk: disk, ownerUID: 501, write: false)
        }
        try journal.writeReceipts(receipts)
        let backend = CycleDisk(journal: journal)
        // Same boot: the full ledger still fails closed.
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-a")
        await #expect(throws: (any Error).self) { _ = try await service.start(id: UUID(), disk: disk, uid: 501) }
        await #expect(throws: (any Error).self) { _ = try await service.start(id: id, disk: disk, uid: 501) }
        #expect(try journal.readReceipts()[id] == receipts[id])
        #expect(try journal.read() == nil)
        #expect(await backend.unmountCount == 0)
    }
    @Test func aNewBootStartsANewLedgerKeepingOnlyTheCurrentRecord() async throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let disk = try target(), current = UUID(), fenced = UUID()
        let first = try HelperMountCycleService(journal: journal, backend: CycleDisk(journal: journal), bootSession: "boot-a")
        _ = try await first.start(id: current, disk: disk, uid: 501)
        _ = try await finish(first, id: current)
        #expect(try await first.resolve(id: fenced, disk: disk, uid: 501, write: false) == nil)
        var receipts = try journal.readReceipts()
        for _ in receipts.count..<HelperMountJournal.receiptLimit {
            let key = UUID(); receipts[key] = .init(id: key, disk: disk, ownerUID: 501, write: false)
        }
        try journal.writeReceipts(receipts)
        // No request survives a restart of the Mac: earlier fences go, new work is admitted.
        let backend = CycleDisk(journal: journal)
        let rebooted = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot-b")
        #expect(Set(try journal.readReceipts().keys) == [current])
        let next = UUID()
        _ = try await rebooted.start(id: next, disk: disk, uid: 501)
        #expect(try await finish(rebooted, id: next).phase == .finished)
        #expect(Set(try journal.readReceipts().keys) == [current, next])
    }
    @Test func missingOrExtraArgumentsNeverReachTheOperation() throws {
        for command in [HelperMountCommand(action: .start), .init(action: .resolve), .init(action: .resolveWrite, id: UUID()), .init(action: .status), .init(action: .recover),
                        .init(action: .latest, id: UUID()), .init(action: .status, id: UUID(), disk: try target())] {
            #expect(throws: (any Error).self) { _ = try HelperMountCommand.decode(JSONEncoder().encode(command)) }
        }
        #expect(throws: (any Error).self) { _ = try HelperMountCommand.decode(Data(repeating: 32, count: 4097)) }
    }
    @Test func unsafeJournalCannotBeFollowedOrUsedForDiskOperations() throws {
        let journal = try store(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let outside = journal.directory.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: journal.directory.appendingPathComponent("operation.json"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try journal.read() }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "private")
    }
}

// Only OS disk effects are substituted. The actual coordinator, journal,
// persistence, identity/owner checks and recovery state machine run unchanged.
private actor CycleDisk: HelperMountCycleBackend {
    let journal: HelperMountJournal
    var pausePreparation: Bool
    var preparing = false
    private var preparation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    var mounted = true
    var unmountCount = 0
    var restoreCount = 0
    var inspectionFails: Bool
    var restoreFails: Bool
    init(journal: HelperMountJournal, inspectionFails: Bool = false, restoreFails: Bool = false, pausePreparation: Bool = false) {
        self.pausePreparation = pausePreparation
        self.journal = journal; self.inspectionFails = inspectionFails; self.restoreFails = restoreFails
    }
    func prepare(_ disk: HelperDiskRequest) async throws -> Bool {
        if pausePreparation {
            await withCheckedContinuation { continuation in
                preparing = true; preparation = continuation
                observer?.resume(); observer = nil
            }
        }
        return mounted
    }
    func waitUntilPreparing() async {
        if !preparing { await withCheckedContinuation { observer = $0 } }
    }
    func releasePreparation() { preparation?.resume(); preparation = nil }
    func unmount(_ disk: HelperDiskRequest) async throws {
        guard try journal.read()?.phase == .unmounting else { throw HelperServiceError.invalidRequest }
        unmountCount += 1; mounted = false
    }
    func inspect(_ disk: HelperDiskRequest) async throws -> HelperDiskReport {
        if inspectionFails { throw HelperDiskFailure.permissionDenied }
        return .init(version: 1, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: disk.byteCount,
                     bootSHA256: String(repeating: "a", count: 64), effectiveUID: 0,
                     writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) async throws {
        restoreCount += 1
        if restoreFails { throw HelperDiskFailure.busy }
        mounted = originallyMounted
    }
    func allowRestore() { restoreFails = false }
}
