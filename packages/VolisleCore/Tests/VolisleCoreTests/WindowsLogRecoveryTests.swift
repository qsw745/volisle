import Testing
import Foundation
@testable import VolisleCore

/// "Recover on This Mac" for a disk Windows let go of without Safe Removal.
@MainActor struct WindowsLogRecoveryTests {
    private nonisolated func examination(marked: Bool = false, maintenance: Bool = false, hibernated: Bool = false, readable: Bool = true,
                             clean: Bool = false, simulated: Bool = true, pending: Int64 = 2) -> WindowsLogExamination {
        .init(markedForCheck: marked, maintenancePending: maintenance, hibernated: hibernated, logReadable: readable,
              logClean: clean, logVersion: "2.0", replaySimulated: simulated, pendingChanges: pending)
    }

    @Test func theHelpersEngineIsCalledNotTheDefault() throws {
        // Through `any PartitionMaintenanceEngine`, as the helper calls it: a
        // method that is only an extension would reach the default instead.
        struct Engine: PartitionMaintenanceEngine {
            func format(descriptor: Int32, blockSize: Int, byteCount: UInt64, label: String) throws {}
            func clearCheckMarker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Int64 { 0 }
            func isBitLocker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Bool { false }
            func bitLockerKey(descriptor: Int32, blockSize: Int, byteCount: UInt64, kind: BitLockerSecretKind, secret: String) throws -> String { "" }
            func examineWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> WindowsLogExamination {
                .init(markedForCheck: false, maintenancePending: false, hibernated: false, logReadable: true, logClean: false,
                      logVersion: "2.0", replaySimulated: true, pendingChanges: 7)
            }
            func recoverWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
                .init(replayed: 7, checkedItems: 3)
            }
            func discardWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
                .init(replayed: 0, checkedItems: 3, discarded: true)
            }
        }
        let engine: any PartitionMaintenanceEngine = Engine()
        #expect(try engine.examineWindowsLog(descriptor: 0, blockSize: 512, byteCount: 1).pendingChanges == 7)
        #expect(try engine.recoverWindowsLog(descriptor: 0, blockSize: 512, byteCount: 1, undoFile: URL(filePath: "/dev/null")).replayed == 7)
        #expect(try engine.discardWindowsLog(descriptor: 0, blockSize: 512, byteCount: 1, undoFile: URL(filePath: "/dev/null")).discarded)
    }

    @Test func onlyAnUnpluggedLookingDiskMayBeReplayed() {
        #expect(examination().fitsUnplug && examination().refusal == nil)
        #expect(examination(hibernated: true).refusal == .windowsHibernated)
        #expect(examination(maintenance: true).refusal == .windowsMaintenancePending)
        // Windows saw a problem: not just an unplug.
        #expect(examination(marked: true).refusal == .ntfsDirty)
        #expect(examination(readable: false).refusal == .windowsLogUnreadable)
        #expect(examination(simulated: false).refusal == .windowsLogUnreadable)
        // Already complete: nothing to replay, nothing refused.
        #expect(examination(clean: true).refusal == nil && !examination(clean: true).fitsUnplug)
    }

    @Test func aLogThatWillNotReplayMayOnlyBeGivenUpWhenTheDiskHoldsTogether() {
        let passed = WindowsLogExamination(markedForCheck: false, maintenancePending: false, hibernated: false, logReadable: true,
                                           logClean: false, logVersion: "1.1", replaySimulated: false, pendingChanges: 0,
                                           discardChecked: true, discardPassed: true, checkedItems: 120)
        #expect(!passed.replayable && passed.discardable && passed.fitsUnplug && passed.refusal == nil)
        let failed = WindowsLogExamination(markedForCheck: false, maintenancePending: false, hibernated: false, logReadable: true,
                                           logClean: false, logVersion: "1.1", replaySimulated: false, pendingChanges: 0,
                                           discardChecked: true, discardPassed: false, discardDetail: "inconsistent record 9: clusters marked free")
        #expect(!failed.fitsUnplug && failed.refusal == .checkFoundProblems)
        // A log that replays is replayed, never given up.
        let replays = WindowsLogExamination(markedForCheck: false, maintenancePending: false, hibernated: false, logReadable: true,
                                            logClean: false, logVersion: "2.0", replaySimulated: true, pendingChanges: 1,
                                            discardChecked: true, discardPassed: true)
        #expect(replays.replayable && !replays.discardable)
    }

    @Test func givingTheLogUpNeedsTheAnswerAndTheAgreement() async {
        let runner = RecordingRunner()
        let asked = Counter()
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in self.examination() },
                                            recover: { _ in Issue.record("不应补写"); throw HelperDiskFailure.unavailable },
                                            discard: { _ in asked.add(); return .init(replayed: 0, checkedItems: 5, discarded: true) })
        await #expect(throws: CheckMarkerError.self) { try await recoverer.discard(partition: "disk8s3", answer: .whileRunning, accepted: false) }
        await #expect(throws: CheckMarkerError.self) { try await recoverer.discard(partition: "disk8s3", answer: .unsure, accepted: true) }
        #expect(asked.value == 0 && runner.calls.isEmpty)
        let result = try? await recoverer.discard(partition: "disk8s3", answer: .whileRunning, accepted: true)
        #expect(result?.discarded == true && asked.value == 1 && runner.calls == ["unmount disk8s3", "mount disk8s3"])
    }

    @Test func refusalsOfTheDiskComeBeforeTheLog() {
        #expect(examination(marked: true, hibernated: true).refusal == .windowsHibernated)
        #expect(examination(marked: true, readable: false).refusal == .ntfsDirty)
    }

    @Test func helperRepliesAreValidated() throws {
        let good = try JSONEncoder().encode(HelperWindowsLogReply(examination: examination()))
        #expect(try HelperWindowsLogReply.decodeExamination(good) == examination())
        let badVersion = WindowsLogExamination(markedForCheck: false, maintenancePending: false, hibernated: false, logReadable: true,
                                               logClean: false, logVersion: "x; rm", replaySimulated: true, pendingChanges: 1)
        #expect(throws: HelperServiceError.invalidReply) {
            try HelperWindowsLogReply.decodeExamination(JSONEncoder().encode(HelperWindowsLogReply(examination: badVersion)))
        }
        let both = HelperWindowsLogReply(examination: examination(), result: .init(replayed: 1, checkedItems: 1))
        #expect(throws: HelperServiceError.invalidReply) { try HelperWindowsLogReply.decodeResult(JSONEncoder().encode(both)) }
        let failed = try JSONEncoder().encode(HelperWindowsLogReply(failure: .windowsLogReplayRestored))
        #expect(throws: HelperDiskFailure.windowsLogReplayRestored) { try HelperWindowsLogReply.decodeResult(failed) }
        let negative = try JSONEncoder().encode(HelperWindowsLogReply(result: .init(replayed: -1, checkedItems: 0)))
        #expect(throws: HelperServiceError.invalidReply) { try HelperWindowsLogReply.decodeResult(negative) }
    }

    @Test func examineUnmountsAndMountsAgain() async throws {
        let runner = RecordingRunner()
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in self.examination() }, recover: { _ in Issue.record("不应补写"); throw HelperDiskFailure.unavailable })
        let found = try await recoverer.examine(partition: "disk8s3")
        #expect(found.pendingChanges == 2)
        #expect(runner.calls == ["unmount disk8s3", "mount disk8s3"])
        #expect(!recoverer.isWorking)
    }

    @Test func onlyTheAnswerWhileRunningReachesTheHelper() async {
        let runner = RecordingRunner()
        let asked = Counter()
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in self.examination() },
                                            recover: { _ in asked.add(); return .init(replayed: 2, checkedItems: 10) })
        for answer in [WindowsUnplugAnswer.afterShutdown, .unsure] {
            await #expect(throws: CheckMarkerError.self) { try await recoverer.recover(partition: "disk8s3", answer: answer) }
        }
        #expect(asked.value == 0 && runner.calls.isEmpty, "关机或不确定时不得卸载或补写")
        let result = try? await recoverer.recover(partition: "disk8s3", answer: .whileRunning)
        #expect(result == .init(replayed: 2, checkedItems: 10) && asked.value == 1)
    }

    @Test func aFailedRecoveryStillMountsTheDiskAgain() async {
        let runner = RecordingRunner()
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in self.examination() },
                                            recover: { _ in throw HelperDiskFailure.windowsLogReplayRestored })
        await #expect(throws: CheckMarkerError.failed(HelperDiskFailure.windowsLogReplayRestored.errorDescription!)) {
            try await recoverer.recover(partition: "disk8s3", answer: .whileRunning)
        }
        #expect(runner.calls == ["unmount disk8s3", "mount disk8s3"])
    }

    @Test func noAnswerInTimeLeavesTheDiskUnmounted() async {
        // The helper may still be writing: mounting now would race it.
        let runner = RecordingRunner()
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in self.examination() },
                                            recover: { _ in throw HelperServiceError.timedOut })
        await #expect(throws: CheckMarkerError.self) { try await recoverer.recover(partition: "disk8s3", answer: .whileRunning) }
        #expect(runner.calls == ["unmount disk8s3"])
        #expect(!recoverer.isWorking)
    }

    @Test func aDiskThatWillNotUnmountIsLeftAlone() async {
        let runner = RecordingRunner(unmountStatus: 1)
        let recoverer = WindowsLogRecoverer(runner: runner, retryDelay: .zero, isMounted: { _ in true },
                                            examine: { _ in Issue.record("不应研判"); return self.examination() })
        await #expect(throws: CheckMarkerError.self) { try await recoverer.examine(partition: "disk8s3") }
        #expect(runner.calls == ["unmount disk8s3", "unmount disk8s3", "unmount disk8s3"])
    }

    @Test func theRefusalOffersRecoveryOnTheMac() {
        #expect(DiskReadiness.action(for: .windowsLogUnclean) == .recoverOnMac)
        #expect(DiskReadiness.action(for: .windowsLogRestoreFailed) == nil)
        #expect(HelperDiskFailure.windowsLogUnclean.errorDescription?.contains("在 Mac 上恢复") == true)
    }

    @Test func undoPutsEveryRangeBackNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "volisle-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let device = dir.appending(path: "device.img")
        let original = Data((0..<16_384).map { UInt8($0 % 251) })
        try original.write(to: device)
        let fd = open(device.path, O_RDWR)
        defer { close(fd) }
        let undo = try PartitionUndoLog(url: dir.appending(path: "a.undo"))
        // Save-then-write, twice over the same range: restoring newest first ends at the original.
        for (offset, byte) in [(4096, UInt8(0xAA)), (4096, 0xBB), (12_288, 0xCC)] {
            var old = [UInt8](repeating: 0, count: 4096)
            #expect(pread(fd, &old, 4096, off_t(offset)) == 4096)
            #expect(old.withUnsafeBytes { undo.save($0, at: Int64(offset)) })
            let new = [UInt8](repeating: byte, count: 4096)
            #expect(pwrite(fd, new, 4096, off_t(offset)) == 4096)
        }
        #expect(undo.records == 3)
        #expect(try Data(contentsOf: device) != original)
        #expect(undo.restore(to: fd))
        #expect(try Data(contentsOf: device) == original)
    }

    @Test func aDamagedUndoFileIsNotReplayed() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "volisle-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let device = dir.appending(path: "device.img")
        try Data(count: 8192).write(to: device)
        let fd = open(device.path, O_RDWR)
        defer { close(fd) }
        let url = dir.appending(path: "b.undo")
        let undo = try PartitionUndoLog(url: url)
        let block = [UInt8](repeating: 7, count: 4096)
        #expect(block.withUnsafeBytes { undo.save($0, at: 0) })
        // Cut the last record short: nothing is written back.
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: try handle.seekToEnd() - 10)
        try handle.close()
        #expect(!undo.restore(to: fd))
        #expect(try Data(contentsOf: device) == Data(count: 8192))
        // An existing file is never reused.
        #expect(throws: HelperDiskFailure.unavailable) { _ = try PartitionUndoLog(url: url) }
    }
}

private final class RecordingRunner: EraseCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let unmountStatus: Int32
    init(unmountStatus: Int32 = 0) { self.unmountStatus = unmountStatus }
    var calls: [String] { lock.withLock { log } }
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        lock.withLock { log.append(arguments.joined(separator: " ")) }
        return (arguments.first == "unmount" ? unmountStatus : 0, "")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
