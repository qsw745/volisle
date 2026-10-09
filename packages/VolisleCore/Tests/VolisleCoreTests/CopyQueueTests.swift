import Foundation
import Testing
@testable import VolisleCore

/// The copy queue around ResumableCopier: start, stop when Volisle ends the
/// write session, continue when the disk is writable again, recheck after an
/// unplug right at the end, confirm after a clean end, skip, cancel, relaunch.
@MainActor struct CopyQueueTests {
    @MainActor private final class Bench {
        let base: URL, source: URL, disk: URL, records: URL
        var writable = true
        var present = true
        /// The write session: a new one after the disk was unmounted and mounted again.
        var session = UUID()
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-queue-" + UUID().uuidString)
            source = base.appendingPathComponent("source"); disk = base.appendingPathComponent("disk"); records = base.appendingPathComponent("records")
            for url in [source, disk, records] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            var big = Data(count: 48 << 20)
            big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Album"), withIntermediateDirectories: true)
            try big.write(to: source.appendingPathComponent("Album/movie.bin"))
            for i in 0..<5 { try Data("photo \(i)".utf8).write(to: source.appendingPathComponent("Album/photo\(i).jpg")) }
        }
        isolated deinit { try? FileManager.default.removeItem(at: base) }
        var store: CopyJobStore { CopyJobStore(directory: records) }
        func queue() -> CopyQueue {
            CopyQueue(store: store, writableDisk: { [unowned self] uuid in
                uuid == "VOL" && writable && present ? .init(root: disk, session: session) : nil
            }, diskPresent: { [unowned self] uuid in uuid == "VOL" && present })
        }
        func queue(copierFactory: @escaping @Sendable (CopyPlan, URL) -> any CopyQueueCopier) -> CopyQueue {
            CopyQueue(store: store, writableDisk: { [unowned self] uuid in
                uuid == "VOL" && writable && present ? .init(root: disk, session: session) : nil
            }, diskPresent: { [unowned self] uuid in uuid == "VOL" && present }, copierFactory: copierFactory)
        }
        /// The write mount's journal report, as the extension answers it.
        let reports = Reports()
        func queue(reporting: Bool) -> CopyQueue {
            let reports = reports
            return CopyQueue(store: store, writableDisk: { [unowned self] uuid in
                uuid == "VOL" && writable && present ? .init(root: disk, session: session) : nil
            }, diskPresent: { [unowned self] uuid in uuid == "VOL" && present },
               copierFactory: { ResumableCopier(plan: $0, root: $1) }, durability: { _, flush in reports.read(flush: flush) })
        }
        func plan(_ queue: CopyQueue) async throws -> CopyPlan {
            try await queue.plan(sources: [source.appendingPathComponent("Album")], diskKey: "VOL", volumeName: "qsw",
                                 destination: "备份", root: disk).plan
        }
        func add(_ queue: CopyQueue) async throws { try await queue.enqueue(plan(queue)) }
        func same(_ relative: String) throws -> Bool {
            try Data(contentsOf: source.appendingPathComponent(relative)) == Data(contentsOf: disk.appendingPathComponent("备份/" + relative))
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: disk.appendingPathComponent("备份/" + relative).path) }
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var journal = UUID(), written: UInt64 = 7, durable: UInt64 = 4, available = true
        private(set) var flushed = 0
        func read(flush: Bool) -> WriteDurability? {
            lock.withLock {
                if flush { flushed += 1 }
                return available ? WriteDurability(session: journal, writtenBelow: written, durableBelow: durable) : nil
            }
        }
        func set(durable: UInt64? = nil, journal: UUID? = nil, available: Bool? = nil) {
            lock.withLock {
                if let durable { self.durable = durable }
                if let journal { self.journal = journal }
                if let available { self.available = available }
            }
        }
    }

    @Test func endingAnotherDisksSessionLeavesThisCopyRunning() async throws {
        let bench = try Bench(), copier = ReportOnlyCopy()
        let queue = bench.queue(copierFactory: { _, _ in copier })
        try await bench.add(queue)
        try await waitUntil { queue.jobs.first?.running == true }
        let other = UUID()
        await queue.sessionWillEnd(session: other)
        #expect(queue.jobs.first?.running == true, "a copy onto another disk goes on")
        queue.sessionDidEnd(other, cleanly: true)
        await queue.sessionWillEnd(session: bench.session)
        try await waitUntil { queue.jobs.first?.running == false }
        #expect(queue.jobs.first?.progress.pause == .disk, "its own disk's session ending stops it")
    }

    @Test func aCopyIsConfirmedOnceTheDiskReportsItPastRollback() async throws {
        let bench = try Bench()
        let queue = bench.queue(reporting: true)
        try await bench.add(queue)
        try await finished(queue)
        #expect(bench.reports.flushed == 1, "the system's cache is pushed to the disk before the report is read")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(queue.jobs.first?.confirmed == false, "still inside the journal's window")
        bench.reports.set(durable: 7)
        try await waitUntil { queue.jobs.first?.confirmed == true }
        #expect(bench.store.load().isEmpty)
    }

    @Test func noReportOrAnotherJournalSessionNeverConfirms() async throws {
        for change in [0, 1] {
            let bench = try Bench()
            let queue = bench.queue(reporting: true)
            try await bench.add(queue)
            try await finished(queue)
            // The session stopped (no report), or the extension started a new journal: the copy's records may still roll back.
            if change == 0 { bench.reports.set(durable: 99, available: false) } else { bench.reports.set(durable: 99, journal: UUID()) }
            try await Task.sleep(for: .milliseconds(1500))
            await queue.reconcile()
            #expect(queue.jobs.first?.confirmed == false && queue.jobs.first?.progress.finished == true)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
    private func finished(_ queue: CopyQueue) async throws {
        try await waitUntil { queue.jobs.first?.progress.finished == true && queue.jobs.first?.running == false }
    }

    @Test func aPartialTransferReportIsSavedBeforeAnyItemFinishes() async throws {
        let bench = try Bench(), copier = ReportOnlyCopy()
        let queue = bench.queue(copierFactory: { _, _ in copier })
        try await bench.add(queue)
        try await waitUntil { queue.jobs.first?.status.copiedBytes == 8 << 20 }
        #expect(bench.store.load().first?.1.observedBytes == 8 << 20,
                "a crash during one large file must retain its display checkpoint")
        await queue.pause(try #require(queue.jobs.first?.id))
        #expect(queue.jobs.first?.copiedBytes == 8 << 20,
                "the final display must include reports before the last item save")
    }

    @Test(arguments: [0, 1, 2])
    func rapidCheckPhaseChangesAndCompletionReachTheInterface(stage: Int) async throws {
        let bench = try Bench()
        let whole = ResumableCopier.Status(current: "Album/movie.bin", checking: true,
                                           bytesToCheck: 48 << 20, checkingWholeFile: true)
        let partial = ResumableCopier.Status(current: "Album/movie.bin", checking: true, bytesToCheck: 8 << 20)
        let final: ResumableCopier.Status
        switch stage {
        case 0: final = partial
        case 1: final = .init(current: "Album/movie.bin", checking: true, checkedBytes: 8 << 20, bytesToCheck: 8 << 20)
        default: final = .init(copiedBytes: 12 << 20, current: "Album/movie.bin")
        }
        let copier = CheckPhaseCopy(reports: [whole, partial, final]); defer { copier.stop() }
        let queue = bench.queue(copierFactory: { _, _ in copier })
        try await bench.add(queue)
        try await waitUntil { queue.jobs.first?.status == final }
        #expect(queue.jobs.first?.running == true, "the worker remains active while the real phase reaches the UI")
        await queue.pause(try #require(queue.jobs.first?.id))
    }

    @Test func aQueuedCopyRunsToTheEnd() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        #expect(try bench.same("Album/movie.bin") && bench.same("Album/photo4.jpg"))
        #expect(queue.jobs.first?.fraction == 1)
    }

    @Test func anInterruptedCopyRequestsWriteAccessAfterRelaunch() async throws {
        let bench = try Bench(), factory = PauseFailureFactory()
        let first = bench.queue(copierFactory: { factory.make(plan: $0, root: $1) })
        try await bench.add(first)
        try await waitUntil { factory.first.didStart }
        bench.present = false; bench.writable = false
        await first.sessionWillEnd(session: bench.session, reconnecting: true)
        first.sessionDidEnd(bench.session, cleanly: false)
        #expect(first.writeRequest(for: "VOL") != nil)
        #expect(first.writeRequest(for: "OTHER") == nil)
        let second = bench.queue(); second.load()
        #expect(second.writeRequest(for: "VOL") != nil, "the task request survives without changing global preferences")
        bench.present = true; bench.writable = true; bench.session = UUID()
        await second.reconcile(); try await finished(second)
        #expect(try bench.same("Album/movie.bin"))
    }
    @Test func aPlannedReadOnlyEndCannotBeUndoneByALateWorkerSave() async throws {
        let bench = try Bench(), factory = PauseFailureFactory()
        let queue = bench.queue(copierFactory: { factory.make(plan: $0, root: $1) })
        try await bench.add(queue); try await waitUntil { factory.first.didStart }
        let (plan, workerSnapshot) = try #require(bench.store.load().first)
        bench.writable = false
        await queue.sessionWillEnd(session: bench.session)
        queue.sessionDidEnd(bench.session, cleanly: true)
        try bench.store.save(workerSnapshot, for: plan.id) // worker's last old save after a stop timeout
        let relaunched = bench.queue(); relaunched.load()
        #expect(relaunched.writeRequest(for: "VOL") == nil)
        await relaunched.resume(plan.id)
        #expect(relaunched.writeRequest(for: "VOL") != nil, "only a new explicit Continue requests writing again")
    }
    @Test func aUserPauseCannotBeUndoneByALateWorkerSave() async throws {
        let bench = try Bench(), factory = PauseFailureFactory()
        let queue = bench.queue(copierFactory: { factory.make(plan: $0, root: $1) })
        try await bench.add(queue); try await waitUntil { factory.first.didStart }
        let (plan, workerSnapshot) = try #require(bench.store.load().first)
        await queue.pause(plan.id)
        try bench.store.save(workerSnapshot, for: plan.id)
        let relaunched = bench.queue(); relaunched.load()
        #expect(relaunched.writeRequest(for: "VOL") == nil)
        await relaunched.reconcile()
        #expect(relaunched.jobs.first?.progress.pause == .user && relaunched.jobs.first?.running == false,
                "a still-writable disk must not restart an explicitly paused job")
    }
    @Test func endingADiskRevokesItsOlderSessionRequestsToo() async throws {
        let bench = try Bench(), factory = PauseFailureFactory()
        let queue = bench.queue(copierFactory: { factory.make(plan: $0, root: $1) })
        try await bench.add(queue); try await waitUntil { factory.first.didStart }
        bench.writable = false; bench.present = false
        await queue.sessionWillEnd(session: bench.session, reconnecting: true)
        queue.sessionDidEnd(bench.session, cleanly: false)
        #expect(queue.writeRequest(for: "VOL") != nil)
        try queue.revokeWriteRequests(session: UUID(), diskKey: "VOL")
        #expect(queue.writeRequest(for: "VOL") == nil)
        let relaunched = bench.queue(); relaunched.load()
        #expect(relaunched.writeRequest(for: "VOL") == nil)
    }
    @Test func legacyAndStaleRecordsNeverRequestWriting() async throws {
        let bench = try Bench(), queue = bench.queue()
        let plan = try await bench.plan(queue)
        try bench.store.save(plan)
        var progress = CopyProgress(); progress.started = true; progress.pause = .disk; progress.pausedAt = Date()
        try bench.store.save(progress, for: plan.id)
        queue.load()
        #expect(queue.writeRequest(for: "VOL") == nil, "old records grant no new automatic write permission")
        try bench.store.saveWriteRequest(.init(id: UUID(), session: UUID(), enabled: true), for: plan.id)
        progress.pausedAt = Date().addingTimeInterval(-2 * 24 * 3600)
        try bench.store.save(progress, for: plan.id)
        queue.load()
        #expect(queue.writeRequest(for: "VOL") == nil)
    }
    @Test func aSuccessArrivingAfterAnUncleanSessionEndIsRechecked() async throws {
        let bench = try Bench(), copier = LateSuccessCopy()
        let queue = bench.queue(copierFactory: { _, _ in copier })
        try await bench.add(queue); try await waitUntil { copier.didStart }
        bench.writable = false
        queue.sessionDidEnd(bench.session, cleanly: false) // the stop timed out before this result arrived
        copier.complete()
        try await waitUntil { queue.jobs.first?.running == false }
        #expect(queue.jobs.first?.progress.finished == false && queue.jobs.first?.progress.pause == .disk)
        #expect(queue.writeRequest(for: "VOL") != nil)
    }

    @Test func copyingFromTheDiskItselfIsRefused() async throws {
        let bench = try Bench()
        try Data("x".utf8).write(to: bench.disk.appendingPathComponent("inside.txt"))
        await #expect(throws: CopyError.sourceOnDisk) {
            _ = try await bench.queue().plan(sources: [bench.disk.appendingPathComponent("inside.txt")], diskKey: "VOL",
                                             volumeName: "qsw", destination: "", root: bench.disk)
        }
    }

    @Test func endingTheSessionPausesAndTheCopyContinuesWhenWritableAgain() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        await queue.sessionWillEnd()
        let job = try #require(queue.jobs.first)
        #expect(!job.running && job.progress.pause == .disk && !job.progress.finished)
        await queue.reconcile()
        #expect(queue.jobs.first?.running == false, "not while the session is ending")
        bench.writable = false
        queue.sessionDidEnd(bench.session, cleanly: true)
        await queue.reconcile()
        #expect(queue.jobs.first?.running == false, "not while the disk is not writable")
        // What the pause recorded is what the run reached, on screen and on disk.
        var stored = try #require(bench.store.load().first?.1), shown = try #require(queue.jobs.first?.progress)
        stored.savedAt = nil; shown.savedAt = nil
        #expect(stored == shown)
        bench.writable = true; bench.session = UUID()
        await queue.reconcile()
        try await finished(queue)
        #expect(try bench.same("Album/movie.bin"))
    }

    @Test func aUserPauseStillWinsWhenTheWriteFailsAtTheSameTime() async throws {
        let bench = try Bench(), factory = PauseFailureFactory()
        let queue = bench.queue(copierFactory: { factory.make(plan: $0, root: $1) })
        try await bench.add(queue)
        let id = try #require(queue.jobs.first?.id)
        try await waitUntil { factory.first.didStart }
        // The worker returns EIO when pause asks it to stop, before it has a
        // chance to return CopyError.stopped. This is the failure during a write.
        await queue.pause(id)
        #expect(queue.jobs.first?.progress.pause == .user && queue.jobs.first?.running == false)
        #expect(queue.jobs.first?.progress.problem != nil)
        #expect(bench.store.load().first?.1.pause == .user)

        bench.writable = false
        await queue.sessionWillEnd()
        queue.sessionDidEnd(bench.session, cleanly: false)
        await queue.reconcile()
        bench.writable = true; bench.session = UUID()
        await queue.reconcile()
        #expect(queue.jobs.first?.progress.pause == .user && queue.jobs.first?.running == false)
        #expect(factory.count == 1, "restoring write access must not undo an explicit pause")

        // Only Continue starts a real copy; all the source bytes then arrive.
        await queue.resume(id)
        try await finished(queue)
        #expect(factory.count == 2)
        #expect(try bench.same("Album/movie.bin") && bench.same("Album/photo4.jpg"))
    }

    @Test func anUnplugRightAfterFinishingRechecksTheLastFiles() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        // Unplugged within the minute: the session ends without a clean unmount
        // and the disk rolls back the last files.
        bench.present = false
        await queue.sessionWillEnd()
        queue.sessionDidEnd(bench.session, cleanly: false)
        #expect(queue.jobs.first?.progress.finished == false && queue.jobs.first?.progress.pause == .disk)
        try FileManager.default.removeItem(at: bench.disk.appendingPathComponent("备份/Album/photo4.jpg"))
        let movie = try FileHandle(forUpdating: bench.disk.appendingPathComponent("备份/Album/movie.bin"))
        try movie.truncate(atOffset: 1 << 20); try movie.close()
        bench.present = true; bench.session = UUID()
        await queue.reconcile()
        try await finished(queue)
        #expect(try bench.same("Album/movie.bin") && bench.same("Album/photo4.jpg"))
    }

    @Test func aCopyFinishedInAnEarlierSessionIsRecheckedNotConfirmed() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        // The session ended without the hooks (so maybe by an unplug) and a new one began.
        try FileManager.default.removeItem(at: bench.disk.appendingPathComponent("备份/Album/photo4.jpg"))
        bench.session = UUID()
        await queue.reconcile()
        try await finished(queue)
        #expect(try bench.same("Album/photo4.jpg"))
        #expect(queue.jobs.first?.confirmed == false)
    }

    @Test func aMomentWithoutWriteAccessDoesNotUndoAFinishedCopy() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        bench.writable = false  // e.g. the client busy for a moment; the disk is still there
        await queue.reconcile()
        #expect(queue.jobs.first?.progress.finished == true && queue.jobs.first?.running == false)
    }

    @Test func aCleanEndConfirmsAndOnlyThenTheCopyCanBeDismissed() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        let id = try #require(queue.jobs.first).id
        queue.dismiss(id)
        #expect(queue.jobs.count == 1, "kept while it may still have to recheck")
        await queue.sessionWillEnd()
        queue.sessionDidEnd(bench.session, cleanly: true)
        #expect(queue.jobs.first?.confirmed == true)
        #expect(bench.store.load().isEmpty, "nothing left to resume")
        queue.dismiss(id)
        #expect(queue.jobs.isEmpty)
    }

    @Test func cancellingRemovesOnlyThePartAndKeepsAnOlderFile() async throws {
        let bench = try Bench()
        let old = Data(repeating: 0x41, count: 1 << 20)
        try FileManager.default.createDirectory(at: bench.disk.appendingPathComponent("备份/Album"), withIntermediateDirectories: true)
        try old.write(to: bench.disk.appendingPathComponent("备份/Album/movie.bin"))
        let queue = bench.queue()
        try await bench.add(queue)
        let id = try #require(queue.jobs.first).id
        await queue.pause(id)
        #expect(queue.jobs.first?.progress.pause == .user || queue.jobs.first?.progress.finished == true)
        await queue.cancel(id)
        #expect(queue.jobs.isEmpty && bench.store.load().isEmpty)
        let content = try Data(contentsOf: bench.disk.appendingPathComponent("备份/Album/movie.bin"))
        let new = try Data(contentsOf: bench.source.appendingPathComponent("Album/movie.bin"))
        #expect(content == old || content == new, "old or whole, never partial")
        let parts = FileManager.default.enumerator(atPath: bench.disk.path)!.compactMap { $0 as? String }.filter { $0.contains("volisle-part") }
        #expect(parts.isEmpty, "\(parts)")
    }

    @Test func aCopyCutOffByQuittingContinuesAfterRelaunching() async throws {
        let bench = try Bench()
        let first = bench.queue()
        try await bench.add(first)
        await first.sessionWillEnd()  // and the app quits
        // A new process: only the records on disk are left.
        let second = bench.queue()
        second.load()
        #expect(second.jobs.count == 1 && second.jobs[0].progress.pause == .disk)
        await second.reconcile()
        try await finished(second)
        #expect(try bench.same("Album/movie.bin"))
    }

    @Test func aCopyPausedForOverADayWaitsForTheUser() async throws {
        let bench = try Bench()
        let first = bench.queue()
        try await bench.add(first)
        await first.sessionWillEnd()
        let (plan, saved) = try #require(bench.store.load().first)
        var old = saved; old.pausedAt = Date().addingTimeInterval(-2 * 24 * 3600)
        try bench.store.save(old, for: plan.id)
        let second = bench.queue()
        second.load()
        await second.reconcile()
        #expect(second.jobs.first?.running == false && second.jobs.first?.progress.pause == .user)
        #expect(second.jobs.first?.progress.problem != nil)
        await second.resume(plan.id)
        try await finished(second)
    }

    @Test func aProblemItemCanBeSkipped() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        let unreadable = bench.source.appendingPathComponent("Album/photo2.jpg")
        let plan = try await bench.plan(queue)
        let index = try #require(plan.items.firstIndex { $0.relative == "Album/photo2.jpg" })
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        try await queue.enqueue(plan)
        try await waitUntil { queue.jobs.first?.progress.pause == .problem }
        #expect(queue.jobs.first?.progress.problem?.contains("photo2.jpg") == true)
        #expect(queue.jobs.first?.progress.next == index, "stopped at the item, not where the run began")
        #expect(queue.jobs.first?.progress.failedAt == index)
        await queue.skip(plan.id)
        try await finished(queue)
        #expect(queue.jobs.first?.progress.skipped == [index])
        #expect(!bench.exists("Album/photo2.jpg"))
        #expect(try bench.same("Album/photo4.jpg") && bench.same("Album/movie.bin"))
    }

    @Test func skippingAFolderLeavesOutEverythingInIt() async throws {
        let bench = try Bench()
        try FileManager.default.createDirectory(at: bench.source.appendingPathComponent("Album/Sub"), withIntermediateDirectories: true)
        for i in 0..<3 { try Data("s\(i)".utf8).write(to: bench.source.appendingPathComponent("Album/Sub/s\(i).txt")) }
        // A file on the disk where the folder would go.
        try FileManager.default.createDirectory(at: bench.disk.appendingPathComponent("备份/Album"), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: bench.disk.appendingPathComponent("备份/Album/Sub"))
        let queue = bench.queue()
        try await bench.add(queue)
        try await waitUntil { queue.jobs.first?.progress.pause == .problem }
        await queue.skip(try #require(queue.jobs.first).id)
        try await finished(queue)
        #expect(queue.jobs.first?.progress.skipped.count == 1)
        #expect(try Data(contentsOf: bench.disk.appendingPathComponent("备份/Album/Sub")) == Data("in the way".utf8))
        #expect(try bench.same("Album/photo4.jpg") && bench.same("Album/movie.bin"))
    }

    @Test func anItemFailingWhileRecheckedIsTheOneSkipped() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        let plan = try await bench.plan(queue)
        try await queue.enqueue(plan)
        try await finished(queue)
        // Reopened (a new session after an unplug) with one original unreadable now.
        let index = try #require(plan.items.firstIndex { $0.relative == "Album/photo2.jpg" })
        let unreadable = bench.source.appendingPathComponent("Album/photo2.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        bench.session = UUID()
        await queue.reconcile()
        try await waitUntil { queue.jobs.first?.progress.pause == .problem }
        #expect(queue.jobs.first?.progress.failedAt == index && queue.jobs.first?.progress.next == plan.items.count)
        await queue.skip(plan.id)
        try await finished(queue)
        #expect(queue.jobs.first?.progress.skipped == [index])
        #expect(try Data(contentsOf: bench.disk.appendingPathComponent("备份/Album/photo2.jpg")) == Data("photo 2".utf8), "copied before, left as it is")
        #expect(try bench.same("Album/movie.bin") && bench.same("Album/photo4.jpg"))
    }

    @Test func cancellingWhileTheDiskIsAwayRemovesThePartOnceItIsBack() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        let plan = try await queue.plan(sources: [bench.source.appendingPathComponent("Album/movie.bin")], diskKey: "VOL",
                                        volumeName: "qsw", destination: "备份", root: bench.disk).plan
        try await queue.enqueue(plan)
        bench.present = false  // unplugged
        await queue.sessionWillEnd()
        queue.sessionDidEnd(bench.session, cleanly: false)
        let part = bench.disk.appendingPathComponent("备份/.movie.bin.volisle-part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: part.path) { try Data(count: 4096).write(to: part) }
        await queue.cancel(plan.id)
        #expect(queue.jobs.isEmpty && FileManager.default.fileExists(atPath: part.path), "nothing is touched while the disk is away")
        #expect(bench.store.loadCleanups().count == 1)
        bench.present = true; bench.session = UUID()
        await queue.reconcile()
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(bench.store.loadCleanups().isEmpty)
    }

    @Test func onlyTheSessionACopyFinishedInCanConfirmIt() async throws {
        let bench = try Bench()
        let queue = bench.queue()
        try await bench.add(queue)
        try await finished(queue)
        await queue.sessionWillEnd()
        queue.sessionDidEnd(UUID(), cleanly: true)  // another session's clean end
        #expect(queue.jobs.first?.confirmed == false && queue.jobs.first?.progress.finished == true)
    }

    @Test func aCopyCutOffDaysAgoWaitsForTheUserAfterRelaunching() async throws {
        let bench = try Bench()
        let first = bench.queue()
        let plan = try await bench.plan(first)
        try bench.store.save(plan)
        // Cut off mid-run by quitting days ago: no pause recorded, only when it was saved.
        var progress = CopyProgress(); progress.started = true; progress.savedAt = Date().addingTimeInterval(-3 * 24 * 3600)
        try JSONEncoder().encode(progress).write(to: bench.records.appendingPathComponent(plan.id.uuidString + "/progress.json"))
        let second = bench.queue()
        second.load()
        await second.reconcile()
        #expect(second.jobs.first?.running == false && second.jobs.first?.progress.pause == .user)
    }
}

