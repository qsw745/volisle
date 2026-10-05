import Foundation
import Darwin

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
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw HelperServiceError.invalidReply
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard bytes.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            throw HelperServiceError.invalidReply
        }
        let value = try JSONDecoder().decode(MountCycleIntent.self, from: Data(bytes))
        try value.validate()
        return value
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
