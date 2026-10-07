// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

enum WriteJournalError: Error, Equatable {
    case invalid, unavailable, corrupt, unsupportedFormat, capacity, failed, busy, foreignChange
}

/// Per-volume session facts, written before the first write of a session.
/// `initialFlags` is the clean NTFS flag word this host found; only the
/// dirty marker this host added on top of it may ever be released.
struct WriteJournalSessionRecord: Codable, Equatable {
    enum State: String, Codable { case active, recovered }
    var version = 1
    let session: UUID
    let serial: String
    let deviceSize: Int64
    let blockSize: Int
    let bootSector: Data
    let initialFlags: UInt16
    let logfileOffset: Int64
    let logfileLength: Int
    let logfileSHA256: String
    var state: State
}

/// One epoch file: header, groups, and (after a durable device barrier) a
/// checkpoint. Groups are appended and made durable BEFORE their blocks are
/// written to the device, so a torn tail frame never has device effects.
struct WriteJournalEpoch {
    enum Kind: String, Codable { case normal, recovery }
    struct Header: Codable { let session: UUID; let epoch: UInt64; let kind: Kind }
    struct Group {
        var before: [(offset: Int64, bytes: Data)]
        var after: [(offset: Int64, sha256: Data)]
        /// Each written block's 512-byte sectors, hashed: a block the drive left
        /// half written is then still recognised as this host's own write.
        /// Empty in records written before these were kept.
        var afterSectors: [Int64: [UInt64]] = [:]
    }
    static let sectorSize = 512

    /// The first 8 bytes of each sector's SHA-256.
    static func sectorHashes(_ block: Data) -> [UInt64] {
        var hashes: [UInt64] = []
        hashes.reserveCapacity((block.count + sectorSize - 1) / sectorSize)
        block.withUnsafeBytes { raw in
            var at = 0
            while at < raw.count {
                let end = min(at + sectorSize, raw.count)
                hashes.append(sectorHash(UnsafeRawBufferPointer(rebasing: raw[at..<end])))
                at = end
            }
        }
        return hashes
    }

    static func sectorHash(_ sector: UnsafeRawBufferPointer) -> UInt64 {
        SHA256.hash(data: sector).withUnsafeBytes { digest in digest.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } }
    }
    let header: Header
    var groups: [Group]
    var checkpointed: Bool
    var name: String
}

/// Private journal directory inside the extension's own container. The MAC
/// detects torn or damaged records; it is not a boundary against this
/// extension's own user account, which can already write the device.
final class WriteJournalStore {
    static let maximumFrame = 64 * 1024 * 1024
    /// `sectorGroup`: a group that also carries its blocks' sector hashes.
    private enum FrameType: UInt8 { case header = 1, group = 2, checkpoint = 3, sectorGroup = 4 }
    let url: URL
    private let directory: Int32
    private let key: SymmetricKey

