// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

struct BlockJournalBinding: Codable, Equatable, Sendable {
    let transactionID: UUID
    let volumeIdentity: String
    let bootSHA256: String
    let deviceSize: Int64
    let blockSize: Int
    var authorityEpoch: UUID? = nil
    var recoveryBaselineSHA256: String? = nil
}
struct BlockJournalSeal: Equatable, Sendable {
    let sequence: Int
    let authentication: String
}
struct BlockJournalWrite: Codable, Equatable, Sendable {
    let offset: Int64
    let before: Data
    let after: Data
}
struct BlockJournalSnapshot: Sendable {
    let binding: BlockJournalBinding
    let writes: [BlockJournalWrite]
    let checkpoint: String?
    let seal: BlockJournalSeal
}
enum BlockJournalError: Error, Equatable { case invalid, unavailable, corrupt, capacity, failed }

/// Authenticated by the authority state. Filesystem UUID + inode + birth time
/// survive a device-number change; relocation/recreation is deliberately refused.
/// This is a local pool identity, not protection against privileged full-volume cloning.
struct BlockJournalPool: Codable, Equatable, Sendable {
    let path: String
    let volumeUUID: Data
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let byteLimit: Int
    let fileLimit: Int

    func validate() throws {
        let url = URL(fileURLWithPath: path)
        guard path == url.standardizedFileURL.path, path.hasPrefix("/"),
              volumeUUID.count == 16, volumeUUID.contains(where: { $0 != 0 }), inode > 0,
              (16384...16 * 1024 * 1024 * 1024).contains(byteLimit),
              (1...256).contains(fileLimit) else { throw BlockJournalError.invalid }
    }
}

