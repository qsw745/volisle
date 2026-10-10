import Foundation
import Testing
@testable import VolisleCore

/// Copies onto different disks run side by side; onto one disk, one at a time.
/// Stopping, pausing or ending the write session of one disk leaves the copy
/// onto the other alone.
@MainActor struct CopyQueueParallelTests {
    @MainActor private final class Bench {
        struct Disk {
            let root: URL
            var session = UUID()
            var writable = true
        }
        let base: URL, source: URL, records: URL
        var disks: [String: Disk] = [:]
        /// The next question about a disk waits until released, like a slow check of its write session.
        var holdNext = false
        private(set) var held: CheckedContinuation<Void, Never>?
        func release() { held?.resume(); held = nil }
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-parallel-" + UUID().uuidString)
            source = base.appendingPathComponent("source"); records = base.appendingPathComponent("records")
            for url in [source, records] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            for key in ["A", "B"] {
                let root = base.appendingPathComponent("disk-" + key)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                disks[key] = Disk(root: root)
            }
            var movie = Data(count: 4 << 20)
            movie.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try movie.write(to: source.appendingPathComponent("movie.bin"))
        }
        isolated deinit { try? FileManager.default.removeItem(at: base) }
        func queue(copierFactory: @escaping @Sendable (CopyPlan, URL) -> any CopyQueueCopier = { ResumableCopier(plan: $0, root: $1) }) -> CopyQueue {
            CopyQueue(store: store, writableDisk: { [unowned self] key in
                if holdNext {
                    holdNext = false
                    await withCheckedContinuation { held = $0 }
                }
                return disks[key].flatMap { $0.writable ? .init(root: $0.root, session: $0.session) : nil }
            }, diskPresent: { [unowned self] key in disks[key] != nil }, copierFactory: copierFactory)
        }
        var store: CopyJobStore { CopyJobStore(directory: records) }
        func session(_ key: String) throws -> UUID { try #require(disks[key]).session }
        /// As after returning to read-only and turning writing on again.
        func remount(_ key: String) { disks[key]?.session = UUID(); disks[key]?.writable = true }
        @discardableResult func add(_ queue: CopyQueue, to key: String) async throws -> UUID {
            let plan = try await queue.plan(sources: [source.appendingPathComponent("movie.bin")], diskKey: key, volumeName: key,
                                            destination: "", root: try #require(disks[key]).root).plan
            try await queue.enqueue(plan)
            return plan.id
        }
        func same(on key: String) throws -> Bool {
            try Data(contentsOf: source.appendingPathComponent("movie.bin"))
                == Data(contentsOf: try #require(disks[key]).root.appendingPathComponent("movie.bin"))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
    private func job(_ queue: CopyQueue, _ id: UUID) -> CopyQueue.Job? { queue.jobs.first { $0.id == id } }
    private func running(_ queue: CopyQueue, _ id: UUID) -> Bool { job(queue, id)?.running == true }

    @Test func copiesOntoTwoDisksRunAtTheSameTime() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, a) && running(queue, b) }
        await queue.sessionWillEnd()
    }

    @Test func bothCopiesFinishWithTheirFiles() async throws {
        let bench = try Bench(), queue = bench.queue()
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { [a, b].allSatisfy { job(queue, $0)?.progress.finished == true && !running(queue, $0) } }
        #expect(try bench.same(on: "A") && bench.same(on: "B"))
        let sessionA = try bench.session("A"), sessionB = try bench.session("B")
        #expect(job(queue, a)?.finishedIn == sessionA && job(queue, b)?.finishedIn == sessionB,
                "each is confirmed by its own disk's session")
    }

