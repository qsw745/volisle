// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

public enum ReplacementRecoveryError: Error, Equatable, LocalizedError, Sendable {
    case invalidRecord, inaccessibleRecords, sourceNotReadOnly, differentVolume, invalidDestination, noMatchingVersions, changedSource
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: String(localized: "恢复记录不完整或已经变化，不能据此导出文件。")
        case .inaccessibleRecords: String(localized: "无法读取恢复记录，请检查应用的磁盘访问权限。")
        case .sourceNotReadOnly: String(localized: "请先将这块 NTFS 磁盘以只读方式挂载，再导出恢复文件。")
        case .differentVolume: String(localized: "这份记录属于另一块磁盘，未导出任何文件。")
        case .invalidDestination: String(localized: "请选择另一处可写文件夹；不能覆盖现有文件或写回源磁盘。")
        case .noMatchingVersions: String(localized: "没有找到通过内容校验的版本。原文件和恢复记录均已保留。")
        case .changedSource: String(localized: "导出期间磁盘或文件发生变化，本次导出未完成。")
        }
    }
}

public struct ReplacementRecoveryRecord: Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let phase: String
    public let canExport: Bool
    public let modified: Date
    let url: URL
    let inspection: ReplacementJournalInspection?
    public var status: String { canExport ? String(localized: "等待核对文件") : String(localized: "记录无法验证") }
    public var bootHash: String? { inspection?.state?.binding.bootHash }
}

public enum ReplacementRecoveryCatalog {
    /// Fixed, OS-owned container location. Callers cannot select an extension
    /// identity or a privileged path. The catalog never modifies any journal.
    public static var systemStore: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/top.qisw.volisle.filesystem/Data/Library/Application Support/VolisleReplacementJournals", isDirectory: true)
    }
    public static func scan() throws -> [ReplacementRecoveryRecord] { try scan(at: systemStore) }
    /// Explicit user-selected copy from a backup or another installation.
    /// Import means read-only inspection, never copying into the engine store
    /// or resolving/clearing its existing recovery barrier.
    public static func importRecord(at url: URL) throws -> ReplacementRecoveryRecord {
        guard UUID(uuidString: url.lastPathComponent)?.uuidString == url.lastPathComponent else { throw ReplacementRecoveryError.invalidRecord }
        let inspection = try ReplacementJournal.inspect(at: url)
        guard inspection.valid, let state = inspection.state, state.phase != "cleaned" else { throw ReplacementRecoveryError.invalidRecord }
        return .init(id: url.lastPathComponent, filename: state.binding.target, phase: state.phase, canExport: true,
            modified: .now, url: url, inspection: inspection)
    }

    static func scan(at store: URL) throws -> [ReplacementRecoveryRecord] {
        guard store.standardizedFileURL.path == store.resolvingSymlinksInPath().path else { throw ReplacementRecoveryError.inaccessibleRecords }
        let fd = Darwin.open(store.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw ReplacementRecoveryError.inaccessibleRecords }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw ReplacementRecoveryError.inaccessibleRecords }
        let names = try FileManager.default.contentsOfDirectory(atPath: store.path)
        guard names.count <= 4096 else { throw ReplacementRecoveryError.inaccessibleRecords }
        var records: [ReplacementRecoveryRecord] = []
        for name in names where name != ".completed" && name != ".retiring" {
            let url = store.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            let modified = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)) : .distantPast
            let safeName = UUID(uuidString: name)?.uuidString == name
            let result = safeName ? try? ReplacementJournal.inspect(at: url) : nil
            if result?.valid == true && result?.state?.phase == "cleaned" { continue }
            records.append(.init(id: name, filename: result?.state?.binding.target ?? String(localized: "无法识别的文件"),
                phase: result?.state?.phase ?? "unknown", canExport: result?.valid == true && result?.state != nil,
                modified: modified, url: url, inspection: result))
        }
        return records.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }
}

public struct ReplacementRecoveryVersion: Codable, Sendable {
    public let version: String
    public let status: String
    public let file: String?
    public let bytes: UInt64?
    public let sha256: String?
}
public struct ReplacementRecoveryResult: Sendable {
    public let directory: URL
    public let versions: [ReplacementRecoveryVersion]
    public var exportedCount: Int { versions.filter { $0.status == "verified" }.count }
}

