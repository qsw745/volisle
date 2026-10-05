import Foundation
import os

private let autoMountLog = Logger(subsystem: "top.qisw.volisle", category: "automount")
import Observation

/// Preferences never grant access by themselves. Every attempt still goes
/// through the real capability, identity, safety and device exclusion checks.
@MainActor @Observable public final class AutoMountPreferences {
    public private(set) var enabled: Set<PersistentVolumeKey> = []
    public private(set) var loadFailed = false
    public private(set) var automaticChoice: Bool?
    public var automaticEnabled: Bool { automaticChoice == true }
    private let defaults: UserDefaults
    private let storageKey = "volisle.autoMount.v1"
    private struct Document: Codable { let version: Int; let enabled: Set<PersistentVolumeKey> }
    private struct GlobalDocument: Codable { let version: Int; let automatic: Bool?; let enabled: Set<PersistentVolumeKey> }
    public init(defaults: UserDefaults = .standard, defaultAutomatic: Bool = false) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "volisle.autoMount.v2") {
            if let document = try? JSONDecoder().decode(GlobalDocument.self, from: data), document.version == 2 {
                enabled = document.enabled; automaticChoice = document.automatic
            } else { loadFailed = true; automaticChoice = false }
            return
        }
        if let data = defaults.data(forKey: storageKey) {
            if let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 {
                enabled = document.enabled
            } else { loadFailed = true }
        }
        if defaultAutomatic && !loadFailed { automaticChoice = true }
    }
    public func isEnabled(_ identity: VolumeIdentity) -> Bool {
        guard !loadFailed else { return false }
        return automaticChoice ?? (identity.persistentKey.map { enabled.contains($0) } ?? false)
    }
    public func setAutomaticEnabled(_ value: Bool) throws {
        let data = try JSONEncoder().encode(GlobalDocument(version: 2, automatic: value, enabled: enabled))
        defaults.set(data, forKey: "volisle.autoMount.v2")
        automaticChoice = value; loadFailed = false
    }
    public func setEnabled(_ value: Bool, for volume: VolumeSnapshot) throws {
        try WritePolicy.validateTarget(expected: volume.identity, current: volume)
        guard let key = volume.identity.persistentKey else { throw VolumeError.unstableIdentity }
        var next = enabled
        if value { next.insert(key) } else { next.remove(key) }
        let data = try JSONEncoder().encode(GlobalDocument(version: 2, automatic: nil, enabled: next))
        defaults.set(data, forKey: "volisle.autoMount.v2")
        enabled = next; automaticChoice = nil; loadFailed = false
    }
}

/// Thrown by a helper enable closure when nothing was attempted because the
/// background service was momentarily not ready. It does not consume the
/// connection's single automatic attempt.
public struct AutoMountDeferred: Error, Sendable { public init() {} }
/// The attempt failed and the mount cycle already shows the specific reason
/// (e.g. the disk is marked "needs check"). The attempt is spent, but no second,
/// vaguer message is recorded over it.
public struct AutoMountReported: Error, Sendable { public init() {} }

@MainActor @Observable public final class AutoMountController {
    public let preferences: AutoMountPreferences
    public private(set) var lastError: String?
    public private(set) var activeConnections: Set<UUID> = []
    private let engine: any FileSystemAdapter
    private let coordinator: MountCoordinator
    private let helperEnable: (@MainActor (VolumeSnapshot) async throws -> Void)?
    private let helperReady: @MainActor () -> Bool
    private var current: [VolumeSnapshot] = []
    private var attempted: Set<UUID> = []
    private var helperRunning: Set<UUID> = []
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// Deferred (not-ready) starts per connection; bounded so a disk that stays
    /// busy is not retried forever.
    private var deferrals: [UUID: Int] = [:]
    /// A deferred connection is not retried before this instant, even when a
    /// state change calls reconcile; otherwise all retries fire within a second.
    private var notBefore: [UUID: ContinuousClock.Instant] = [:]
    private let deferralDelay: Duration
    /// When each connection was first seen unmounted, and how long macOS gets
    /// to finish its own read-only mount of it before writing starts anyway.
    /// Starting while that mount is still under way races it at every step
    /// (a late native copy beside the write mount, EBUSY opening the device);
    /// starting from a mounted disk is the ordinary, well-tested path.
    private var firstSeen: [UUID: ContinuousClock.Instant] = [:]
    private var graceWakes: Set<UUID> = []
    private let automountGrace: Duration
    private static let maximumDeferrals = 6
    /// Wake-ups per deferral while the background is not ready (about a minute at 5 s).
    private static let maximumWakeups = 12

