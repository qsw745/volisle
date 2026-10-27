import Foundation
import Testing
@testable import VolisleCore

@MainActor struct CopyQueueConcurrencyTests {
    @MainActor private final class Bench {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionA = UUID(), sessionB = UUID()
        var writable = true
        init() throws {
            for dir in ["source", "A", "B"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
            for name in ["a", "b", "c", "d"] { try Data(repeating: 42, count: 4096).write(to: root.appendingPathComponent("source/" + name)) }
        }
        isolated deinit { try? FileManager.default.removeItem(at: root) }
        var store: CopyJobStore { CopyJobStore(directory: root.appendingPathComponent("records")) }
        func queue(factory: @escaping @Sendable (CopyPlan, URL) -> any CopyQueueCopier = { ResumableCopier(plan: $0, root: $1) }) -> CopyQueue {
            CopyQueue(store: store, writableDisk: { [unowned self] key in
                writable ? .init(root: root.appendingPathComponent(key), session: key == "A" ? sessionA : sessionB) : nil
            }, diskPresent: { _ in true }, copierFactory: factory)
        }
        @discardableResult func add(_ queue: CopyQueue, _ name: String, to key: String = "A", destination: String = "") async throws -> UUID {
            let plan = try CopyPlan.make(sources: [root.appendingPathComponent("source/" + name)], diskKey: key, volumeName: key, destination: destination)
            try await queue.enqueue(plan); return plan.id
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    private func job(_ q: CopyQueue, _ id: UUID) -> CopyQueue.Job? { q.jobs.first { $0.id == id } }

    @Test func twoIndependentTargetsRunAndAThirdWaitsUntilOnePauses() async throws {
        let bench = try Bench(), queue = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() })
        let a = try await bench.add(queue, "a"), b = try await bench.add(queue, "b"), c = try await bench.add(queue, "c")
        #expect(job(queue, a)?.running == true && job(queue, b)?.running == true)
        #expect(job(queue, c)?.running == false)
        #expect(job(queue, a)?.plan.partID == a)
        await queue.pause(a)
        try await wait { job(queue, c)?.running == true }
        #expect(job(queue, a)?.progress.pause == .user && job(queue, b)?.running == true)
        await queue.resume(a)
        #expect(job(queue, a)?.running == false, "resuming cannot exceed two active workers")
        await queue.sessionWillEnd()
    }