    @Test func aSecondCopyOntoTheSameDiskWaitsForTheFirst() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let first = try await bench.add(queue, to: "A"), second = try await bench.add(queue, to: "A")
        let other = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, first) && running(queue, other) }
        #expect(!running(queue, second), "one disk takes one copy at a time")
        await queue.pause(first)
        try await waitUntil { running(queue, second) }
        #expect(!running(queue, first) && running(queue, other))
        await queue.sessionWillEnd()
    }

    @Test func endingOneDisksSessionStopsOnlyTheCopyOntoIt() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, a) && running(queue, b) }
        let ended = try bench.session("A")
        await queue.sessionWillEnd(session: ended)
        #expect(!running(queue, a) && job(queue, a)?.progress.pause == .disk)
        #expect(running(queue, b), "the copy onto the other disk goes on")
        #expect(job(queue, a)?.writeIntent?.enabled == false && job(queue, b)?.writeIntent?.enabled == true,
                "only the disk returned to read-only stops being asked for")
        bench.disks["A"]?.writable = false
        queue.sessionDidEnd(ended, cleanly: true)
        #expect(queue.writeRequest(for: "A") == nil, "returning a disk to read-only is not undone by its copy")
        // Writing turned on again, and continued by the user: it joins the copy still running.
        bench.remount("A")
        await queue.resume(a)
        try await waitUntil { running(queue, a) }
        #expect(running(queue, b))
        await queue.sessionWillEnd()
    }

    @Test func aPauseAndAnotherDisksSessionEndKeepTheirOwnReasons() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, a) && running(queue, b) }
        async let paused: Void = queue.pause(a)
        await queue.sessionWillEnd(session: try bench.session("B"))
        await paused
        #expect(job(queue, a)?.progress.pause == .user, "paused by the user: it waits for Continue")
        #expect(job(queue, b)?.progress.pause == .disk, "stopped with its disk: it continues with its disk")
    }

    @Test func endingEverySessionStopsEveryCopy() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, a) && running(queue, b) }
        // Before an update, say: no session is named.
        await queue.sessionWillEnd()
        #expect(!running(queue, a) && !running(queue, b))
        #expect(job(queue, a)?.progress.pause == .disk && job(queue, b)?.progress.pause == .disk)
        queue.sessionDidEnd(nil, cleanly: true)
        #expect(queue.writeRequest(for: "A") == nil && queue.writeRequest(for: "B") == nil,
                "neither copy asks for its disk to be made writable again")
    }

    @Test func cancellingOneCopyLeavesTheOtherRunning() async throws {
        let bench = try Bench(), queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(queue, to: "A"), b = try await bench.add(queue, to: "B")
        try await waitUntil { running(queue, a) && running(queue, b) }
        await queue.cancel(a)
        #expect(job(queue, a) == nil && running(queue, b))
        await queue.sessionWillEnd()
    }

    @Test func aFailingDiskLeavesTheCopyOntoTheOtherAlone() async throws {
        let bench = try Bench()
        let queue = bench.queue(copierFactory: { plan, _ -> any CopyQueueCopier in
            if plan.diskKey == "A" { FailingCopy() } else { HeldCopy() }
        })
        let b = try await bench.add(queue, to: "B"), a = try await bench.add(queue, to: "A")
        let waitingOnB = try await bench.add(queue, to: "B")
        try await waitUntil { job(queue, a)?.progress.pause != nil }
        #expect(!running(queue, a) && running(queue, b))
        #expect(!running(queue, waitingOnB), "a copy ending on one disk does not let a second one onto the other")
        await queue.sessionWillEnd()
    }

    @Test func aCopyBeingCancelledIsNotStartedBehindItsBack() async throws {
        let bench = try Bench(), made = Counter()
        let queue = bench.queue(copierFactory: { _, _ in made.add(); return HeldCopy() })
        let a = try await bench.add(queue, to: "A")
        try await waitUntil { running(queue, a) }
        // Unplugged and plugged back in: it waits for its disk, which is writable again.
        let ended = try bench.session("A")
        await queue.sessionWillEnd(session: ended, reconnecting: true)
        queue.sessionDidEnd(ended, cleanly: false)
        bench.remount("A")
        // Cancelling removes its part file, for which it first asks about the disk…
        bench.holdNext = true
        async let cancelled: Void = queue.cancel(a)
        try await waitUntil { bench.held != nil }
        // …and meanwhile the disk list changes, or a copy onto the other disk ends.
        await queue.reconcile()
        #expect(!running(queue, a) && made.count == 1, "a cancelled copy must not write its file after all")
        bench.release()
        await cancelled
        #expect(job(queue, a) == nil)
        await queue.sessionWillEnd()
    }

    @Test func continuingAStaleCopyWhileAnotherDiskAnswersIsNotUndone() async throws {
        let bench = try Bench()
        let first = bench.queue(copierFactory: { _, _ in HeldCopy() })
        let a = try await bench.add(first, to: "A"), b = try await bench.add(first, to: "B")
        try await waitUntil { running(first, a) && running(first, b) }
        await first.sessionWillEnd()
        var old = try #require(bench.store.load().first { $0.0.id == b }?.1)
        old.pausedAt = Date().addingTimeInterval(-2 * 24 * 3600)
        try bench.store.save(old, for: b)
        // Relaunched: the copy onto A is looked at first, and its disk takes a moment to answer.
        let queue = bench.queue(copierFactory: { _, _ in HeldCopy() })
        queue.load()
        bench.holdNext = true
        async let reconciled: Void = queue.reconcile()
        try await waitUntil { bench.held != nil }
        await queue.resume(b)
        bench.release()
        await reconciled
        try await waitUntil { running(queue, b) }
        #expect(job(queue, b)?.progress.problem == nil, "the user's Continue is newer than the day-old pause")
        await queue.sessionWillEnd()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// Fails at once, like a write onto a disk that just stopped answering.
private final class FailingCopy: CopyQueueCopier, @unchecked Sendable {
    func stop() {}
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        throw CopyError.destination("movie.bin", EIO)
    }
}

/// Runs until told to stop, like a copy in the middle of a large file.
private final class HeldCopy: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var stopping = false
    func stop() { condition.lock(); stopping = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        condition.lock()
        while !stopping { condition.wait() }
        condition.unlock()
        throw CopyError.stopped
    }
}
