import Foundation
import Observation
import os

private let cyclesLog = Logger(subsystem: "top.qisw.volisle", category: "cycle")

/// The read-write sessions Volisle holds, one MountCycleClient slot per disk,
/// at most `maximumSessions` at once. Each slot keeps its own durable intent
/// and pauses only its own disk while idle; one disk operation (start, check,
/// end) runs at a time across all of them, as the daemon prepares one at a time.
@MainActor @Observable public final class MountCycles {
    public nonisolated static let maximumSessions = 2
    /// Oldest first; the first keeps the single intent file of earlier versions.
    public private(set) var slots: [MountCycleClient] = []
    /// Why the daemon's newest finished operation left its disk read-only (also after a relaunch).
    private var listedRefusal: HelperMountOperation?
    public private(set) var lastError: String?
    private var refreshing = false
    private var initialized = false
    /// Until the daemon's records are known, every disk waits.
    private var barrier: UUID?
    @ObservationIgnored private var slotIDs: [ObjectIdentifier: UUID?] = [:]
    @ObservationIgnored private let makeSlot: @MainActor (UUID?) -> MountCycleClient
    @ObservationIgnored private let listRecords: @MainActor () async throws -> [HelperMountOperation]
    @ObservationIgnored private let gate: DeviceOperationGate

    /// Runs before Volisle ends a slot's write session (its operation then), see MountCycleClient.
    public var willEndWriteSession: (@MainActor (_ operation: HelperMountOperation?, _ reconnecting: Bool) async throws -> Void)?
    public var didEndWriteSession: (@MainActor (UUID?, Bool) -> Void)?
    public var operationFinished: (@MainActor (HelperMountOperation) -> Void)?

    /// `deviceKey`: the VolumeSnapshot.deviceGroup a request's disk is on now, nil when not connected.
    public convenience init(backend: (any MountCycleClientBackend)? = nil, directory: URL? = nil,
                            gate: DeviceOperationGate = .shared, onActivity: @escaping @MainActor () -> Void = {},
                            deviceKey: @escaping @MainActor (HelperDiskRequest) -> String?) {
        let backend = backend ?? SystemMountCycleClientBackend()
        let directory = directory ?? FileMountCycleIntentStore.defaultDirectory
        self.init(gate: gate, list: { try await backend.list() }, existing: FileMountCycleIntentStore.slots(in: directory)) { slot in
            MountCycleClient(backend: backend, store: FileMountCycleIntentStore(directory: directory, slot: slot), gate: gate,
                             onActivity: onActivity, deviceKey: deviceKey, adoptsLatest: false)
        }
    }
    init(gate: DeviceOperationGate, list: @escaping @MainActor () async throws -> [HelperMountOperation],
         existing: [UUID?], makeSlot: @escaping @MainActor (UUID?) -> MountCycleClient) {
        self.gate = gate; self.listRecords = list; self.makeSlot = makeSlot
        barrier = gate.suspendNewOperations()
        // The first slot is always the legacy file's, so its record is found again.
        for slot in ([nil] + existing.compactMap { $0 }.map { Optional($0) }) { add(slot) }
    }

    @discardableResult private func add(_ id: UUID?) -> MountCycleClient {
        let slot = makeSlot(id)
        slot.willEndWriteSession = { [weak self, weak slot] reconnecting in
            try await self?.willEndWriteSession?(slot?.operation, reconnecting)
        }
        slot.didEndWriteSession = { [weak self] id, clean in self?.didEndWriteSession?(id, clean) }
        slot.operationFinished = { [weak self] record in self?.operationFinished?(record) }
        slots.append(slot)
        slotIDs[ObjectIdentifier(slot)] = id
        return slot
    }

    // MARK: state

