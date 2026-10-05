// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

struct ReplacementFingerprint: Codable, Equatable, Sendable {
    let size: UInt64
    let sha256: String
    static func of(_ data: Data) -> Self { Self(size: UInt64(data.count), sha256: ReplacementJournal.hash(data)) }
    /// The caller holds the volume's operation lock for a stable length and
    /// file reference. Never allocate in proportion to an untrusted file size.
    static func read(size: UInt64, reader: (UInt64, UnsafeMutableRawBufferPointer) throws -> Int) throws -> Self {
        guard size <= UInt64(Int64.max) else { throw POSIXError(.EFBIG) }
        var hash = SHA256()
        if size > 0 {
            let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(min(size, 256 * 1024)), alignment: 16)
            defer { storage.deallocate() }
            var offset: UInt64 = 0
            while offset < size {
                let requested = Int(min(UInt64(storage.count), size - offset))
                let buffer = UnsafeMutableRawBufferPointer(rebasing: storage[..<requested])
                let count = try reader(offset, buffer)
                guard count > 0, count <= requested else { throw POSIXError(.EIO) }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                offset += UInt64(count)
            }
        }
        return Self(size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

struct ReplacementBinding: Codable, Equatable, Sendable {
    let serial: String
    let bootHash: String
    let directory: String
    let source: String
    let target: String
    let backup: String
    let oldReference: UInt64
    let newReference: UInt64
    /// Missing in older records means the source was in the target directory.
    var sourceDirectory: String? = nil
    var sourceParent: String { sourceDirectory ?? directory }
    var sourcePath: String { sourceParent == "/" ? "/" + source : sourceParent + "/" + source }
    var targetPath: String { directory == "/" ? "/" + target : directory + "/" + target }
    var backupPath: String { directory == "/" ? "/" + backup : directory + "/" + backup }
}

enum ReplacementRole: String, Codable, Sendable { case old, new }

struct ReplacementProof: Equatable, Sendable {
    let oldReference: UInt64
    let newReference: UInt64
    let old: ReplacementFingerprint
    let new: ReplacementFingerprint
    let sourceAbsent: Bool
}

struct ReplacementJournalView: Codable, Sendable {
    var phase: String
    var pendingRole: ReplacementRole?
    var reclaimed: Bool
    var before: ReplacementFingerprint
    var after: ReplacementFingerprint
    let binding: ReplacementBinding
}

struct ReplacementJournalInspection: Encodable, Sendable {
    let valid: Bool
    let records: Int
    let state: ReplacementJournalView?
    let problem: String?
    /// Nil means even the first complete record could not establish ownership.
    var belongsToVolume: Bool? = nil
    var blocksWriting: Bool { belongsToVolume != false && (!valid || state?.phase != "cleaned") }
    // A persisted reclaim event is never permission to delete after restart.
    let cleanupAuthorized: Bool = false
}

/// Serialized, host-side recovery metadata. Not the NTFS $LogFile and not an
/// atomic rename implementation. No existing journal can become a live writer.
final class ReplacementJournal {
    private struct Event: Codable {
        let kind: String
        var role: ReplacementRole? = nil
        var fingerprint: ReplacementFingerprint? = nil
        var binding: ReplacementBinding? = nil
        var before: ReplacementFingerprint? = nil
        var after: ReplacementFingerprint? = nil
    }
    private struct Envelope: Codable {
        let version: Int
        let sequence: Int
        let previous: String
        let payload: Data
        let digest: String
    }
    enum JournalError: Error { case invalid(String), system(Int32) }
    private(set) var state: ReplacementJournalView
    private(set) var failed = false
    let url: URL
    private var fd: Int32 = -1
    private var count = 0
    private var checkpointSequence = 0
    #if VOLISLE_JOURNAL_TESTING
    var storageBoundary: ((String) throws -> Void)?
    #endif
    private func boundary(_ name: String) throws {
        #if VOLISLE_JOURNAL_TESTING
        try storageBoundary?(name)
        #endif
    }
    private var previous = String(repeating: "0", count: 64)
    private let failClosed: () -> Void

    init(at url: URL, binding: ReplacementBinding, before: ReplacementFingerprint,
         after: ReplacementFingerprint, failClosed: @escaping () -> Void) throws {
        self.url = url
        self.failClosed = failClosed
        self.state = ReplacementJournalView(phase: "prepared", reclaimed: false,
                                           before: before, after: after, binding: binding)
        try Self.validate(binding)
        try Self.validate(before); try Self.validate(after)
        try Self.validateURL(url)
        guard mkdir(url.path, 0o700) == 0 else { throw JournalError.system(errno) }
        do {
            fd = try Self.openDirectory(url, exclusive: true)
            let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw JournalError.system(errno) }
            defer { Darwin.close(parent) }
            guard fsync(parent) == 0 else { throw JournalError.system(errno) }
            try append(Event(kind: "prepared", binding: binding, before: before, after: after))
        } catch { close(); throw error }
    }
    deinit { close() }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The callback must perform the NTFS operation AND its durable sync.
    func publish(_ operation: () throws -> Void) throws {
        try append(Event(kind: "replace-intent"))
        do { try operation(); try append(Event(kind: "published")) }
        catch { poison(); throw error }
    }
    /// Record the intent before a file changes; acknowledge its new fingerprint
    /// only after mutation+sync+readback. Pending writes never authorize cleanup.
    func write(_ role: ReplacementRole, operation: () throws -> ReplacementFingerprint) throws {
        try append(Event(kind: "write-intent", role: role))
        do {
            let fingerprint = try operation()
            try append(Event(kind: "write-complete", role: role, fingerprint: fingerprint))
        } catch { poison(); throw error }
    }
    /// Only the owning session's final object-reclaim callback may call this.
    /// A close(fd) notification is not sufficient; no resume API replays it.
    func oldItemReclaimed() throws { try append(Event(kind: "reclaimed")) }

    func cleanup(verify: () throws -> ReplacementProof, removeAndSync: () throws -> Void) throws {
        guard !failed, fd >= 0, state.phase == "published", state.reclaimed else {
            throw JournalError.invalid("旧对象尚未最终回收，或会话不可清理")
        }
        let expected = ReplacementProof(oldReference: state.binding.oldReference,
            newReference: state.binding.newReference, old: state.before, new: state.after, sourceAbsent: true)
        guard try verify() == expected else { throw JournalError.invalid("清理前身份或内容不匹配") }
        try append(Event(kind: "cleanup-intent"))
        do {
            guard try verify() == expected else { throw JournalError.invalid("记录意图后身份发生变化") }
            try removeAndSync()
            try append(Event(kind: "cleaned"))
        } catch { poison(); throw error }
    }

    func close() {
        if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
    }
    private func poison() {
        if !failed { failed = true; failClosed() }
    }

    private func append(_ event: Event) throws {
        guard !failed, fd >= 0, count < Int.max else { throw JournalError.invalid("恢复记录会话已关闭或编号溢出") }
        // Invalid caller transitions have no side effect and do not poison a
        // healthy volume. Persistence/mutation failures do poison it.
        let next = try Self.advance(count == 0 ? nil : state, event)
        // Compact only a stable state, before recording the next mutation's
        // intent. A checkpoint cannot recreate a live cleanup capability.
        if count - checkpointSequence >= 128 && state.phase == "published" {
            do { try checkpoint() } catch { poison(); throw error }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(event)
        let sequence = count + 1
        let digest = Self.frameHash(sequence: sequence, previous: previous, payload: payload)
        let data = try encoder.encode(Envelope(version: 1, sequence: sequence,
                                              previous: previous, payload: payload, digest: digest))
        guard data.count <= 65536 else { throw JournalError.invalid("恢复记录过大") }
        do {
            try Self.persist(data, at: Self.eventName(sequence), directory: fd)
            guard fsync(fd) == 0 else { throw JournalError.system(errno) }
        } catch { poison(); throw error }
        state = next; count = sequence; previous = digest
    }

    private static func eventName(_ sequence: Int) -> String {
        String(format: "%06lld.json", Int64(sequence))
    }
    private static func eventSequence(_ name: String) -> Int? {
        guard name.hasSuffix(".json"), let n = Int(name.dropLast(5)), n > 0,
              name == eventName(n) else { return nil }
        return n
    }
    private static func persist(_ data: Data, at name: String, directory: Int32,
                                boundary: (String) throws -> Void = { _ in }) throws {
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw JournalError.system(errno) }
        defer { Darwin.close(file) }
        try boundary("created")
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = Darwin.write(file, bytes.baseAddress!.advanced(by: done), bytes.count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw JournalError.system(n < 0 ? errno : EIO) }
                done += n
            }
        }
        try boundary("written")
        guard fsync(file) == 0 else { throw JournalError.system(errno) }
        try boundary("synced")
    }
    private func checkpoint() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(state)
        let digest = Self.frameHash(sequence: count, previous: previous, payload: payload)
        let data = try encoder.encode(Envelope(version: 2, sequence: count, previous: previous,
                                               payload: payload, digest: digest))
        guard data.count <= 65536 else { throw JournalError.invalid("检查点过大") }
        try Self.persist(data, at: "checkpoint.pending", directory: fd) { try self.boundary("checkpoint-" + $0) }
        guard renameat(fd, "checkpoint.pending", fd, "checkpoint.json") == 0 else { throw JournalError.system(errno) }
        try boundary("checkpoint-renamed")
        // Only after BOTH the checkpoint file and its directory entry are
        // durable may any covered events be retired. Interrupted pruning is
        // harmless: the checkpoint supersedes all events through its sequence.
        guard fsync(fd) == 0 else { throw JournalError.system(errno) }
        try boundary("checkpoint-committed")
        for n in (checkpointSequence + 1)...count {
            guard unlinkat(fd, Self.eventName(n), 0) == 0 else { throw JournalError.system(errno) }
            try boundary("checkpoint-pruned-\(n - checkpointSequence)")
        }
        guard fsync(fd) == 0 else { throw JournalError.system(errno) }
        try boundary("checkpoint-prune-committed")
        checkpointSequence = count; previous = digest
    }
    private static func validateCheckpoint(_ s: ReplacementJournalView) throws {
        try validate(s.binding); try validate(s.before); try validate(s.after)
        guard s.phase == "published", s.pendingRole == nil else { throw JournalError.invalid("检查点不是稳定发布状态") }
    }
    private static func readRecord(_ name: String, directory: Int32) throws -> Data {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw JournalError.system(errno) }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65536 else { throw JournalError.invalid("恢复记录文件无效") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = Darwin.read(file, buffer.baseAddress!.advanced(by: done), buffer.count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw JournalError.invalid("恢复记录未完整读回") }
                done += n
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(file, &extra, 1) == 0 else { throw JournalError.invalid("恢复记录并发变化") }
        return Data(bytes)
    }

    private static func frameHash(sequence: Int, previous: String, payload: Data) -> String {
        hash(Data("\(sequence)|\(previous)|".utf8) + payload)
    }
    private static func hex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validate(_ fingerprint: ReplacementFingerprint) throws {
        guard fingerprint.size <= UInt64(Int64.max), hex(fingerprint.sha256, count: 64) else {
            throw JournalError.invalid("文件指纹无效或超出有符号偏移范围")
        }
    }
    private static func validate(_ b: ReplacementBinding) throws {
        guard hex(b.serial, count: 16), b.serial != String(repeating: "0", count: 16), hex(b.bootHash, count: 64),
              b.oldReference >> 48 != 0, b.newReference >> 48 != 0, b.oldReference != b.newReference,
              [b.directory, b.sourceParent].allSatisfy({ directory in
                  directory.hasPrefix("/") && !directory.contains("\0") &&
                  (directory == "/" || directory.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }))
              }) else {
            throw JournalError.invalid("卷或文件身份无效")
        }
        let names = [b.source, b.target, b.backup]
        let paths = [b.sourcePath, b.targetPath, b.backupPath]
        guard Set(paths.map { $0.lowercased() }).count == 3, names.allSatisfy({ name in
            !name.isEmpty && name != "." && name != ".." && !name.hasPrefix("$") &&
            name.utf16.count <= 255 && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil &&
            max(b.directory.utf8.count, b.sourceParent.utf8.count) + name.utf8.count + 1 < 4096
        }) else { throw JournalError.invalid("恢复名称无效") }
    }
    private static func advance(_ previous: ReplacementJournalView?, _ e: Event) throws -> ReplacementJournalView {
        if e.kind == "prepared" {
            guard previous == nil, e.role == nil, e.fingerprint == nil,
                  let binding = e.binding, let before = e.before, let after = e.after else {
                throw JournalError.invalid("无效起始记录")
            }
            try validate(binding); try validate(before); try validate(after)
            return ReplacementJournalView(phase: "prepared", reclaimed: false, before: before, after: after, binding: binding)
        }
        guard var s = previous, e.binding == nil, e.before == nil, e.after == nil else {
            throw JournalError.invalid("恢复记录缺少起始身份或重复携带身份")
        }
        switch e.kind {
        case "replace-intent" where s.phase == "prepared" && e.role == nil && e.fingerprint == nil:
            s.phase = "replacing"
        case "published" where s.phase == "replacing" && e.role == nil && e.fingerprint == nil:
            s.phase = "published"
        case "write-intent" where s.phase == "published" && e.role != nil && e.fingerprint == nil:
            guard e.role != .old || !s.reclaimed else { throw JournalError.invalid("已回收旧对象不能写入") }
            s.phase = "writing"; s.pendingRole = e.role
        case "write-complete" where s.phase == "writing" && e.role == s.pendingRole && e.fingerprint != nil:
            try validate(e.fingerprint!)
            if e.role == .old { s.before = e.fingerprint! } else { s.after = e.fingerprint! }
            s.phase = "published"; s.pendingRole = nil
        case "reclaimed" where s.phase == "published" && !s.reclaimed && e.role == nil && e.fingerprint == nil:
            s.reclaimed = true
        case "cleanup-intent" where s.phase == "published" && s.reclaimed && e.role == nil && e.fingerprint == nil:
            s.phase = "cleaning"
        case "cleaned" where s.phase == "cleaning" && e.role == nil && e.fingerprint == nil:
            s.phase = "cleaned"
        default: throw JournalError.invalid("恢复状态转移不合法")
        }
        return s
    }
    private static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw JournalError.invalid("恢复目录不能经过软链接")
        }
    }
    private static func openDirectory(_ url: URL, exclusive: Bool) throws -> Int32 {
        try validateURL(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw JournalError.system(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(fd); throw JournalError.invalid("恢复目录权限不符合要求")
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(fd); throw JournalError.system(code)
        }
        return fd
    }
    struct StoreAudit {
        let completed: Int
        let unresolved: Int
        let blocksWriting: Bool
    }
    #if VOLISLE_JOURNAL_TESTING
    nonisolated(unsafe) static var storeStorageBoundary: ((String) throws -> Void)?
    #endif
    private static func storeBoundary(_ name: String) throws {
        #if VOLISLE_JOURNAL_TESTING
        try storeStorageBoundary?(name)
        #endif
    }
    private static func withStore<T>(_ url: URL, _ body: (Int32, URL, Int32, URL, Int32) throws -> T) throws -> T {
        let root = try openDirectory(url, exclusive: true)
        defer { Darwin.close(root) }
        let completedURL = url.appendingPathComponent(".completed", isDirectory: true)
        let retiringURL = url.appendingPathComponent(".retiring", isDirectory: true)
        for name in [".completed", ".retiring"] {
            if mkdirat(root, name, 0o700) != 0 && errno != EEXIST { throw JournalError.system(errno) }
        }
        let completed = try openDirectory(completedURL, exclusive: true)
        defer { Darwin.close(completed) }
        let retiring = try openDirectory(retiringURL, exclusive: true)
        defer { Darwin.close(retiring) }
        guard fsync(root) == 0 else { throw JournalError.system(errno) }
        // Only already-retired host metadata is removed here. No callback or
        // path in this store API can issue an NTFS operation.
        for entry in try FileManager.default.contentsOfDirectory(atPath: retiringURL.path) {
            try removeRetired(entry, at: retiringURL, parent: retiring)
        }
        return try body(root, completedURL, completed, retiringURL, retiring)
    }
    private static func checkName(_ name: String) throws {
        guard UUID(uuidString: name)?.uuidString == name else { throw JournalError.invalid("恢复目录名称不是事务标识") }
    }
    private static func sameDirectory(_ fd: Int32, parent: Int32, name: String) throws {
        var held = stat(), linked = stat()
        guard fstat(fd, &held) == 0, fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == linked.st_dev, held.st_ino == linked.st_ino else { throw JournalError.invalid("恢复目录身份变化") }
    }
    private static func archive(_ name: String, at rootURL: URL, root: Int32, completed: Int32) throws -> ReplacementJournalInspection {
        try checkName(name)
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        let fd = try openDirectory(url, exclusive: true)
        defer { Darwin.close(fd) }
        let result = inspectContents(at: url, fd: fd)
        if result.valid && result.state?.phase == "cleaned" {
            try sameDirectory(fd, parent: root, name: name)
            guard renameatx_np(root, name, completed, name, UInt32(RENAME_EXCL)) == 0 else { throw JournalError.system(errno) }
            try storeBoundary("archive-renamed")
            guard fsync(completed) == 0, fsync(root) == 0 else { throw JournalError.system(errno) }
            try storeBoundary("archive-committed")
        }
        return result
    }
    private static func removeRetired(_ name: String, at url: URL, parent: Int32) throws {
        try checkName(name)
        let path = url.appendingPathComponent(name, isDirectory: true)
        let fd = try openDirectory(path, exclusive: true)
        defer { Darwin.close(fd) }
        let names = try FileManager.default.contentsOfDirectory(atPath: path.path).sorted()
        // A retirement move is durably committed before pruning starts. A
        // partial deletion can therefore be resumed, even after the prepared
        // event is gone. Reject all unknown paths and non-private objects.
        for entry in names {
            guard eventSequence(entry) != nil || entry == "checkpoint.json" else { throw JournalError.invalid("归档中出现未知文件") }
            _ = try readRecord(entry, directory: fd)
        }
        for (index, entry) in names.enumerated() {
            guard unlinkat(fd, entry, 0) == 0 else { throw JournalError.system(errno) }
            try storeBoundary("retired-pruned-\(index + 1)")
        }
        guard fsync(fd) == 0 else { throw JournalError.system(errno) }
        try sameDirectory(fd, parent: parent, name: name)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw JournalError.system(errno) }
        try storeBoundary("retired-removed")
    }
    private static func pruneArchive(at url: URL, fd: Int32, retiringURL: URL, retiring: Int32) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        // Modification time comes from the completed journal, not a volume
        // filename or clock value supplied by a mounted filesystem.
        let ordered = try names.map { name -> (String, timespec) in
            try checkName(name)
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { throw JournalError.invalid("归档对象无效") }
            return (name, info.st_mtimespec)
        }.sorted { a, b in
            if a.1.tv_sec != b.1.tv_sec { return a.1.tv_sec < b.1.tv_sec }
            if a.1.tv_nsec != b.1.tv_nsec { return a.1.tv_nsec < b.1.tv_nsec }
            return a.0 < b.0
        }
        for (name, _) in ordered.prefix(max(0, ordered.count - 64)) {
            let path = url.appendingPathComponent(name, isDirectory: true)
            let journal = try openDirectory(path, exclusive: true)
            defer { Darwin.close(journal) }
            let result = inspectContents(at: path, fd: journal)
            guard result.valid, result.state?.phase == "cleaned" else { throw JournalError.invalid("未完成或损坏的记录不能淘汰") }
            try sameDirectory(journal, parent: fd, name: name)
            guard renameatx_np(fd, name, retiring, name, UInt32(RENAME_EXCL)) == 0 else { throw JournalError.system(errno) }
            try storeBoundary("retired-renamed")
            guard fsync(retiring) == 0, fsync(fd) == 0 else { throw JournalError.system(errno) }
            try storeBoundary("retired-committed")
            // Release the journal lock before the deletion helper acquires it.
            _ = flock(journal, LOCK_UN)
            try removeRetired(name, at: retiringURL, parent: retiring)
        }
    }
    /// Archive only a fully validated cleaned transaction, while retaining
    /// the newest 64 completed journals across volumes. Unfinished evidence is
    /// never expired. The original writer must close before calling this.
    static func retireCompleted(at journalURL: URL) throws {
        let store = journalURL.deletingLastPathComponent()
        try withStore(store) { root, completedURL, completed, retiringURL, retiring in
            let result = try archive(journalURL.lastPathComponent, at: store, root: root, completed: completed)
            guard result.valid, result.state?.phase == "cleaned" else { throw JournalError.invalid("记录尚未完成") }
            try pruneArchive(at: completedURL, fd: completed, retiringURL: retiringURL, retiring: retiring)
        }
    }
    /// Startup migration also handles legacy completed directories. The limit
    /// applies to unresolved records only, never the lifetime save count.
    static func auditStore(at store: URL, serial: String, bootHash: String) throws -> StoreAudit {
        try withStore(store) { root, completedURL, completedFD, retiringURL, retiring in
            var unresolved = 0, blocked = false, active = 0
            let names = try FileManager.default.contentsOfDirectory(atPath: store.path)
            for name in names where name != ".completed" && name != ".retiring" {
                let result = try archive(name, at: store, root: root, completed: completedFD)
                if result.valid && result.state?.phase == "cleaned" { continue }
                active += 1
                let matches = result.state.map { $0.binding.serial == serial && $0.binding.bootHash == bootHash }
                if matches != false { blocked = true; unresolved += 1 }
            }
            var completed = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: completedURL.path) {
                try checkName(name)
                let result = try inspect(at: completedURL.appendingPathComponent(name), serial: serial, bootHash: bootHash)
                if result.valid && result.state?.phase == "cleaned" { completed += 1 }
                else if result.blocksWriting { blocked = true; unresolved += 1 }
            }
            try pruneArchive(at: completedURL, fd: completedFD, retiringURL: retiringURL, retiring: retiring)
            return StoreAudit(completed: completed, unresolved: unresolved, blocksWriting: blocked || active > 256)
        }
    }

    static func inspect(at url: URL, serial: String? = nil, bootHash: String? = nil) throws -> ReplacementJournalInspection {
        let fd = try openDirectory(url, exclusive: false)
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        return inspectContents(at: url, fd: fd, serial: serial, bootHash: bootHash)
    }
    private static func inspectContents(at url: URL, fd: Int32, serial: String? = nil,
                                        bootHash: String? = nil) -> ReplacementJournalInspection {
        var state: ReplacementJournalView?
        var belongsToVolume: Bool?
        var count = 0, previous = String(repeating: "0", count: 64)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            guard !names.isEmpty, names.count <= 512 else { throw JournalError.invalid("恢复记录为空或过多") }
            var covered = 0
            if names.contains("checkpoint.json") {
                let record = try JSONDecoder().decode(Envelope.self, from: readRecord("checkpoint.json", directory: fd))
                guard record.version == 2, record.sequence > 0, record.sequence < Int.max,
                      hex(record.previous, count: 64), record.digest == frameHash(sequence: record.sequence,
                        previous: record.previous, payload: record.payload) else { throw JournalError.invalid("检查点校验失败") }
                let snapshot = try JSONDecoder().decode(ReplacementJournalView.self, from: record.payload)
                try validateCheckpoint(snapshot)
                belongsToVolume = (serial == nil || snapshot.binding.serial == serial) && (bootHash == nil || snapshot.binding.bootHash == bootHash)
                guard belongsToVolume == true else { throw JournalError.invalid("恢复记录属于其他卷") }
                state = snapshot; count = record.sequence; covered = count; previous = record.digest
            }
            let unknown = names.contains { $0 != "checkpoint.json" && eventSequence($0) == nil }
            let events = names.compactMap { name -> (Int, String)? in
                guard let n = eventSequence(name) else { return nil }
                return (n, name)
            }.sorted { $0.0 < $1.0 }
            for (sequence, name) in events {
                // Validate leftover objects, but their old payload is no longer
                // authoritative once the durable checkpoint supersedes it.
                let data = try readRecord(name, directory: fd)
                if sequence <= covered { continue }
                guard count < Int.max, sequence == count + 1 else { throw JournalError.invalid("恢复记录编号缺失") }
                let record = try JSONDecoder().decode(Envelope.self, from: data)
                guard record.version == 1, record.sequence == count + 1, record.previous == previous,
                      record.digest == frameHash(sequence: record.sequence, previous: previous, payload: record.payload) else {
                    throw JournalError.invalid("恢复记录校验链不完整")
                }
                let next = try advance(state, JSONDecoder().decode(Event.self, from: record.payload))
                if count == 0 { belongsToVolume = (serial == nil || next.binding.serial == serial) && (bootHash == nil || next.binding.bootHash == bootHash) }
                guard belongsToVolume == true else {
                    throw JournalError.invalid("恢复记录属于其他卷")
                }
                state = next
                previous = record.digest; count += 1
            }
            if unknown { throw JournalError.invalid("恢复记录出现未知或未提交文件") }
            return ReplacementJournalInspection(valid: true, records: count, state: state, problem: nil, belongsToVolume: belongsToVolume)
        } catch {
            // The valid prefix is diagnostic only. Even a valid full replay
            // never carries a live-session cleanup capability.
            return ReplacementJournalInspection(valid: false, records: count, state: state,
                                                 problem: String(describing: error), belongsToVolume: belongsToVolume)
        }
    }
}
