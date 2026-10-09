import AppKit
import Observation
import VolisleCore

/// Application-owned observation survives closing the main window.
@MainActor final class BackgroundDiskRuntime {
    private let discovery: DiskDiscovery
    private let actions: DiskActions
    private let automatic: AutoMountController
    private let cycle: MountCycles
    private let engine: EngineStatus
    private let helper: HelperServiceController
    private let updates: UpdateMaintenance
    private let copies: CopyQueue
    /// No idle sleep while a copy runs (a setting, on by default).
    private let sleepGuard = CopySleepGuard()
    private var started = false
    private var refreshing = false
    /// Interrupted operations with an automatic recovery under way or waiting to retry.
    private var recoveryQueued = Set<UUID>()
    /// Automatic recoveries per interrupted operation. A cable pull can leave
    /// a stale mount for a few seconds, so one attempt is not enough.
    private var recoveryAttempts: [UUID: Int] = [:]
    private static let recoveryRetryDelays: [UInt64] = [3, 10, 30]
    private var previous: [VolumeSnapshot] = []
    private var notifications: [NSObjectProtocol] = []

    init(discovery: DiskDiscovery, actions: DiskActions, automatic: AutoMountController,
         cycle: MountCycles, engine: EngineStatus, helper: HelperServiceController, updates: UpdateMaintenance, copies: CopyQueue) {
        self.discovery = discovery; self.actions = actions; self.automatic = automatic
        self.cycle = cycle; self.engine = engine
        self.helper = helper; self.updates = updates; self.copies = copies
    }
    func start() {
        guard !started else { return }
        started = true
        discovery.start()
        observeAndReconcile()
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshAfterActivation() }
            })
        Task { await refresh() }
        // A write session can stop on a device error (writes then fail) or its
        // mount can vanish; say so, or wind it up, even with no window open.
        Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                tick += 1
                if !self.updates.blocking { await self.cycle.checkWriteSessions() }
                // A helper check that failed once (e.g. timed out just after waking)
                // would otherwise keep automatic writing off until the app is activated;
                // a request whose reply was lost would wait for "Check again".
                if tick % 3 == 0, self.helper.state == .failed || self.cycle.awaitsResult { await self.refresh() }
                // A copy that waits to retry, or a finished one past its first minute.
                await self.copies.reconcile()
            }
        }
    }
    func refresh() async {
        guard started, !refreshing, !cycle.isBusy, !updates.blocking else { return }
        refreshing = true
        defer { refreshing = false }
        await helper.refresh()
        await cycle.refresh()
        await engine.refresh()
        automatic.reconcile(discovery.volumes)
    }
    /// Coming back to the window only picks up what System Settings may have
    /// changed meanwhile: the background item, Full Disk Access, the extension
    /// switch. Disk changes arrive from Disk Arbitration, the write session's
    /// health from the 10-second check, a lost reply from `awaitsResult`. The full
    /// refresh here used to flash "checking", grey out the disk buttons and clear
    /// the message at the bottom on every switch between apps.
    func refreshAfterActivation() async {
        let ready = helper.state == .connected && helper.fullDiskAccess != false && engine.capability.available
        if ready, let last = lastActivationCheck, ContinuousClock.now - last < Self.activationInterval { return }
        guard started, !refreshing, !cycle.isBusy, !updates.blocking else { return }
        refreshing = true
        defer { refreshing = false }
        lastActivationCheck = .now
        await helper.refresh()
        if helper.state == .failed || cycle.awaitsResult { await cycle.refresh() }
        await engine.refresh(quietly: true)
        automatic.reconcile(discovery.volumes)
    }
    static let activationInterval: Duration = .seconds(60)
    private var lastActivationCheck: ContinuousClock.Instant?
    private func observeAndReconcile() {
        withObservationTracking {
            _ = discovery.volumes
            _ = cycle.isBusy; _ = cycle.canRecover; _ = cycle.isReady; _ = cycle.hasFreePlace
            _ = cycle.slots.map(\.operation); _ = engine.capability
            _ = helper.state; _ = helper.fullDiskAccess; _ = updates.blocking
            _ = automatic.preferences.automaticChoice; _ = automatic.preferences.enabled
            _ = copies.jobs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndReconcile() }
        }
        let volumes = discovery.volumes
        // A session settled while its disk was not listed paused every disk; now only its own.
        cycle.settleBarriers()
        actions.reconcile(previous: previous, current: volumes)
        previous = volumes
        automatic.reconcile(volumes)
        scheduleRecoveryIfNeeded(volumes)
        // A disk came back writable (or went away): copies onto it continue or wait.
        Task { await copies.reconcile() }
        sleepGuard.update(copying: copies.jobs.contains(where: \.running))
    }
    /// Each session whose disk is gone is wound up on its own, with bounded retries.
    private func scheduleRecoveryIfNeeded(_ volumes: [VolumeSnapshot]) {
        for slot in cycle.slots {
            guard let operation = slot.operation else { continue }
            if volumes.contains(where: { $0.identity.mediaRegistryID == operation.disk.registryID }) {
                recoveryAttempts[operation.id] = nil
                continue
            }
            guard !updates.blocking, !recoveryQueued.contains(operation.id), !slot.isBusy, slot.canRecover else { continue }
            let done = recoveryAttempts[operation.id] ?? 0
            guard done <= Self.recoveryRetryDelays.count else { continue }  // then the user decides
            recoveryQueued.insert(operation.id)
            recoveryAttempts[operation.id] = done + 1
            Task {
                if done > 0 { try? await Task.sleep(nanoseconds: Self.recoveryRetryDelays[done - 1] * 1_000_000_000) }
                // The list can be empty while it refreshes (after erasing, ⌘R): only a
                // disk that is really gone may end its session.
                if slot.operationMediaPresent() {
                    recoveryQueued.remove(operation.id); recoveryAttempts[operation.id] = nil
                    return
                }
                await cycle.recover(slot, automatically: true)
                recoveryQueued.remove(operation.id)
                scheduleRecoveryIfNeeded(discovery.volumes)  // next bounded retry if still unresolved
            }
        }
    }
}
