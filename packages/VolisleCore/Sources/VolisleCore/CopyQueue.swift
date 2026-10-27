import Foundation
import Observation
import os

/// The queue's file worker. Kept internal so tests can reproduce a failed
/// write at the same moment the user requests a pause, without a faulty disk.
protocol CopyQueueCopier: Sendable {
    func stop()
    func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void,
             report: (ResumableCopier.Status) -> Void) throws -> CopyProgress
}
extension ResumableCopier: CopyQueueCopier {}

/// Copies onto NTFS disks that pause when the disk goes away and continue once
/// it is writable again. Up to two independent targets run on each disk;
/// conflicting targets retain their order, including across pauses and rollback confirmation.
@MainActor @Observable public final class CopyQueue {
    public enum WaitReason: Sendable, Equatable { case capacity, targetConflict, cleanup }
    public struct Job: Identifiable, Sendable {
        public let plan: CopyPlan
        public let topLevelCount: Int
        public var progress: CopyProgress
        public var status = ResumableCopier.Status()
        public var running = false
        public var isCancelling = false
        public var isPausing = false
        public var waitingFor: WaitReason?
        let targetClaims: Set<String>
        private var transferRate = CopyTransferRate()
        private var comparisonRate = CopyTransferRate()

        /// Recent transfer rate, excluding comparison and past runs. nil while not copying.
        public func transferBytesPerSecond(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
            guard running, !status.checking else { return nil }
            return transferRate.bytesPerSecond(at: uptime)
        }

        /// Logical bytes compared per second, not the sum of reads from the two files.
        public func comparisonBytesPerSecond(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
            guard running, status.checking else { return nil }
            return comparisonRate.bytesPerSecond(at: uptime)
        }

        mutating func resetTransferRate() {
            transferRate = CopyTransferRate(); comparisonRate = CopyTransferRate()
        }

        mutating func recordTransfer(_ status: ResumableCopier.Status, at uptime: TimeInterval) {
            if status.checking {
                transferRate = CopyTransferRate()
                if !self.status.checking || self.status.current != status.current
                    || self.status.checkingWholeFile != status.checkingWholeFile
                    || self.status.bytesToCheck != status.bytesToCheck {
                    comparisonRate = CopyTransferRate()
                }
                comparisonRate.record(bytes: status.checkedBytes, at: uptime)
            } else {
                comparisonRate = CopyTransferRate()
                transferRate.record(bytes: status.transferredBytes, at: uptime)
            }
            self.status = status
        }
        /// Finished, and past the time in which an unplug could still undo its last files.
        public var confirmed = false
        /// The write session it finished in: only that session can confirm it.
        var finishedIn: UUID?
        /// When it finished, in time awake: the disk's own recovery window does not run during sleep either.
        var finishedUptime: TimeInterval?
        /// The disk's report read right after it finished: confirmed once the
        /// disk reports all of that past rollback. nil: the timer confirms it.
        var durableMark: WriteDurability?
        var writeIntent: CopyJobStore.WriteRequest?
        public var id: UUID { plan.id }
        init(plan: CopyPlan, progress: CopyProgress) {
            self.plan = plan; self.progress = progress; topLevelCount = plan.topLevelCount
            targetClaims = CopyAdmission.claims(for: plan)
        }
        /// Transfer progress, including the last observed part while paused.
        /// Until rechecked, that saved count is a display estimate only.
        public var copiedBytes: Int64 {
            if progress.finished { return plan.totalBytes }
            let completed = plan.items[..<min(progress.next, plan.items.count)].reduce(Int64(0)) { $0 + $1.size }
            let observed = progress.observedBytes ?? completed
            let bytes = running
                ? (status.checking || status.current == nil ? max(observed, status.copiedBytes) : status.copiedBytes)
                : observed
            return min(max(0, bytes), plan.totalBytes)
        }
        public var fraction: Double {
            guard plan.totalBytes > 0 else { return progress.finished ? 1 : 0 }
            return min(1, Double(copiedBytes) / Double(plan.totalBytes))
        }
    }
    /// A disk Volisle has read-write right now, and which write session that is.
    public struct WritableDisk: Sendable {
        public let root: URL
        public let session: UUID
        public init(root: URL, session: UUID) { self.root = root; self.session = session }
    }
    public private(set) var jobs: [Job] = []
    /// After a finished copy, this long with the disk writable and its files are safe on the disk.
    /// Only for an extension that does not report it (the journal keeps about 20 s, after a checkpoint).
    static let confirmAfter: TimeInterval = 60
    /// How often a finished copy asks its disk whether it is past rollback yet.
    static let durabilityPoll: Duration = .seconds(1)
    /// A copy that failed while its disk still looked writable waits this long before trying again…
    static let retryAfter: TimeInterval = 30
    /// …and after this many such failures in a row it waits for the user.
    static let retryLimit = 3
    /// I/O errors in a row at one item after which it stops resuming on its own.
    nonisolated static let deviceErrorLimit = 2

