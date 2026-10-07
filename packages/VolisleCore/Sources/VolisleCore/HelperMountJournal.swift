import Foundation
import Darwin

/// Fixed-name, bounded, atomic record in a private directory. Never follows a
/// record/lock symlink, never accepts a path from IPC, and holds an advisory
/// process lock for the entire service lifetime. All operations use a held dirfd.
final class HelperMountJournal: @unchecked Sendable {
    let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private let lock = NSLock()
    init(directory: URL) throws {
        self.directory = directory
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd); throw HelperServiceError.untrustedPackage
        }
        let held = openat(fd, "service.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard held >= 0 else { close(fd); throw HelperServiceError.unavailable }
        var lockInfo = stat()
        guard fstat(held, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o777 == 0o600,
              flock(held, LOCK_EX | LOCK_NB) == 0 else {
            close(held); close(fd); throw HelperServiceError.unavailable
        }
        directoryFD = fd; lockFD = held
    }
    deinit { close(lockFD); close(directoryFD) }
    static func system() throws -> HelperMountJournal {
        guard geteuid() == 0 else { throw HelperServiceError.wrongPrivileges }
        let directory = URL(filePath: "/private/var/db/volisle")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw HelperServiceError.unavailable }
        return try .init(directory: directory)
    }
    func read() throws -> HelperMountOperation? {
        guard let data = try readFile("operation.json", limit: 8192) else { return nil }
        let value = try JSONDecoder().decode(HelperMountOperation.self, from: data)
        try value.validate()
        return value
    }
    func write(_ record: HelperMountOperation) throws {
        try record.validate()
        try writeFile(JSONEncoder().encode(record), name: "operation.json", limit: 8192)
    }
    // Within one boot IDs are never evicted: a delayed request must not regain
    // permission to run. The bounded ledger fails closed when full. It stores
    // identities, not paths supplied to filesystem operations. No request can be
    // delivered across a restart of the Mac, so a new boot starts a new ledger
    // (see HelperMountCycleService.init); before 0.7 it was kept for ever and,
    // once full after enough connections, refused every write start.
    static let receiptLimit = 16_384
    /// The boot session the ledger belongs to.
    func readReceiptBoot() throws -> String? {
        try readFile("receipts-boot", limit: 128).map { String(decoding: $0, as: UTF8.self) }
    }
    func writeReceiptBoot(_ boot: String) throws {
        try writeFile(Data(boot.utf8), name: "receipts-boot", limit: 128)
    }
    func readReceipts() throws -> [UUID: HelperMountReceipt] {
        guard let data = try readFile("requests.json", limit: 16 * 1024 * 1024) else { return [:] }
        let records = try JSONDecoder().decode([HelperMountReceipt].self, from: data)
        guard records.count <= Self.receiptLimit else { throw HelperServiceError.invalidReply }
        var result: [UUID: HelperMountReceipt] = [:]
        for record in records {
            try record.validate()
            guard result.updateValue(record, forKey: record.id) == nil else { throw HelperServiceError.invalidReply }
        }
        return result
    }
    func writeReceipts(_ records: [UUID: HelperMountReceipt]) throws {
        guard records.count <= Self.receiptLimit else { throw HelperServiceError.unavailable }
        for (id, record) in records {
            guard id == record.id else { throw HelperServiceError.invalidReply }
            try record.validate()
        }
        try writeFile(JSONEncoder().encode(records.values.sorted { $0.id.uuidString < $1.id.uuidString }),
                      name: "requests.json", limit: 16 * 1024 * 1024)
    }
    private func readFile(_ name: String, limit: Int) throws -> Data? {
        try lock.withLock {
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { return nil }
            guard fd >= 0 else { throw HelperServiceError.untrustedPackage }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= limit else {
                throw HelperServiceError.untrustedPackage
            }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            try bytes.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw HelperServiceError.invalidReply }
                    offset += count
                }
            }
            return Data(bytes)
        }
    }
    private func writeFile(_ data: Data, name destination: String, limit: Int) throws {
        guard data.count <= limit else { throw HelperServiceError.invalidReply }
        try lock.withLock {
            let name = "operation-" + UUID().uuidString + ".tmp"
            let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw HelperServiceError.unavailable }
            defer { close(fd); unlinkat(directoryFD, name, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw HelperServiceError.unavailable }
                    offset += count
                }
            }
            guard fsync(fd) == 0,
                  renameat(directoryFD, name, directoryFD, destination) == 0,
                  fsync(directoryFD) == 0 else { throw HelperServiceError.unavailable }
        }
    }
}

/// A durable fence for an admitted or withdrawn request, never a claim about
/// the current mount state. Only a matching operation can supply that state.
struct HelperMountReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let disk: HelperDiskRequest
    let ownerUID: UInt32
    let write: Bool
    func validate() throws {
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        guard ownerUID != 0, ownerUID != .max else { throw HelperServiceError.invalidRequest }
    }
}
