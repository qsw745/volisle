import Foundation
import Testing
@testable import VolisleCore

struct CopyTransferRateTests {
    // Counting the restored offset as new traffic would inflate the first speed.
    @Test func restoredBytesAreOnlyABaseline() {
        var rate = CopyTransferRate()
        rate.record(bytes: 900_000_000, at: 10)
        #expect(rate.bytesPerSecond(at: 10) == nil)
        rate.record(bytes: 902_000_000, at: 10.5)
        #expect(rate.bytesPerSecond(at: 10.5) == 4_000_000)
    }

    // A lifetime average would keep including the old, slow phase.
    @Test func reportsRecentTrafficAcrossFileBoundaries() {
        var rate = CopyTransferRate()
        for (time, bytes) in [(0.0, 0), (1, 1_000_000), (2, 2_000_000),
                              (3, 5_000_000), (4, 8_000_000), (5, 11_000_000)] {
            rate.record(bytes: Int64(bytes), at: time)
        }
        #expect(rate.bytesPerSecond(at: 5) == 3_000_000)
    }

    // No new callback must not leave an old nonzero speed on screen forever.
    @Test func blockedIOFallsToZeroWithoutAnotherReport() {
        var rate = CopyTransferRate()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 2_000_000, at: 1)
        rate.record(bytes: 4_000_000, at: 2)
        #expect(rate.bytesPerSecond(at: 3) == 4_000_000.0 / 3)
        #expect(rate.bytesPerSecond(at: 4) == 2_000_000.0 / 3)
        #expect(rate.bytesPerSecond(at: 5) == 0)
    }

    @Test func interpolatesTheRollingWindowBoundary() {
        var rate = CopyTransferRate()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 4_000_000, at: 2)
        rate.record(bytes: 8_000_000, at: 4)
        #expect(rate.bytesPerSecond(at: 4) == 2_000_000)
    }

    // File boundaries bypass UI throttling; a fixed sample count must not shrink the time window.
    @Test func denseSmallFileReportsKeepTheWholeRecentWindow() throws {
        var rate = CopyTransferRate()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 1_000_000, at: 1)
        rate.record(bytes: 2_000_000, at: 2)
        for tick in 2001...3000 {
            rate.record(bytes: 2_000_000 + Int64(tick - 2000) * 3_000, at: Double(tick) / 1_000)
        }
        let speed = try #require(rate.bytesPerSecond(at: 3))
        #expect(abs(speed - 5_000_000.0 / 3) < 0.001)
    }

    // A shorter recovered part starts a fresh measurement instead of a negative speed.
    @Test func decreasedOffsetRestartsMeasurement() {
        var rate = CopyTransferRate()
        rate.record(bytes: 10_000_000, at: 0)
        rate.record(bytes: 12_000_000, at: 1)
        rate.record(bytes: 5_000_000, at: 2)
        #expect(rate.bytesPerSecond(at: 2) == nil)
        rate.record(bytes: 6_000_000, at: 3)
        #expect(rate.bytesPerSecond(at: 3) == 1_000_000)
    }

    @Test func ignoresAnOlderOrDuplicateTimestamp() {
        var rate = CopyTransferRate()
        rate.record(bytes: 0, at: 10)
        rate.record(bytes: 2_000_000, at: 11)
        rate.record(bytes: 99_000_000, at: 11)
        rate.record(bytes: 99_000_000, at: 9)
        #expect(rate.bytesPerSecond(at: 11) == 2_000_000)
    }

    @Test func jobHidesSpeedOutsideCopyingAndResetsAfterChecking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("source".utf8).write(to: source)
        let plan = try CopyPlan.make(sources: [source], diskKey: "DISK", volumeName: "Disk", destination: "")
        var job = CopyQueue.Job(plan: plan, progress: CopyProgress())
        job.running = true
        job.recordTransfer(.init(copiedBytes: 1_000_000, transferredBytes: 0), at: 0)
        job.recordTransfer(.init(copiedBytes: 3_000_000, transferredBytes: 2_000_000), at: 1)
        #expect(job.transferBytesPerSecond(at: 1) == 2_000_000)
        job.running = false
        #expect(job.transferBytesPerSecond(at: 1) == nil)
        job.running = true
        job.recordTransfer(.init(copiedBytes: 3_000_000, checking: true, checkedBytes: 99_000_000), at: 2)
        #expect(job.transferBytesPerSecond(at: 2) == nil)
        job.recordTransfer(.init(copiedBytes: 2_000_000, transferredBytes: 2_000_000), at: 30)
        #expect(job.transferBytesPerSecond(at: 30) == nil)
        job.recordTransfer(.init(copiedBytes: 3_000_000, transferredBytes: 3_000_000), at: 31)
        #expect(job.transferBytesPerSecond(at: 31) == 1_000_000)
        job.resetTransferRate()
        #expect(job.transferBytesPerSecond(at: 31) == nil)
    }

    @Test func simultaneousTransfersKeepSeparateRates() {
        var a = CopyTransferRate(), b = CopyTransferRate()
        a.record(bytes: 0, at: 0); b.record(bytes: 0, at: 0)
        a.record(bytes: 1_000_000, at: 1); b.record(bytes: 9_000_000, at: 1)
        #expect(a.bytesPerSecond(at: 1) == 1_000_000)
        #expect(b.bytesPerSecond(at: 1) == 9_000_000)
    }

    @Test func skippedContentDoesNotCountAsTransferredTraffic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skipped = root.appendingPathComponent("skip"), copied = root.appendingPathComponent("copy")
        try Data(count: 1_000_000).write(to: skipped)
        try Data(count: 2_000_000).write(to: copied)
        let plan = try CopyPlan.make(sources: [skipped, copied], diskKey: "DISK", volumeName: "Disk", destination: "")
        var progress = CopyProgress(); progress.skipped = [0]
        var last = ResumableCopier.Status()
        _ = try ResumableCopier(plan: plan, root: disk).run(from: progress, resuming: false, save: { _ in }, report: { last = $0 })
        #expect(last.copiedBytes == 3_000_000)
        #expect(last.transferredBytes == 2_000_000)
        // A following run can reuse the matching file; those bytes must not become traffic again.
        _ = try ResumableCopier(plan: plan, root: disk).run(from: progress, resuming: true, save: { _ in }, report: { last = $0 })
        #expect(last.transferredBytes == 0)
    }

    // Exercise the real worker -> main-actor queue path, not only the rate calculator.
    @MainActor @Test func queueReportsSpeedAndClearsItOnComparisonAndPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data(count: 64_000).write(to: source)
        let copier = ControlledTransfer()
        defer { copier.stop() }
        let queue = CopyQueue(store: CopyJobStore(directory: root.appendingPathComponent("records")),
                              writableDisk: { _ in .init(root: root, session: UUID()) }, diskPresent: { _ in true },
                              copierFactory: { _, _ in copier })
        let plan = try CopyPlan.make(sources: [source], diskKey: "DISK", volumeName: "Disk", destination: "")
        try await queue.enqueue(plan)
        try await wait { queue.jobs.first?.status.current == "first" }
        copier.send(.init(copiedBytes: 8_000, transferredBytes: 8_000, current: "second"))
        try await wait { queue.jobs.first?.status.current == "second" }
        #expect((queue.jobs.first?.transferBytesPerSecond() ?? 0) > 0)
        copier.send(.init(copiedBytes: 8_000, transferredBytes: 8_000, current: "second", checking: true, checkedBytes: 64_000))
        try await wait { queue.jobs.first?.status.checking == true }
        #expect(queue.jobs.first?.transferBytesPerSecond() == nil)
        copier.send(.init(copiedBytes: 8_000, transferredBytes: 8_000, current: "second"))
        try await wait { queue.jobs.first?.status.checking == false }
        #expect(queue.jobs.first?.transferBytesPerSecond() == nil)
        copier.send(.init(copiedBytes: 16_000, transferredBytes: 16_000, current: "third"))
        try await wait { queue.jobs.first?.status.current == "third" }
        #expect((queue.jobs.first?.transferBytesPerSecond() ?? 0) > 0)
        await queue.pause(plan.id)
        #expect(queue.jobs.first?.running == false)
        #expect(queue.jobs.first?.transferBytesPerSecond() == nil)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

/// Only filesystem I/O is replaced; the actual queue still schedules, samples and pauses the worker.
private final class ControlledTransfer: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [ResumableCopier.Status] = [.init(copiedBytes: 0, current: "first")]
    private var stopped = false
    func send(_ status: ResumableCopier.Status) {
        condition.lock(); pending.append(status); condition.signal(); condition.unlock()
    }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        while true {
            condition.lock()
            while pending.isEmpty && !stopped { condition.wait() }
            if stopped { condition.unlock(); throw CopyError.stopped }
            let status = pending.removeFirst()
            condition.unlock()
            report(status)
        }
    }
}
