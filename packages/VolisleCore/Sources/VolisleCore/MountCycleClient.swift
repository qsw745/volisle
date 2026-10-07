import Foundation
import Observation
import ServiceManagement
import IOKit
import os

private let cycleLog = Logger(subsystem: "top.qisw.volisle", category: "cycle")

public enum MountCycleVerifiedState: Sendable { case readOnly, unmounted, disconnected }
/// A mounted write session as seen from outside the extension.
public enum WriteSessionHealth: Sendable { case writing, stopped, gone, extensionEnded }

public struct MountCycleIntent: Codable, Equatable, Sendable {
    public let id: UUID
    public let disk: HelperDiskRequest
    public var purpose: HelperMountPurpose? = nil
    func validate() throws { _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk)) }
}
public struct MountCycleStillRunning: LocalizedError, Equatable {
    public var errorDescription: String? { String(localized: "盘屿还在结束这块盘的读写或检查，完成后会自动核验，请稍后再推出。") }
}
@MainActor public protocol MountCycleIntentStore {
    func load() throws -> MountCycleIntent?
    func save(_ intent: MountCycleIntent) throws
    func clear() throws
}
@MainActor public protocol MountCycleClientBackend {
    func prepare(_ volume: VolumeSnapshot) async throws -> HelperDiskRequest
    func send(_ command: HelperMountCommand) async throws -> HelperMountOperation?
    func verifyWritable(_ record: HelperMountOperation) async throws -> URL
    func verifyRestored(_ record: HelperMountOperation) async throws -> MountCycleVerifiedState
    func waitForUpdate() async throws
    /// Whether the write mount still exists and can still write.
    func writeSessionHealth(_ record: HelperMountOperation) async -> WriteSessionHealth
    /// Whether the operation's media is still connected (IORegistry), whatever the disk list says.
    func mediaPresent(_ record: HelperMountOperation) -> Bool
}

public extension MountCycleClientBackend {
    func verifyWritable(_ record: HelperMountOperation) async throws -> URL { throw HelperDiskFailure.unavailable }
    func writeSessionHealth(_ record: HelperMountOperation) async -> WriteSessionHealth { .writing }
    func mediaPresent(_ record: HelperMountOperation) -> Bool { false }
}