private final class CheckPhaseCopy: CopyQueueCopier, @unchecked Sendable {
    private let reports: [ResumableCopier.Status]
    private let condition = NSCondition()
    private var stopping = false
    init(reports: [ResumableCopier.Status]) { self.reports = reports }
    func stop() { condition.lock(); stopping = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        for status in reports { report(status) }
        condition.lock()
        while !stopping { condition.wait() }
        condition.unlock()
        throw CopyError.stopped
    }
}

private final class ReportOnlyCopy: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var stopping = false
    func stop() { condition.lock(); stopping = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        report(.init(copiedBytes: 8 << 20, current: "Album/movie.bin", checking: false))
        condition.lock()
        while !stopping { condition.wait() }
        condition.unlock()
        throw CopyError.stopped
    }
}

private final class LateSuccessCopy: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var didStart: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func stop() {}
    func complete() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        condition.lock(); started = true
        while !released { condition.wait() }
        condition.unlock()
        var result = start; result.finished = true
        return result
    }
}

private final class PauseFailureFactory: @unchecked Sendable {
    let first = PauseWriteFailure()
    private let lock = NSLock()
    private var created = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return created }
    func make(plan: CopyPlan, root: URL) -> any CopyQueueCopier {
        lock.lock(); created += 1; let initial = created == 1; lock.unlock()
        if initial { return first }
        return ResumableCopier(plan: plan, root: root)
    }
}