    public var isBusy: Bool { refreshing || slots.contains(where: \.isBusy) }
    public var needsAttention: Bool { lastError != nil || slots.contains(where: \.needsAttention) }
    public var awaitsResult: Bool { slots.contains(where: \.awaitsResult) }
    public var canRecover: Bool { slots.contains(where: \.canRecover) }
    /// The slot whose request, session or last result concerns this volume.
    public func session(for volume: VolumeSnapshot) -> MountCycleClient? {
        slots.first { slot in
            guard let disk = slot.disk ?? slot.operation?.disk else { return false }
            return disk.bsdName == volume.bsdName && disk.registryID == volume.identity.mediaRegistryID
        }
    }
    /// Slots holding a read-write session now (mounted, or waiting to be ended).
    public var writeSessions: [MountCycleClient] {
        slots.filter { $0.operation?.isWrite == true && ($0.operation?.phase == .writeMounted || $0.operation?.phase == .needsRecovery) }
    }
    private var active: [MountCycleClient] { slots.filter { $0.disk != nil } }
    /// The daemon's records are known and nothing failed to read them.
    public var isReady: Bool { initialized && lastError == nil }
    /// Another disk could start a session now (as far as places go).
    public var hasFreePlace: Bool { active.count < Self.maximumSessions }
    /// No session, request or pause left anywhere: an update may stop the daemon.
    public var holdsNothing: Bool { isReady && !isBusy && barrier == nil && slots.allSatisfy { !$0.blocksActions } }
    public func isWritable(_ volume: VolumeSnapshot) -> Bool { slots.contains { $0.isWritable(volume) } }
    public func verifiedWritableURL(for volume: VolumeSnapshot) async throws -> URL {
        guard let slot = session(for: volume) else { throw HelperDiskFailure.busy }
        return try await slot.verifiedWritableURL(for: volume)
    }
    /// The most recently started operation any slot shows, for diagnostics.
    public var latestOperation: HelperMountOperation? {
        slots.compactMap(\.operation).max { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }
    /// The newest refusal shown for any disk (e.g. the disk needs a check).
    public var lastRefusal: HelperMountOperation? {
        (slots.compactMap(\.lastRefusal) + [listedRefusal].compactMap { $0 })
            .max { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }
    /// Operations on this disk are paused (a session on it, or any operation under way).
    public func blocksActions(on volume: VolumeSnapshot) -> Bool { gate.isBusy(volume.deviceGroup) }
    /// Why a write session cannot start on this volume now, if anything: nil when it can.
    public func writeRefusal(for volume: VolumeSnapshot) -> WriteSlotRefusal? {
        if let slot = session(for: volume), slot.disk != nil { return .ownSession }
        if active.count >= Self.maximumSessions { return .full(active.compactMap { $0.disk }) }
        return nil
    }
    public enum WriteSlotRefusal: Equatable, Sendable {
        /// This disk already has a session (or a request still being settled).
        case ownSession
        /// The maximum number of disks are being written.
        case full([HelperDiskRequest])
    }

    // MARK: actions

    public func clearMessage() { slots.forEach { $0.clearMessage() } }

    /// At launch and when asked: every slot settles its own request, then the
    /// daemon's records not held by any slot are taken over, one slot each.
    public func refresh() async {
        guard !refreshing, !slots.contains(where: \.isBusy) else { return }
        refreshing = true
        defer { refreshing = false }
        for slot in slots { await slot.refresh() }
        do {
            let records = try await listRecords()
            let finished = records.filter { $0.phase == .finished }.max { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
            listedRefusal = finished?.failure == nil ? nil : finished
            // A slot's own request counts even when it could not be resolved just now:
            // its record is never handed to a second slot.
            let held = Set(slots.compactMap { $0.operation?.id } + slots.compactMap(\.pendingID))
            for record in records where record.phase != .finished && !held.contains(record.id) {
                cyclesLog.notice("接管后台的未结束操作：阶段=\(record.phase.rawValue, privacy: .public)")
                await (idleSlot() ?? add(UUID())).adopt(record)
            }
            lastError = nil
            initialized = true
            if let barrier { gate.resumeOperations(barrier); self.barrier = nil }
        } catch {
            cyclesLog.error("读取后台操作记录失败：\(String(describing: error), privacy: .public)")
            lastError = String(localized: "\(error.localizedDescription) 后台状态仍待核验，已暂停新的磁盘操作。")
        }
        dropIdleSlots()
    }

    private func idleSlot() -> MountCycleClient? {
        slots.first { !$0.isBusy && $0.disk == nil && !$0.needsAttention }
    }
    /// Spare slots go once idle (their files already cleared); the legacy one stays.
    private func dropIdleSlots() {
        for slot in slots.dropFirst() where !slot.isBusy && slot.disk == nil && !slot.needsAttention && slot.operation == nil {
            slots.removeAll { $0 === slot }
            slotIDs[ObjectIdentifier(slot)] = nil
        }
    }

    /// Returns false when nothing was sent because nothing could start now
    /// (another operation under way, no free place); the caller may retry later.
    @discardableResult
    public func startWrite(_ volume: VolumeSnapshot, resolver: any VolumeResolver) async -> Bool {
        guard let slot = await slotForStart(volume) else { return false }
        return await slot.startWrite(volume, resolver: resolver)
    }
    public func start(_ volume: VolumeSnapshot, resolver: any VolumeResolver) async {
        guard let slot = await slotForStart(volume) else { return }
        await slot.start(volume, resolver: resolver)
    }
    private func slotForStart(_ volume: VolumeSnapshot) async -> MountCycleClient? {
        guard initialized, !isBusy, writeRefusal(for: volume) == nil else {
            cyclesLog.notice("启动被推迟：initialized=\(self.initialized) busy=\(self.isBusy) 会话=\(self.active.count)")
            return nil
        }
        // A slot that still shows how its disk's last request ended is reused only for that disk.
        let idle = slots.filter { !$0.isBusy && $0.disk == nil }
        let reusable = idle.first { $0.operation == nil || session(for: volume) === $0 }
        // Out of spare slots: one still showing another disk's last result is reused after all.
        guard let slot = reusable ?? (slots.count <= Self.maximumSessions ? add(UUID()) : idle.first) else { return nil }
        await slot.refresh()  // a new slot: nothing on record yet, only marks it ready
        return slot
    }

    /// Ends this volume's session (if any) and requires everything on its disk to be settled.
    public func prepareForEject(_ volume: VolumeSnapshot) async throws {
        if let slot = session(for: volume) {
            try await slot.prepareForEject(volume)
        } else if gate.isBusy(volume.deviceGroup) {
            throw HelperDiskFailure.busy
        }
    }
    public func recover(_ volume: VolumeSnapshot, automatically: Bool = false) async {
        await session(for: volume)?.recover(automatically: automatically)
    }
    public func recover(_ slot: MountCycleClient, automatically: Bool = false) async {
        await slot.recover(automatically: automatically)
    }
    /// Before an update: every session is ended, one after the other.
    public func endAllSessions() async {
        for slot in slots where slot.canRecover { await slot.recover() }
    }
    /// The disk list changed: each idle slot pauses only its own disk if that disk is listed now.
    public func settleBarriers() { slots.forEach { $0.settleBarrier() } }
    public func checkWriteSessions() async {
        for slot in slots { await slot.checkWriteSession() }
    }
}
