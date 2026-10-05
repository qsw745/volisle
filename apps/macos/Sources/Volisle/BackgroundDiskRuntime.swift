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
         cycle: MountCycleClient, engine: EngineStatus, helper: HelperServiceController, updates: UpdateMaintenance) {
        self.discovery = discovery; self.actions = actions; self.automatic = automatic
        self.cycle = cycle; self.engine = engine
        self.helper = helper; self.updates = updates
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
                Task { @MainActor in await self?.refresh() }
            })
        Task { await refresh() }
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
    private func observeAndReconcile() {
        withObservationTracking {
            _ = discovery.volumes
            _ = cycle.blocksActions; _ = cycle.isBusy; _ = cycle.canRecover
            _ = cycle.operation; _ = engine.capability
            _ = helper.state; _ = updates.blocking
            _ = automatic.preferences.automaticChoice; _ = automatic.preferences.enabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndReconcile() }
        }
        let volumes = discovery.volumes
        actions.reconcile(previous: previous, current: volumes)
        previous = volumes
        automatic.reconcile(volumes)
        scheduleRecoveryIfNeeded(volumes)
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
            await cycle.recover()
            recoveryQueued = false
            scheduleRecoveryIfNeeded(discovery.volumes)  // next bounded retry if still unresolved
        }
    }
}