/// No root operations and no source writes. A draft is only published after
/// the coordinator rechecks the original connection through the trusted helper.
final class ReplacementRecoveryDraft {
    private let parent: Int32
    private var fd: Int32
    private let parentURL: URL
    private let temporaryName: String
    private let finalName: String
    private let versions: [ReplacementRecoveryVersion]
    private var committed = false
    init(parent: Int32, fd: Int32, parentURL: URL, temporaryName: String, finalName: String,
         versions: [ReplacementRecoveryVersion]) {
        self.parent = parent; self.fd = fd; self.parentURL = parentURL
        self.temporaryName = temporaryName; self.finalName = finalName; self.versions = versions
    }
    deinit {
        if !committed { discard() }
        Darwin.close(fd); Darwin.close(parent)
    }
    func discard() {
        // Only these files were created by this exporter. Never recursively
        // remove contents introduced by another process or follow a link.
        for file in versions.compactMap(\.file) + ["恢复报告.json"] { _ = unlinkat(fd, file, 0) }
        _ = unlinkat(parent, temporaryName, AT_REMOVEDIR)
    }
    func commit() throws -> ReplacementRecoveryResult {
        try Task.checkCancellation()
        guard !committed else { throw ReplacementRecoveryError.invalidDestination }
        var held = stat(), linked = stat()
        guard fstat(fd, &held) == 0, fstatat(parent, temporaryName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == linked.st_dev, held.st_ino == linked.st_ino,
              fsync(fd) == 0 else { throw ReplacementRecoveryError.invalidDestination }
        guard renameatx_np(parent, temporaryName, parent, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw ReplacementRecoveryError.invalidDestination
        }
        // Once published, keep the user's verified files even if a directory
        // sync fails; never erase an already visible result on a later error.
        committed = true
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
        return .init(directory: parentURL.appendingPathComponent(finalName), versions: versions)
    }
}

enum ReplacementRecoveryExport {
    private struct Report: Encodable {
        let format = 1
        let record: String
        let originalFilename: String
        let phase: String
        let versions: [ReplacementRecoveryVersion]
        let scope = "仅导出符合记录长度和 SHA-256 的未命名数据流；不恢复权限、扩展属性或时间戳；不修复磁盘，不解除写入阻止。"
    }
    static func stage(record: ReplacementRecoveryRecord, source: URL, destination: URL,
                      checkSource: (Int32) throws -> Void) throws -> ReplacementRecoveryDraft {
        guard record.canExport, let original = record.inspection?.state else { throw ReplacementRecoveryError.invalidRecord }
        let current = try ReplacementJournal.inspect(at: record.url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard current.valid, let state = current.state, state.phase != "cleaned",
              try encoder.encode(state) == encoder.encode(original) else { throw ReplacementRecoveryError.invalidRecord }
        guard source.standardizedFileURL.path == source.resolvingSymlinksInPath().path else { throw ReplacementRecoveryError.changedSource }
        let input = Darwin.open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard input >= 0 else { throw ReplacementRecoveryError.sourceNotReadOnly }
        defer { Darwin.close(input) }
        try checkSource(input)
        var sourceInfo = stat()
        guard fstat(input, &sourceInfo) == 0 else { throw ReplacementRecoveryError.changedSource }
        guard destination.standardizedFileURL.path == destination.resolvingSymlinksInPath().path,
              destination.path != source.path, !destination.path.hasPrefix(source.path + "/") else { throw ReplacementRecoveryError.invalidDestination }
        let parent = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw ReplacementRecoveryError.invalidDestination }
        var parentTransferred = false
        defer { if !parentTransferred { Darwin.close(parent) } }
        var destinationFS = statfs()
        guard fstatfs(parent, &destinationFS) == 0, destinationFS.f_flags & UInt32(MNT_RDONLY) == 0 else { throw ReplacementRecoveryError.invalidDestination }
        let identifier = UUID().uuidString
        let temporary = ".Volisle-Recovery-" + identifier + ".partial"
        let final = "盘屿恢复-" + identifier.prefix(8)
        guard mkdirat(parent, temporary, 0o700) == 0 else { throw ReplacementRecoveryError.invalidDestination }
        let output = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard output >= 0 else { _ = unlinkat(parent, temporary, AT_REMOVEDIR); throw ReplacementRecoveryError.invalidDestination }
        var transferred = false, created: [String] = []
        defer {
            if !transferred {
                for name in created + ["恢复报告.json"] { _ = unlinkat(output, name, 0) }
                Darwin.close(output); _ = unlinkat(parent, temporary, AT_REMOVEDIR)
            }
        }
        var info = stat()
        guard fstat(output, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ReplacementRecoveryError.invalidDestination }
        let b = state.binding
        let ext = (b.target as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        var versions: [ReplacementRecoveryVersion] = []
        for (role, paths, expected) in [("旧版本", [b.targetPath, b.backupPath], state.before),
                                       ("新版本", [b.sourcePath, b.targetPath], state.after)] {
            var status = "missing"
            let name = role + suffix
            for path in paths {
                try Task.checkCancellation(); try checkSource(input)
                let file: Int32
                do { file = try openFile(path, root: input) }
                catch let error as POSIXError where error.code == .ENOENT { continue }
                catch { status = "unreadable"; continue }
                defer { Darwin.close(file) }
                var before = stat()
                guard fstat(file, &before) == 0, before.st_dev == sourceInfo.st_dev,
                      before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
                      UInt64(before.st_size) == expected.size else { status = "mismatch"; continue }
                let target = openat(output, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard target >= 0 else { throw ReplacementRecoveryError.invalidDestination }
                created.append(name)
                var matched = false
                do {
                    defer { Darwin.close(target) }
                    let actual = try ReplacementFingerprint.read(size: expected.size) { offset, buffer in
                        try Task.checkCancellation(); try checkSource(input)
                        let count = Darwin.pread(file, buffer.baseAddress, buffer.count, off_t(offset))
                        guard count > 0 else { throw ReplacementRecoveryError.changedSource }
                        try writeAll(target, UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                        return count
                    }
                    var after = stat()
                    guard fstat(file, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ReplacementRecoveryError.changedSource }
                    matched = actual == expected
                    if matched {
                        guard fsync(target) == 0 else { throw POSIXError(.EIO) }
                        let copied = try ReplacementFingerprint.read(size: expected.size) { offset, buffer in
                            try Task.checkCancellation()
                            let n = Darwin.pread(target, buffer.baseAddress, buffer.count, off_t(offset))
                            guard n > 0 else { throw POSIXError(.EIO) }
                            return n
                        }
                        var saved = stat()
                        guard copied == expected, fstat(target, &saved) == 0, saved.st_size >= 0,
                              UInt64(saved.st_size) == expected.size, saved.st_nlink == 1,
                              saved.st_uid == getuid(), saved.st_mode & 0o077 == 0 else { throw POSIXError(.EIO) }
                    }
                }
                if !matched {
                    guard unlinkat(output, name, 0) == 0 else { throw POSIXError(.EIO) }
                    created.removeLast(); status = "mismatch"; continue
                }
                try checkSource(input)
                status = "verified"
                break
            }
            versions.append(.init(version: role, status: status, file: status == "verified" ? name : nil,
                bytes: status == "verified" ? expected.size : nil, sha256: status == "verified" ? expected.sha256 : nil))
        }
        guard versions.contains(where: { $0.status == "verified" }) else { throw ReplacementRecoveryError.noMatchingVersions }
        try checkSource(input)
        let report = try encoder.encode(Report(record: record.id, originalFilename: b.target, phase: state.phase, versions: versions))
        let reportFD = openat(output, "恢复报告.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard reportFD >= 0 else { throw ReplacementRecoveryError.invalidDestination }
        do {
            defer { Darwin.close(reportFD) }
            try report.withUnsafeBytes { try writeAll(reportFD, $0) }
            guard fsync(reportFD) == 0, fsync(output) == 0 else { throw POSIXError(.EIO) }
        }
        transferred = true; parentTransferred = true
        return .init(parent: parent, fd: output, parentURL: destination, temporaryName: temporary, finalName: String(final), versions: versions)
    }
    private static func openFile(_ path: String, root: Int32) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), parts.count > 1, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ReplacementRecoveryError.invalidRecord }
        var parent = dup(root)
        guard parent >= 0 else { throw POSIXError(.EMFILE) }
        defer { Darwin.close(parent) }
        for component in parts.dropFirst().dropLast() {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            Darwin.close(parent); parent = next
        }
        let file = openat(parent, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return file
    }
    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: done), bytes.count - done)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            done += n
        }
    }
}