/// One controller shared by the main window and menu bar. The local intent is
/// durable BEFORE submission: a lost XPC reply cannot be mistaken for no work.
/// Only a bound terminal reply plus live verification clears an accepted intent.
@MainActor @Observable public final class MountCycleClient {
    public private(set) var isBusy = false
    public private(set) var needsAttention = false
    public private(set) var lastError: String?
    public private(set) var notice: String?
    public private(set) var verifiedState: MountCycleVerifiedState?
    public private(set) var operation: HelperMountOperation?
    private var sessionHealth: WriteSessionHealth?
    public var requiresRestart: Bool { sessionHealth == .extensionEnded }
    /// The latest finished operation that was refused (e.g. the disk needs a
    /// check), also read back after a relaunch; cleared by a later clean finish.
    public private(set) var lastRefusal: HelperMountOperation?
    public var blocksActions: Bool { barrier != nil }
    /// The only thing held is an idle read-write session, which the erase
    /// sheet ends itself (via `prepareForEject`) before touching the disk.
    public var onlyHoldsWriteSession: Bool {
        barrier != nil && !isBusy && !needsAttention && operation?.phase == .writeMounted
    }
    public var canRecover: Bool { !requiresRestart && (operation?.phase == .needsRecovery || operation?.phase == .writeMounted) }
    public private(set) var writableURL: URL?
    public func isWritable(_ volume: VolumeSnapshot) -> Bool {
        writableURL != nil && !needsAttention && !isBusy && operation?.phase == .writeMounted &&
        operation?.disk.bsdName == volume.bsdName && operation?.disk.registryID == volume.identity.mediaRegistryID
    }
    public func verifiedWritableURL(for volume: VolumeSnapshot) async throws -> URL {
        guard isWritable(volume), let operation else { throw HelperDiskFailure.busy }
        do {
            let root = try await backend.verifyWritable(operation)
            guard isWritable(volume), self.operation?.id == operation.id else { throw HelperDiskFailure.busy }
            let health = await backend.writeSessionHealth(operation)
            guard isWritable(volume), self.operation?.id == operation.id else { throw HelperDiskFailure.busy }
            guard acceptWriteSessionHealth(health) else { throw VolumeError.mountNotVerified }
            return root
        } catch {
            // A verification that overlapped recovery must not disturb the
            // restored disk, or a different session that has since started.
            if self.operation?.id == operation.id, self.operation?.phase == .writeMounted, !needsAttention {
                attention(error)
            }
            throw error
        }
    }
    private let onActivity: @MainActor () -> Void
    /// Runs before Volisle ends a write session (eject, restore read-only, an
    /// update, winding up after an unplug): a copy onto the disk stops and closes
    /// its files first, or the unmount would find the disk busy.
    public var willEndWriteSession: (@MainActor (_ reconnecting: Bool) async throws -> Void)?
    /// After ending one (its operation ID): `true` only for a healthy session on
    /// a disk that was still connected, unmounted and verified read-only or
    /// unmounted — then everything was written and nothing will be rolled back.
    public var didEndWriteSession: (@MainActor (UUID?, Bool) -> Void)?
    /// Each operation that reached its end, for the diagnostics history.
    public var operationFinished: (@MainActor (HelperMountOperation) -> Void)?
    private var initialized = false
    private var intent: MountCycleIntent?
    private var barrier: UUID?
    private let backend: any MountCycleClientBackend
    private let store: any MountCycleIntentStore
    private let gate: DeviceOperationGate
    public init(backend: (any MountCycleClientBackend)? = nil,
                store: (any MountCycleIntentStore)? = nil, gate: DeviceOperationGate = .shared,
                onActivity: @escaping @MainActor () -> Void = {}) {
        self.onActivity = onActivity
        self.backend = backend ?? SystemMountCycleClientBackend()
        self.store = store ?? FileMountCycleIntentStore()
        self.gate = gate
        barrier = gate.suspendNewOperations()
    }
    public func clearMessage() { notice = nil; if !needsAttention { lastError = nil } }
    /// A submitted request whose end is unknown (a lost reply, a long check that
    /// outlasted following it): asking again by its ID never repeats disk work.
    public var awaitsResult: Bool {
        needsAttention && !isBusy && intent != nil && (operation.map { $0.phase.running } ?? true)
    }
    public func refresh() async {
        guard !isBusy else { return }
        onActivity(); isBusy = true; block(); notice = nil
        defer { isBusy = false }
        do {
            intent = try store.load()
            if let intent {
                try intent.validate()
                // Resolution returns the exact operation or a durable fence
                // against late execution. It never starts or repeats disk work.
                let record = try await backend.send(.init(action: intent.purpose == .readWrite ? .resolveWrite : .resolve,
                                                          id: intent.id, disk: intent.disk))
                if let record { try await follow(record) }
                else {
                    try store.clear(); self.intent = nil
                    operation = nil; writableURL = nil; verifiedState = nil
                    try await reconcileLatest()
                    if !blocksActions { notice = String(localized: "上次请求已结束，可以重新操作磁盘。") }
                }
            } else {
                try await reconcileLatest()
            }
            initialized = true
        } catch { attention(error) }
    }
    public func start(_ volume: VolumeSnapshot, resolver: any VolumeResolver) async {
        await start(volume, resolver: resolver, write: false)
    }
    /// Returns false when nothing was sent because this client was not ready;
    /// the caller may retry later without treating it as a disk failure.
    @discardableResult
    public func startWrite(_ volume: VolumeSnapshot, resolver: any VolumeResolver) async -> Bool {
        await start(volume, resolver: resolver, write: true)
    }
    /// Normal unmount/flush must finish before DiskActions may eject a device.
    /// Keep the barrier on any unverified result; never force a busy volume.
    public func prepareForEject(_ volume: VolumeSnapshot) async throws {
        if let operation, operation.disk.registryID == volume.identity.mediaRegistryID,
           operation.disk.bsdName == volume.bsdName, canRecover { await recover() }
        // Still flushing or checking, not files in use: "busy" would send the user
        // looking for an app to quit.
        if awaitsResult { throw MountCycleStillRunning() }
        guard !blocksActions, !isBusy else { throw HelperDiskFailure.busy }
    }
    @discardableResult
    private func start(_ volume: VolumeSnapshot, resolver: any VolumeResolver, write: Bool) async -> Bool {
        guard initialized, !isBusy, !blocksActions else {
            cycleLog.notice("启动被推迟：initialized=\(self.initialized) busy=\(self.isBusy) blocked=\(self.blocksActions)")
            return false
        }
        onActivity(); isBusy = true; block(); notice = nil; lastError = nil; operation = nil; verifiedState = nil; writableURL = nil; sessionHealth = nil
        var submitted = false
        defer { isBusy = false }
        do {
            guard !gate.hasOtherOperations(excluding: barrier) else { throw VolumeError.busy }
            let current = try await resolver.resolve(volume.identity)
            try validate(current, expected: volume)
            let disk = try await backend.prepare(current)
            guard disk.bsdName == current.bsdName, disk.registryID == current.identity.mediaRegistryID else {
                throw VolumeError.identityChanged
            }
            try validate(try await resolver.resolve(volume.identity), expected: volume)
            try Task.checkCancellation()
            let pending = MountCycleIntent(id: UUID(), disk: disk, purpose: write ? .readWrite : nil)
            try store.save(pending)
            intent = pending
            let record: HelperMountOperation?
            submitted = true
            do { record = try await backend.send(.init(action: write ? .startWrite : .start, id: pending.id, disk: disk)) }
            catch let rejected as HelperDiskFailure {
                // A typed rejection of start is a definitive server reply.
                // A transport timeout/invalid reply NEVER enters this branch.
                cycleLog.error("后台拒绝启动：\(rejected.rawValue, privacy: .public)")
                try store.clear(); intent = nil
                try await reconcileLatest()
                lastError = rejected.localizedDescription
                // Right after a disk appears, macOS's own driver is still probing
                // it and the helper reports busy. That is transient: nothing ran.
                return rejected != .busy
            }
            guard let record else { throw HelperServiceError.invalidReply }
            try await follow(record)
            cycleLog.notice("启动结果：\(self.operation?.phase.rawValue ?? "none", privacy: .public)")
            // Same as a busy rejection, one step later: macOS was still mounting a
            // just-inserted disk when the helper opened it, and nothing was changed.
            if operation?.phase == .finished, operation?.failure == .busy { return false }
        } catch {
            cycleLog.error("启动失败：\(String(describing: error), privacy: .public) submitted=\(submitted)")
            if intent == nil && !submitted, let volume = error as? VolumeError, volume == .busy {
                unblock(); return false  // another operation holds the device; not a disk failure
            }
            if intent == nil && !submitted { unblock(); lastError = error.localizedDescription }
            else { attention(error) }
        }
        return true
    }
    /// While a write session is mounted: an error stops it (writes fail,
    /// a normal unmount cannot flush), which the app must say, and only
    /// "Restore read-only" ends it; a write mount that vanished (unmounted
    /// elsewhere) is wound up right away. One whose extension ended (crashed,
    /// killed) stays behind answering ESTALE, and even a forced unmount of it
    /// hangs in the kernel: the app says so and leaves it to a restart.
    public func checkWriteSession() async {
        guard !isBusy, !needsAttention, let operation, operation.phase == .writeMounted, writableURL != nil else { return }
        let health = await backend.writeSessionHealth(operation)
        guard !isBusy, !needsAttention, writableURL != nil,
              self.operation?.id == operation.id, self.operation?.phase == .writeMounted else { return }
        switch health {
        case .writing: return
        case .gone:
            cycleLog.notice("读写挂载已不在，结束本次读写")
            await recover(automatically: true)
        case .stopped, .extensionEnded:
            _ = acceptWriteSessionHealth(health)
        }
    }
    /// Mount flags stay writable after a journal failure: the live session
    /// must also permit writing before any caller can use its root.
    private func acceptWriteSessionHealth(_ health: WriteSessionHealth) -> Bool {
        sessionHealth = health
        switch health {
        case .writing: return true
        case .gone:
            attention(VolumeError.mountNotVerified)
        case .stopped:
            writableURL = nil; needsAttention = true; notice = nil
            lastError = String(localized: "写入过程中发生错误，盘屿已停止写入以保护数据。点“恢复只读”可尝试结束写入会话；后续恢复可能撤销出错前约 20 秒内的改动。排除故障并通过安全核验后，才能重新开启读写。")
        case .extensionEnded:
            cycleLog.error("文件系统扩展已退出，读写挂载不再应答")
            writableURL = nil; needsAttention = true; notice = nil
            lastError = String(localized: "盘屿的文件系统扩展意外退出，这块盘暂时无法读写，也无法推出。请重启 Mac 后再使用这块盘；重新连接时会自动回到最后一致的状态，退出前约 20 秒内的改动会被撤销。")
        }
        return false
    }
    /// The operation's disk is still connected: an empty or partial disk list is
    /// then a refresh in progress, not an unplug, and must not end its session.
    public func operationMediaPresent() -> Bool {
        guard let operation else { return false }
        return backend.mediaPresent(operation)
    }
    public func recover(automatically: Bool = false) async {
        guard canRecover, !isBusy, let intent else { await refresh(); return }
        defer { cycleLog.notice("核验结果：\(self.operation?.phase.rawValue ?? "none", privacy: .public)") }
        onActivity(); isBusy = true; block(); notice = nil
        defer { isBusy = false }
        let ending = operation
        let healthy = ending?.phase == .writeMounted && writableURL != nil && !needsAttention
        let present = ending.map { backend.mediaPresent($0) } ?? false
        defer {
            let clean = healthy && present && operation?.id == ending?.id && operation?.phase == .finished
                && operation?.failure == nil && (verifiedState == .readOnly || verifiedState == .unmounted)
            didEndWriteSession?(ending?.id, clean)
        }
        do {
            if let willEndWriteSession { try await willEndWriteSession(automatically && !present) }
            writableURL = nil; verifiedState = nil
            guard let record = try await backend.send(.init(action: .recover, id: intent.id)) else {
                throw HelperServiceError.invalidReply
            }
            try await follow(record)
        } catch { attention(error) }
    }
    private func reconcileLatest() async throws {
        let latest = try await backend.send(.init(action: .latest))
        if let latest, latest.phase == .finished { lastRefusal = latest.failure == nil ? nil : latest }
        guard let record = latest, record.phase != .finished else {
            // The operation on screen finished with a reason (e.g. the disk is
            // marked "needs check"): later reconciliation must not erase why the
            // disk stayed read-only, nor the disk it concerns. The next operation
            // replaces both.
            if let latest, latest.id == operation?.id, latest.failure != nil, let shown = lastError {
                unblock(); lastError = shown; return
            }
            operation = nil; unblock(); return
        }
        try record.validate()
        let pending = MountCycleIntent(id: record.id, disk: record.disk, purpose: record.purpose)
        try store.save(pending); intent = pending
        try await follow(record)
    }
    private func follow(_ initial: HelperMountOperation) async throws {
        var record = initial
        for attempt in 0...60 {
            guard let intent, intent.id == record.id, intent.disk == record.disk else { throw HelperServiceError.invalidReply }
            try record.validate()
            // A write intent cannot be satisfied by a read-only operation.
            guard (intent.purpose == .readWrite) == record.isWrite else { throw HelperServiceError.invalidReply }
            operation = record
            switch record.phase {
            case .finished:
                writableURL = nil
                operationFinished?(record)
                // A completed historic entry alone cannot assert today's mount.
                let restored = try await backend.verifyRestored(record)
                verifiedState = restored
                try store.clear(); self.intent = nil
                unblock()
                lastRefusal = record.failure == nil ? nil : record
                if let failure = record.failure { lastError = failure.localizedDescription }
                else {
                    switch restored {
                    case .readOnly: notice = record.report == nil ? String(localized: "已核对磁盘恢复只读。") : String(localized: "检查完成，磁盘已恢复只读。")
                    case .unmounted: notice = String(localized: "后台操作已结束，磁盘保持未挂载。")
                    case .disconnected: notice = String(localized: "原设备已断开，后台操作已结束。")
                    }
                }
                return
            case .needsRecovery:
                needsAttention = true
                lastError = String(localized: "磁盘意外断开或后台操作被中断，正在自动核验；如果一直停在这里，请点“重新核验”。")
                return
            case .writeMounted:
                let root = try await backend.verifyWritable(record)
                guard acceptWriteSessionHealth(await backend.writeSessionHealth(record)) else { return }
                writableURL = root
                needsAttention = false; lastError = nil
                notice = String(localized: "读写已启用，使用完毕后请安全推出。")
                return
            default: break
            }
            guard attempt < 60 else { throw HelperServiceError.timedOut }
            try await backend.waitForUpdate()
            guard let next = try await backend.send(.init(action: .status, id: record.id)) else { throw HelperServiceError.invalidReply }
            record = next
        }
    }
    private func validate(_ current: VolumeSnapshot, expected: VolumeSnapshot) throws {
        guard current.identity == expected.identity, current.bsdName == expected.bsdName,
              current.deviceGroup == expected.deviceGroup else { throw VolumeError.identityChanged }
        guard current.isExternal, !current.isProtected else { throw VolumeError.protectedVolume }
        guard current.isNTFS else { throw VolumeError.unsupportedFileSystem }
        guard current.mountState == .readOnly || current.mountState == .unmounted else { throw VolumeError.busy }
    }
    private func block() { if barrier == nil { barrier = gate.suspendNewOperations() } }
    private func unblock() {
        if let barrier { gate.resumeOperations(barrier) }
        barrier = nil; needsAttention = false; lastError = nil; sessionHealth = nil
    }
    private func attention(_ error: any Error) {
        writableURL = nil
        needsAttention = true
        if error as? HelperDiskFailure == .invalidRequest {
            lastError = String(localized: "暂时无法确认上次操作是否结束，已暂停新的磁盘操作。")
        } else {
            lastError = String(localized: "\(error.localizedDescription) 后台状态仍待核验，已暂停新的磁盘操作。")
        }
    }
}