    /// The I/O errors in a row at the item this run failed at, counting this one,
    /// and whether that is reason to stop resuming on its own.
    nonisolated static func deviceErrors(after reached: CopyProgress) -> (count: Int, at: Int, stop: Bool)? {
        guard let at = reached.failedAt else { return nil }
        let count = reached.deviceErrorAt == at ? (reached.deviceErrors ?? 0) + 1 : 1
        return (count, at, count >= deviceErrorLimit)
    }
    /// A copy paused this long does not continue on its own: the source or the disk may have changed.
    static let staleAfter: TimeInterval = 24 * 3600
    /// The longest Volisle waits for a copy to stop before ending a write session anyway.
    static let stopTimeout: TimeInterval = 10
    private static let log = Logger(subsystem: "top.qisw.volisle", category: "copy")

    @ObservationIgnored private let store: CopyJobStore
    @ObservationIgnored private let writableDisk: @MainActor (String) async -> WritableDisk?
    @ObservationIgnored private let diskPresent: @MainActor (String) -> Bool
    @ObservationIgnored private let copierFactory: @Sendable (CopyPlan, URL) -> any CopyQueueCopier
    @ObservationIgnored private let durability: @Sendable (URL, Bool) -> WriteDurability?
    @ObservationIgnored private var watchingDurability = Set<UUID>()
    /// A copy being made, by its job.
    private struct Run {
        let token: UUID
        let diskKey: String
        let session: UUID
        let copier: any CopyQueueCopier
        let task: Task<Void, Never>
        /// Why it was asked to stop, if it was.
        var pendingStop: CopyProgress.Pause?
    }
    @ObservationIgnored private var runs: [UUID: Run] = [:]
    @ObservationIgnored private var cancelling = Set<UUID>()
    @ObservationIgnored private var finishingCancellations = Set<UUID>()
    @ObservationIgnored private var pendingEnqueues = Set<UUID>()
    @ObservationIgnored private var cleaningDisks: [String: Int] = [:]
    @ObservationIgnored private var notBefore: [UUID: Date] = [:]
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var advanceAgain = false
    /// Between the two session hooks: nothing starts on a disk about to be
    /// unmounted. By session; a session not named (nil) stands for every disk.
    @ObservationIgnored private var endingSessions = Set<UUID>()
    @ObservationIgnored private var endingAll = 0
    private func ending(_ session: UUID?) -> Bool { endingAll > 0 || session.map(endingSessions.contains) == true }
    @ObservationIgnored private var sessionOutcomes: [UUID: Bool] = [:]
    /// Sessions that ended cleanly, and when (time awake). The end only handed
    /// the last writes to the drive: unplugged before the drive wrote its own
    /// cache out, they are rolled back at the next connection. A copy finished
    /// in such a session is confirmed once its disk has stayed connected this
    /// long after the end, or was ejected through Volisle (an eject makes the
    /// drive write its cache out); gone before that, it is checked again.
    @ObservationIgnored private var cleanEnds: [UUID: TimeInterval] = [:]
    static let settleAfterCleanEnd: TimeInterval = 25
    /// Disks Volisle is ejecting, and since when: gone shortly after, it was
    /// that eject. Only one asked for after the session ended counts, and one
    /// that failed is withdrawn: neither an earlier eject nor a refused one
    /// may vouch for a later pull.
    @ObservationIgnored private var ejectRequests: [String: TimeInterval] = [:]
    static let ejectTakes: TimeInterval = 60
    /// Time awake; a test's own clock.
    @ObservationIgnored var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var cleanups: [CopyJobStore.Cleanup] = []

    /// `writableDisk`: the disk with this resume key while Volisle has it
    /// read-write, else nil. `diskPresent`: the disk is connected (whether or
    /// not it is writable at this moment).
    public convenience init(store: CopyJobStore = CopyJobStore(), writableDisk: @escaping @MainActor (String) async -> WritableDisk?,
                            diskPresent: @escaping @MainActor (String) -> Bool) {
        self.init(store: store, writableDisk: writableDisk, diskPresent: diskPresent,
                  copierFactory: { ResumableCopier(plan: $0, root: $1) })
    }

    /// `durability`: the write mount's report at a root, flushing it first when asked (WriteDurability.read).
    init(store: CopyJobStore, writableDisk: @escaping @MainActor (String) async -> WritableDisk?,
         diskPresent: @escaping @MainActor (String) -> Bool,
         copierFactory: @escaping @Sendable (CopyPlan, URL) -> any CopyQueueCopier,
         durability: @escaping @Sendable (URL, Bool) -> WriteDurability? = { WriteDurability.read(root: $0, flush: $1) }) {
        self.store = store; self.writableDisk = writableDisk; self.diskPresent = diskPresent
        self.copierFactory = copierFactory; self.durability = durability
    }

