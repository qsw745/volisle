// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin
import Security

struct BlockJournalRecoveryCompletion: Equatable, Sendable {
    let binding: BlockJournalBinding
    let seal: BlockJournalSeal
    /// Identifier supplied by the trusted recovery policy, not inferred from the log.
    let checkpoint: String
}

struct BlockJournalCommitCompletion: Equatable, Sendable {
    let binding: BlockJournalBinding
    let seal: BlockJournalSeal
    /// Matches the committed log; independent validation remains a caller duty.
    let checkpoint: String
}

/// Maintenance is bookkeeping only; no device validation or writes occur here.
struct BlockJournalMaintenanceResult: Equatable, Sendable {
    let removedLogs: Int
    let alreadyAbsentLogs: Int
    let unresolvedTransactions: Int
    let advancedEpoch: Bool
}

/// Root-private key and durable anchor authority. Serialized by its owner;
/// separate from the block-log directory. No IPC, device access, automatic
/// repair, key replacement, receipt eviction, or protection against root/full
/// filesystem rollback. A single directory lease excludes other instances.
final class BlockJournalAuthority {
    private struct Entry: Codable, Equatable {
        let binding: BlockJournalBinding
        let sequence: Int
        let authentication: String
        var recoveryCheckpoint: String? = nil
        var commitCheckpoint: String? = nil
        var terminal: Bool { recoveryCheckpoint != nil || commitCheckpoint != nil }
        var seal: BlockJournalSeal { .init(sequence: sequence, authentication: authentication) }
    }
    // Version 6 additionally binds an optional independent recovery baseline.
    // Version 5 binds one pool identity and budget. Unbound legacy state is
    // accepted only by isolated legacy fixtures, never silently adopted by system().
    private struct Payload: Codable {
        let version: Int
        let entries: [Entry]
        let epoch: UUID?
        let generation: UInt64?
        let pool: BlockJournalPool?
    }
    private struct Decoded {
        let entries: [UUID: Entry]
        let epoch: UUID?
        let generation: UInt64
    }
    private struct Envelope: Codable { let payload: Data; let authentication: Data }
    private struct Pending {
        let name: String
        let data: Data
        let entries: [UUID: Entry]
        let changed: Entry?
        let epoch: UUID?
        let generation: UInt64
    }
    private let owner: uid_t
    private let pool: BlockJournalPool?
    private let capacity: Int
    private var directory: Int32 = -1
    private var parent: Int32 = -1
    private var leaf = ""
    private var secret = Data()
    private var encodedState: Data?
    private var entries: [UUID: Entry] = [:]
    private var epoch: UUID?
    private var generation: UInt64 = 0
    private var pending: Pending?
    private var recoveringDevice = false
    private(set) var failed = false
    private static let stateLimit = 512 * 1024
    #if VOLISLE_BLOCK_JOURNAL_TESTING
    var storageBoundary: ((String) throws -> Void)?
    static func fixture(directory: URL, capacity: Int = 256, recovering: Bool = false, pool: BlockJournalPool? = nil) throws -> BlockJournalAuthority {
        try .init(directory: directory, owner: geteuid(), capacity: capacity, strictAncestors: false, recovering: recovering, pool: pool)
    }
    #endif