    public init(preferences: AutoMountPreferences, engine: any FileSystemAdapter, coordinator: MountCoordinator,
                helperEnable: (@MainActor (VolumeSnapshot) async throws -> Void)? = nil,
                helperReady: @escaping @MainActor () -> Bool = { true }, deferralDelay: Duration = .seconds(5),
                automountGrace: Duration = .seconds(8)) {
        self.preferences = preferences; self.engine = engine; self.coordinator = coordinator
        self.deferralDelay = deferralDelay; self.automountGrace = automountGrace
        self.helperEnable = helperEnable; self.helperReady = helperReady
    }
    public func clearMessage() { lastError = nil }
    public func isBusy(_ volume: VolumeSnapshot) -> Bool {
        current.contains { $0.deviceGroup == volume.deviceGroup && activeConnections.contains($0.identity.connection) }
    }
    public func setEnabled(_ value: Bool, for volume: VolumeSnapshot) async throws {
        if value {
            let capability = await engine.capability()
            guard capability.available && capability.finderReadWrite else { throw VolumeError.engineUnavailable }
            guard current.contains(where: { $0.identity == volume.identity }) else { throw VolumeError.disconnected }
        }
        try preferences.setEnabled(value, for: volume)
        reconcile(current)
    }
    public func reconcile(_ volumes: [VolumeSnapshot]) {
        current = volumes
        let connected = Set(volumes.map { $0.identity.connection })
        attempted.formIntersection(connected)
        deferrals = deferrals.filter { connected.contains($0.key) }
        notBefore = notBefore.filter { connected.contains($0.key) }
        firstSeen = firstSeen.filter { connected.contains($0.key) }
        graceWakes.formIntersection(connected)
        for volume in volumes where firstSeen[volume.identity.connection] == nil {
            firstSeen[volume.identity.connection] = .now
        }
        for (connection, task) in pending {
            if !helperRunning.contains(connection) && !volumes.contains(where: { $0.identity.connection == connection && eligible($0, in: volumes) }) { task.cancel() }
        }
        guard helperReady() else { return }
        for volume in volumes where eligible(volume, in: volumes) {
            let connection = volume.identity.connection
            guard !attempted.contains(connection), pending[connection] == nil else { continue }
            if let earliest = notBefore[connection], ContinuousClock.now < earliest { continue }
            if volume.mountState == .unmounted, let seen = firstSeen[connection], ContinuousClock.now < seen + automountGrace {
                waitForAutomount(connection, until: seen + automountGrace)
                continue
            }
            if helperEnable != nil && !pending.isEmpty { break }
            activeConnections.insert(connection)
            pending[connection] = Task { [weak self] in
                guard let self else { return }
                var didAttempt = false
                defer {
                    self.pending[connection] = nil; self.activeConnections.remove(connection); self.helperRunning.remove(connection)
                    if didAttempt && self.helperEnable != nil { self.reconcile(self.current) }
                }
                let capability = await self.engine.capability()
                guard !Task.isCancelled, capability.available && capability.finderReadWrite,
                      let fresh = self.current.first(where: { $0.identity == volume.identity }),
                      self.eligible(fresh, in: self.current), self.helperReady() else { return }
                // Missing prerequisites do not consume the connection's attempt.
                // Actual failures do: no automatic busy/unsafe retry loop.
                self.attempted.insert(connection); didAttempt = true
                do {
                    if let helperEnable = self.helperEnable {
                        // Once delegated, the persistent helper owns recovery.
                        // A DA callback announcing our successful write mount
                        // must not cancel the client's verification loop.
                        self.helperRunning.insert(connection)
                        try await helperEnable(fresh)
                    }
                    else { _ = try await self.coordinator.enableReadWrite(expected: fresh.identity, automatic: true) }
                }
                catch is CancellationError { }
                catch is AutoMountReported { autoMountLog.notice("自动读写未完成，原因已由挂载流程显示") }
                catch is AutoMountDeferred {
                    let count = (self.deferrals[connection] ?? 0) + 1
                    self.deferrals[connection] = count
                    didAttempt = false
                    guard count <= Self.maximumDeferrals else {
                        autoMountLog.error("自动读写多次推迟后停止重试")
                        return  // stays attempted; the user can enable manually
                    }
                    // Retried after a short delay, or earlier by a state change.
                    self.attempted.remove(connection)
                    autoMountLog.notice("自动读写推迟：后台暂未就绪（第 \(count) 次）")
                    let delay = self.deferralDelay
                    self.notBefore[connection] = ContinuousClock.now + delay
                    Task { [weak self] in
                        // Keep waking while the background is not ready yet: a single
                        // wake-up that finds it busy would otherwise leave the disk
                        // read-only until something unrelated changes.
                        for _ in 0..<Self.maximumWakeups {
                            try? await Task.sleep(for: delay)
                            guard let self, !Task.isCancelled else { return }
                            self.reconcile(self.current)
                            guard self.current.contains(where: { $0.identity.connection == connection }),
                                  self.pending[connection] == nil, !self.attempted.contains(connection),
                                  self.deferrals[connection] == count else { return }
                        }
                    }
                }
                catch {
                    autoMountLog.error("自动读写失败：\(String(describing: error), privacy: .public)")
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
    /// macOS's mount arrives as a state change and reconciles by itself; this
    /// wake-up covers a disk it never mounts.
    private func waitForAutomount(_ connection: UUID, until deadline: ContinuousClock.Instant) {
        guard graceWakes.insert(connection).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard let self, !Task.isCancelled else { return }
            self.reconcile(self.current)
        }
    }
    public func stop() { for task in pending.values { task.cancel() } }
    private func eligible(_ volume: VolumeSnapshot, in volumes: [VolumeSnapshot]) -> Bool {
        guard volume.isNTFS, volume.isExternal, !volume.isProtected,
              volume.mountState == .readOnly || volume.mountState == .unmounted,
              preferences.isEnabled(volume.identity) else { return false }
        if let key = volume.identity.persistentKey {
            guard volume.identity.supportsCurrentOperation,
                  volumes.filter({ $0.identity.persistentKey == key }).count == 1 else { return false }
        } else {
            // Global mode need not remember a UUID-less USB disk. Only the
            // trusted helper may bind and recheck this live IORegistry object.
            guard preferences.automaticEnabled, helperEnable != nil,
                  !volume.identity.devicePath.isEmpty,
                  let registry = volume.identity.mediaRegistryID, registry > 0,
                  volumes.filter({ $0.identity.mediaRegistryID == registry }).count == 1 else { return false }
        }
        if case .risk = volume.safety { return false }
        return true
    }
}
