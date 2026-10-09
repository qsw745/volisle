import Foundation
import Testing
@testable import VolisleCore

/// The daemon's records with more than one disk: one cycle per physical disk,
/// at most `maximumActive` at once, each recovered on its own, clones refused,
/// and the single record of earlier versions taken over.
struct HelperMultiDiskTests {
    private func journal() throws -> HelperMountJournal {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return try HelperMountJournal(directory: dir)
    }
    private func disk(_ bsd: String, _ registry: UInt64) throws -> HelperDiskRequest {
        try .init(bsdName: bsd, registryID: registry, byteCount: 67108864)
    }
    private func wait(_ service: HelperMountCycleService, id: UUID) async throws -> HelperMountOperation {
        for _ in 0..<400 {
            let record = try await service.status(id: id, uid: 501)
            if !record.phase.running { return record }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HelperServiceError.timedOut
    }

    @Test func twoDisksAreWrittenAtOnceButNeverTwoCyclesOnOneDisk() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = Disks(journal: journal)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let a = UUID(), b = UUID()
        _ = try await service.startWrite(id: a, disk: disk("disk7s1", 71), uid: 501)
        _ = try await service.startWrite(id: b, disk: disk("disk8s1", 81), uid: 501)
        #expect(try await wait(service, id: a).phase == .writeMounted)
        #expect(try await wait(service, id: b).phase == .writeMounted)
        var state = await backend.state
        #expect(state["disk7s1"] == .readWrite && state["disk8s1"] == .readWrite)
        // Another partition of disk 7, and a third disk: refused before any disk access.
        await #expect(throws: HelperDiskFailure.busy) { _ = try await service.startWrite(id: UUID(), disk: disk("disk7s2", 72), uid: 501) }
        await #expect(throws: HelperDiskFailure.busy) { _ = try await service.startWrite(id: UUID(), disk: disk("disk9s1", 91), uid: 501) }
        #expect(await backend.prepared == 2)
        // Ending one leaves the other written, and frees a place.
        _ = try await service.recover(id: a, uid: 501)
        #expect(try await wait(service, id: a).phase == .finished)
        state = await backend.state
        #expect(state["disk7s1"] == .readOnly && state["disk8s1"] == .readWrite)
        let c = UUID()
        _ = try await service.startWrite(id: c, disk: disk("disk9s1", 91), uid: 501)
        #expect(try await wait(service, id: c).phase == .writeMounted)
        #expect(try await service.list(uid: 501).map(\.id) == [a, b, c])
        #expect(try await service.latest(uid: 501)?.id == c)
        await #expect(throws: (any Error).self) { try await service.quiesce() }
        for id in [b, c] {
            _ = try await service.recover(id: id, uid: 501)
            #expect(try await wait(service, id: id).phase == .finished)
        }
        #expect(try await service.list(uid: 501).map(\.id) == [c], "only the newest finished record is listed")
        try await service.quiesce()
    }

    @Test func aRestartTurnsEveryMountedSessionIntoItsOwnRecovery() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = Disks(journal: journal)
        let first = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let a = UUID(), b = UUID()
        _ = try await first.startWrite(id: a, disk: disk("disk7s1", 71), uid: 501)
        _ = try await first.startWrite(id: b, disk: disk("disk8s1", 81), uid: 501)
        _ = try await wait(first, id: a); _ = try await wait(first, id: b)
        let restarted = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        for id in [a, b] { #expect(try await restarted.status(id: id, uid: 501).phase == .needsRecovery) }
        // B is unplugged meanwhile: it retires without touching anything; A is put back read-only.
        await backend.disconnect("disk8s1")
        _ = try await restarted.recover(id: b, uid: 501)
        #expect(try await wait(restarted, id: b).phase == .finished)
        #expect(await backend.state["disk7s1"] == .readWrite, "A untouched until it is recovered itself")
        _ = try await restarted.recover(id: a, uid: 501)
        #expect(try await wait(restarted, id: a).phase == .finished)
        #expect(await backend.state["disk7s1"] == .readOnly)
        #expect(await backend.restored == ["disk7s1"])
    }