    /// At launch. A copy cut off by quitting (or one finished shortly before)
    /// continues, and rechecks its last files, when its disk is writable.
    public func load() {
        jobs = store.load().map { plan, saved in
            var progress = saved
            if progress.finished || progress.pause == nil {
                progress.finished = false; progress.finishedAt = nil
                // Since its last save: a copy cut off days ago waits for the user.
                progress.pause = .disk; progress.pausedAt = progress.pausedAt ?? progress.savedAt ?? Date()
            }
            var job = Job(plan: plan, progress: progress)
            job.writeIntent = store.loadWriteRequest(plan.id)
            if job.writeIntent?.userPaused == true { job.progress.pause = .user }
            return job
        }
        cleanups = store.loadCleanups()
    }

    /// Works out what to copy into `root` (the disk's writable mount) without starting it:
    /// walking folders can take a moment. Returns the plan and the free space on the disk.
    public func plan(sources: [URL], diskKey: String, volumeName: String, destination: String,
                     root: URL) async throws -> (plan: CopyPlan, available: Int64?) {
        try await Task.detached(priority: .userInitiated) {
            let disk = root.resolvingSymlinksInPath().path
            for source in sources {
                let path = source.resolvingSymlinksInPath().path
                if path == disk || path.hasPrefix(disk + "/") { throw CopyError.sourceOnDisk }
            }
            let plan = try CopyPlan.make(sources: sources, diskKey: diskKey, volumeName: volumeName, destination: destination)
            var info = statfs()
            let available = statfs(root.path, &info) == 0 ? Int64(info.f_bavail) * Int64(info.f_bsize) : nil
            return (plan, available)
        }.value
    }

    /// Records the copy and starts it (or queues it behind another).
    public func enqueue(_ plan: CopyPlan) async throws {
        try plan.validate()
        guard !jobs.contains(where: { $0.id == plan.id }), pendingEnqueues.insert(plan.id).inserted else { throw CopyError.invalidPlan }
        defer { pendingEnqueues.remove(plan.id) }
        let plan = plan.usingOwnedParts()
        let store = store
        try await Task.detached(priority: .userInitiated) {
            try store.save(plan)
            do { try store.save(CopyProgress(), for: plan.id) } catch { store.remove(plan.id); throw error }
        }.value
        jobs.append(Job(plan: plan, progress: CopyProgress()))
        await advance()
    }

