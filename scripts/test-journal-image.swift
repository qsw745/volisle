import Foundation
import Darwin

private final class ImageDevice {
    let fd: Int32
    var writes = 0
    var failWriteAt: Int?
    var crashWriteAt: Int?
    init(_ url: URL, readonly: Bool = false) throws {
        let parent = url.deletingLastPathComponent().deletingLastPathComponent()
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".workbench").standardizedFileURL
        guard parent.lastPathComponent.hasPrefix("volisle-journal-"),
              parent.deletingLastPathComponent().standardizedFileURL == work,
              url.path == url.resolvingSymlinksInPath().path else { throw POSIXError(.EPERM) }
        fd = Darwin.open(url.path, (readonly ? O_RDONLY : O_RDWR) | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == 64 * 1024 * 1024 else { Darwin.close(fd); throw POSIXError(.EPERM) }
    }
    deinit { Darwin.close(fd) }
    func descriptor() -> nk_io {
        var result = nk_io()
        result.ctx = Unmanaged.passUnretained(self).toOpaque()
        result.size = 64 * 1024 * 1024
        result.readonly = 0
        result.pread = { context, buffer, count, offset in
            let io = Unmanaged<ImageDevice>.fromOpaque(context!).takeUnretainedValue()
            return Int64(Darwin.pread(io.fd, buffer, Int(count), off_t(offset)))
        }
        result.pwrite = { context, buffer, count, offset in
            let io = Unmanaged<ImageDevice>.fromOpaque(context!).takeUnretainedValue()
            io.writes += 1
            if io.writes == io.failWriteAt { return -1 }
            let written = Darwin.pwrite(io.fd, buffer, Int(count), off_t(offset))
            if io.writes == io.crashWriteAt { precondition(fsync(io.fd) == 0); _exit(86) }
            return Int64(written)
        }
        result.sync = { context in fsync(Unmanaged<ImageDevice>.fromOpaque(context!).takeUnretainedValue().fd) }
        return result
    }
}

