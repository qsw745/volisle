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

/// The daemon owns one cycle at a time, across all client connections. A client
/// timeout cannot cancel this task or free its slot. Journals survive crashes;
/// interrupted records require explicit recovery and never auto-repeat work.
actor HelperMountCycleService {
    private let journal: HelperMountJournal
    private let backend: any HelperMountCycleBackend
    private let bootSession: String
    private var operation: HelperMountOperation?
    private var receipts: [UUID: HelperMountReceipt]
    private var receiptsUsable = true
    private var working = false
    private var accepting = true
    init(journal: HelperMountJournal, backend: any HelperMountCycleBackend, bootSession: String) throws {
        self.journal = journal; self.backend = backend; self.bootSession = bootSession
        receipts = try journal.readReceipts()
        operation = try journal.read()
        // Migrate the current legacy record before it can be replaced.
        if let current = operation {
            let receipt = HelperMountReceipt(id: current.id, disk: current.disk, ownerUID: current.ownerUID, write: current.isWrite)
            if let old = receipts[current.id], old != receipt { throw HelperServiceError.invalidReply }
            if receipts[current.id] == nil {
                receipts[current.id] = receipt
                try journal.writeReceipts(receipts)
            }
        }
        if var old = operation, old.phase.running || old.phase == .writeMounted {
            old.phase = .needsRecovery
            old.failure = .unavailable
            try journal.write(old)
            operation = old
        }
    }
    func start(id: UUID, disk: HelperDiskRequest, uid: UInt32) async throws -> HelperMountOperation {
        try await start(id: id, disk: disk, uid: uid, write: false)
    }
    func startWrite(id: UUID, disk: HelperDiskRequest, uid: UInt32) async throws -> HelperMountOperation {
        try await start(id: id, disk: disk, uid: uid, write: true)
    }
    private func start(id: UUID, disk: HelperDiskRequest, uid: UInt32, write: Bool) async throws -> HelperMountOperation {
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        guard uid != 0, uid != .max else { throw HelperServiceError.invalidRequest }
        if let current = operation, current.id == id {
            guard current.ownerUID == uid, current.disk == disk, current.isWrite == write else { throw HelperServiceError.invalidRequest }
            return current
        }
        guard accepting, !working, operation == nil || operation?.phase == .finished else { throw HelperDiskFailure.busy }
        guard receiptsUsable else { throw HelperServiceError.unavailable }
        guard receipts[id] == nil else { throw HelperServiceError.invalidRequest }
        // Fence the ID before suspension. A crash before operation.json exists
        // permits reconciliation but never a replay of this request.
        try remember(.init(id: id, disk: disk, ownerUID: uid, write: write))
        working = true
        do {
            let mounted: Bool
            if write {
                guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
                mounted = try await writable.prepareWrite(disk, id: id, uid: uid)
            } else { mounted = try await backend.prepare(disk) }
            var record = HelperMountOperation(id: id, disk: disk, ownerUID: uid, bootSession: bootSession,
                                             phase: .queued, restoreRequired: mounted)
            record.purpose = write ? .readWrite : nil
            try journal.write(record) // Before the first possible OS mutation.
            operation = record
            Task { await self.run(id: id) }
            return record
        } catch { working = false; throw error }
    }
    /// Return an existing operation, or durably fence an unknown request.
    /// Nil means only that this ID cannot execute in the future; the client
    /// must still reconcile the current operation before releasing its barrier.
    func resolve(id: UUID, disk: HelperDiskRequest, uid: UInt32, write: Bool) throws -> HelperMountOperation? {
        let receipt = HelperMountReceipt(id: id, disk: disk, ownerUID: uid, write: write)
        try receipt.validate()
        if let current = operation, current.id == id {
            guard current.ownerUID == uid, current.disk == disk, current.isWrite == write else { throw HelperServiceError.invalidRequest }
            return current
        }
        // Preparation suspends before operation.json is written. Never issue a
        // withdrawal proof during that window (even for a different ID).
        guard !working else { throw HelperDiskFailure.busy }
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
        guard !working, operation == nil || operation?.phase == .finished else { throw HelperDiskFailure.busy }
        accepting = false
    }
    func resume() { accepting = true }
    func status(id: UUID, uid: UInt32) throws -> HelperMountOperation {
        guard let current = operation, current.id == id, current.ownerUID == uid else {
            throw HelperServiceError.invalidRequest
        }
        return current
    }
    func latest(uid: UInt32) throws -> HelperMountOperation? {
        // Preparation may suspend before a new journal exists. A concurrent
        // client must not mistake the old finished record for an idle daemon.
        if working && (operation == nil || operation?.phase == .finished) { throw HelperDiskFailure.busy }
        guard operation?.ownerUID == uid else { return nil }
        return operation
    }
    func recover(id: UUID, uid: UInt32) throws -> HelperMountOperation {
        let current = try status(id: id, uid: uid)
        guard !working, current.phase == .needsRecovery || current.phase == .writeMounted else { return current }
        // Registry IDs can be reused after reboot. Never touch such a target.
        try change(.restoring)
        working = true
        Task { await self.restore(id: id) }
        return operation!
    }
    private func change(_ phase: HelperMountPhase) throws {
        guard var current = operation else { throw HelperServiceError.invalidRequest }
        current.phase = phase
        try journal.write(current)
        operation = current
    }
    private func run(id: UUID) async {
        guard let original = operation, original.id == id else { working = false; return }
        do {
            if original.restoreRequired {
                try change(.unmounting)
                try await backend.unmount(original.disk)
            }
            try change(.inspecting)
            let report = try await backend.inspect(original.disk)
            _ = try HelperDiskReport.decode(JSONEncoder().encode(report), matching: original.disk)
            guard report.effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
            operation?.report = report
            if original.isWrite {
                guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
                try change(.mountingWrite)
                try await writable.activateWrite(operation!)
                try change(.writeMounted)
                working = false
                return // A mounted write claim is active, never a finished cycle.
            }
        } catch {
            operation?.failure = .from(error)
            // The category crosses XPC; the exact cause stays in the local log.
            cycleFailureLog.error("磁盘操作失败：阶段=\(self.operation?.phase.rawValue ?? "-", privacy: .public) 归类=\(self.operation?.failure?.rawValue ?? "-", privacy: .public) 原因=\(String(describing: error), privacy: .public)")
        }
        await restore(id: id)
    }
    private func restore(id: UUID) async {
        defer { working = false }
        guard let current = operation, current.id == id else { return }
        do {
            if try await backend.originalDisconnected(current, currentBoot: bootSession) {
                operation?.recoveryFailure = nil
                try change(.finished)
                return
            }
            guard current.bootSession == bootSession else { throw HelperDiskFailure.changedMedia }
            try change(.restoring)
            if current.isWrite {
                guard let writable = backend as? any HelperWritableMountBackend else { throw HelperDiskFailure.unavailable }
                try await writable.restoreWrite(operation!)
            } else { try await backend.restore(current.disk, originallyMounted: current.restoreRequired) }
            operation?.recoveryFailure = nil
            try change(.finished)
        } catch {
            cycleFailureLog.error("恢复失败：阶段=\(self.operation?.phase.rawValue ?? "-", privacy: .public) 原因=\(String(describing: error), privacy: .public)")
            operation?.phase = .needsRecovery
            operation?.recoveryFailure = .from(error)
            // If persistence fails, the older in-progress journal still blocks
            // the next daemon instance. Memory also remains quarantined.
            if let operation { try? journal.write(operation) }
        }
    }
}
