import Foundation
import OSLog

private let cycleFailureLog = Logger(subsystem: "top.qisw.volisle.helper", category: "cycle")

public enum HelperMountPhase: String, Codable, Sendable {
    case queued, unmounting, inspecting, mountingWrite, writeMounted, restoring, finished, needsRecovery
    public var running: Bool { self != .finished && self != .needsRecovery && self != .writeMounted }
}

public enum HelperMountPurpose: String, Codable, Sendable { case readWrite }

/// Only the daemon supplies
/// owner, boot session, phase and results; the caller supplies an idempotency ID.
public struct HelperMountOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let disk: HelperDiskRequest
    public let ownerUID: UInt32
    public let bootSession: String
    public var phase: HelperMountPhase
    public let restoreRequired: Bool
    public var report: HelperDiskReport?
    public var failure: HelperDiskFailure?
    public var recoveryFailure: HelperDiskFailure? = nil
    /// Absent in legacy records: they always remain read-only cycles.
    public var purpose: HelperMountPurpose? = nil
    /// Start order among the daemon's records; absent (0) in records before 0.9.
    public var sequence: UInt64? = nil
    public var isWrite: Bool { purpose == .readWrite }
    func validate() throws {
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        guard ownerUID != 0, ownerUID != .max, !bootSession.isEmpty, bootSession.utf8.count <= 128 else {
            throw HelperServiceError.invalidReply
        }
        if phase == .mountingWrite || phase == .writeMounted {
            guard isWrite, report != nil else { throw HelperServiceError.invalidReply }
        }
        if let report {
            _ = try HelperDiskReport.decode(JSONEncoder().encode(report), matching: disk)
            guard report.effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
        }
    }
}

protocol HelperMountCycleBackend: Sendable {
    /// Validate the original device, native mount ownership and read access.
    /// Return whether the original native read-only mount must be restored.
    func prepare(_ disk: HelperDiskRequest) async throws -> Bool
    func unmount(_ disk: HelperDiskRequest) async throws
    func inspect(_ disk: HelperDiskRequest) async throws -> HelperDiskReport
    /// Verify the same live media before any OS operation. Never force or repair.
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) async throws
    /// Read-only proof that the original connection and its owned mount no
    /// longer exist. A missing /dev path alone is not sufficient.
    func originalDisconnected(_ operation: HelperMountOperation, currentBoot: String) async throws -> Bool
}

extension HelperMountCycleBackend {
    func originalDisconnected(_ operation: HelperMountOperation, currentBoot: String) async throws -> Bool { false }
}

/// Opt-in backend contract. A read-only backend can never acquire a write
/// claim. No client-provided path, shell command or mount options are accepted.
protocol HelperWritableMountBackend: HelperMountCycleBackend {
    func prepareWrite(_ disk: HelperDiskRequest, id: UUID, uid: UInt32) async throws -> Bool
    /// Recheck identity, perform authoritative NTFS preflight, mount at the
    /// operation-owned location, and independently verify the writable mount.
    func activateWrite(_ operation: HelperMountOperation) async throws
    /// Also called after process restart: recover using only the saved record,
    /// never a transient session object or caller-supplied replacement target.
    func restoreWrite(_ operation: HelperMountOperation) async throws
}