    public func pause(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), !job.isCancelling, !job.isPausing, !job.progress.finished else { return }
        setWriteRequest(id, enabled: false, userPaused: true)
        if runs[id] != nil {
            update(id) { $0.isPausing = true }
            _ = await stop(id, as: .user)
        }
        else { update(id) { $0.progress.pause = .user; $0.progress.pausedAt = Date() } }
    }

    public func resume(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), !job.isCancelling, !job.isPausing,
              !job.progress.finished, runs[id] == nil else { return }
        setWriteRequest(id, enabled: true, newAttempt: true)
        notBefore[id] = nil; failures[id] = nil
        update(id) { $0.progress.pause = nil; $0.progress.problem = nil; $0.progress.pausedAt = nil }
        await advance()
    }

    /// Leaves out the item the copy failed at (a name the disk refuses, an
    /// unreadable file), a folder with everything in it, and goes on. While
    /// rechecking, that item lies before `next`.
    public func skip(_ id: UUID) async {
        guard runs[id] == nil, let job = jobs.first(where: { $0.id == id }), !job.isCancelling, !job.progress.finished,
              let at = job.progress.failedAt, at < job.plan.items.count else { return }
        guard await removeParts([at], of: job) else { return }
        // Cleanup suspends: a second skip, resume or cancellation may have won meanwhile.
        guard runs[id] == nil, let current = jobs.first(where: { $0.id == id }), !current.isCancelling,
              !current.progress.finished, current.progress.pause == .problem, current.progress.failedAt == at else { return }
        let end = (job.plan.leftOut([at]).max() ?? at) + 1
        update(id) {
            $0.progress.skipped.append(at)
            $0.progress.failedAt = nil
            if at >= $0.progress.next { $0.progress.next = end }
        }
        await resume(id)
    }

    /// Stops and forgets the copy. What finished stays on the disk; parts of
    /// files not finished are removed (now, or once the disk is writable again).
    /// Names on the disk only ever hold a whole file, so nothing else is touched.
    public func cancel(_ id: UUID) async {
        guard jobs.contains(where: { $0.id == id }), cancelling.insert(id).inserted else { return }
        update(id) { $0.isCancelling = true }
        setWriteRequest(id, enabled: false, userPaused: true)
        if runs[id] != nil, !(await stop(id, as: .user)) { return }
        await finishCancellation(id)
    }

    private func finishCancellation(_ id: UUID) async {
        guard cancelling.contains(id), runs[id] == nil, finishingCancellations.insert(id).inserted else { return }
        defer { finishingCancellations.remove(id) }
        if let job = jobs.first(where: { $0.id == id }), !job.progress.finished {
            // Parts can only belong to the items from the recheck point to the next one.
            let progress = job.progress, last = min(progress.next, job.plan.items.count - 1)
            if progress.recheckFrom <= last,
               !(await removeParts(Array(progress.recheckFrom...last), of: job)) { return }
        }
        store.remove(id)
        jobs.removeAll { $0.id == id }
        notBefore[id] = nil; failures[id] = nil
        cancelling.remove(id)
        await advance()
    }

    /// Takes a confirmed copy off the list. Until then it stays, since it may
    /// still have to recheck its last files.
    public func dismiss(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.progress.finished, job.confirmed else { return }
        jobs.removeAll { $0.id == id }
    }

    /// Volisle is about to end a write session (eject, restore read-only, an
    /// update, or winding up after an unplug): copying stops and closes its files.
    /// Never waits for ever: a copy stuck in the system is left to the unmount.
    public func sessionWillEnd(session: UUID? = nil, reconnecting: Bool = false) async {
        if let session { endingSessions.insert(session) } else { endingAll += 1 }
        // Only the copy onto this session's disk: one onto another disk goes on.
        let stopping = runs.filter { session == nil || $0.value.session == session }
        if !reconnecting {
            for ended in session.map({ [$0] }) ?? Array(Set(stopping.values.map(\.session))) {
                do { try revokeWriteRequests(session: ended) }
                catch { Self.log.error("拷贝读写请求未能撤销：\(error.localizedDescription, privacy: .public)") }
            }
        }
        // Together: several stuck copies still hold the unmount up for one timeout only.
        let stopped = await withTaskGroup(of: Bool.self) { group in
            for id in stopping.keys { group.addTask { await self.stop(id, as: .disk) } }
            var all = true
            for await one in group where !one { all = false }
            return all
        }
        if !stopped { Self.log.error("拷贝未能在 \(Int(Self.stopTimeout), privacy: .public) 秒内停下") }
    }

    /// The pending copy's current request, consumed once by the mount controller.
    public func writeRequest(for diskKey: String) -> UUID? {
        return jobs.first { job in
            job.plan.diskKey == diskKey && waiting(job) && job.writeIntent?.enabled == true && !ending(job.writeIntent?.session)
                && (job.progress.pausedAt.map { Date().timeIntervalSince($0) <= Self.staleAfter } ?? true)
        }?.writeIntent?.id
    }

    /// Called before an explicit unmount. Persist revocation before asking a
    /// worker to stop; its independent progress saves cannot restore this intent.
    public func revokeWriteRequests(session: UUID?, diskKey: String? = nil) throws {
        var keys = Set(jobs.filter { session != nil && $0.writeIntent?.session == session }.map { $0.plan.diskKey })
        if let diskKey { keys.insert(diskKey) }
        for job in jobs where keys.contains(job.plan.diskKey) && !job.confirmed {
            guard var request = job.writeIntent else { continue }
            request.enabled = false
            update(job.id) { $0.writeIntent = request }
            try store.saveWriteRequest(request, for: job.id)
        }
    }

    private func setWriteRequest(_ id: UUID, enabled: Bool, session: UUID? = nil, newAttempt: Bool = false, userPaused: Bool = false) {
        guard let job = jobs.first(where: { $0.id == id }), !job.confirmed else { return }
        var request = job.writeIntent ?? .init(id: UUID(), session: nil, enabled: false)
        if newAttempt { request = .init(id: UUID(), session: request.session, enabled: enabled) }
        request.enabled = enabled
        request.userPaused = userPaused
        if let session { request.session = session }
        do {
            try store.saveWriteRequest(request, for: id)
            update(id) { $0.writeIntent = request }
        } catch {
            update(id) { $0.writeIntent = nil }
            Self.log.error("拷贝读写请求未能保存：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// The write session `session` ended. `cleanly`: a healthy session on a
    /// disk still connected, ended by unmounting it — everything was handed
    /// to the drive, and copies finished in it are confirmed once the drive
    /// has had its time (see `cleanEnds`). Otherwise (unplugged, an error)
    /// they recheck their last files once the disk is writable again.
    public func sessionDidEnd(_ session: UUID?, cleanly: Bool) {
        if let session, endingSessions.remove(session) != nil {} else { endingAll = max(0, endingAll - 1) }
        if let session {
            sessionOutcomes[session] = cleanly
            cleanEnds[session] = cleanly ? uptime() : nil
        }
        for job in jobs where job.progress.finished && !job.confirmed && job.finishedIn == session {
            if cleanly { settle(job.id) } else { reopen(job.id) }
        }
    }

    /// Volisle is about to eject these disks (resume keys). One that goes away
    /// soon after was ejected, not pulled: its drive wrote its cache out.
    public func ejectRequested(_ disks: [String]) {
        for disk in disks { ejectRequests[disk] = uptime() }
    }

    /// That eject did not go through: the disks are still there, as written to as before.
    public func ejectFailed(_ disks: [String]) {
        for disk in disks { ejectRequests[disk] = nil }
    }

    /// A finished copy whose session ended cleanly: confirmed, checked again,
    /// or left waiting, by where its disk is now. Returns whether it is decided.
    @discardableResult
    private func settle(_ id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.progress.finished, !job.confirmed,
              let session = job.finishedIn, let ended = cleanEnds[session] else { return false }
        let now = uptime(), disk = job.plan.diskKey
        if !diskPresent(disk) {
            if let asked = ejectRequests[disk], asked >= ended, now - asked < Self.ejectTakes { confirm(id) } else { reopen(id) }
            return true
        }
        guard now - ended >= Self.settleAfterCleanEnd else { return false }
        confirm(id)
        return true
    }

    /// The end of `session` was asked for and refused (files in use): it goes
    /// on as it was. Nothing is recorded about how it ended, since it did not:
    /// copies paused for the end continue, and ones finishing in it later are
    /// judged by how it really ends.
    public func sessionDidNotEnd(_ session: UUID?) {
        if let session, endingSessions.remove(session) != nil {} else { endingAll = max(0, endingAll - 1) }
    }

    /// The disk list or write state changed, or time passed: continue copies
    /// waiting for a disk that is writable now, confirm finished ones that stayed
    /// on a writable disk long enough.
    public func reconcile() async {
        for job in jobs where !diskPresent(job.plan.diskKey) {
            // Gone for real: its return is reason enough to retry at once.
            notBefore[job.id] = nil; failures[job.id] = nil
        }
        // An eject asked for long ago says nothing about a disk that leaves now.
        let now = uptime()
        ejectRequests = ejectRequests.filter { now - $0.value < Self.ejectTakes }
        for job in jobs where job.progress.finished && !job.confirmed {
            if settle(job.id) { continue }
            // Its session ended cleanly and the disk has been here since (it
            // would have been checked again the moment it left): written to
            // again or not, it only waits for the drive's time to be up.
            if let session = job.finishedIn, cleanEnds[session] != nil { continue }
            guard let disk = await writableDisk(job.plan.diskKey),
                  let current = jobs.first(where: { $0.id == job.id }), current.progress.finished, !current.confirmed else { continue }
            if disk.session != current.finishedIn {
                // Its session ended without word of how (so maybe by an unplug) and a new one began.
                reopen(job.id)
            } else if current.durableMark != nil {
                await confirmIfDurable(job.id, on: disk)
            } else if let at = current.finishedUptime, ProcessInfo.processInfo.systemUptime - at >= Self.confirmAfter {
                confirm(job.id)
            }
        }
        for id in Array(cancelling) where runs[id] == nil { await finishCancellation(id) }
        await advance()
    }

    // MARK: running

    private func advance() async {
        guard !advancing else { advanceAgain = true; return }
        advancing = true
        defer { advancing = false }
        repeat {
            advanceAgain = false
            await removeLeftoverParts()
            await startWaiting()
        } while advanceAgain
    }

    /// Recheck admission after every suspension: pause, cancel and disk events can interleave.
    private func startWaiting() async {
        for id in jobs.map(\.id) {
            // As it is now: an earlier one's disk may have taken a moment to answer.
            guard let job = jobs.first(where: { $0.id == id }), waiting(job) else { continue }
            if let reason = admissionFailure(job) { setWaiting(id, reason); continue }
            if let paused = job.progress.pausedAt, Date().timeIntervalSince(paused) > Self.staleAfter {
                update(job.id) {
                    $0.progress.pause = .user
                    $0.progress.problem = String(localized: "这次拷贝暂停已超过一天。确认源文件和盘上的内容没有变化后，点“继续”接着拷。")
                }
                continue
            }
            if let wait = notBefore[job.id], wait > Date() { continue }
            guard let disk = await writableDisk(job.plan.diskKey), !ending(disk.session) else { continue }
            // Paused, cancelled or started meanwhile.
            guard let current = jobs.first(where: { $0.id == job.id }), waiting(current),
                  admissionFailure(current) == nil else { continue }
            start(current, on: disk)
        }
    }

    private func admissionFailure(_ job: Job) -> WaitReason? {
        let key = job.plan.diskKey
        if cleaningDisks[key, default: 0] > 0 { return .cleanup }
        if cleanups.contains(where: { cleanup in
            guard cleanup.diskKey == key else { return false }
            let claims = Set(cleanup.targets.flatMap { target in
                [CopyAdmission.canonical(target), CopyAdmission.canonical(ResumableCopier.partPath(for: "/" + target, partID: cleanup.partID))]
            })
            return CopyAdmission.overlap(claims, job.targetClaims)
        }) { return .cleanup }
        if runs.values.filter({ $0.diskKey == key }).count >= 2 { return .capacity }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return .targetConflict }
        for (otherIndex, other) in jobs.enumerated() where other.id != job.id && other.plan.diskKey == key && !other.confirmed {
            if (otherIndex < index || other.running || other.isCancelling || other.progress.finished)
                && CopyAdmission.overlap(job.targetClaims, other.targetClaims) { return .targetConflict }
        }
        return nil
    }

    private func setWaiting(_ id: UUID, _ reason: WaitReason) {
        guard jobs.first(where: { $0.id == id })?.waitingFor != reason else { return }
        update(id) { $0.waitingFor = reason }
    }

    /// Not one being cancelled: removing its parts takes a moment, and it must not start meanwhile.
    private func waiting(_ job: Job) -> Bool {
        !job.progress.finished && !job.running && !cancelling.contains(job.id)
            && (job.progress.pause == nil || job.progress.pause == .disk)
    }

    private func start(_ job: Job, on disk: WritableDisk) {
        setWriteRequest(job.id, enabled: true, session: disk.session)
        let copier = copierFactory(job.plan, disk.root)
        var progress = job.progress
        let resuming = progress.started
        progress.started = true; progress.pause = nil; progress.problem = nil; progress.pausedAt = nil
        store.trySave(progress, for: job.id)
        update(job.id) { $0.progress = progress; $0.resetTransferRate(); $0.running = true }
        // A long copy should not slow down with the window closed or let the Mac
        // sleep idly halfway: sleep and unplugging are what interrupts copies.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: String(localized: "正在拷贝到磁盘"))
        }
        let id = job.id, token = UUID(), store = store, initial = progress, probe = durability, root = disk.root
        Self.log.notice("拷贝开始：\(job.plan.items.count, privacy: .public) 项，续传=\(resuming, privacy: .public)")
        let task = Task { [weak self] in
            // Blocking file calls belong on a thread of their own, not the shared pool.
            let (result, reached, mark): (Result<CopyProgress, any Error>, CopyProgress, WriteDurability?) = await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    var lastSave = Date.distantPast
                    var lastShown = Date.distantPast
                    var shown: ResumableCopier.Status?
                    var reached = initial
                    var unsaved = false
                    func persist() { lastSave = Date(); unsaved = false; store.trySave(reached, for: id) }
                    let result = Result {
                        try copier.run(from: initial, resuming: resuming, save: { saved in
                            reached = saved; unsaved = true
                            // Often enough to resume close to here (quit, crash); the last files are rechecked anyway.
                            if Date().timeIntervalSince(lastSave) >= 0.5 { persist() }
                        }, report: { status in
                            if !status.checking {
                                reached.observedBytes = status.copiedBytes
                                unsaved = true
                            }
                            // The files before a large one are recorded while it is copied.
                            if unsaved && Date().timeIntervalSince(lastSave) >= 0.5 { persist() }
                            let phaseChanged = shown?.checking != status.checking || shown?.current != status.current
                                || (status.checking && (shown?.checkingWholeFile != status.checkingWholeFile
                                    || shown?.bytesToCheck != status.bytesToCheck))
                            let checkedAll = status.checking && status.checkedBytes == status.bytesToCheck
                            guard phaseChanged || checkedAll || Date().timeIntervalSince(lastShown) >= 0.25 else { return }
                            lastShown = Date(); shown = status
                            let uptime = ProcessInfo.processInfo.systemUptime
                            Task { @MainActor in self?.live(id, token: token) { $0.recordTransfer(status, at: uptime) } }
                        })
                    }
                    // Its writes leave the system's cache for the disk, then the disk says how far its journal is.
                    let mark = (try? result.get()) == nil ? nil : probe(root, true)
                    continuation.resume(returning: (result, reached, mark))
                }
            }
            await self?.finish(id, token: token, result, reached: reached, mark: mark)
        }
        update(id) { $0.waitingFor = nil; $0.isPausing = false }
        runs[id] = Run(token: token, diskKey: job.plan.diskKey, session: disk.session, copier: copier, task: task)
    }

    /// `reached`: how far the run got, so a pause does not lose (and recheck) what it copied.
    private func finish(_ id: UUID, token: UUID, _ result: Result<CopyProgress, any Error>, reached: CopyProgress,
                        mark: WriteDurability? = nil) async {
        guard runs[id]?.token == token, let run = runs.removeValue(forKey: id) else { return }
        if runs.isEmpty, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        let stop = run.pendingStop
        let present = diskPresent(jobs.first { $0.id == id }?.plan.diskKey ?? "")
        update(id) { job in
            job.running = false
            job.isPausing = false
            job.resetTransferRate()
            job.status.checking = false
            job.status.checkedBytes = 0; job.status.bytesToCheck = 0; job.status.checkingWholeFile = false
            job.status.current = nil
            switch result {
            case .success(var progress):
                progress.finishedAt = Date()
                progress.deviceErrors = nil; progress.deviceErrorAt = nil
                job.progress = progress
                job.finishedIn = run.session
                job.finishedUptime = ProcessInfo.processInfo.systemUptime
                job.durableMark = mark
                failures[id] = nil
            case .failure(let error):
                job.progress = reached
                job.progress.pausedAt = Date()
                let copyError = error as? CopyError
                if copyError == .stopped {
                    job.progress.pause = stop ?? .user
                } else if let copyError, copyError.diskUnavailable || (stop != nil && copyError.isDestination) {
                    if stop == .user {
                        // A failed write can beat the worker's stop check. The
                        // explicit pause still wins over reconnecting or retries.
                        job.progress.pause = .user
                        job.progress.problem = copyError.errorDescription
                        break
                    }
                    // The same file failing with an I/O error again is the disk itself
                    // (bad sectors), not a loose connection: reconnecting would only
                    // hit it again, so it waits for the user.
                    if copyError.isDeviceError, let repeated = Self.deviceErrors(after: reached) {
                        job.progress.deviceErrors = repeated.count; job.progress.deviceErrorAt = repeated.at
                        if repeated.stop {
                            job.progress.pause = .problem
                            job.progress.problem = String(localized: "这块盘在同一个文件的位置反复出现读写错误（多半是硬盘有坏道），续传已停止，避免硬盘反复掉线。可以把这个文件拷到别的盘，或点“跳过此项”；换线、换接口后仍想再试可以点“重试”。")
                            break
                        }
                    }
                    // The disk went away, or is being ejected: it continues once the disk is writable again.
                    let ownFault = present && stop == nil
                    if ownFault { failures[id, default: 0] += 1 }
                    if failures[id, default: 0] >= Self.retryLimit {
                        job.progress.pause = .problem
                        job.progress.problem = String(localized: "读写这块盘时反复出错：\(copyError.errorDescription ?? "")")
                    } else {
                        job.progress.pause = .disk
                        job.progress.problem = copyError.errorDescription
                        if ownFault { notBefore[id] = Date().addingTimeInterval(Self.retryAfter) }
                    }
                } else {
                    job.progress.pause = .problem
                    job.progress.problem = copyError?.errorDescription ?? error.localizedDescription
                }
            }
        }
        if jobs.first(where: { $0.id == id })?.progress.finished == true,
           let clean = sessionOutcomes[run.session] {
            if clean { settle(id) } else { reopen(id) }
        }
        if let job = jobs.first(where: { $0.id == id }), job.progress.finished, !job.confirmed, job.durableMark != nil {
            watchDurability(id)
        }
        if let job = jobs.first(where: { $0.id == id }) {
            // The run's own final progress: later saves of the copying thread cannot overtake it.
            if !job.confirmed { store.trySave(job.progress, for: id) }
            Self.log.notice("拷贝结束：完成=\(job.progress.finished, privacy: .public) 暂停=\(job.progress.pause?.rawValue ?? "-", privacy: .public)")
        }
        if cancelling.contains(id) { await finishCancellation(id) }
        else { await advance() }
    }

    /// Stops a running copy (between two chunks) and waits for its files to
    /// be closed, at most `stopTimeout`. An explicit pause by the user wins over
    /// a later stop for another reason.
    private func stop(_ id: UUID, as reason: CopyProgress.Pause) async -> Bool {
        guard let run = runs[id] else { return true }
        if run.pendingStop != .user { runs[id]?.pendingStop = reason }
        run.copier.stop()
        return await Self.wait(for: run.task, seconds: Self.stopTimeout)
    }

    private static func wait(for task: Task<Void, Never>, seconds: TimeInterval) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { await task.value; once.run { continuation.resume(returning: true) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.run { continuation.resume(returning: false) } }
        }
    }

    /// The parts of these items, never the user's files. With the disk away (or
    /// being unmounted) they are noted and removed when it is writable again.
    private func removeParts(_ indexes: [Int], of job: Job) async -> Bool {
        let targets = indexes.filter { $0 < job.plan.items.count && job.plan.items[$0].kind != .directory }
            .map { job.plan.target(job.plan.items[$0]) }
        guard !targets.isEmpty else { return true }
        let key = job.plan.diskKey
        cleaningDisks[key, default: 0] += 1
        defer { cleaningDisks[key, default: 0] -= 1 }
        if let disk = await writableDisk(job.plan.diskKey), !ending(disk.session) {
            let root = disk.root
            let safe = legacySafeTargets(targets, diskKey: key, partID: job.plan.partID, excluding: job.id)
            await Self.removeParts(safe, root: root, partID: job.plan.partID)
            return true
        }
        let uuid = job.plan.diskKey
        if let index = cleanups.firstIndex(where: { $0.diskKey == uuid && $0.partID == job.plan.partID }) {
            cleanups[index].targets += targets.filter { !cleanups[index].targets.contains($0) }
        } else {
            cleanups.append(.init(diskKey: uuid, targets: targets, partID: job.plan.partID))
        }
        return store.saveCleanups(cleanups)
    }

    private func legacySafeTargets(_ targets: [String], diskKey: String, partID: UUID?, excluding id: UUID? = nil) -> [String] {
        guard partID == nil else { return targets }
        let protected = Set(jobs.filter { $0.id != id && $0.plan.diskKey == diskKey && $0.plan.partID == nil && !$0.confirmed }
            .flatMap { job in job.plan.items.filter { $0.kind != .directory }.map { CopyAdmission.canonical(job.plan.target($0)) } })
        return targets.filter { !protected.contains(CopyAdmission.canonical($0)) }
    }

    /// Parts noted while their disk was away, once it is writable.
    private func removeLeftoverParts() async {
        for cleanup in cleanups {
            cleaningDisks[cleanup.diskKey, default: 0] += 1
            defer { cleaningDisks[cleanup.diskKey, default: 0] -= 1 }
            guard let disk = await writableDisk(cleanup.diskKey), !ending(disk.session) else { continue }
            let safe = legacySafeTargets(cleanup.targets, diskKey: cleanup.diskKey, partID: cleanup.partID)
            await Self.removeParts(safe, root: disk.root, partID: cleanup.partID)
            cleanups.removeAll { $0 == cleanup }
            store.saveCleanups(cleanups)
        }
    }

    private static func removeParts(_ targets: [String], root: URL, partID: UUID?) async {
        await Task.detached(priority: .utility) {
            for target in targets { ResumableCopier.removePart(of: target, root: root.path, partID: partID) }
        }.value
    }

    /// Confirms a finished copy once its disk reports it past rollback; asks
    /// every second meanwhile. Stops asking once it is confirmed, rechecked or
    /// gone, or its disk is not writable in that session (reconcile takes over).
    private func watchDurability(_ id: UUID) {
        guard watchingDurability.insert(id).inserted else { return }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.durabilityPoll)
                guard let self else { return }
                guard let job = self.jobs.first(where: { $0.id == id }), job.progress.finished, !job.confirmed,
                      job.durableMark != nil, let disk = await self.writableDisk(job.plan.diskKey),
                      disk.session == job.finishedIn else { break }
                await self.confirmIfDurable(id, on: disk)
            }
            self?.watchingDurability.remove(id)
        }
    }

    private func confirmIfDurable(_ id: UUID, on disk: WritableDisk) async {
        guard let mark = jobs.first(where: { $0.id == id })?.durableMark else { return }
        let probe = durability, root = disk.root
        let now = await Task.detached(priority: .utility) { probe(root, false) }.value
        // No report now (the session stopped, say): its records stay, so not confirmed.
        guard let now, now.covers(mark),
              let current = jobs.first(where: { $0.id == id }), current.progress.finished, !current.confirmed,
              current.finishedIn == disk.session else { return }
        confirm(id)
    }

    private func confirm(_ id: UUID) {
        update(id) { $0.confirmed = true }
        store.remove(id)
        Task { [weak self] in await self?.advance() }
    }

    /// A finished copy whose last files the disk may have rolled back: they are
    /// checked again once it is writable.
    private func reopen(_ id: UUID) {
        update(id) {
            $0.progress.finished = false; $0.progress.finishedAt = nil
            $0.progress.pause = .disk; $0.progress.pausedAt = Date()
            $0.durableMark = nil
        }
    }

    /// From the copying thread: ignored once the job stopped, so a late report cannot undo the final state.
    private func live(_ id: UUID, token: UUID, _ change: (inout Job) -> Void) {
        guard runs[id]?.token == token, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].running else { return }
        change(&jobs[index])
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        if !jobs[index].running && !jobs[index].confirmed { store.trySave(jobs[index].progress, for: id) }
    }
}

/// Runs its body once, whichever caller comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}