protocol RecoveryReadOnlyMounting: Sendable {
    func unmount(_ volume: VolumeSnapshot) async throws
    func mount(_ volume: VolumeSnapshot) async throws
}
private struct SystemRecoveryReadOnlyMounting: RecoveryReadOnlyMounting {
    func unmount(_ volume: VolumeSnapshot) async throws {
        let disk = try await NativeReadOnlyDisk(bsdName: volume.bsdName, registryID: volume.identity.mediaRegistryID ?? 0)
        try await disk.unmount()
    }
    func mount(_ volume: VolumeSnapshot) async throws {
        let disk = try await NativeReadOnlyDisk(bsdName: volume.bsdName, registryID: volume.identity.mediaRegistryID ?? 0)
        try await disk.mount()
    }
}

public actor ReplacementRecoveryCoordinator {
    private let backend: any DiskAccessBackend
    private let gate: DeviceOperationGate
    private let mounts: any RecoveryReadOnlyMounting
    private let sourceValidator: @Sendable (Int32, VolumeSnapshot) throws -> Void
    public init(backend: any DiskAccessBackend = SystemDiskAccessBackend(), gate: DeviceOperationGate = .shared) {
        self.backend = backend; self.gate = gate; self.mounts = SystemRecoveryReadOnlyMounting()
        self.sourceValidator = Self.validateMountedSource
    }
    init(testBackend: any DiskAccessBackend, gate: DeviceOperationGate, mounts: any RecoveryReadOnlyMounting,
         sourceValidator: @escaping @Sendable (Int32, VolumeSnapshot) throws -> Void) {
        self.backend = testBackend; self.gate = gate; self.mounts = mounts; self.sourceValidator = sourceValidator
    }
    public func export(_ record: ReplacementRecoveryRecord, volume: VolumeSnapshot, destination: URL,
                       resolver: any VolumeResolver) async throws -> ReplacementRecoveryResult {
        guard record.canExport, record.bootHash != nil else { throw ReplacementRecoveryError.invalidRecord }
        let lease = try gate.acquire(volume.deviceGroup); defer { gate.release(lease) }
        let original = try await resolver.resolve(volume.identity)
        try validate(original, matching: volume, allowUnmounted: true)
        let request = try await backend.prepare(original)
        guard request.bsdName == original.bsdName, request.registryID == original.identity.mediaRegistryID else { throw VolumeError.identityChanged }
        var restoreOnFailure = false
        let sourceVolume: VolumeSnapshot
        do {
            // macOS FSKit denies a second raw-device open while mounted.
            // Unmount normally (never force), prove the boot identity before
            // mounting, then use the retained media instance and readonly VFS
            // identity throughout the copy. No cached report substitutes for
            // the initial fresh boot read.
            if original.mountState == .readOnly {
                try await mounts.unmount(original)
                restoreOnFailure = true
            }
            let unmounted = try await resolver.resolve(volume.identity)
            guard unmounted.identity == original.identity, unmounted.bsdName == original.bsdName,
                  unmounted.mountState == .unmounted, unmounted.mountURL == nil else { throw VolumeError.identityChanged }
            try Task.checkCancellation()
            try await backend.requestAuthorization(request)
            let report = try HelperDiskReport.decode(JSONEncoder().encode(try await backend.inspect(request)), matching: request)
            guard report.effectiveUID == 0, report.bootSHA256 == record.bootHash else { throw ReplacementRecoveryError.differentVolume }
            let checked = try await resolver.resolve(volume.identity)
            try validate(checked, matching: unmounted, allowUnmounted: true)
            try Task.checkCancellation()
            try await mounts.mount(checked)
            restoreOnFailure = false
            sourceVolume = try await resolver.resolve(volume.identity)
            guard sourceVolume.identity == original.identity, sourceVolume.bsdName == original.bsdName else { throw VolumeError.identityChanged }
            try validate(sourceVolume, matching: sourceVolume)
        } catch {
            if restoreOnFailure { try? await mounts.mount(original) }
            throw error
        }
        try Task.checkCancellation()
        let draft = try ReplacementRecoveryExport.stage(record: record, source: sourceVolume.mountURL!, destination: destination) { fd in
            try sourceValidator(fd, sourceVolume)
        }
        // prepare reads live IORegistry media metadata and validates the signed
        // helper connection; it performs no raw-device open and no disk writes.
        guard try await backend.prepare(sourceVolume) == request else { throw ReplacementRecoveryError.changedSource }
        let final = try await resolver.resolve(volume.identity)
        try validate(final, matching: sourceVolume)
        let held = Darwin.open(sourceVolume.mountURL!.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard held >= 0 else { throw ReplacementRecoveryError.changedSource }
        defer { Darwin.close(held) }
        try sourceValidator(held, final)
        try Task.checkCancellation()
        return try draft.commit()
    }
    private func validate(_ volume: VolumeSnapshot, matching original: VolumeSnapshot, allowUnmounted: Bool = false) throws {
        guard volume.identity == original.identity, volume.bsdName == original.bsdName,
              volume.mountURL == original.mountURL else { throw VolumeError.identityChanged }
        guard volume.isExternal, !volume.isProtected, volume.isNTFS,
              (volume.mountState == .readOnly && volume.mountURL != nil) ||
                (allowUnmounted && volume.mountState == .unmounted && volume.mountURL == nil) else { throw ReplacementRecoveryError.sourceNotReadOnly }
    }
    static func validateMountedSource(_ fd: Int32, volume: VolumeSnapshot) throws {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw ReplacementRecoveryError.changedSource }
        func string<T>(_ value: T) -> String { withUnsafeBytes(of: value) { bytes in String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) } }
        guard info.f_flags & UInt32(MNT_RDONLY) != 0,
              ["ntfs", "volisle"].contains(string(info.f_fstypename)),
              string(info.f_mntfromname) == "/dev/" + volume.bsdName,
              string(info.f_mntonname) == volume.mountURL?.path else { throw ReplacementRecoveryError.sourceNotReadOnly }
    }
}