@MainActor public struct SystemMountCycleClientBackend: MountCycleClientBackend {
    public init() {}
    public func prepare(_ volume: VolumeSnapshot) async throws -> HelperDiskRequest {
        try await SystemDiskAccessBackend().prepare(volume)
    }
    public func send(_ command: HelperMountCommand) async throws -> HelperMountOperation? {
        try HelperPackage.validate()
        // No running daemon can perform a late request in a fresh installation.
        // A saved intent queries its exact ID instead and remains blocked.
        if command.action == .latest {
            let status = SMAppService.daemon(plistName: HelperIdentity.plistName).status
            if status == .notRegistered || status == .notFound || status == .requiresApproval { return nil }
        }
        return try await HelperRPC.mountCycle(command)
    }
    public func verifyWritable(_ record: HelperMountOperation) async throws -> URL {
        try SystemHelperWriteMountBackend.verifyWritableState(record)
    }
    public func verifyRestored(_ record: HelperMountOperation) async throws -> MountCycleVerifiedState {
        try SystemHelperMountCycleBackend().verifyRestoredState(record)
    }
    public func waitForUpdate() async throws { try await Task.sleep(for: .seconds(1)) }
    public func writeSessionHealth(_ record: HelperMountOperation) async -> WriteSessionHealth {
        let path = "/private/var/run/volisle-write-mounts/" + record.id.uuidString.lowercased()
        // Off the main thread: the volume answers between its own operations.
        return await Task.detached(priority: .utility) { () -> WriteSessionHealth in
            guard let records = try? SystemMountRecord.current() else { return .writing }
            guard records.contains(where: { $0.path == path && $0.type == "volisle" }) else { return .gone }
            var value = [UInt8](repeating: 0, count: 16)
            let size = getxattr(path, "top.qisw.volisle.write-state", &value, value.count, 0, 0)
            if size < 0, [ESTALE, ENXIO, ENODEV].contains(errno) { return .extensionEnded }
            return size > 0 && String(decoding: value.prefix(size), as: UTF8.self) == "stopped" ? .stopped : .writing
        }.value
    }
    public func mediaPresent(_ record: HelperMountOperation) -> Bool {
        // Registry IDs start over after a restart of the Mac and can then name another disk.
        guard (try? SystemHelperMountService.currentBootSession()) == record.bootSession else { return false }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(record.disk.registryID))
        guard media != 0 else { return false }
        IOObjectRelease(media)
        return true
    }
}