    init(directory url: URL) throws {
        self.url = url
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw WriteJournalError.unavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WriteJournalError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw WriteJournalError.unavailable
        }
        directory = fd
        do { key = SymmetricKey(data: try Self.loadKey(fd)) }
        catch { Darwin.close(fd); throw error }
    }
    deinit { Darwin.close(directory) }

    private static func loadKey(_ directory: Int32) throws -> Data {
        for _ in 0..<2 {
            if let key = try readKey(directory) { return key }
            // A missing key with existing records must never mint a fresh key.
            guard try noRecords(directory) else { throw WriteJournalError.corrupt }
            if let key = try createKey(directory) { return key }
        }
        throw WriteJournalError.unavailable
    }

    /// Nil when there is none. Before 0.7 the key was written in place, so a host
    /// that filled up or a kill could leave it short: such a file is replaced,
    /// but only while no record depends on it.
    private static func readKey(_ directory: Int32) throws -> Data? {
        let fd = openat(directory, "key.bin", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw WriteJournalError.unavailable
        }
        let data: Data
        do { data = try readAll(fd, limit: 32) } catch { Darwin.close(fd); throw error }
        Darwin.close(fd)
        if data.count == 32 { return data }
        guard try noRecords(directory), unlinkat(directory, "key.bin", 0) == 0 || errno == ENOENT else {
            throw WriteJournalError.corrupt
        }
        return nil
    }

    /// Written aside and renamed into place, so key.bin is never seen half
    /// written. Nil when another volume's instance created it first.
    private static func createKey(_ directory: Int32) throws -> Data? {
        var key = Data(count: 32)
        guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw WriteJournalError.unavailable
        }
        let temporary = "key-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteJournalError.unavailable }
        defer { Darwin.close(fd); _ = unlinkat(directory, temporary, 0) }
        try writeAll(fd, key)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        guard renameatx_np(directory, temporary, directory, "key.bin", UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return nil }
            throw WriteJournalError.unavailable
        }
        guard fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        return key
    }

    /// Nothing that a key authenticates: locks, the archive, and leftovers of key creation.
    private static func noRecords(_ directory: Int32) throws -> Bool {
        try listNames(directory).allSatisfy {
            $0 == "key.bin" || $0.hasSuffix(".lock") || $0 == supersededName || ($0.hasPrefix("key-") && $0.hasSuffix(".tmp"))
        }
    }

    // MARK: session record

    func sessionRecord(serial: String) throws -> WriteJournalSessionRecord? {
        let fd = openat(directory, serial + ".session", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw WriteJournalError.unavailable }
        defer { Darwin.close(fd) }
        let data = try Self.readAll(fd, limit: 64 * 1024)
        guard data.count > 32 else { throw WriteJournalError.corrupt }
        let body = data.prefix(data.count - 32), mac = data.suffix(32)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data("session|".utf8) + body, using: key) else {
            throw WriteJournalError.corrupt
        }
        let record: WriteJournalSessionRecord
        do { record = try JSONDecoder().decode(WriteJournalSessionRecord.self, from: body) }
        catch { throw WriteJournalError.corrupt }
        guard record.serial == serial, record.bootSector.count == 512 else { throw WriteJournalError.corrupt }
        guard record.version == 1 else { throw WriteJournalError.unsupportedFormat }
        return record
    }

    func saveSessionRecord(_ record: WriteJournalSessionRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(record)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("session|".utf8) + body, using: key))
        let temporary = record.serial + ".session.tmp"
        _ = unlinkat(directory, temporary, 0)
        let fd = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteJournalError.unavailable }
        defer { Darwin.close(fd) }
        try Self.writeAll(fd, body + mac)
        guard fcntl(fd, F_FULLFSYNC) == 0,
              renameat(directory, temporary, directory, record.serial + ".session") == 0,
              fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
    }

    /// Only after the device holds everything the records describe. The session
    /// goes first: without it nothing is replayed, so an interruption leaves only
    /// orphan epochs (removed by the next session), never a partial set that
    /// recovery would roll back.
    func removeAll(serial: String) throws {
        guard unlinkat(directory, serial + ".session", 0) == 0 || errno == ENOENT,
              fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        #if VOLISLE_WRITE_JOURNAL_TESTING
        Self.afterSessionRemoved?()
        #endif
        try removeOrphanEpochs(serial: serial)
    }
    #if VOLISLE_WRITE_JOURNAL_TESTING
    nonisolated(unsafe) static var afterSessionRemoved: (() -> Void)?
    #endif

    /// Epochs with no session record describe nothing that can be recovered.
    func removeOrphanEpochs(serial: String) throws {
        var removed = false
        for name in try Self.listNames(directory) where name.hasPrefix(serial + "-") && name.hasSuffix(".epoch") {
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw WriteJournalError.unavailable }
            removed = true
        }
        if removed { guard fsync(directory) == 0 else { throw WriteJournalError.unavailable } }
    }

    static let supersededName = "superseded"
    /// Records this host can no longer apply because the volume was used
    /// elsewhere since (e.g. mounted by Windows): move them out of the way,
    /// kept for inspection, so they stop blocking writes. The newest few stay.
    func archive(serial: String, keep: Int = 3) throws {
        let names = try Self.listNames(directory).filter {
            $0 == serial + ".session" || ($0.hasPrefix(serial + "-") && $0.hasSuffix(".epoch"))
        }
        guard !names.isEmpty else { return }
        if mkdirat(directory, Self.supersededName, 0o700) != 0 && errno != EEXIST { throw WriteJournalError.unavailable }
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let folder = Self.supersededName + "/" + stamp + "-" + serial
        guard mkdirat(directory, folder, 0o700) == 0 else { throw WriteJournalError.unavailable }
        // Epochs first, the session record last: a half-done move still has no session, so nothing is replayed.
        for name in names.filter({ $0.hasSuffix(".epoch") }).sorted() + names.filter({ !$0.hasSuffix(".epoch") }) {
            guard renameat(directory, name, directory, folder + "/" + name) == 0 else { throw WriteJournalError.unavailable }
        }
        guard fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        let root = url.appendingPathComponent(Self.supersededName, isDirectory: true)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        for old in kept.dropLast(keep) { try? FileManager.default.removeItem(at: root.appendingPathComponent(old)) }
    }

    /// Held for the life of a mount; excludes a second volume instance or a
    /// concurrent recovery of the same serial in this or another process.
    func lock(serial: String) throws -> Int32 {
        let fd = openat(directory, serial + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteJournalError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw WriteJournalError.busy }
        return fd
    }

    // MARK: epochs

    func epochName(serial: String, epoch: UInt64) -> String { String(format: "%@-%016llx.epoch", serial, epoch) }

    func createEpoch(serial: String, header: WriteJournalEpoch.Header) throws -> (Int32, Data) {
        let name = epochName(serial: serial, epoch: header.epoch)
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteJournalError.unavailable }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let mac = try append(fd, type: .header, payload: try encoder.encode(header), previous: Data(count: 32))
            guard fcntl(fd, F_FULLFSYNC) == 0, fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
            return (fd, mac)
        } catch {
            // No group was recorded under it, so nothing on the device depends on it.
            Darwin.close(fd); _ = unlinkat(directory, name, 0)
            throw error
        }
    }

    func appendGroup(_ fd: Int32, _ group: WriteJournalEpoch.Group, previous: Data) throws -> Data {
        var payload = Data()
        payload.appendInteger(UInt32(group.before.count))
        for item in group.before {
            payload.appendInteger(item.offset); payload.appendInteger(UInt32(item.bytes.count)); payload.append(item.bytes)
        }
        payload.appendInteger(UInt32(group.after.count))
        let sectors = !group.afterSectors.isEmpty
        for item in group.after {
            payload.appendInteger(item.offset); payload.append(item.sha256)
            guard sectors else { continue }
            let hashes = group.afterSectors[item.offset] ?? []
            payload.appendInteger(UInt32(hashes.count))
            for hash in hashes { payload.appendInteger(hash) }
        }
        let mac = try append(fd, type: sectors ? .sectorGroup : .group, payload: payload, previous: previous)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        return mac
    }

    func appendCheckpoint(_ fd: Int32, epoch: UInt64, previous: Data) throws {
        var payload = Data(); payload.appendInteger(epoch)
        _ = try append(fd, type: .checkpoint, payload: payload, previous: previous)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
    }

    func removeEpoch(_ name: String) {
        _ = unlinkat(directory, name, 0)
    }

    /// Recovery rolls back every checkpointed epoch still present, so a pruned
    /// one must not come back after a crash.
    func removeEpochDurably(_ name: String) throws {
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT,
              fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
    }

    private func append(_ fd: Int32, type: FrameType, payload: Data, previous: Data) throws -> Data {
        guard payload.count <= Self.maximumFrame else { throw WriteJournalError.capacity }
        var frame = Data([type.rawValue]); frame.appendInteger(UInt32(payload.count)); frame.append(payload)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: previous + frame, using: key))
        try Self.writeAll(fd, frame + mac)
        return mac
    }

    /// Returns every epoch of `serial`. A torn final frame is dropped; any
    /// other damage, or a header from another session, is corruption. An epoch
    /// whose header never became complete (the host filled up, or the process
    /// died while creating it) recorded no group, so no device write depends on
    /// it: it is removed instead of blocking recovery forever.
    func epochs(serial: String, session: UUID) throws -> [WriteJournalEpoch] {
        let names = try Self.listNames(directory).filter { $0.hasPrefix(serial + "-") && $0.hasSuffix(".epoch") }.sorted()
        var result: [WriteJournalEpoch] = []
        var empty: [String] = []
        for name in names {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw WriteJournalError.unavailable }
            defer { Darwin.close(fd) }
            if let epoch = try parse(Self.readAll(fd, limit: 2 * 1024 * 1024 * 1024), name: name, session: session) {
                result.append(epoch)
            } else {
                empty.append(name)
            }
        }
        // A refusal keeps the entire record set. Only clean up incomplete
        // headers once every epoch has been authenticated and understood.
        for name in empty {
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT,
                  fcntl(directory, F_FULLFSYNC) == 0 else { throw WriteJournalError.unavailable }
        }
        return result
    }

    /// Nil when not even the header frame is complete.
    private func parse(_ data: Data, name: String, session: UUID) throws -> WriteJournalEpoch? {
        var at = 0, previous = Data(count: 32)
        var header: WriteJournalEpoch.Header?
        var groups: [WriteJournalEpoch.Group] = []
        var checkpointed = false
        var unsupported = false
        while at < data.count {
            guard data.count - at >= 5 else { break }  // torn tail
            let length = Int(data.readInteger(UInt32.self, at: at + 1))
            let end = at + 5 + length + 32
            guard end <= data.count else { break }     // torn tail
            let frame = data.subdata(in: at..<at + 5 + length)
            let mac = data.subdata(in: at + 5 + length..<end)
            guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: previous + frame, using: key),
                  !checkpointed else {
                // A complete but invalid frame, or data after a checkpoint.
                throw WriteJournalError.corrupt
            }
            guard let type = FrameType(rawValue: frame[frame.startIndex]) else {
                // Keep authenticating the rest: a bad MAC or known structural
                // error must not be mistaken for a newer journal format.
                unsupported = true; previous = mac; at = end
                continue
            }
            let payload = frame.subdata(in: 5..<frame.count)
            switch type {
            case .header:
                guard at == 0, header == nil else { throw WriteJournalError.corrupt }
                let decoded: WriteJournalEpoch.Header
                do { decoded = try JSONDecoder().decode(WriteJournalEpoch.Header.self, from: payload) }
                catch { throw WriteJournalError.corrupt }
                guard decoded.session == session else { throw WriteJournalError.corrupt }
                header = decoded
            case .group, .sectorGroup:
                guard header != nil else { throw WriteJournalError.corrupt }
                groups.append(try Self.decodeGroup(payload, sectors: type == .sectorGroup))
            case .checkpoint:
                guard let header, payload.count == 8, payload.readInteger(UInt64.self, at: 0) == header.epoch else {
                    throw WriteJournalError.corrupt
                }
                checkpointed = true
            }
            previous = mac; at = end
        }
        // Frames are parsed in order and the first must be the header.
        if at == 0 { return nil }
        guard let header, name == epochName(serial: String(name.prefix { $0 != "-" }), epoch: header.epoch) else {
            throw WriteJournalError.corrupt
        }
        guard !unsupported else { throw WriteJournalError.unsupportedFormat }
        return .init(header: header, groups: groups, checkpointed: checkpointed, name: name)
    }

    private static func decodeGroup(_ payload: Data, sectors: Bool) throws -> WriteJournalEpoch.Group {
        var at = 0
        func need(_ count: Int) throws { guard count >= 0, payload.count - at >= count else { throw WriteJournalError.corrupt } }
        try need(4); let befores = Int(payload.readInteger(UInt32.self, at: at)); at += 4
        var group = WriteJournalEpoch.Group(before: [], after: [])
        for _ in 0..<befores {
            try need(12)
            let offset = payload.readInteger(Int64.self, at: at), count = Int(payload.readInteger(UInt32.self, at: at + 8)); at += 12
            try need(count); group.before.append((offset, payload.subdata(in: at..<at + count))); at += count
        }
        try need(4); let afters = Int(payload.readInteger(UInt32.self, at: at)); at += 4
        for _ in 0..<afters {
            try need(40)
            let offset = payload.readInteger(Int64.self, at: at)
            group.after.append((offset, payload.subdata(in: at + 8..<at + 40))); at += 40
            guard sectors else { continue }
            try need(4); let count = Int(payload.readInteger(UInt32.self, at: at)); at += 4
            try need(count * 8)
            group.afterSectors[offset] = (0..<count).map { payload.readInteger(UInt64.self, at: at + $0 * 8) }; at += count * 8
        }
        guard at == payload.count else { throw WriteJournalError.corrupt }
        return group
    }

    // MARK: file helpers

    private static func listNames(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw WriteJournalError.unavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= limit else { throw WriteJournalError.corrupt }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw WriteJournalError.unavailable }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var at = 0
            while at < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: at), buffer.count - at)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WriteJournalError.unavailable }
                at += count
            }
        }
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func readInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[startIndex + offset + index]) }
        return value
    }
}