    @Test func aCloneOfADiskBeingWrittenStaysReadOnly() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let backend = Disks(journal: journal, sameBootSector: true)
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        let a = UUID(), clone = UUID()
        _ = try await service.startWrite(id: a, disk: disk("disk7s1", 71), uid: 501)
        #expect(try await wait(service, id: a).phase == .writeMounted)
        _ = try await service.startWrite(id: clone, disk: disk("disk8s1", 81), uid: 501)
        let refused = try await wait(service, id: clone)
        #expect(refused.phase == .finished && refused.failure == .sameVolumeWriting)
        let state = await backend.state
        #expect(state["disk8s1"] == .readOnly && state["disk7s1"] == .readWrite)
        #expect(await backend.mounted == ["disk7s1"])
    }

    @Test func theSingleRecordOfAnEarlierVersionIsTakenOver() async throws {
        let journal = try journal(); defer { try? FileManager.default.removeItem(at: journal.directory) }
        let id = UUID(), target = try disk("disk7s1", 71)
        var legacy = HelperMountOperation(id: id, disk: target, ownerUID: 501, bootSession: "boot", phase: .writeMounted,
                                          restoreRequired: true, report: Disks.report(target, same: false))
        legacy.purpose = .readWrite
        let file = journal.directory.appendingPathComponent("operation.json")
        try JSONEncoder().encode(legacy).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let backend = Disks(journal: journal)
        await backend.mountedWritable("disk7s1")
        let service = try HelperMountCycleService(journal: journal, backend: backend, bootSession: "boot")
        #expect(try await service.status(id: id, uid: 501).phase == .needsRecovery)
        #expect(!FileManager.default.fileExists(atPath: file.path), "taken over by its own record file")
        // Still a session on that disk: nothing else starts there until it is recovered.
        await #expect(throws: HelperDiskFailure.busy) { _ = try await service.startWrite(id: UUID(), disk: target, uid: 501) }
        _ = try await service.recover(id: id, uid: 501)
        #expect(try await wait(service, id: id).phase == .finished)
        #expect(await backend.state["disk7s1"] == .readOnly)
    }

    @Test func listRepliesAreCheckedLikeSingleRecords() throws {
        let mine = HelperMountOperation(id: UUID(), disk: try disk("disk7s1", 71), ownerUID: 501, bootSession: "boot",
                                        phase: .finished, restoreRequired: true)
        let reply = { (records: [HelperMountOperation]?) in
            try JSONEncoder().encode(HelperMountReply(operation: nil, failure: nil, operations: records))
        }
        #expect(try HelperRPC.decodeMountListReply(reply([mine]), uid: 501) == [mine])
        #expect(try HelperRPC.decodeMountListReply(reply([]), uid: 501).isEmpty)
        for bad in [nil, [mine, mine], Array(repeating: mine, count: HelperMountCycleService.maximumActive + 2)] {
            #expect(throws: (any Error).self) { _ = try HelperRPC.decodeMountListReply(reply(bad), uid: 501) }
        }
        #expect(throws: (any Error).self) { _ = try HelperRPC.decodeMountListReply(reply([mine]), uid: 502) }
        // A list never answers a single-record command.
        let command = HelperMountCommand(action: .latest)
        #expect(throws: (any Error).self) { _ = try HelperRPC.decodeMountReply(reply([mine]), command: command, uid: 501) }
    }
}

/// Several disks' OS effects; each mutating step checks its own record first.
private actor Disks: HelperWritableMountBackend {
    let journal: HelperMountJournal
    let sameBootSector: Bool
    var state: [String: MountState] = [:]
    var prepared = 0
    var mounted: [String] = []
    var restored: [String] = []
    var gone: Set<String> = []
    init(journal: HelperMountJournal, sameBootSector: Bool = false) {
        self.journal = journal; self.sameBootSector = sameBootSector
    }
    static func report(_ disk: HelperDiskRequest, same: Bool) -> HelperDiskReport {
        let hash = same ? String(repeating: "c", count: 64)
            : String(String(disk.registryID, radix: 16).padding(toLength: 64, withPad: "0", startingAt: 0))
        return .init(version: 1, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: disk.byteCount,
                     bootSHA256: hash, effectiveUID: 0, writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
    func mountedWritable(_ bsd: String) { state[bsd] = .readWrite }
    func disconnect(_ bsd: String) { gone.insert(bsd) }
    private func record(_ disk: HelperDiskRequest, in phase: HelperMountPhase) throws -> HelperMountOperation {
        guard let saved = try journal.readAll().last(where: { $0.disk == disk && $0.phase == phase }) else {
            throw HelperDiskFailure.invalidRequest
        }
        return saved
    }
    func originalDisconnected(_ operation: HelperMountOperation, currentBoot: String) -> Bool { gone.contains(operation.disk.bsdName) }
    func prepareWrite(_ disk: HelperDiskRequest, id: UUID, uid: UInt32) -> Bool {
        prepared += 1
        return (state[disk.bsdName] ?? .readOnly) == .readOnly
    }
    func prepare(_ disk: HelperDiskRequest) -> Bool { (state[disk.bsdName] ?? .readOnly) == .readOnly }
    func unmount(_ disk: HelperDiskRequest) throws {
        _ = try record(disk, in: .unmounting)
        state[disk.bsdName] = .unmounted
    }
    func inspect(_ disk: HelperDiskRequest) -> HelperDiskReport { Self.report(disk, same: sameBootSector) }
    func activateWrite(_ operation: HelperMountOperation) throws {
        let saved = try record(operation.disk, in: .mountingWrite)
        guard saved.id == operation.id, saved.isWrite, state[operation.disk.bsdName] == .unmounted else { throw HelperDiskFailure.invalidRequest }
        state[operation.disk.bsdName] = .readWrite
        mounted.append(operation.disk.bsdName)
    }
    func restoreWrite(_ operation: HelperMountOperation) throws {
        let saved = try record(operation.disk, in: .restoring)
        guard saved.id == operation.id else { throw HelperDiskFailure.invalidRequest }
        restored.append(operation.disk.bsdName)
        state[operation.disk.bsdName] = operation.restoreRequired ? .readOnly : .unmounted
    }
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) throws {
        guard state[disk.bsdName] != .readWrite else { throw HelperDiskFailure.busy }
        state[disk.bsdName] = originallyMounted ? .readOnly : .unmounted
    }
}