/// The daemon runs one cycle per physical disk, up to `maximumActive` disks at
/// once, across all client connections. A client timeout cannot cancel a task
/// or free its slot. Records survive crashes; interrupted records require
/// explicit recovery and never auto-repeat work.
actor HelperMountCycleService {
    /// Unfinished records (write sessions included) at once.
    static let maximumActive = 2
    /// Finished records kept for clients still asking about them.
    static let finishedKept = 4
    private let journal: HelperMountJournal
    private let backend: any HelperMountCycleBackend
    private let bootSession: String
    private var operations: [UUID: HelperMountOperation] = [:]
    private var receipts: [UUID: HelperMountReceipt]
    private var receiptsUsable = true
    /// Disks between admission and their first record: nothing on disk says
    /// they exist yet, so no withdrawal proof or idle answer is given meanwhile.
    private var preparing: Set<String> = []
    /// Records whose run or restore task is under way.
    private var working: Set<UUID> = []
    private var accepting = true
    init(journal: HelperMountJournal, backend: any HelperMountCycleBackend, bootSession: String) throws {
        self.journal = journal; self.backend = backend; self.bootSession = bootSession
        var receipts = try journal.readReceipts()
        var records = Dictionary(uniqueKeysWithValues: try journal.readAll().map { ($0.id, $0) })
        // A request reaches only a daemon of the boot it was sent in: fences from an
        // earlier boot protect nothing. Keep only the current records' own receipts.
        if try journal.readReceiptBoot() != bootSession {
            let kept = receipts.filter { records[$0.key] != nil }
            if kept.count != receipts.count { try journal.writeReceipts(kept) }
            receipts = kept
            try journal.writeReceiptBoot(bootSession)
        }
        // Migrate current legacy records before they can be replaced.
        for current in records.values.sorted(by: Self.order) {
            let receipt = HelperMountReceipt(id: current.id, disk: current.disk, ownerUID: current.ownerUID, write: current.isWrite)
            if let old = receipts[current.id], old != receipt { throw HelperServiceError.invalidReply }
            if receipts[current.id] == nil {
                receipts[current.id] = receipt
                try journal.writeReceipts(receipts)
            }
        }
        for var old in records.values.sorted(by: Self.order) where old.phase.running || old.phase == .writeMounted {
            // A start cut off midway did not complete. A mounted write session had
            // succeeded: ending it now is ordinary recovery, and a failure recorded
            // here showed "cannot verify the disk" even after a clean restore.
            if old.phase.running { old.failure = .unavailable }
            old.phase = .needsRecovery
            try journal.write(old)
            records[old.id] = old
        }
        self.receipts = receipts
        operations = records
    }
    private static func order(_ a: HelperMountOperation, _ b: HelperMountOperation) -> Bool {
        (a.sequence ?? 0, a.id.uuidString) < (b.sequence ?? 0, b.id.uuidString)
    }
    /// The physical disk: two partitions of one disk never run cycles at once.
    static func device(_ disk: HelperDiskRequest) -> String {
        disk.bsdName.replacingOccurrences(of: "s[0-9]+\\z", with: "", options: .regularExpression)
    }
    private var unfinished: [HelperMountOperation] { operations.values.filter { $0.phase != .finished } }
    func start(id: UUID, disk: HelperDiskRequest, uid: UInt32) async throws -> HelperMountOperation {
        try await start(id: id, disk: disk, uid: uid, write: false)
    }
    func startWrite(id: UUID, disk: HelperDiskRequest, uid: UInt32) async throws -> HelperMountOperation {
        try await start(id: id, disk: disk, uid: uid, write: true)
    }
    private func start(id: UUID, disk: HelperDiskRequest, uid: UInt32, write: Bool) async throws -> HelperMountOperation {
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        guard uid != 0, uid != .max else { throw HelperServiceError.invalidRequest }
        if let current = operations[id] {
            guard current.ownerUID == uid, current.disk == disk, current.isWrite == write else { throw HelperServiceError.invalidRequest }
            return current
        }
        let device = Self.device(disk)
        guard accepting, !preparing.contains(device),
              !unfinished.contains(where: { Self.device($0.disk) == device }),
              unfinished.count + preparing.count < Self.maximumActive else { throw HelperDiskFailure.busy }
        guard receiptsUsable else { throw HelperServiceError.unavailable }
        guard receipts[id] == nil else { throw HelperServiceError.invalidRequest }
        // Fence the ID before suspension. A crash before its record exists
        // permits reconciliation but never a replay of this request.
        try remember(.init(id: id, disk: disk, ownerUID: uid, write: write))
        preparing.insert(device)
        defer { preparing.remove(device) }
        let mounted: Bool
        if write {
            guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
            mounted = try await writable.prepareWrite(disk, id: id, uid: uid)
        } else { mounted = try await backend.prepare(disk) }
        var record = HelperMountOperation(id: id, disk: disk, ownerUID: uid, bootSession: bootSession,
                                         phase: .queued, restoreRequired: mounted)
        record.purpose = write ? .readWrite : nil
        record.sequence = (operations.values.compactMap(\.sequence).max() ?? 0) + 1
        try journal.write(record) // Before the first possible OS mutation.
        operations[id] = record
        working.insert(id)
        pruneFinished()
        Task { await self.run(id: id) }
        return record
    }
    /// Old finished records go once newer ones exist; their receipts stay.
    private func pruneFinished() {
        let finished = operations.values.filter { $0.phase == .finished }.sorted(by: Self.order)
        for old in finished.dropLast(Self.finishedKept) {
            guard (try? journal.remove(id: old.id)) != nil else { return }
            operations[old.id] = nil
        }
    }
    /// Return an existing operation, or durably fence an unknown request.
    /// Nil means only that this ID cannot execute in the future; the client
    /// must still reconcile the current operations before releasing its barrier.
    func resolve(id: UUID, disk: HelperDiskRequest, uid: UInt32, write: Bool) throws -> HelperMountOperation? {
        let receipt = HelperMountReceipt(id: id, disk: disk, ownerUID: uid, write: write)
        try receipt.validate()
        if let current = operations[id] {
            guard current.ownerUID == uid, current.disk == disk, current.isWrite == write else { throw HelperServiceError.invalidRequest }
            return current
        }
        // Preparation suspends before its record is written. Never issue a
        // withdrawal proof during that window (even for a different ID).
        guard preparing.isEmpty else { throw HelperDiskFailure.busy }
        try remember(receipt)
        return nil
    }
    private func remember(_ receipt: HelperMountReceipt) throws {
        guard receiptsUsable else { throw HelperServiceError.unavailable }
        if let old = receipts[receipt.id] {
            guard old == receipt else { throw HelperServiceError.invalidRequest }
            return
        }
        var next = receipts
        next[receipt.id] = receipt
        do { try journal.writeReceipts(next) }
        catch {
            // rename may have succeeded before directory fsync failed. Do not
            // acknowledge another request from stale in-memory ledger state.
            receiptsUsable = false
            throw error
        }
        receipts = next
    }
    func quiesce() throws {
        guard preparing.isEmpty, working.isEmpty, unfinished.isEmpty else { throw HelperDiskFailure.busy }
        accepting = false
    }
    func resume() { accepting = true }
    func status(id: UUID, uid: UInt32) throws -> HelperMountOperation {
        guard let current = operations[id], current.ownerUID == uid else {
            throw HelperServiceError.invalidRequest
        }
        return current
    }
    /// The caller's most recently started record.
    func latest(uid: UInt32) throws -> HelperMountOperation? {
        try list(uid: uid).last
    }
    /// The caller's records, oldest first: every unfinished one and the newest finished one.
    func list(uid: UInt32) throws -> [HelperMountOperation] {
        // Preparation may suspend before a new record exists. A concurrent
        // client must not mistake the old records for all there is.
        guard preparing.isEmpty else { throw HelperDiskFailure.busy }
        let own = operations.values.filter { $0.ownerUID == uid }.sorted(by: Self.order)
        let lastFinished = own.last { $0.phase == .finished }
        return own.filter { $0.phase != .finished || $0.id == lastFinished?.id }
    }
    func recover(id: UUID, uid: UInt32) throws -> HelperMountOperation {
        let current = try status(id: id, uid: uid)
        guard !working.contains(id), current.phase == .needsRecovery || current.phase == .writeMounted else { return current }
        // Registry IDs can be reused after reboot. Never touch such a target.
        try change(id, to: .restoring)
        working.insert(id)
        Task { await self.restore(id: id) }
        return operations[id]!
    }
    private func change(_ id: UUID, to phase: HelperMountPhase) throws {
        guard var current = operations[id] else { throw HelperServiceError.invalidRequest }
        current.phase = phase
        try journal.write(current)
        operations[id] = current
    }
    private func run(id: UUID) async {
        guard let original = operations[id] else { working.remove(id); return }
        do {
            if original.restoreRequired {
                try change(id, to: .unmounting)
                try await backend.unmount(original.disk)
            }
            try change(id, to: .inspecting)
            let report = try await backend.inspect(original.disk)
            _ = try HelperDiskReport.decode(JSONEncoder().encode(report), matching: original.disk)
            guard report.effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
            operations[id]?.report = report
            if original.isWrite {
                guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
                // A cloned disk carries the same boot sector (and volume serial): the
                // extension keeps one journal per serial, so only one of them is written at a time.
                guard !unfinished.contains(where: { $0.id != id && $0.isWrite && $0.report?.bootSHA256 == report.bootSHA256 }) else {
                    throw HelperDiskFailure.sameVolumeWriting
                }
                try change(id, to: .mountingWrite)
                try await writable.activateWrite(operations[id]!)
                try change(id, to: .writeMounted)
                working.remove(id)
                return // A mounted write claim is active, never a finished cycle.
            }
        } catch {
            operations[id]?.failure = .from(error)
            // The category crosses XPC; the exact cause stays in the local log.
            cycleFailureLog.error("磁盘操作失败：阶段=\(self.operations[id]?.phase.rawValue ?? "-", privacy: .public) 归类=\(self.operations[id]?.failure?.rawValue ?? "-", privacy: .public) 原因=\(String(describing: error), privacy: .public)")
        }
        await restore(id: id)
    }
    private func restore(id: UUID) async {
        defer { working.remove(id) }
        guard let current = operations[id] else { return }
        do {
            if try await backend.originalDisconnected(current, currentBoot: bootSession) {
                operations[id]?.recoveryFailure = nil
                try change(id, to: .finished)
                return
            }
            guard current.bootSession == bootSession else { throw HelperDiskFailure.changedMedia }
            try change(id, to: .restoring)
            if current.isWrite {
                guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
                try await writable.restoreWrite(operations[id]!)
            } else { try await backend.restore(current.disk, originallyMounted: current.restoreRequired) }
            operations[id]?.recoveryFailure = nil
            try change(id, to: .finished)
        } catch {
            cycleFailureLog.error("恢复失败：阶段=\(self.operations[id]?.phase.rawValue ?? "-", privacy: .public) 原因=\(String(describing: error), privacy: .public)")
            operations[id]?.phase = .needsRecovery
            operations[id]?.recoveryFailure = .from(error)
            // If persistence fails, the older in-progress record still blocks
            // the next daemon instance. Memory also remains quarantined.
            if let record = operations[id] { try? journal.write(record) }
        }
    }
}