    /// Only this fixed root-owned location is available in production builds.
    /// Not invoked by the current helper until the device/recovery protocol is wired.
    static func system(recovering: Bool = false) throws -> BlockJournalAuthority {
        guard getuid() == 0, geteuid() == 0 else { throw BlockJournalError.unavailable }
        let base = URL(fileURLWithPath: "/private/var/db/volisle")
        let database = try openDirectory(base.deletingLastPathComponent(), owner: 0, strictAncestors: true, privateLeaf: false)
        defer { Darwin.close(database.0); Darwin.close(database.1) }
        if !recovering, mkdirat(database.0, "volisle", 0o700) != 0 && errno != EEXIST { throw BlockJournalError.unavailable }
        guard fsync(database.0) == 0 else { throw BlockJournalError.unavailable }
        let held = try openDirectory(base, owner: 0, strictAncestors: true)
        defer { Darwin.close(held.0); Darwin.close(held.1) }
        if !recovering, mkdirat(held.0, "block-authority", 0o700) != 0 && errno != EEXIST { throw BlockJournalError.unavailable }
        guard fsync(held.0) == 0 else { throw BlockJournalError.unavailable }
        if !recovering, mkdirat(held.0, "block-logs", 0o700) != 0 && errno != EEXIST { throw BlockJournalError.unavailable }
        guard fsync(held.0) == 0, fcntl(held.0, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        let pool = try BlockJournalStore.pool(directory: base.appendingPathComponent("block-logs"))
        return try .init(directory: base.appendingPathComponent("block-authority"), owner: 0, capacity: 256, strictAncestors: true, recovering: recovering, pool: pool)
    }

    private init(directory url: URL, owner: uid_t, capacity: Int, strictAncestors: Bool, recovering: Bool, pool: BlockJournalPool?) throws {
        self.owner = owner; self.capacity = capacity; self.pool = pool
        guard (1...256).contains(capacity) else { throw BlockJournalError.invalid }
        do {
            try verifyPool()
            let opened = try Self.openDirectory(url, owner: owner, strictAncestors: strictAncestors)
            directory = opened.0; parent = opened.1; leaf = url.lastPathComponent
            guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw BlockJournalError.unavailable }
            let names = try names()
            if names.isEmpty {
                guard !recovering else { throw BlockJournalError.corrupt }
                func bootstrap() throws {
                    var key = Data(count: 32)
                    let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
                    guard status == errSecSuccess else { throw BlockJournalError.unavailable }
                    secret = key
                    let fd = openat(directory, "key.bin", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw BlockJournalError.unavailable }
                    defer { Darwin.close(fd) }
                    try Self.write(fd, key)
                    guard fsync(fd) == 0, fsync(directory) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
                    // A crash before the first state publication leaves a key-only
                    // directory. Reopening refuses it; never assume it is new.
                    try persist([:])
                }
                if let pool {
                    try BlockJournalStore.withEmptyDirectoryLease(directory: URL(fileURLWithPath: pool.path), expectedPool: pool, publish: bootstrap)
                } else { try bootstrap() }
            } else {
                let fixed = Set(["key.bin", "anchors.json"])
                let extra = names.subtracting(fixed)
                guard fixed.isSubset(of: names), extra.isEmpty || (recovering && extra.count == 1) else { throw BlockJournalError.corrupt }
                secret = try readFile("key.bin", limit: 32)
                guard secret.count == 32 else { throw BlockJournalError.corrupt }
                let bytes = try readFile("anchors.json", limit: Self.stateLimit)
                let decoded = try decode(bytes)
                entries = decoded.entries; epoch = decoded.epoch; generation = decoded.generation; encodedState = bytes
                if let name = extra.first {
                    guard name.hasPrefix("anchor-"), name.hasSuffix(".tmp"),
                          let id = UUID(uuidString: String(name.dropFirst(7).dropLast(4))),
                          name == "anchor-"+id.uuidString.lowercased()+".tmp" else { throw BlockJournalError.corrupt }
                    let data = try readFile(name, limit: Self.stateLimit)
                    let proposed = try decode(data)
                    let changed: Entry?
                    if proposed.epoch == epoch && proposed.generation == generation {
                        changed = try Self.singleAdvance(from: entries, to: proposed.entries)
                    } else {
                        guard !entries.isEmpty, entries.values.allSatisfy(\.terminal),
                              proposed.entries.isEmpty, let nextEpoch = proposed.epoch, nextEpoch != epoch,
                              generation < UInt64.max, proposed.generation == generation + 1 else { throw BlockJournalError.corrupt }
                        changed = nil
                    }
                    pending = Pending(name: name, data: data, entries: proposed.entries, changed: changed,
                                      epoch: proposed.epoch, generation: proposed.generation)
                }
            }
        } catch { failed = true; close(); throw error }
    }
    deinit { close() }
    func close() {
        if directory >= 0 { _ = flock(directory, LOCK_UN); Darwin.close(directory); directory = -1 }
        if parent >= 0 { Darwin.close(parent); parent = -1 }
        secret = Data() // Does not claim guaranteed zeroization of copied Swift Data.
    }
    var hasInterruptedPublication: Bool { pending != nil }