    @Test func pausedSameTargetStillBlocksItsReplacementButNotUnrelatedWork() async throws {
        let bench = try Bench(), queue = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() })
        let first = try await bench.add(queue, "a")
        await queue.pause(first)
        let replacement = try await bench.add(queue, "a"), independent = try await bench.add(queue, "b")
        #expect(job(queue, replacement)?.running == false)
        #expect(job(queue, independent)?.running == true)
        await queue.cancel(first)
        try await wait { job(queue, replacement)?.running == true }
        #expect(job(queue, independent)?.running == true)
        await queue.sessionWillEnd()
    }

    @Test func completedUnconfirmedTargetKeepsItsReservation() async throws {
        let bench = try Bench(), queue = bench.queue()
        let first = try await bench.add(queue, "a")
        try await wait { job(queue, first)?.progress.finished == true }
        let replacement = try await bench.add(queue, "a"), independent = try await bench.add(queue, "b")
        #expect(job(queue, first)?.confirmed == false)
        #expect(job(queue, replacement)?.running == false && job(queue, replacement)?.progress.finished == false)
        try await wait { job(queue, independent)?.progress.finished == true }
    }

    @Test func endingOneVolumeStopsBothWorkersAndLeavesTheOtherVolumeRunning() async throws {
        let bench = try Bench(), queue = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() })
        let a = try await bench.add(queue, "a"), b = try await bench.add(queue, "b"), other = try await bench.add(queue, "c", to: "B")
        #expect(job(queue, a)?.running == true && job(queue, b)?.running == true)
        await queue.sessionWillEnd(session: bench.sessionA)
        #expect(job(queue, a)?.running == false && job(queue, b)?.running == false)
        #expect(job(queue, a)?.progress.pause == .disk && job(queue, b)?.progress.pause == .disk)
        #expect(job(queue, other)?.running == true)
        await queue.sessionWillEnd()
    }

    @Test func cancellationTimeoutKeepsItsPartAndSlotUntilTheWorkerActuallyExits() async throws {
        let bench = try Bench(), stuck = ConcurrencyHeldCopy(ignoresStop: true)
        defer { stuck.release() }
        let queue = bench.queue(factory: { plan, _ in plan.items[0].relative == "a" ? stuck : ConcurrencyHeldCopy() })
        let a = try await bench.add(queue, "a"), b = try await bench.add(queue, "b"), c = try await bench.add(queue, "c")
        let plan = try #require(job(queue, a)?.plan)
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: bench.root.appendingPathComponent("A/a").path, partID: plan.partID))
        try Data("in-flight".utf8).write(to: part)
        await queue.cancel(a) // The actual production ten-second deadline expires.
        #expect(job(queue, a)?.isCancelling == true && job(queue, a)?.running == true)
        #expect(FileManager.default.fileExists(atPath: part.path))
        #expect(job(queue, c)?.running == false)
        await queue.resume(a)
        await queue.cancel(a)
        #expect(job(queue, a)?.writeIntent?.enabled == false)
        stuck.release()
        try await wait { job(queue, a) == nil && job(queue, c)?.running == true }
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(job(queue, b)?.running == true)
        await queue.sessionWillEnd()
    }

    @Test func twoRealCopiesOnTheSameVolumeKeepTheirExactContents() async throws {
        let bench = try Bench(), queue = bench.queue()
        let a = try await bench.add(queue, "a"), b = try await bench.add(queue, "b")
        try await wait { [a,b].allSatisfy { job(queue, $0)?.progress.finished == true } }
        for name in ["a", "b"] {
            #expect(try Data(contentsOf: bench.root.appendingPathComponent("source/" + name)) == Data(contentsOf: bench.root.appendingPathComponent("A/" + name)))
        }
    }

    @Test func aFullDestinationOnlyStopsItsOwnJob() async throws {
        let bench = try Bench(), queue = bench.queue(factory: { plan, _ in
            plan.items[0].relative == "a" ? FullDestinationCopy() as any CopyQueueCopier : ConcurrencyHeldCopy()
        })
        let a = try await bench.add(queue, "a"), b = try await bench.add(queue, "b"), c = try await bench.add(queue, "c")
        try await wait { job(queue, a)?.progress.pause == .problem && job(queue, c)?.running == true }
        #expect(job(queue, b)?.running == true)
        await queue.cancel(a)
        #expect(job(queue, b)?.running == true && job(queue, c)?.running == true)
        await queue.sessionWillEnd()
    }

    @Test func deferredOwnedCleanupCannotRemoveANewerJobsPart() async throws {
        let bench = try Bench(), queue = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() })
        let old = try await bench.add(queue, "a")
        await queue.pause(old)
        let newer = try await bench.add(queue, "a")
        let final = bench.root.appendingPathComponent("A/a").path
        let oldPart = URL(fileURLWithPath: ResumableCopier.partPath(for: final, partID: old))
        let newPart = URL(fileURLWithPath: ResumableCopier.partPath(for: final, partID: newer))
        try Data("old".utf8).write(to: oldPart); try Data("newer".utf8).write(to: newPart)
        bench.writable = false
        await queue.cancel(old)
        #expect(bench.store.loadCleanups().first?.partID == old)
        bench.writable = true
        await queue.reconcile()
        try await wait { job(queue, newer)?.running == true }
        #expect(!FileManager.default.fileExists(atPath: oldPart.path))
        #expect(try Data(contentsOf: newPart) == Data("newer".utf8))
        await queue.sessionWillEnd()
    }

    @Test func deferredCleanupReservesItsActualHiddenPathAcrossWritableTransitions() async throws {
        let bench = try Bench(), owner = UUID()
        let hidden = (ResumableCopier.partPath(for: "/a", partID: owner) as NSString).lastPathComponent
        try Data("new file".utf8).write(to: bench.root.appendingPathComponent("source/" + hidden))
        try Data("old partial".utf8).write(to: bench.root.appendingPathComponent("A/" + hidden))
        #expect(bench.store.saveCleanups([.init(diskKey: "A", targets: ["a"], partID: owner)]))
        var reads = 0
        let queue = CopyQueue(store: bench.store, writableDisk: { _ in
            reads += 1
            return reads == 1 ? nil : .init(root: bench.root.appendingPathComponent("A"), session: bench.sessionA)
        }, diskPresent: { _ in true }, copierFactory: { _, _ in ConcurrencyHeldCopy() })
        queue.load()
        let id = try await bench.add(queue, hidden)
        #expect(job(queue, id)?.running == false, "cleanup must reserve its hidden path even if the disk becomes writable between lookups")
        #expect(job(queue, id)?.waitingFor == .cleanup)
        await queue.reconcile()
        try await wait { job(queue, id)?.running == true }
        #expect(bench.store.loadCleanups().isEmpty)
        await queue.sessionWillEnd()
    }

    @Test func oldSharedPartsSurviveCancellingOneLegacyRecord() async throws {
        let bench = try Bench()
        let first = try CopyPlan.make(sources: [bench.root.appendingPathComponent("source/a")], diskKey: "A", volumeName: "A", destination: "")
        let second = try CopyPlan.make(sources: [bench.root.appendingPathComponent("source/a")], diskKey: "A", volumeName: "A", destination: "")
        for plan in [first, second] {
            try bench.store.save(plan)
            var saved = CopyProgress(); saved.pause = .user; saved.started = true
            try bench.store.save(saved, for: plan.id)
        }
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: bench.root.appendingPathComponent("A/a").path))
        try Data(repeating: 42, count: 1024).write(to: part)
        let queue = bench.queue(); queue.load()
        await queue.cancel(first.id)
        #expect(FileManager.default.fileExists(atPath: part.path))
        await queue.resume(second.id)
        try await wait { job(queue, second.id)?.progress.finished == true }
        #expect(job(queue, second.id)?.plan.partID == nil)
        #expect(try Data(contentsOf: bench.root.appendingPathComponent("A/a")) == Data(repeating: 42, count: 4096))
    }

    @Test func relaunchRetainsTwoNamespacesAndExplicitPause() async throws {
        let bench = try Bench(), old = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() })
        let a = try await bench.add(old, "a"), b = try await bench.add(old, "b")
        await old.pause(a)
        await old.sessionWillEnd(reconnecting: true)
        let restored = bench.queue(factory: { _, _ in ConcurrencyHeldCopy() }); restored.load()
        await restored.reconcile()
        #expect(job(restored, a)?.progress.pause == .user && job(restored, a)?.running == false)
        #expect(job(restored, b)?.running == true)
        #expect(job(restored, a)?.plan.partID == a && job(restored, b)?.plan.partID == b)
        await restored.resume(a)
        #expect(job(restored, a)?.running == true && job(restored, b)?.running == true)
        await restored.sessionWillEnd()
    }

    @Test func repeatedSkipWhileCleanupWaitsOnlySkipsOnce() async throws {
        let bench = try Bench()
        let plan = try CopyPlan.make(sources: [bench.root.appendingPathComponent("source/a")], diskKey: "A", volumeName: "A", destination: "").usingOwnedParts()
        try bench.store.save(plan)
        var progress = CopyProgress(); progress.pause = .problem; progress.failedAt = 0
        try bench.store.save(progress, for: plan.id)
        var held: [CheckedContinuation<CopyQueue.WritableDisk?, Never>] = []
        var holding = true
        let disk = CopyQueue.WritableDisk(root: bench.root.appendingPathComponent("A"), session: bench.sessionA)
        let queue = CopyQueue(store: bench.store, writableDisk: { _ in
            if holding { return await withCheckedContinuation { held.append($0) } }
            return disk
        }, diskPresent: { _ in true }, copierFactory: { _, _ in ConcurrencyHeldCopy() })
        queue.load()
        let one = Task { await queue.skip(plan.id) }, two = Task { await queue.skip(plan.id) }
        try await wait { held.count == 2 }
        holding = false
        for continuation in held { continuation.resume(returning: disk) }
        await one.value; await two.value
        #expect(job(queue, plan.id)?.progress.skipped == [0])
        await queue.sessionWillEnd()
    }
}

private struct FullDestinationCopy: CopyQueueCopier {
    func stop() {}
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void, report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        throw CopyError.destination("a", ENOSPC)
    }
}

private final class ConcurrencyHeldCopy: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false, released = false
    private let ignoresStop: Bool
    init(ignoresStop: Bool = false) { self.ignoresStop = ignoresStop }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void, report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        condition.lock()
        while !released && (!stopped || ignoresStop) { condition.wait() }
        condition.unlock()
        throw CopyError.stopped
    }
}
