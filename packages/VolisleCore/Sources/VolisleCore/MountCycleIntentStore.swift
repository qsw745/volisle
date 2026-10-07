import Foundation
import Darwin

public struct MountCycleIntentUnreadable: LocalizedError, Equatable {
    public var errorDescription: String? { String(localized: "上次磁盘请求的本机记录无法读取，重启 Mac 后盘屿会自动核对并解除暂停。") }
}

/// A user-owned pending ID, not authority to mutate a disk. The daemon always
/// resolves its own persisted record and original device for recovery.
@MainActor public final class FileMountCycleIntentStore: MountCycleIntentStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("pending-readonly-check.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volisle", isDirectory: true)
    }
    public func load() throws -> MountCycleIntent? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw HelperServiceError.invalidReply }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            throw HelperServiceError.invalidReply
        }
        if let value = Self.decode(fd, size: info.st_size) { return value }
        // Its request may still be queued for the daemon in this boot, so only a
        // record from an earlier boot is set aside; the daemon's own records then
        // say what ran.
        guard info.st_mtimespec.tv_sec < Self.bootTime() else { throw MountCycleIntentUnreadable() }
        guard rename(file.path, directory.appendingPathComponent("pending-readonly-check.invalid.json").path) == 0 else {
            throw HelperServiceError.unavailable
        }
        try syncDirectory()
        return nil
    }
    private static func decode(_ fd: Int32, size: off_t) -> MountCycleIntent? {
        guard size > 0, size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard bytes.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) == bytes.count,
              let value = try? JSONDecoder().decode(MountCycleIntent.self, from: Data(bytes)),
              (try? value.validate()) != nil else { return nil }
        return value
    }
    /// 0 when unknown, which keeps an unreadable record blocking.
    private static func bootTime() -> Int {
        var value = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return value.tv_sec
    }
    public func save(_ intent: MountCycleIntent) throws {
        try intent.validate()
        let data = try JSONEncoder().encode(intent)
        guard data.count <= 4096 else { throw HelperServiceError.invalidRequest }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperServiceError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw HelperServiceError.unavailable }
        try syncDirectory()
    }
    public func clear() throws {
        if unlink(file.path) != 0 && errno != ENOENT { throw HelperServiceError.unavailable }
        if FileManager.default.fileExists(atPath: directory.path) { try syncDirectory() }
    }
    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperServiceError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw HelperServiceError.unavailable }
    }
}