/// Native storage only; does not write/repair a device. Serialized by its owner.
/// The caller supplies a private existing directory, a separately protected
/// 256-bit key, and a trusted seal for inspection. Neither key nor seal is
/// bootstrapped from this log. A MAC alone does not prevent rollback/replay.
final class BlockJournalStore {
    private(set) var failed = false
    private(set) var seal = BlockJournalSeal(sequence: 0, authentication: String(repeating: "0", count: 64))
    private var committed = false
    private var directory: Int32 = -1
    private var file: Int32 = -1
    private var used = 0
    private let key: SymmetricKey
    private let binding: BlockJournalBinding
    private let byteLimit: Int
    private let recordLimit: Int
    private let failClosed: () -> Void
    private let expectedPool: BlockJournalPool?
    private let directoryURL: URL
    private static let maxFrame = 4 * 1024 * 1024
    private static let reserve = 8192
    #if VOLISLE_BLOCK_JOURNAL_TESTING
    var storageBoundary: ((String) throws -> Void)?
    #endif
    private struct Event: Codable {
        let kind: String
        var binding: BlockJournalBinding? = nil
        var write: BlockJournalWrite? = nil
        var checkpoint: String? = nil
    }
    private struct Frame: Codable {
        let version: Int
        let sequence: Int
        let previous: String
        let payload: Data
        let authentication: String
    }
    init(directory url: URL, binding: BlockJournalBinding, key: Data,
         byteLimit: Int = 64 * 1024 * 1024, recordLimit: Int = 4096,
         directoryByteLimit: Int = 1024 * 1024 * 1024, directoryFileLimit: Int = 256,
         expectedPool: BlockJournalPool? = nil, failClosed: @escaping () -> Void) throws {
        self.expectedPool = expectedPool; self.directoryURL = url
        self.binding = binding; self.key = SymmetricKey(data: key)
        self.byteLimit = byteLimit; self.recordLimit = recordLimit; self.failClosed = failClosed
        try Self.validate(binding)
        guard key.count == 32, byteLimit >= 16384, byteLimit <= 256 * 1024 * 1024,
              recordLimit >= 3, recordLimit <= 65536,
              directoryByteLimit >= 16384, directoryByteLimit <= 16 * 1024 * 1024 * 1024,
              directoryFileLimit > 0, directoryFileLimit <= 256 else { throw BlockJournalError.invalid }
        do {
            directory = try Self.openDirectory(url, expectedPool: expectedPool)
            // Reserve the entire per-log logical budget before creating a file.
            // The directory lease is held until close, so cooperating writers
            // cannot concurrently spend this space. This is not disk preallocation.
            try Self.admit(directory, bytes: byteLimit, totalLimit: expectedPool?.byteLimit ?? directoryByteLimit, fileLimit: expectedPool?.fileLimit ?? directoryFileLimit)
            file = openat(directory, Self.name(binding), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard file >= 0 else { throw BlockJournalError.unavailable }
            try append(Event(kind: "begin", binding: binding), terminal: false)
            guard fsync(directory) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        } catch { poison(); close(); throw error }
    }
    deinit { close() }
    func close() {
        if file >= 0 { Darwin.close(file); file = -1 }
        if directory >= 0 { _ = flock(directory, LOCK_UN); Darwin.close(directory); directory = -1 }
    }
    private func poison() { if !failed { failed = true; failClosed() } }
    /// The operation coordinator must call this after any device/pipeline
    /// failure; a successful later flush cannot retroactively commit it.
    func abort() { poison() }
    func record(offset: Int64, before: Data, after: Data) throws {
        do {
            let write = BlockJournalWrite(offset: offset, before: before, after: after)
            try Self.validate(write, binding)
            try append(Event(kind: "write", write: write), terminal: false)
        } catch { poison(); throw error }
    }
    func commit(checkpoint: String, flushDevice: () throws -> Void) throws {
        do {
            guard !failed, !committed, file >= 0, Self.hex(checkpoint) else { throw BlockJournalError.failed }
            try flushDevice()
            try append(Event(kind: "committed", checkpoint: checkpoint), terminal: true)
            committed = true
        } catch { poison(); throw error }
    }
    private func append(_ event: Event, terminal: Bool) throws {
        guard !failed, !committed, file >= 0 else { throw BlockJournalError.failed }
        guard seal.sequence < recordLimit - (terminal ? 0 : 1) else { throw BlockJournalError.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(event)
        let sequence = seal.sequence + 1
        let authentication = Self.authenticate(key, sequence, seal.authentication, payload)
        let frame = try encoder.encode(Frame(version: 1, sequence: sequence, previous: seal.authentication,
                                              payload: payload, authentication: authentication))
        guard frame.count <= Self.maxFrame, frame.count + 4 <= byteLimit - used - (terminal ? 0 : Self.reserve) else {
            throw BlockJournalError.capacity
        }
        try validateLiveFile(size: used)
        var length = UInt32(frame.count).bigEndian
        var bytes = withUnsafeBytes(of: &length) { Data($0) }; bytes.append(frame)
        try boundary("before-write")
        try bytes.withUnsafeBytes { buffer in
            var at = 0
            while at < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: at), buffer.count-at)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BlockJournalError.unavailable }
                at += count
            }
        }
        try boundary("written")
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("durable")
        try validateLiveFile(size: used + bytes.count)
        used += bytes.count
        seal = BlockJournalSeal(sequence: sequence, authentication: authentication)
    }
    private func boundary(_ name: String) throws {
        #if VOLISLE_BLOCK_JOURNAL_TESTING
        try storageBoundary?(name)
        #endif
    }
    private func validateLiveFile(size: Int) throws {
        try Self.verifyPool(expectedPool, directory: directory, url: directoryURL)
        var info = stat(); var named = stat()
        guard fstat(file, &info) == 0, info.st_size == size,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              fstatat(directory, Self.name(binding), &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino,
              named.st_mode & S_IFMT == S_IFREG else { throw BlockJournalError.corrupt }
    }
    static func reconcile(directory: URL, binding: BlockJournalBinding, key: Data,
                          expectedSeal: BlockJournalSeal, expectedPool: BlockJournalPool? = nil,
                          saveRecoveredSeal: (BlockJournalSeal, BlockJournalSeal) throws -> BlockJournalSeal) throws -> BlockJournalSnapshot {
        try load(directory: directory, binding: binding, key: key, expectedSeal: expectedSeal,
                 byteLimit: 64 * 1024 * 1024, recordLimit: 4096, allowOneAhead: true, saveRecoveredSeal: saveRecoveredSeal, expectedPool: expectedPool)
    }
    static func inspect(directory url: URL, binding: BlockJournalBinding, key: Data,
                        expectedSeal: BlockJournalSeal, byteLimit: Int = 64 * 1024 * 1024,
                        recordLimit: Int = 4096, expectedPool: BlockJournalPool? = nil) throws -> BlockJournalSnapshot {
        try load(directory: url, binding: binding, key: key, expectedSeal: expectedSeal,
                 byteLimit: byteLimit, recordLimit: recordLimit, allowOneAhead: false,
                 saveRecoveredSeal: { _, _ in throw BlockJournalError.corrupt }, expectedPool: expectedPool)
    }
    /// Validate and flush an exact authenticated head, retaining the file and
    /// directory leases while a trusted authority completes its publication.
    static func withVerifiedSnapshot(directory: URL, binding: BlockJournalBinding, key: Data,
                                     expectedSeal: BlockJournalSeal, requiredPrefix: BlockJournalSeal?,
                                     expectedPool: BlockJournalPool? = nil, publish: () throws -> Void) throws {
        _ = try load(directory: directory, binding: binding, key: key, expectedSeal: expectedSeal,
                     byteLimit: 64 * 1024 * 1024, recordLimit: 4096, allowOneAhead: false,
                     saveRecoveredSeal: { _, _ in throw BlockJournalError.corrupt }, expectedPool: expectedPool,
                     publication: true, requiredPrefix: requiredPrefix, afterValidation: { _ in try publish() })
    }
    /// Retain the authenticated log lease through a recovery executor. Device
    /// identity/fencing and independent baseline validation remain caller duties.
    /// Completion publishes only after recovery returns and log identity is
    /// rechecked, while both log leases are still held.
    static func withRecoverySnapshot(directory: URL, binding: BlockJournalBinding, key: Data,
                                     expectedSeal: BlockJournalSeal,
                                     expectedPool: BlockJournalPool? = nil, publishCompletion: () throws -> Void = {},
                                     recover: (BlockJournalSnapshot) throws -> Void) throws {
        _ = try load(directory: directory, binding: binding, key: key, expectedSeal: expectedSeal,
                     byteLimit: 64 * 1024 * 1024, recordLimit: 4096, allowOneAhead: false,
                     saveRecoveredSeal: { _, _ in throw BlockJournalError.corrupt }, expectedPool: expectedPool,
                     publication: true, afterValidation: recover, afterRecoveryValidation: publishCompletion)
    }
    /// Admission inventory only. Authentication of terminal content remains
    /// retireCompleted's duty. Unknown names are never adopted or deleted.
    static func validatePoolInventory(_ pool: BlockJournalPool, known: Set<UUID>, required: Set<UUID>) throws {
        try pool.validate()
        guard required.isSubset(of: known), known.count <= 256 else { throw BlockJournalError.invalid }
        let url = URL(fileURLWithPath: pool.path)
        let directory = try openDirectory(url, expectedPool: pool)
        defer { _ = flock(directory, LOCK_UN); Darwin.close(directory) }
        let copy = dup(directory)
        guard copy >= 0 else { throw BlockJournalError.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw BlockJournalError.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var seen = Set<UUID>(), used = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw BlockJournalError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard name.hasSuffix(".blocklog"), let id = UUID(uuidString: String(name.dropLast(9))),
                  id.uuidString.lowercased()+".blocklog" == name, known.contains(id), seen.insert(id).inserted else {
                throw BlockJournalError.corrupt
            }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 64 * 1024 * 1024 else { throw BlockJournalError.corrupt }
            guard seen.count <= pool.fileLimit, info.st_size <= pool.byteLimit-used else { throw BlockJournalError.capacity }
            used += Int(info.st_size)
        }
        guard required.isSubset(of: seen) else { throw BlockJournalError.corrupt }
        try verifyPool(pool, directory: directory, url: url)
    }
    /// The caller owns a durable all-terminal authority state. Keep the pool
    /// empty and exclusively leased while its generation fence is replaced.
    static func withEmptyDirectoryLease(directory url: URL, expectedPool: BlockJournalPool? = nil, publish: () throws -> Void) throws {
        let directory = try openDirectory(url, expectedPool: expectedPool)
        defer { _ = flock(directory, LOCK_UN); Darwin.close(directory) }
        func empty() throws {
            try verifyPool(expectedPool, directory: directory, url: url)
            try verifyRetirementDirectory(directory, url: url)
            let copy = dup(directory)
            guard copy >= 0 else { throw BlockJournalError.unavailable }
            guard let stream = fdopendir(copy) else { Darwin.close(copy); throw BlockJournalError.unavailable }
            defer { closedir(stream) }; rewinddir(stream)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw BlockJournalError.unavailable }; break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) }
                }
                guard name == "." || name == ".." else { throw BlockJournalError.unavailable }
            }
        }
        try empty()
        guard fsync(directory) == 0, fcntl(directory, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try empty(); try publish(); try empty()
    }
    /// Only a durable authority terminal may authorize this call. Authenticate
    /// the exact log before unlinking; an already absent name is acknowledged
    /// only for this selected directory, after flushing its directory entry.
    /// No device I/O, tombstone deletion, scanning, or untrusted-path cleanup.
    static func retireCompleted(directory url: URL, binding: BlockJournalBinding, key: Data,
                                expectedSeal: BlockJournalSeal, expectedCheckpoint: String?,
                                expectedPool: BlockJournalPool? = nil, boundary: (String) throws -> Void = { _ in }) throws -> Bool {
        try validate(binding)
        guard key.count == 32, (1...4096).contains(expectedSeal.sequence),
              hex(expectedSeal.authentication) else { throw BlockJournalError.invalid }
        let directory = try openDirectory(url, expectedPool: expectedPool)
        defer { _ = flock(directory, LOCK_UN); Darwin.close(directory) }
        var named = stat()
        if fstatat(directory, name(binding), &named, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw BlockJournalError.unavailable }
            try syncRetirementDirectory(directory, url: url, boundary: boundary)
            // If an unexpected writer introduced the name during the flush,
            // do not report that this directory is absent/durable.
            guard fstatat(directory, name(binding), &named, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw BlockJournalError.corrupt }
            return false
        }
        _ = try load(directory: url, binding: binding, key: key, expectedSeal: expectedSeal,
            byteLimit: 64 * 1024 * 1024, recordLimit: 4096, allowOneAhead: false,
            saveRecoveredSeal: { _, _ in throw BlockJournalError.corrupt }, expectedPool: expectedPool, publication: true,
            afterValidation: { snapshot in
                guard snapshot.checkpoint == expectedCheckpoint else { throw BlockJournalError.corrupt }
            }, leasedDirectory: directory, retiring: true, retirementBoundary: boundary)
        return true
    }
    private static func verifyRetirementDirectory(_ directory: Int32, url: URL) throws {
        let current = try openDirectory(url, lock: false); defer { Darwin.close(current) }
        var held = stat(), named = stat()
        guard fstat(directory, &held) == 0, fstat(current, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode == named.st_mode, held.st_uid == named.st_uid else { throw BlockJournalError.corrupt }
    }
    private static func syncRetirementDirectory(_ directory: Int32, url: URL,
                                                 boundary: (String) throws -> Void) throws {
        try boundary("retirement-before-directory-sync")
        try verifyRetirementDirectory(directory, url: url)
        guard fsync(directory) == 0, fcntl(directory, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
        try boundary("retirement-directory-durable")
        try verifyRetirementDirectory(directory, url: url)
    }
    /// For a fenced recovery session only: all records must authenticate, the
    /// trusted head must match an exact prefix, and at most ONE record may follow.
    /// The producer must obey BlockJournalTransaction's log -> anchor -> device
    /// ordering. This never handles unknown initial anchors or partial tails.
    /// The caller must hold the device lease; this method holds the log lease
    /// across the durable authority CAS. It neither repairs nor cleans a volume.
    private static func load(directory url: URL, binding: BlockJournalBinding, key: Data,
                             expectedSeal: BlockJournalSeal, byteLimit: Int, recordLimit: Int,
                             allowOneAhead: Bool,
                             saveRecoveredSeal: (BlockJournalSeal, BlockJournalSeal) throws -> BlockJournalSeal,
                             expectedPool: BlockJournalPool? = nil, publication: Bool = false,
                             requiredPrefix: BlockJournalSeal? = nil,
                             afterValidation: (BlockJournalSnapshot) throws -> Void = { _ in },
                             afterRecoveryValidation: () throws -> Void = {},
                             leasedDirectory: Int32? = nil, retiring: Bool = false,
                             retirementBoundary: (String) throws -> Void = { _ in }) throws -> BlockJournalSnapshot {
        try validate(binding)
        guard key.count == 32, byteLimit >= 16384, byteLimit <= 256 * 1024 * 1024,
              recordLimit >= 3, recordLimit <= 65536,
              expectedSeal.sequence > 0, expectedSeal.sequence <= recordLimit,
              hex(expectedSeal.authentication) else { throw BlockJournalError.invalid }
        if let requiredPrefix {
            guard requiredPrefix.sequence > 0, requiredPrefix.sequence < expectedSeal.sequence,
                  hex(requiredPrefix.authentication) else { throw BlockJournalError.invalid }
        }
        let directory = try leasedDirectory ?? openDirectory(url, expectedPool: expectedPool)
        defer { if leasedDirectory == nil { _ = flock(directory, LOCK_UN); Darwin.close(directory) } }
        let file = openat(directory, name(binding), (allowOneAhead || publication ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw BlockJournalError.unavailable }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= byteLimit else { throw BlockJournalError.corrupt }
        let size = Int(info.st_size)
        func unchanged() throws {
            try verifyPool(expectedPool, directory: directory, url: url)
            var after = stat(), named = stat()
            guard fstat(file, &after) == 0, after.st_size == info.st_size,
                  after.st_uid == info.st_uid, after.st_mode == info.st_mode, after.st_nlink == 1,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
                  fstatat(directory, name(binding), &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_ino == info.st_ino, named.st_dev == info.st_dev,
                  named.st_mode & S_IFMT == S_IFREG else { throw BlockJournalError.corrupt }
        }
        try unchanged()
        let key = SymmetricKey(data: key)
        var at = 0; var sequence = 0; var previous = String(repeating: "0", count: 64)
        var matchedTrustedPrefix = false
        var matchedRequiredPrefix = requiredPrefix == nil
        var writes: [BlockJournalWrite] = []; var checkpoint: String?
        while at < size {
            guard sequence < recordLimit, checkpoint == nil, size-at >= 4 else { throw BlockJournalError.corrupt }
            let prefix = try read(file, at, 4)
            let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= maxFrame, length <= size-at-4 else { throw BlockJournalError.corrupt }
            let frame = try JSONDecoder().decode(Frame.self, from: read(file, at+4, length))
            guard frame.version == 1, frame.sequence == sequence+1, frame.previous == previous,
                  hex(frame.authentication), let tag = unhex(frame.authentication),
                  HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message(frame.sequence, frame.previous, frame.payload), using: key) else {
                throw BlockJournalError.corrupt
            }
            if frame.sequence == expectedSeal.sequence {
                guard frame.authentication == expectedSeal.authentication else { throw BlockJournalError.corrupt }
                matchedTrustedPrefix = true
            } else if frame.sequence > expectedSeal.sequence {
                guard allowOneAhead, frame.sequence == expectedSeal.sequence + 1 else { throw BlockJournalError.corrupt }
            }
            if let requiredPrefix, frame.sequence == requiredPrefix.sequence {
                guard frame.authentication == requiredPrefix.authentication else { throw BlockJournalError.corrupt }
                matchedRequiredPrefix = true
            }
            let event = try JSONDecoder().decode(Event.self, from: frame.payload)
            if sequence == 0 {
                guard event.kind == "begin", event.binding == binding, event.write == nil, event.checkpoint == nil else { throw BlockJournalError.corrupt }
            } else if event.kind == "write" {
                guard event.binding == nil, event.checkpoint == nil, let write = event.write else { throw BlockJournalError.corrupt }
                try validate(write, binding); writes.append(write)
            } else if event.kind == "committed" {
                guard event.binding == nil, event.write == nil, let digest = event.checkpoint, hex(digest) else { throw BlockJournalError.corrupt }
                checkpoint = digest
            } else { throw BlockJournalError.corrupt }
            sequence = frame.sequence; previous = frame.authentication; at += 4+length
        }
        let seal = BlockJournalSeal(sequence: sequence, authentication: previous)
        guard matchedTrustedPrefix, matchedRequiredPrefix else { throw BlockJournalError.corrupt }
        try unchanged()
        if seal != expectedSeal {
            guard allowOneAhead, seal.sequence == expectedSeal.sequence + 1 else { throw BlockJournalError.corrupt }
            // A complete record may have survived before its original fsync
            // returned. Make it durable before moving the independent anchor.
            guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
            try unchanged()
            guard try saveRecoveredSeal(expectedSeal, seal) == seal else { throw BlockJournalError.corrupt }
            try unchanged()
        }
        let snapshot = BlockJournalSnapshot(binding: binding, writes: writes, checkpoint: checkpoint, seal: seal)
        if publication {
            guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
            try unchanged(); try afterValidation(snapshot); try unchanged()
            try afterRecoveryValidation(); try unchanged()
        }
        if retiring {
            guard publication, leasedDirectory != nil else { throw BlockJournalError.invalid }
            try retirementBoundary("retirement-before-unlink")
            try verifyRetirementDirectory(directory, url: url); try unchanged()
            guard unlinkat(directory, name(binding), 0) == 0 else { throw BlockJournalError.unavailable }
            try retirementBoundary("retirement-unlinked")
            try syncRetirementDirectory(directory, url: url, boundary: retirementBoundary)
            var remaining = stat()
            guard fstatat(directory, name(binding), &remaining, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw BlockJournalError.corrupt }
        }
        return snapshot
    }
    private static func admit(_ directory: Int32, bytes: Int, totalLimit: Int, fileLimit: Int) throws {
        let copied = dup(directory)
        guard copied >= 0 else { throw BlockJournalError.unavailable }
        guard let stream = fdopendir(copied) else { Darwin.close(copied); throw BlockJournalError.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var used = 0, count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw BlockJournalError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard name.hasSuffix(".blocklog"), let id = UUID(uuidString: String(name.dropLast(9))),
                  id.uuidString.lowercased()+".blocklog" == name else { throw BlockJournalError.corrupt }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 256 * 1024 * 1024 else { throw BlockJournalError.corrupt }
            guard count < fileLimit, info.st_size <= totalLimit - used else { throw BlockJournalError.capacity }
            count += 1; used += Int(info.st_size)
        }
        guard count < fileLimit, bytes <= totalLimit - used else { throw BlockJournalError.capacity }
    }
    private static func read(_ file: Int32, _ offset: Int, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var at = 0
            while at < count {
                let n = pread(file, buffer.baseAddress!.advanced(by: at), count-at, off_t(offset+at))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BlockJournalError.corrupt }; at += n
            }
        }; return data
    }
    private static func name(_ binding: BlockJournalBinding) -> String { binding.transactionID.uuidString.lowercased()+".blocklog" }
    private static func message(_ sequence: Int, _ previous: String, _ payload: Data) -> Data {
        Data("VolisleBlockJournal/v1|\(sequence)|\(previous)|".utf8)+payload
    }
    private static func authenticate(_ key: SymmetricKey, _ sequence: Int, _ previous: String, _ payload: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: message(sequence, previous, payload), using: key).map { String(format: "%02x", $0) }.joined()
    }
    private static func hex(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func unhex(_ value: String) -> Data? {
        guard hex(value) else { return nil }
        let bytes = Array(value.utf8)
        return Data(stride(from:0,to:64,by:2).map { UInt8(String(bytes:bytes[$0..<$0+2],encoding:.utf8)!,radix:16)! })
    }
    static func validate(_ binding: BlockJournalBinding) throws {
        if let baseline = binding.recoveryBaselineSHA256 {
            guard hex(baseline) else { throw BlockJournalError.invalid }
        }
        guard !binding.volumeIdentity.isEmpty, binding.volumeIdentity.utf8.count <= 256, hex(binding.bootSHA256),
              binding.deviceSize >= 512, binding.deviceSize % 512 == 0,
              binding.blockSize >= 512, binding.blockSize <= 1024*1024,
              binding.blockSize & (binding.blockSize-1) == 0 else { throw BlockJournalError.invalid }
    }
    private static func validate(_ write: BlockJournalWrite, _ binding: BlockJournalBinding) throws {
        guard write.offset >= 0, write.offset < binding.deviceSize, write.offset % Int64(binding.blockSize) == 0,
              write.before.count == write.after.count,
              write.before.count == Int(min(Int64(binding.blockSize),binding.deviceSize-write.offset)) else { throw BlockJournalError.invalid }
    }
    static func pool(directory url: URL, byteLimit: Int = 1024 * 1024 * 1024,
                     fileLimit: Int = 256) throws -> BlockJournalPool {
        let fd = try openDirectory(url, lock: false); defer { Darwin.close(fd) }
        return try identifyPool(fd, url: url, byteLimit: byteLimit, fileLimit: fileLimit)
    }
    static func verifyPool(_ expected: BlockJournalPool?, directory: Int32, url: URL) throws {
        guard let expected else { return }
        try expected.validate()
        guard try identifyPool(directory, url: url, byteLimit: expected.byteLimit, fileLimit: expected.fileLimit) == expected else {
            throw BlockJournalError.corrupt
        }
        // Detect a replaced/renamed path as well as a wrong held descriptor.
        try verifyRetirementDirectory(directory, url: url)
    }
    private static func identifyPool(_ fd: Int32, url: URL, byteLimit: Int, fileLimit: Int) throws -> BlockJournalPool {
        var info = stat(), attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 20)
        let result = bytes.withUnsafeMutableBytes { fgetattrlist(fd, &attrs, $0.baseAddress!, $0.count, 0) }
        guard fstat(fd, &info) == 0, result == 0, bytes[0..<4].elementsEqual([20,0,0,0]) else {
            throw BlockJournalError.unavailable
        }
        let value = BlockJournalPool(path: url.path, volumeUUID: Data(bytes[4..<20]), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            byteLimit: byteLimit, fileLimit: fileLimit)
        try value.validate(); return value
    }
    /// Walk from / with openat; no symlink in any component is followed. The
    /// private final directory is pinned by descriptor and exclusively locked.
    private static func openDirectory(_ url: URL, lock: Bool = true, expectedPool: BlockJournalPool? = nil) throws -> Int32 {
        guard url.isFileURL, url.path == url.standardizedFileURL.path else { throw BlockJournalError.invalid }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw BlockJournalError.unavailable }
        do {
            for part in url.pathComponents.dropFirst() {
                let next = openat(fd,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw BlockJournalError.unavailable }
                Darwin.close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  (!lock || flock(fd,LOCK_EX | LOCK_NB) == 0) else { throw BlockJournalError.unavailable }
            try verifyPool(expectedPool, directory: fd, url: url)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}
