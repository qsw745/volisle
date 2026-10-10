import Testing
import Foundation
import CryptoKit
import os
@testable import VolisleCore

/// "Repair on This Mac" for stale folder entries, and the undo records an
/// interruption leaves behind.
@MainActor struct StaleEntryRepairTests {
    private static let staleDetail = "inconsistent record 194973: stale entry, record reused; folder 5021, entry seq 3, record seq 4"

    private nonisolated func examination(entries: Int = 1, repairable: Bool = true, detail: String? = nil) -> StaleEntryExamination {
        .init(markedForCheck: true, staleEntries: entries, folders: entries > 0 ? [5021] : [], reusedRecords: entries > 0 ? 1 : 0,
              repairable: repairable, checkedItems: 120, detail: detail)
    }

    // MARK: The check's refusal

    @Test func aStaleEntryRefusalIsRecognizedAndKeepsItsNumbers() {
        let refusal = CheckMarkerRefusal(.checkFoundProblems, detail: Self.staleDetail)
        #expect(refusal?.isStaleEntry == true && refusal?.detail == Self.staleDetail)
        #expect(CheckMarkerRefusal(.checkFoundProblems, detail: "inconsistent record 9: stale entry, record free; folder 5, entry seq 1, record seq 2")?.isStaleEntry == true)
        #expect(CheckMarkerRefusal(.checkFoundProblems, detail: "inconsistent record 9: listed as a folder, record is a file; folder 5, entry seq 1, record seq 1")?.isStaleEntry == false)
        #expect(CheckMarkerRefusal(.checkReadFailed, detail: "read failed at record 9")?.isStaleEntry == false)
    }

    @Test func checkOnThisMacOffersTheRepairOnlyForStaleEntries() async {
        let detail = Self.staleDetail
        let stale = CheckMarkerClearer(runner: Runner(), retryDelay: .zero, isMounted: { _ in true },
                                       clear: { _ in throw CheckMarkerRefusal(.checkFoundProblems, detail: detail)! })
        do { _ = try await stale.run(partition: "disk8s3"); Issue.record("应当抛出") }
        catch {
            if case .staleEntries(let carried) = error {
                #expect(carried == detail && error.errorDescription?.contains(detail) == true)
            }
            else { Issue.record("应当提供在 Mac 上修复：\(error)") }
        }
        let other = CheckMarkerClearer(runner: Runner(), retryDelay: .zero, isMounted: { _ in true },
                                       clear: { _ in throw CheckMarkerRefusal(.checkFoundProblems, detail: "inconsistent record 9: clusters marked free")! })
        do { _ = try await other.run(partition: "disk8s3"); Issue.record("应当抛出") }
        catch {
            if case .failed = error {} else { Issue.record("其他问题不应提供修复：\(error)") }
        }
    }

    @Test func theNewRefusalsOfferNoFurtherAction() {
        for failure in [HelperDiskFailure.staleEntriesNotRepairable, .staleEntriesRepairRestored, .staleEntriesRestoreFailed] {
            #expect(DiskReadiness.action(for: failure) == nil)
            #expect(failure.errorDescription?.contains("Windows") == true)
        }
    }

    // MARK: The App's flow

