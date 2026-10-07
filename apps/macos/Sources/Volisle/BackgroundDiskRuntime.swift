import AppKit
import Observation
import VolisleCore

/// Application-owned observation survives closing the main window.
@MainActor final class BackgroundDiskRuntime {
    private let discovery: DiskDiscovery
    private let actions: DiskActions
    private let automatic: AutoMountController
    private let cycle: MountCycleClient
    private let engine: EngineStatus
    private let helper: HelperServiceController
    private let updates: UpdateMaintenance
    private let copies: CopyQueue
    private var started = false
    private var refreshing = false
    private var recoveryQueued = false
    /// Automatic recoveries per interrupted operation. A cable pull can leave
    /// a stale mount for a few seconds, so one attempt is not enough.
    private var recoveryAttempts: (id: UUID, count: Int)?
    private static let recoveryRetryDelays: [UInt64] = [3, 10, 30]
    private var previous: [VolumeSnapshot] = []
    private var notifications: [NSObjectProtocol] = []

    init(discovery: DiskDiscovery, actions: DiskActions, automatic: AutoMountController,
         cycle: MountCycleClient, engine: EngineStatus, helper: HelperServiceController, updates: UpdateMaintenance, copies: CopyQueue) {
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
                if !self.updates.blocking { await self.cycle.checkWriteSession() }
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
            _ = cycle.blocksActions; _ = cycle.isBusy; _ = cycle.canRecover
            _ = cycle.operation; _ = engine.capability
            _ = helper.state; _ = helper.fullDiskAccess; _ = updates.blocking
            _ = automatic.preferences.automaticChoice; _ = automatic.preferences.enabled
            _ = copies.jobs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndReconcile() }
        }
        let volumes = discovery.volumes
        actions.reconcile(previous: previous, current: volumes)
        previous = volumes
        automatic.reconcile(volumes)
        scheduleRecoveryIfNeeded(volumes)
        // A disk came back writable (or went away): copies onto it continue or wait.
        Task { await copies.reconcile() }
    }
    private func scheduleRecoveryIfNeeded(_ volumes: [VolumeSnapshot]) {
        if let operation = cycle.operation,
           volumes.contains(where: { $0.identity.mediaRegistryID == operation.disk.registryID }) {
            recoveryAttempts = nil
        }
        guard !updates.blocking, !recoveryQueued, !cycle.isBusy, let operation = cycle.operation, cycle.canRecover,
              !volumes.contains(where: { $0.identity.mediaRegistryID == operation.disk.registryID }) else { return }
        let done = recoveryAttempts?.id == operation.id ? recoveryAttempts!.count : 0
        guard done <= Self.recoveryRetryDelays.count else { return }  // then the user decides
        recoveryQueued = true
        recoveryAttempts = (operation.id, done + 1)
        Task {
            if done > 0 { try? await Task.sleep(nanoseconds: Self.recoveryRetryDelays[done - 1] * 1_000_000_000) }
            // The list can be empty while it refreshes (after erasing, ⌘R): only a
            // disk that is really gone may end its session.
            if cycle.operationMediaPresent() {
                recoveryQueued = false; recoveryAttempts = nil
                return
            }
            await cycle.recover(automatically: true)
            recoveryQueued = false
            scheduleRecoveryIfNeeded(discovery.volumes)  // next bounded retry if still unresolved
        }
    }
}