@main struct JournalImageTest {
    static func main() throws {
        let requestedMode = CommandLine.arguments[1]
        let crossDirectory = requestedMode == "cross-published"
        let mode = crossDirectory ? "published" : requestedMode
        let checkpointFault = mode.hasPrefix("checkpoint-crash-") || mode.hasPrefix("checkpoint-failure-")
        let cleanupFault = mode.range(of: #"^cleanup-write-(failure|crash)-([1-9][0-9]{0,2})$"#, options: .regularExpression) != nil
        guard Set(["normal", "inspect", "identity-mismatch", "identity-after-intent", "intent-failure", "completion-failure",
                   "cleanup-completion-failure", "prepared", "replace-intent", "replace-data", "published", "old-intent",
                   "old-data", "old-complete", "new-intent", "new-data", "new-complete", "reclaimed", "cleanup-intent",
                   "cleanup-deleted", "cleaned", "sustained"]).contains(mode) || cleanupFault || checkpointFault else { throw POSIXError(.EINVAL) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        let image = folder.appendingPathComponent("fixture.img")
        let io = try ImageDevice(image, readonly: mode == "inspect")
        var bytes = [UInt8](repeating: 0, count: 512)
        guard Darwin.pread(io.fd, &bytes, 512, 0) == 512 else { throw POSIXError(.EIO) }
        let boot = Data(bytes)
        let serial = boot[72..<80].map { String(format: "%02x", $0) }.joined()
        let bootHash = ReplacementJournal.hash(Data(boot))
        if mode == "inspect" {
            let result = try ReplacementJournal.inspect(at: folder.appendingPathComponent("journal"), serial: serial, bootHash: bootHash)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); return
        }
        var descriptor = io.descriptor()
        guard let volume = nk_mount_io(&descriptor, nil, 0) else { throw POSIXError(.EIO) }
        func require(_ rc: Int32) throws { guard rc == 0 else { throw POSIXError(.EIO) } }
        func reference(_ path: String) throws -> UInt64 {
            var ref: UInt64 = 0; try require(path.withCString { nk_reference_path(volume, $0, &ref) }); return ref
        }
        func fingerprint(_ ref: UInt64) throws -> ReplacementFingerprint {
            var stat = nk_stat(); try require(nk_stat_reference(volume, ref, &stat))
            guard stat.size >= 0 else { throw POSIXError(.EFBIG) }
            return try ReplacementFingerprint.read(size: UInt64(stat.size)) { offset, buffer in
                let count = nk_read_reference(volume, ref, Int64(offset), Int64(buffer.count), buffer.baseAddress)
                guard count >= 0 else { throw POSIXError(.EIO) }
                return Int(count)
            }
        }
        func checkpoint(_ name: String) {
            if mode == name { precondition(fsync(io.fd) == 0); _exit(86) }
        }
        func occupy(_ number: Int) throws {
            let path = folder.appendingPathComponent("journal").appendingPathComponent(String(format: "%06d.json", number)).path
            let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else { throw POSIXError(.EIO) }; Darwin.close(fd)
        }
        let old = try reference(crossDirectory ? "/saved/document" : "/document")
        let new = try reference(crossDirectory ? "/incoming/document" : "/draft")
        let binding = ReplacementBinding(serial: serial, bootHash: bootHash, directory: crossDirectory ? "/saved" : "/",
            source: crossDirectory ? "document" : "draft", target: "document", backup: ".old",
            oldReference: old, newReference: new, sourceDirectory: crossDirectory ? "/incoming" : nil)
        let journal = try ReplacementJournal(at: folder.appendingPathComponent("journal"), binding: binding,
            before: fingerprint(old), after: fingerprint(new), failClosed: { nk_abort_write_session(volume) })
        checkpoint("prepared")
        var cleanupWrites = 0
        do {
            if mode == "intent-failure" { try occupy(2) }
            try journal.publish {
                checkpoint("replace-intent")
                try require(nk_replace_between(volume, binding.sourceParent, binding.source, binding.directory, binding.target, binding.backup))
                try require(nk_sync(volume)); checkpoint("replace-data")
            }
            checkpoint("published")
            for role in [ReplacementRole.old, .new] {
                let ref = role == .old ? old : new
                try journal.write(role) {
                    checkpoint("\(role.rawValue)-intent")
                    let data = Data((role == .old ? "OLD-edited!" : "NEW-edited!").utf8)
                    let n = data.withUnsafeBytes { nk_write_reference(volume, ref, 0, Int64(data.count), $0.baseAddress) }
                    guard n == data.count else { throw POSIXError(.EIO) }
                    try require(nk_sync(volume)); checkpoint("\(role.rawValue)-data")
                    if mode == "completion-failure" && role == .old { try occupy(5) }
                    return try fingerprint(ref)
                }
                checkpoint("\(role.rawValue)-complete")
            }
            if mode == "sustained" || checkpointFault {
                #if VOLISLE_JOURNAL_TESTING
                journal.storageBoundary = { point in
                    let expected = mode.replacingOccurrences(of: "checkpoint-crash-", with: "checkpoint-")
                        .replacingOccurrences(of: "checkpoint-failure-", with: "checkpoint-")
                    if point == expected {
                        if mode.hasPrefix("checkpoint-failure-") { throw POSIXError(.EIO) }
                        precondition(fsync(io.fd) == 0); _exit(86)
                    }
                }
                #endif
                for n in 0..<320 {
                    try journal.write(.new) {
                        let data = Data(String(format: "repeat-%03d", n).utf8)
                        let written = data.withUnsafeBytes { nk_write_reference(volume, new, 0, Int64(data.count), $0.baseAddress) }
                        guard written == data.count else { throw POSIXError(.EIO) }
                        try require(nk_sync(volume))
                        return try fingerprint(new)
                    }
                }
            }
            try journal.oldItemReclaimed(); checkpoint("reclaimed")
            func changeBackupIdentity() throws {
                try require(nk_rename(volume, "/.old", "/", ".kept-old"))
                try require(nk_create(volume, "/", ".old"))
                let data = Data("unrelated-backup-name".utf8)
                let n = data.withUnsafeBytes { nk_write(volume, "/.old", 0, Int64(data.count), $0.baseAddress) }
                guard n == data.count else { throw POSIXError(.EIO) }; try require(nk_sync(volume))
            }
            if mode == "identity-mismatch" { try changeBackupIdentity() }
            var removed = false
            do {
                try journal.cleanup(verify: {
                    if journal.state.phase == "cleaning" {
                        checkpoint("cleanup-intent")
                        if mode == "identity-after-intent" { try changeBackupIdentity() }
                    }
                    var absent = nk_stat()
                    let rc = nk_stat_path(volume, "/draft", &absent)
                    guard rc == -1 && errno == ENOENT else { throw POSIXError(.ESTALE) }
                    let oldRef = try reference("/.old"), newRef = try reference("/document")
                    return ReplacementProof(oldReference: oldRef, newReference: newRef,
                        old: try fingerprint(oldRef), new: try fingerprint(newRef), sourceAbsent: true)
                }, removeAndSync: {
                    if cleanupFault {
                        let point = Int(mode.split(separator: "-").last!)!
                        precondition(point <= 128)
                        if mode.contains("-failure-") { io.failWriteAt = io.writes + point }
                        else { io.crashWriteAt = io.writes + point }
                    }
                    let startingWrites = io.writes
                    try require(nk_delete(volume, "/.old")); try require(nk_sync(volume)); removed = true
                    cleanupWrites = io.writes - startingWrites
                    checkpoint("cleanup-deleted")
                    if mode == "cleanup-completion-failure" { try occupy(10) }
                })
            } catch {
                if mode != "identity-mismatch" { throw error }
                precondition(!removed && !journal.failed && journal.state.phase == "published")
            }
            checkpoint("cleaned")
            try require(nk_umount(volume)); journal.close()
            print("{\"success\":true,\"cleanup_writes\":\(cleanupWrites)}")
        } catch {
            guard ["intent-failure", "completion-failure", "cleanup-completion-failure", "identity-after-intent"].contains(mode) || cleanupFault || mode.hasPrefix("checkpoint-failure-") else { throw error }
            precondition(journal.failed)
            let before = io.writes
            precondition(nk_create(volume, "/", "blocked") == -1 && io.writes == before)
            precondition(nk_umount(volume) == -1 && nk_inspect(&descriptor) == NK_CHECK_DIRTY)
            journal.close()
            print("{\"expected_failure\":true,\"dirty_retained\":true}")
        }
    }
}