    /// Explicit recovery only. The caller fences device access. No device is
    /// written and no incomplete/unknown temporary file is silently discarded.
    func finishInterruptedPublication(logDirectory: URL,
        validateRecovery: ((BlockJournalBinding, String) throws -> Void)? = nil,
        validateCommit: ((BlockJournalBinding, String) throws -> Void)? = nil) throws {
        do {
            guard !failed, directory >= 0, let candidate = pending else { throw BlockJournalError.failed }
            try verifyPending(candidate); try verifyPool(logDirectory)
            guard let changed = candidate.changed else {
                try BlockJournalStore.withEmptyDirectoryLease(directory: logDirectory, expectedPool: pool) { try self.publishPending(candidate) }
                return
            }
            if let checkpoint = changed.recoveryCheckpoint ?? changed.commitCheckpoint {
                // A durable temporary receipt is not enough: a fenced device
                // must still match the independent checkpoint before publication.
                let committed = changed.commitCheckpoint != nil
                guard let validate = committed ? validateCommit : validateRecovery else { throw BlockJournalError.unavailable }
                try BlockJournalStore.withRecoverySnapshot(directory: logDirectory,
                    binding: changed.binding, key: secret, expectedSeal: changed.seal, expectedPool: pool,
                    publishCompletion: { try self.publishPending(candidate) }) { snapshot in
                    guard snapshot.checkpoint == (committed ? checkpoint : nil) else { throw BlockJournalError.corrupt }
                    try validate(changed.binding, checkpoint)
                }
            } else {
                try BlockJournalStore.withVerifiedSnapshot(directory: logDirectory, binding: changed.binding,
                    key: secret, expectedSeal: changed.seal,
                    requiredPrefix: entries[changed.binding.transactionID]?.seal, expectedPool: pool) {
                    try self.publishPending(candidate)
                }
            }
        } catch { failed = true; throw error }
    }
    private func publishPending(_ candidate: Pending) throws {
        try verifyPending(candidate)
        let fd = openat(directory, candidate.name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BlockJournalError.unavailable }; defer { Darwin.close(fd) }
        try validateNamedFile(fd, candidate.name, size: candidate.data.count)
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("recovery-before-rename")
        try verifyPending(candidate)
        try validateNamedFile(fd, candidate.name, size: candidate.data.count)
        guard renameat(directory, candidate.name, directory, "anchors.json") == 0 else { throw BlockJournalError.unavailable }
        try boundary("recovery-after-rename")
        guard fsync(directory) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("recovery-after-durable")
        try validateDirectory(); try verifyPool(); try validateNamedFile(fd, "anchors.json", size: candidate.data.count)
        guard try names() == Set(["key.bin", "anchors.json"]),
              try readFile("anchors.json", limit: Self.stateLimit) == candidate.data,
              try readFile("key.bin", limit: 32) == secret else { throw BlockJournalError.corrupt }
        guard !failed else { throw BlockJournalError.failed }
        encodedState = candidate.data; entries = candidate.entries; epoch = candidate.epoch; generation = candidate.generation; pending = nil
    }
    private func verifyPending(_ candidate: Pending) throws {
        guard !failed, directory >= 0, secret.count == 32, let encodedState else { throw BlockJournalError.failed }
        try validateDirectory(); try verifyPool()
        guard try names() == Set(["key.bin", "anchors.json", candidate.name]),
              try readFile("key.bin", limit: 32) == secret,
              try readFile("anchors.json", limit: Self.stateLimit) == encodedState,
              try readFile(candidate.name, limit: Self.stateLimit) == candidate.data else { throw BlockJournalError.corrupt }
    }
    private static func singleAdvance(from old: [UUID: Entry], to new: [UUID: Entry]) throws -> Entry {
        guard old.keys.allSatisfy({ new[$0] != nil }) else { throw BlockJournalError.corrupt }
        let differences = new.values.filter { old[$0.binding.transactionID] != $0 }
        guard differences.count == 1, let changed = differences.first else { throw BlockJournalError.corrupt }
        let prior = old[changed.binding.transactionID]
        guard prior == nil || prior?.binding == changed.binding,
              prior?.terminal != true else { throw BlockJournalError.corrupt }
        if changed.terminal {
            guard let prior, changed.seal == prior.seal else { throw BlockJournalError.corrupt }
        } else {
            guard changed.sequence == (prior?.sequence ?? 0) + 1,
                  changed.authentication != prior?.authentication else { throw BlockJournalError.corrupt }
            if prior == nil { try checkAdmission(changed.binding, entries: old) }
        }
        return changed
    }
    func key() throws -> Data {
        do { try verifyLive(); return secret }
        catch { failed = true; throw error }
    }
    /// Restart discovery supplies identities only; it never authorizes recovery.
    func bindings() throws -> [BlockJournalBinding] {
        do {
            try verifyLive()
            return entries.values.map(\.binding).sorted { $0.transactionID.uuidString < $1.transactionID.uuidString }
        } catch { failed = true; throw error }
    }
    func unresolvedBindings() throws -> [BlockJournalBinding] {
        do {
            try verifyLive()
            return entries.values.filter { !$0.terminal }.map(\.binding)
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString }
        } catch { failed = true; throw error }
    }
    /// Retained terminal receipts fence old transaction identifiers indefinitely.
    /// This is not a device health check, nor authority to reuse an engine mount.
    func recoveryCompletion(_ binding: BlockJournalBinding) throws -> BlockJournalRecoveryCompletion? {
        do {
            try verifyLive(); try validateBinding(binding)
            guard let entry = entries[binding.transactionID] else { return nil }
            guard entry.binding == binding else { throw BlockJournalError.corrupt }
            guard let checkpoint = entry.recoveryCheckpoint else { return nil }
            return .init(binding: binding, seal: entry.seal, checkpoint: checkpoint)
        } catch { failed = true; throw error }
    }
    func commitCompletion(_ binding: BlockJournalBinding) throws -> BlockJournalCommitCompletion? {
        do {
            try verifyLive(); try validateBinding(binding)
            guard let entry = entries[binding.transactionID] else { return nil }
            guard entry.binding == binding else { throw BlockJournalError.corrupt }
            guard let checkpoint = entry.commitCheckpoint else { return nil }
            return .init(binding: binding, seal: entry.seal, checkpoint: checkpoint)
        } catch { failed = true; throw error }
    }
    /// Reclaim only the selected, authenticated terminal log. The terminal
    /// receipt remains until a safe epoch rollover. Strict authorities own one pool.
    /// true means a file was removed, false means already absent and flushed.
    /// A failure after unlink is ambiguous: reopen and retry against this pool.
    func retireLog(_ binding: BlockJournalBinding, logDirectory: URL) throws -> Bool {
        do {
            try verifyLive(); try validateBinding(binding); try verifyPool(logDirectory)
            guard let entry = entries[binding.transactionID], entry.binding == binding,
                  entry.terminal else { throw BlockJournalError.corrupt }
            recoveringDevice = true
            defer { recoveringDevice = false }
            let removed = try BlockJournalStore.retireCompleted(directory: logDirectory, binding: binding,
                key: secret, expectedSeal: entry.seal, expectedCheckpoint: entry.commitCheckpoint, expectedPool: pool) { stage in
                    try self.boundary(stage)
                    try self.verifyLive(allowDeviceOperation: true)
                }
            try verifyLive(allowDeviceOperation: true)
            return removed
        } catch { failed = true; throw error }
    }
    /// Only the authority supplies the epoch for new work. This is not a
    /// device identity lookup; callers must obtain identity from a trusted lease.
    func newBinding(volumeIdentity: String, bootSHA256: String, deviceSize: Int64, blockSize: Int, recoveryBaselineSHA256: String? = nil) throws -> BlockJournalBinding {
        do {
            try verifyLive()
            var binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: volumeIdentity,
                bootSHA256: bootSHA256, deviceSize: deviceSize, blockSize: blockSize)
            binding.authorityEpoch = epoch
            binding.recoveryBaselineSHA256 = recoveryBaselineSHA256
            try requireNewTransaction(binding)
            return binding
        } catch { failed = true; throw error }
    }
    /// Compact a fully quiescent batch only. No unresolved transaction can be
    /// forgotten. Old requests retain their old epoch and fail before lookup.
    /// The directory must match the authenticated pool, including its persistent identity.
    func advanceEpoch(logDirectory: URL) throws {
        do {
            try verifyLive(); try verifyPool(logDirectory)
            guard !entries.isEmpty, entries.values.allSatisfy(\.terminal), generation < UInt64.max else {
                throw BlockJournalError.unavailable
            }
            let next = UUID()
            guard next != epoch else { throw BlockJournalError.unavailable }
            recoveringDevice = true
            defer { recoveringDevice = false }
            try BlockJournalStore.withEmptyDirectoryLease(directory: logDirectory, expectedPool: pool) {
                try self.persist([:], newEpoch: next, allowDeviceOperation: true)
                try self.verifyLive(allowDeviceOperation: true)
            }
        } catch { failed = true; throw error }
    }
    private func validateBinding(_ binding: BlockJournalBinding) throws {
        try BlockJournalStore.validate(binding)
        guard binding.recoveryBaselineSHA256 == nil || pool != nil else { throw BlockJournalError.invalid }
        guard binding.authorityEpoch == epoch else { throw BlockJournalError.corrupt }
    }
    /// Call before creating a log; save repeats the check before authorizing any
    /// device write. The caller retains a stable physical-device identity/lease.
    func requireNewTransaction(_ binding: BlockJournalBinding) throws {
        do {
            try verifyLive(); try validateBinding(binding)
            try Self.checkAdmission(binding, entries: entries)
            guard entries.count < capacity else { throw BlockJournalError.capacity }
        } catch { failed = true; throw error }
    }
    private static func checkAdmission(_ binding: BlockJournalBinding, entries: [UUID: Entry]) throws {
        guard entries[binding.transactionID] == nil,
              !entries.values.contains(where: {
                  $0.binding.volumeIdentity == binding.volumeIdentity && !$0.terminal
              }) else { throw BlockJournalError.unavailable }
    }
    /// Owns the authority/log leases through rollback, flush, readback and
    /// receipt publication. The trusted callback must perform all restoration
    /// and independent checkpoint validation under an exclusive device lease.
    /// On any error, reopen/reconcile; never continue writing in this instance.
    func recover(_ binding: BlockJournalBinding, logDirectory: URL, checkpoint: String,
                 restoreAndValidate: (BlockJournalSnapshot) throws -> Void) throws -> BlockJournalRecoveryCompletion {
        let seal = try finalize(binding, logDirectory: logDirectory, checkpoint: checkpoint,
                                committed: false, validate: restoreAndValidate)
        return .init(binding: binding, seal: seal, checkpoint: checkpoint)
    }
    /// Only valid while finalize holds an authenticated log and authority lease.
    /// Recovery I/O rechecks this fence around each device/validator callback.
    func verifyRecoveryLease() throws {
        do {
            guard recoveringDevice else { throw BlockJournalError.failed }
            try verifyLive(allowDeviceOperation: true)
        } catch { failed = true; throw error }
    }
    /// A later device failure must also prevent reuse of this authority object.
    /// An already durable completion remains historical evidence, not live health.
    func invalidateRecovery() { failed = true }

    /// Obtain the baseline only from the authenticated original binding.
    /// Caller validates the virtual restored view AND the flushed device under
    /// an independent policy; this API never derives a baseline from the log.
    func recoverUsingStoredBaseline(_ binding: BlockJournalBinding, logDirectory: URL,
                                   restoreAndValidate: (BlockJournalSnapshot, String) throws -> Void) throws -> BlockJournalRecoveryCompletion {
        do {
            try verifyLive(); try validateBinding(binding)
            guard let entry = entries[binding.transactionID], entry.binding == binding,
                  let baseline = entry.binding.recoveryBaselineSHA256 else { throw BlockJournalError.unavailable }
            return try recover(binding, logDirectory: logDirectory, checkpoint: baseline) { snapshot in
                try restoreAndValidate(snapshot, baseline)
            }
        } catch { failed = true; throw error }
    }
    /// A log commit alone is insufficient. The trusted callback must quiesce
    /// and flush the exclusively held device, independently validate its final
    /// checkpoint/readback and clean reopen policy, without issuing more writes.
    /// A completed session keeps its tombstone and is never eligible for rollback.
    func completeCommit(_ binding: BlockJournalBinding, logDirectory: URL, checkpoint: String,
                        validateCommitted: (BlockJournalSnapshot) throws -> Void) throws -> BlockJournalCommitCompletion {
        let seal = try finalize(binding, logDirectory: logDirectory, checkpoint: checkpoint,
                                committed: true, validate: validateCommitted)
        return .init(binding: binding, seal: seal, checkpoint: checkpoint)
    }
    private func finalize(_ binding: BlockJournalBinding, logDirectory: URL, checkpoint: String,
                          committed: Bool, validate: (BlockJournalSnapshot) throws -> Void) throws -> BlockJournalSeal {
        do {
            try verifyLive(); try validateBinding(binding); try Self.validateCheckpoint(checkpoint); try verifyPool(logDirectory)
            if !committed, let baseline = binding.recoveryBaselineSHA256 {
                guard checkpoint == baseline else { throw BlockJournalError.corrupt }
            }
            guard let entry = entries[binding.transactionID], entry.binding == binding,
                  !entry.terminal else { throw BlockJournalError.corrupt }
            try BlockJournalStore.withRecoverySnapshot(directory: logDirectory, binding: binding,
                key: secret, expectedSeal: entry.seal, expectedPool: pool, publishCompletion: {
                    try self.verifyLive()
                    var updated = self.entries
                    var completed = entry
                    if committed { completed.commitCheckpoint = checkpoint }
                    else { completed.recoveryCheckpoint = checkpoint }
                    updated[binding.transactionID] = completed
                    try self.persist(updated)
                }) { snapshot in
                    guard snapshot.checkpoint == (committed ? checkpoint : nil) else { throw BlockJournalError.corrupt }
                    recoveringDevice = true
                    defer { recoveringDevice = false }
                    try validate(snapshot)
                    recoveringDevice = false
                    try verifyLive() // Detect swallowed reentrant errors or authority mutation.
                }
            return entry.seal
        } catch { failed = true; throw error }
    }
    private static func validateCheckpoint(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw BlockJournalError.invalid }
    }
    func read(_ binding: BlockJournalBinding) throws -> BlockJournalSeal? {
        do {
            try verifyLive(); try validateBinding(binding)
            guard let entry = entries[binding.transactionID] else { return nil }
            guard entry.binding == binding, !entry.terminal else { throw BlockJournalError.corrupt }
            return entry.seal
        } catch { failed = true; throw error }
    }
    func save(_ binding: BlockJournalBinding, previous: BlockJournalSeal?, next: BlockJournalSeal) throws -> BlockJournalSeal {
        do {
            try verifyLive(); try validateBinding(binding); try Self.validate(next)
            let old = entries[binding.transactionID]
            if old == nil { try Self.checkAdmission(binding, entries: entries) }
            guard old?.terminal != true, old?.seal == previous, old == nil || old?.binding == binding,
                  next.sequence == (previous?.sequence ?? 0) + 1,
                  next.authentication != previous?.authentication else { throw BlockJournalError.corrupt }
            guard old != nil || entries.count < capacity else { throw BlockJournalError.capacity }
            var updated = entries
            updated[binding.transactionID] = Entry(binding: binding, sequence: next.sequence, authentication: next.authentication)
            try persist(updated)
            return next
        } catch { failed = true; throw error }
    }
    private static func validate(_ seal: BlockJournalSeal) throws {
        guard (1...65536).contains(seal.sequence), seal.authentication.utf8.count == 64,
              seal.authentication.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BlockJournalError.invalid
        }
    }
    private func decode(_ data: Data) throws -> Decoded {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard HMAC<SHA256>.isValidAuthenticationCode(envelope.authentication,
            authenticating: Self.message(envelope.payload), using: SymmetricKey(data: secret)) else { throw BlockJournalError.corrupt }
        let payload = try JSONDecoder().decode(Payload.self, from: envelope.payload)
        guard [1, 2, 3, 4, 5, 6].contains(payload.version), payload.entries.count <= capacity else { throw BlockJournalError.corrupt }
        guard payload.pool == pool, (payload.version >= 5) == (payload.pool != nil) else { throw BlockJournalError.corrupt }
        try payload.pool?.validate()
        let count = payload.generation ?? 0
        guard (payload.epoch == nil) == (count == 0),
              payload.version >= 4 || (payload.epoch == nil && count == 0) else { throw BlockJournalError.corrupt }
        var records: [UUID: Entry] = [:]
        for entry in payload.entries {
            try BlockJournalStore.validate(entry.binding); try Self.validate(entry.seal)
            guard entry.binding.recoveryBaselineSHA256 == nil || payload.version >= 6 else { throw BlockJournalError.corrupt }
            guard entry.binding.authorityEpoch == payload.epoch else { throw BlockJournalError.corrupt }
            if let checkpoint = entry.recoveryCheckpoint {
                guard payload.version >= 2 else { throw BlockJournalError.corrupt }
                try Self.validateCheckpoint(checkpoint)
                guard entry.binding.recoveryBaselineSHA256 == nil || entry.binding.recoveryBaselineSHA256 == checkpoint else { throw BlockJournalError.corrupt }
            }
            if let checkpoint = entry.commitCheckpoint {
                guard payload.version >= 3, entry.recoveryCheckpoint == nil else { throw BlockJournalError.corrupt }
                try Self.validateCheckpoint(checkpoint)
            }
            guard records.updateValue(entry, forKey: entry.binding.transactionID) == nil else { throw BlockJournalError.corrupt }
        }
        return Decoded(entries: records, epoch: payload.epoch, generation: count)
    }
    private static func message(_ payload: Data) -> Data { Data("VolisleBlockAuthority/v1|".utf8) + payload }
    private func persist(_ updated: [UUID: Entry], newEpoch: UUID? = nil, allowDeviceOperation: Bool = false) throws {
        try verifyLive(allowDeviceOperation: allowDeviceOperation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let nextGeneration = newEpoch == nil ? generation : generation + 1
        let nextEpoch = newEpoch ?? epoch
        let payload = try encoder.encode(Payload(version: pool == nil ? 4 : 6, entries: updated.values.sorted { $0.binding.transactionID.uuidString < $1.binding.transactionID.uuidString }, epoch: nextEpoch, generation: nextGeneration, pool: pool))
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Self.message(payload), using: SymmetricKey(data: secret)))
        let data = try encoder.encode(Envelope(payload: payload, authentication: tag))
        guard data.count <= Self.stateLimit else { throw BlockJournalError.capacity }
        try boundary("before-write")
        let temp = "anchor-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(directory, temp, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BlockJournalError.unavailable }
        defer { Darwin.close(fd); _ = unlinkat(directory, temp, 0) }
        try Self.write(fd, data); try boundary("written")
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("file-durable")
        try verifyLive(extra: temp, allowDeviceOperation: allowDeviceOperation)
        try validateNamedFile(fd, temp, size: data.count)
        guard renameat(directory, temp, directory, "anchors.json") == 0 else { throw BlockJournalError.unavailable }
        try boundary("renamed")
        guard fsync(directory) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("directory-durable")
        try validateDirectory(); try verifyPool(); try validateNamedFile(fd, "anchors.json", size: data.count)
        guard try readFile("anchors.json", limit: Self.stateLimit) == data,
              try readFile("key.bin", limit: 32) == secret else { throw BlockJournalError.corrupt }
        guard !failed else { throw BlockJournalError.failed }
        encodedState = data; entries = updated; epoch = nextEpoch; generation = nextGeneration
    }
    private func verifyLive(extra: String? = nil, allowDeviceOperation: Bool = false) throws {
        guard !failed, (!recoveringDevice || allowDeviceOperation), directory >= 0, secret.count == 32, pending == nil else { throw BlockJournalError.failed }
        try validateDirectory(); try verifyPool()
        var expected = Set(["key.bin"])
        if encodedState != nil { expected.insert("anchors.json") }
        if let extra { expected.insert(extra) }
        guard try names() == expected, try readFile("key.bin", limit: 32) == secret else { throw BlockJournalError.corrupt }
        if let encodedState {
            guard try readFile("anchors.json", limit: Self.stateLimit) == encodedState else { throw BlockJournalError.corrupt }
        }
    }
    private func verifyPool(_ supplied: URL? = nil) throws {
        guard let pool else { return } // Test-only legacy fixtures have no pool.
        try pool.validate()
        if let supplied { guard supplied.isFileURL, supplied.path == pool.path else { throw BlockJournalError.corrupt } }
        guard try BlockJournalStore.pool(directory: URL(fileURLWithPath: pool.path),
            byteLimit: pool.byteLimit, fileLimit: pool.fileLimit) == pool else { throw BlockJournalError.corrupt }
    }
    /// Called at a serialized idle/admission boundary. Only durable terminal
    /// receipts authorize deletion. Unknown logs and unresolved transactions are
    /// never repaired, abandoned or promoted to terminal to create capacity.
    func maintainCompletedTransactions() throws -> BlockJournalMaintenanceResult {
        do {
            try verifyLive()
            guard let pool else { throw BlockJournalError.unavailable }
            let logs = URL(fileURLWithPath: pool.path)
            try BlockJournalStore.validatePoolInventory(pool, known: Set(entries.keys),
                required: Set(entries.values.filter { !$0.terminal }.map { $0.binding.transactionID }))
            let completed = entries.values.filter(\.terminal).map(\.binding)
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString }
            var removed = 0, absent = 0
            for binding in completed {
                if try retireLog(binding, logDirectory: logs) { removed += 1 }
                else { absent += 1 }
            }
            let unresolved = entries.values.filter { !$0.terminal }.count
            let advance = !entries.isEmpty && unresolved == 0
            if advance { try advanceEpoch(logDirectory: logs) }
            try verifyLive()
            return .init(removedLogs: removed, alreadyAbsentLogs: absent,
                         unresolvedTransactions: unresolved, advancedEpoch: advance)
        } catch { failed = true; throw error }
    }
    /// One admission path for the service: reclaim safe prior work BEFORE
    /// allocating the new binding, so a rollover never expires a just-issued ID.
    /// Caller owns physical-device fencing; no recovery is inferred or attempted.
    func prepareTransaction(volumeIdentity: String, bootSHA256: String, deviceSize: Int64,
                            blockSize: Int, byteLimit: Int = 64 * 1024 * 1024, recoveryBaselineSHA256: String? = nil,
                            stopWrites: @escaping () -> Void) throws ->
        (binding: BlockJournalBinding, transaction: BlockJournalTransaction, maintenance: BlockJournalMaintenanceResult) {
        var stopped = false
        let stop = { if !stopped { stopped = true; stopWrites() } }
        do {
            try verifyLive()
            // Reject bad/duplicate requests before touching old completed logs.
            var proposed = BlockJournalBinding(transactionID: UUID(), volumeIdentity: volumeIdentity,
                bootSHA256: bootSHA256, deviceSize: deviceSize, blockSize: blockSize)
            proposed.recoveryBaselineSHA256 = recoveryBaselineSHA256
            try BlockJournalStore.validate(proposed)
            guard (16384...64 * 1024 * 1024).contains(byteLimit) else { throw BlockJournalError.invalid }
            guard let pool else { throw BlockJournalError.unavailable }
            guard byteLimit <= pool.byteLimit else { throw BlockJournalError.capacity }
            try Self.checkAdmission(proposed, entries: entries)
            let maintenance = try maintainCompletedTransactions()
            let binding = try newBinding(volumeIdentity: volumeIdentity, bootSHA256: bootSHA256,
                                         deviceSize: deviceSize, blockSize: blockSize, recoveryBaselineSHA256: recoveryBaselineSHA256)
            let transaction = try beginTransaction(binding, byteLimit: byteLimit, stopWrites: stop)
            return (binding, transaction, maintenance)
        } catch { failed = true; stop(); throw error }
    }
    /// All managed transactions share one authenticated directory and capacity.
    /// The caller still owns device fencing and before-image acquisition.
    func beginTransaction(_ binding: BlockJournalBinding, byteLimit: Int = 64 * 1024 * 1024,
                          stopWrites: @escaping () -> Void) throws -> BlockJournalTransaction {
        do {
            try requireNewTransaction(binding)
            guard let pool, (16384...64 * 1024 * 1024).contains(byteLimit) else { throw BlockJournalError.invalid }
            return try BlockJournalTransaction(directory: URL(fileURLWithPath: pool.path), binding: binding, key: secret,
                byteLimit: byteLimit, expectedPool: pool,
                saveAnchor: { [self] binding, previous, next in try save(binding, previous: previous, next: next) },
                stopWrites: stopWrites)
        } catch { failed = true; throw error }
    }
    private func validateDirectory() throws {
        var opened = stat(), named = stat()
        guard fstat(directory, &opened) == 0, opened.st_uid == owner, opened.st_mode & 0o777 == 0o700,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_mode & S_IFMT == S_IFDIR else { throw BlockJournalError.corrupt }
    }
    private func validateNamedFile(_ fd: Int32, _ name: String, size: Int) throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, opened.st_size == size, opened.st_uid == owner,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_mode & 0o777 == 0o600, opened.st_nlink == 1,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { throw BlockJournalError.corrupt }
    }
    private func readFile(_ name: String, limit: Int) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BlockJournalError.unavailable }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= limit else { throw BlockJournalError.corrupt }
        let size = Int(info.st_size)
        try validateNamedFile(fd, name, size: size)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var at = 0
            while at < size {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: at), size-at)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BlockJournalError.corrupt }; at += n
            }
        }
        try validateNamedFile(fd, name, size: size); return data
    }
    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var at = 0
            while at < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: at), bytes.count-at)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BlockJournalError.unavailable }; at += n
            }
        }
    }
    private func names() throws -> Set<String> {
        let copied = dup(directory)
        guard copied >= 0 else { throw BlockJournalError.unavailable }
        guard let stream = fdopendir(copied) else { Darwin.close(copied); throw BlockJournalError.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw BlockJournalError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.insert(name) }
            guard names.count <= 3 else { throw BlockJournalError.corrupt }
        }
        return names
    }
    private static func openDirectory(_ url: URL, owner: uid_t, strictAncestors: Bool, privateLeaf: Bool = true) throws -> (Int32, Int32) {
        guard url.isFileURL, url.path == url.standardizedFileURL.path, url.pathComponents.count > 1 else { throw BlockJournalError.invalid }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var parent: Int32 = -1
        guard fd >= 0 else { throw BlockJournalError.unavailable }
        do {
            for part in url.pathComponents.dropFirst() {
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw BlockJournalError.unavailable }
                if strictAncestors {
                    guard info.st_uid == owner, info.st_mode & 0o022 == 0 else { throw BlockJournalError.corrupt }
                }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BlockJournalError.unavailable }
                if parent >= 0 { Darwin.close(parent) }; parent = fd; fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == owner,
                  privateLeaf ? info.st_mode & 0o777 == 0o700 : info.st_mode & 0o022 == 0 else { throw BlockJournalError.corrupt }
            return (fd, parent)
        } catch { Darwin.close(fd); if parent >= 0 { Darwin.close(parent) }; throw error }
    }
    private func boundary(_ name: String) throws {
        #if VOLISLE_BLOCK_JOURNAL_TESTING
        try storageBoundary?(name)
        #endif
    }
}