    @Test func theRepairNeedsTheUsersAgreement() async {
        let runner = Runner()
        let asked = Tally()
        let repairer = StaleEntryRepairer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                          examine: { _ in self.examination() },
                                          repair: { _ in asked.add(); return .init(removed: 1, checkedItems: 120) })
        await #expect(throws: CheckMarkerError.self) { try await repairer.repair(partition: "disk8s3", accepted: false) }
        #expect(asked.value == 0 && runner.calls.isEmpty, "未同意时不得卸载或修复")
        let result = try? await repairer.repair(partition: "disk8s3", accepted: true)
        #expect(result == .init(removed: 1, checkedItems: 120) && asked.value == 1)
        #expect(runner.calls == ["unmount disk8s3", "mount disk8s3"])
    }

    @Test func examineUnmountsAndMountsAgain() async throws {
        let runner = Runner()
        let repairer = StaleEntryRepairer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                          examine: { _ in self.examination() },
                                          repair: { _ in Issue.record("不应修复"); throw HelperDiskFailure.unavailable })
        #expect(try await repairer.examine(partition: "disk8s3").staleEntries == 1)
        #expect(runner.calls == ["unmount disk8s3", "mount disk8s3"] && !repairer.isWorking)
    }

    @Test func aFailedRepairStillMountsTheDiskAgainButNotWithoutAnAnswer() async {
        let runner = Runner()
        let restored = StaleEntryRepairer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                          repair: { _ in throw HelperDiskFailure.staleEntriesRepairRestored })
        await #expect(throws: CheckMarkerError.failed(HelperDiskFailure.staleEntriesRepairRestored.errorDescription!)) {
            try await restored.repair(partition: "disk8s3", accepted: true)
        }
        #expect(runner.calls == ["unmount disk8s3", "mount disk8s3"])
        // The helper may still be writing: mounting now would race it.
        let silent = Runner()
        let late = StaleEntryRepairer(runner: silent, retryDelay: .zero, isMounted: { _ in true },
                                      repair: { _ in throw HelperServiceError.timedOut })
        await #expect(throws: CheckMarkerError.self) { try await late.repair(partition: "disk8s3", accepted: true) }
        #expect(silent.calls == ["unmount disk8s3"] && !late.isWorking)
    }

    @Test func helperRepliesAreValidated() throws {
        let good = try JSONEncoder().encode(HelperStaleEntryReply(examination: examination()))
        #expect(try HelperStaleEntryReply.decodeExamination(good) == examination())
        for bad in [examination(entries: 0, repairable: true), examination(entries: 9),
                    examination(repairable: false, detail: "~/秘密.txt")] {
            #expect(throws: HelperServiceError.invalidReply) {
                try HelperStaleEntryReply.decodeExamination(JSONEncoder().encode(HelperStaleEntryReply(examination: bad)))
            }
        }
        let refused = examination(repairable: false, detail: "inconsistent record 9: stale entry not in a leaf; folder 5, entry seq 1, record seq 2")
        #expect(try HelperStaleEntryReply.decodeExamination(JSONEncoder().encode(HelperStaleEntryReply(examination: refused))) == refused)
        for bad in [StaleEntryRepairResult(removed: 9, checkedItems: 1), .init(removed: 1, checkedItems: -1),
                    .init(removed: 1, checkedItems: 1, restoredLeftover: true)] {
            #expect(throws: HelperServiceError.invalidReply) {
                try HelperStaleEntryReply.decodeResult(JSONEncoder().encode(HelperStaleEntryReply(result: bad)))
            }
        }
        let failed = try JSONEncoder().encode(HelperStaleEntryReply(failure: .staleEntriesNotRepairable,
                                                                    detail: "inconsistent record 9: stale entry alone in its block; folder 5, entry seq 1, record seq 2"))
        do { _ = try HelperStaleEntryReply.decodeResult(failed); Issue.record("应当抛出") }
        catch let refusal as CheckMarkerRefusal { #expect(refusal.failure == .staleEntriesNotRepairable) }
    }

    @Test func theHelpersEngineIsCalledNotTheDefault() throws {
        let engine: any PartitionMaintenanceEngine = Engine(device: nil, facts: { .init(markedForCheck: true, logOffset: 4096, logLength: 4096) })
        #expect(try engine.examineStaleEntries(descriptor: 0, blockSize: 512, byteCount: 1).staleEntries == 2)
        #expect(try engine.volumeFacts(descriptor: 0, blockSize: 512, byteCount: 1).logOffset == 4096)
        let identity = PartitionUndoIdentity(serial: 1, byteCount: 1, logOffset: 0, logLength: 0, logDigest: Data(count: 32))
        #expect(try engine.repairStaleEntries(descriptor: 0, blockSize: 512, byteCount: 1, undoFile: URL(filePath: "/dev/null"),
                                              identity: identity).removed == 2)
    }

    // MARK: Undo records left behind

    @Test func anUndoFileNamesItsVolumeAndSurvivesACutLastRecord() throws {
        let dir = try Scratch()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let identity = PartitionUndoIdentity(serial: 0x1122_3344_5566_7788, byteCount: 1 << 20, logOffset: 65_536, logLength: 8192,
                                             logDigest: Data(repeating: 0xAB, count: 32))
        let url = dir.url.appending(path: "a.undo")
        let undo = try PartitionUndoLog(url: url, identity: identity)
        for (offset, byte) in [(4096, UInt8(1)), (8192, 2)] {
            #expect([UInt8](repeating: byte, count: 512).withUnsafeBytes { undo.save($0, at: Int64(offset)) })
        }
        var found = try #require(PartitionUndoLog.leftover(at: url))
        #expect(found.identity == identity && found.entries.map { $0.offset } == [4096, 8192])
        // The helper stopped while appending a record: its write never happened.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0, 16, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 7]))
        try handle.close()
        found = try #require(PartitionUndoLog.leftover(at: url))
        #expect(found.entries.count == 2)
        // A file without a volume (the Windows log recovery's) is never replayed later.
        let plain = dir.url.appending(path: "b.undo")
        _ = try PartitionUndoLog(url: plain)
        #expect(PartitionUndoLog.leftover(at: plain) == nil)
    }

    @Test func aLeftoverIsReplayedOnlyOntoItsVolumeWhileNothingMountedIt() {
        let identity = PartitionUndoIdentity(serial: 7, byteCount: 100, logOffset: 0, logLength: 1, logDigest: Data([1]))
        typealias D = LeftoverUndo.Decision
        let cases: [(UInt64?, UInt64, Data?, Bool?, D)] = [
            (7, 100, Data([1]), true, .replay),      // still marked: unfinished
            (7, 100, Data([1]), nil, .replay),       // does not even read: half-written
            (7, 100, Data([1]), false, .obsolete),   // the last write (clearing the mark) happened, or chkdsk ran
            (7, 100, Data([2]), true, .obsolete),    // something mounted it since (its log head changed)
            (8, 100, Data([1]), true, .keep),        // another volume
            (7, 200, Data([1]), true, .keep),
            (nil, 100, Data([1]), true, .keep),      // boot sector unreadable now
            (7, 100, nil, true, .keep),
        ]
        for (serial, size, digest, marked, expected) in cases {
            #expect(LeftoverUndo.decide(identity, serial: serial, byteCount: size, logDigest: digest, markedForCheck: marked) == expected)
        }
    }

    @Test func anInterruptedRepairIsPutBackBeforeTheNextChange() throws {
        let dir = try Scratch()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let device = try dir.device()
        defer { close(device.fd) }
        let marked = Flag(true)
        let engine = Engine(device: device.fd, facts: {
            guard let state = marked.value else { throw HelperDiskFailure.unavailable }
            return .init(markedForCheck: state, logOffset: 65_536, logLength: 8192)
        })
        let undoDir = dir.url.appending(path: "undo")
        try FileManager.default.createDirectory(at: undoDir, withIntermediateDirectories: true)
        let log = Logger(subsystem: "top.qisw.volisle.tests", category: "stale")

        func interrupted(_ name: String) throws -> Data {
            let identity = try LeftoverUndo.identity(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size)
            let pristine = try Data(contentsOf: device.url)
            let undo = try PartitionUndoLog(url: undoDir.appending(path: name), identity: identity)
            for offset in [4096, 12_288] {  // save, then write: the helper dies after the second write
                var old = [UInt8](repeating: 0, count: 512)
                #expect(pread(device.fd, &old, 512, off_t(offset)) == 512)
                #expect(old.withUnsafeBytes { undo.save($0, at: Int64(offset)) })
                #expect(pwrite(device.fd, [UInt8](repeating: 0xEE, count: 512), 512, off_t(offset)) == 512)
            }
            return pristine
        }

        // Still marked "needs check": put back, file gone.
        var pristine = try interrupted("1.undo")
        #expect(LeftoverUndo.pending(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir))
        #expect(try LeftoverUndo.settle(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir, log: log))
        #expect(try Data(contentsOf: device.url) == pristine)
        #expect(try FileManager.default.contentsOfDirectory(atPath: undoDir.path).isEmpty)

        // Unreadable now (a half-written record): put back too.
        pristine = try interrupted("2.undo")
        engine.failFactsOnce = true
        #expect(try LeftoverUndo.settle(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir, log: log))
        #expect(try Data(contentsOf: device.url) == pristine)

        // The mark was cleared (the repair's last write happened): set aside, not replayed.
        _ = try interrupted("3.undo")
        let finished = try Data(contentsOf: device.url)
        marked.value = false
        #expect(!LeftoverUndo.pending(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir))
        #expect(try !LeftoverUndo.settle(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir, log: log))
        #expect(try Data(contentsOf: device.url) == finished)
        #expect(try FileManager.default.contentsOfDirectory(atPath: undoDir.path) == ["3.undo.obsolete"])

        // Windows mounted it since (its log head changed): never replayed.
        marked.value = true
        _ = try interrupted("4.undo")
        #expect(pwrite(device.fd, [UInt8](repeating: 0x55, count: 512), 512, 65_536) == 512)
        let afterWindows = try Data(contentsOf: device.url)
        #expect(try !LeftoverUndo.settle(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir, log: log))
        #expect(try Data(contentsOf: device.url) == afterWindows)

        // Another disk's record stays where it is, untouched.
        let other = PartitionUndoIdentity(serial: 1, byteCount: device.size, logOffset: 65_536, logLength: 8192, logDigest: Data(count: 32))
        let foreign = try PartitionUndoLog(url: undoDir.appending(path: "5.undo"), identity: other)
        #expect([UInt8](repeating: 9, count: 512).withUnsafeBytes { foreign.save($0, at: 0) })
        let before = try Data(contentsOf: device.url)
        #expect(try !LeftoverUndo.settle(engine: engine, descriptor: device.fd, blockSize: 512, byteCount: device.size, directory: undoDir, log: log))
        #expect(try Data(contentsOf: device.url) == before)
        #expect(FileManager.default.fileExists(atPath: undoDir.appending(path: "5.undo").path))
    }

    @Test func aLeftoverReachingBeyondThePartitionIsNotWritten() throws {
        let dir = try Scratch()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let device = try dir.device()
        defer { close(device.fd) }
        let before = try Data(contentsOf: device.url)
        #expect(!PartitionUndoLog.write([(Int64(device.size) - 256, Data(count: 512))], to: device.fd, limit: device.size))
        #expect(!PartitionUndoLog.write([(Int64(-1), Data(count: 1))], to: device.fd, limit: device.size))
        #expect(try Data(contentsOf: device.url) == before)
    }
}