private final class PauseWriteFailure: CopyQueueCopier, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var stopping = false
    var didStart: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func stop() { condition.lock(); stopping = true; condition.broadcast(); condition.unlock() }
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress {
        condition.lock(); started = true
        while !stopping { condition.wait() }
        condition.unlock()
        throw CopyError.destination("movie.bin", EIO)
    }
}

/// Copies find their disk again by the partition: macOS reports no volume UUID
/// for NTFS (seen on a real disk: "Volume UUID: None").
@Test func anNTFSPartitionWithoutAVolumeUUIDStillHasAResumeKey() {
    let gpt = VolumeIdentity(volumeUUID: nil, mediaUUID: "8222A1E1-5C8A-4D3B-91D8-76F59E626656", devicePath: "/dev/x")
    #expect(gpt.resumeKey == "media:8222a1e1-5c8a-4d3b-91d8-76f59e626656")
    let usb = "usb-v1:" + String(repeating: "ab", count: 32)
    #expect(VolumeIdentity(volumeUUID: nil, mediaUUID: nil, devicePath: "/dev/x", mediaFingerprint: usb).resumeKey == usb)
    // The partition first, whatever the mount reports: the same key either way it is mounted.
    #expect(VolumeIdentity(volumeUUID: "C0FFEE00-0000-0000-0000-000000000001", mediaUUID: "8222A1E1-5C8A-4D3B-91D8-76F59E626656",
                           devicePath: "/dev/x").resumeKey == gpt.resumeKey)
    #expect(VolumeIdentity(volumeUUID: "C0FFEE00-0000-0000-0000-000000000001", mediaUUID: " ", devicePath: "/dev/x").resumeKey
            == "volume:c0ffee00-0000-0000-0000-000000000001")
    #expect(VolumeIdentity(volumeUUID: nil, mediaUUID: nil, devicePath: "/dev/x", mediaFingerprint: "other").resumeKey == nil)
}

/// A disk that fails at the same file again (bad sectors) stops resuming on its
/// own; a failure somewhere else starts counting afresh. Seen on a real disk:
/// every reconnection resumed, hit the same unreadable sectors and dropped off.
@Test func repeatedDeviceErrorsAtOneFileStopTheAutomaticResume() throws {
    var progress = CopyProgress()
    #expect(CopyQueue.deviceErrors(after: progress) == nil, "no failing item, nothing to count")
    progress.failedAt = 3
    let first = try #require(CopyQueue.deviceErrors(after: progress))
    #expect(first.count == 1 && first.at == 3 && !first.stop)
    progress.deviceErrors = first.count; progress.deviceErrorAt = first.at
    let second = try #require(CopyQueue.deviceErrors(after: progress))
    #expect(second.count == 2 && second.stop)
    progress.failedAt = 4
    #expect(CopyQueue.deviceErrors(after: progress)?.count == 1, "another file: counted afresh")
    #expect(CopyError.destination("/x", EIO).isDeviceError && !CopyError.destination("/x", ENXIO).isDeviceError)
    #expect(!CopyError.source("/x", EIO).isDeviceError)
    // Records written by 0.8.0 have neither field and still load.
    let old = try JSONSerialization.data(withJSONObject: ["next": 2, "started": true, "recheckFrom": 0, "finished": false,
                                                          "skipped": [], "vanished": []])
    let decoded = try JSONDecoder().decode(CopyProgress.self, from: old)
    #expect(decoded.next == 2 && decoded.deviceErrors == nil && decoded.deviceErrorAt == nil)
}