// MARK: Test doubles

/// A device image: an NTFS-looking boot sector (serial at 0x48) and a log head at 64 KiB.
private struct Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "volisle-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func device() throws -> (url: URL, fd: Int32, size: UInt64) {
        var bytes = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        bytes.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        bytes.replaceSubrange(0x48..<0x50, with: withUnsafeBytes(of: UInt64(0x0102_0304_0506_0708).littleEndian) { Data($0) })
        let image = url.appending(path: "device.img")
        try bytes.write(to: image)
        return (image, open(image.path, O_RDWR), UInt64(bytes.count))
    }
}

private final class Engine: PartitionMaintenanceEngine, @unchecked Sendable {
    let device: Int32?
    let facts: () throws -> NTFSVolumeFacts
    var failFactsOnce = false
    init(device: Int32?, facts: @escaping () throws -> NTFSVolumeFacts) { self.device = device; self.facts = facts }
    func format(descriptor: Int32, blockSize: Int, byteCount: UInt64, label: String) throws {}
    func clearCheckMarker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Int64 { 0 }
    func isBitLocker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Bool { false }
    func bitLockerKey(descriptor: Int32, blockSize: Int, byteCount: UInt64, kind: BitLockerSecretKind, secret: String) throws -> String { "" }
    func examineWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> WindowsLogExamination { throw HelperDiskFailure.unavailable }
    func recoverWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult { throw HelperDiskFailure.unavailable }
    func discardWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult { throw HelperDiskFailure.unavailable }
    func examineStaleEntries(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> StaleEntryExamination {
        .init(markedForCheck: true, staleEntries: 2, folders: [40], reusedRecords: 1, repairable: true, checkedItems: 9)
    }
    func repairStaleEntries(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL,
                            identity: PartitionUndoIdentity) throws -> StaleEntryRepairResult {
        .init(removed: 2, checkedItems: 9)
    }
    /// The first read after a half-written record fails, as the bridge's mount would.
    func volumeFacts(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> NTFSVolumeFacts {
        if failFactsOnce { failFactsOnce = false; throw HelperDiskFailure.unavailable }
        return try facts()
    }
}

private final class Flag: @unchecked Sendable {
    var value: Bool?
    init(_ value: Bool?) { self.value = value }
}

private final class Runner: EraseCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        lock.withLock { log.append(arguments.joined(separator: " ")) }
        return (0, "")
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
