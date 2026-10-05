// Test transport ONLY: held, flocked 64 MiB regular files in a fresh workbench.
// This does not claim a physical disk or implement Disk Arbitration exclusion.
import Foundation
import CryptoKit
import Darwin

final class DetachedRecoveryDevice {
    private var fd: Int32 = -1
    private let path: String
    private let binding: BlockJournalBinding
    private let connection = UUID().uuidString
    private let lease = UUID()
    private var fileIdentity = stat()
    private var parentIdentity = stat()
    private var closed = false
    var beforeWrite: ((Int32, Int64, Data) throws -> Bool)?
    var beforeRead: (() throws -> Void)?
    var writes = 0

    init(path: String, heldDescriptor: Int32, binding: BlockJournalBinding) throws {
        self.path = path; self.binding = binding
        let url = URL(fileURLWithPath: path)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench")
        guard url.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("block-journal-"),
              url.resolvingSymlinksInPath().path == path, binding.deviceSize == 64*1024*1024 else {
            throw BlockJournalError.invalid
        }
        fd = fcntl(heldDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0, fstat(fd, &fileIdentity) == 0,
              lstat(url.deletingLastPathComponent().path, &parentIdentity) == 0 else { throw BlockJournalError.unavailable }
    }
    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    func session() throws -> BlockJournalDeviceSession {
        try .init(binding: binding, connectionIdentity: connection, leaseID: lease,
            observe: { try self.observe() },
            read: { offset, count in
                try self.beforeRead?()
                var bytes = Data(count: count)
                let n = bytes.withUnsafeMutableBytes { pread(self.fd, $0.baseAddress, count, off_t(offset)) }
                guard n == count else { throw BlockJournalError.unavailable }; return bytes
            }, write: { offset, bytes in
                self.writes += 1
                if try self.beforeWrite?(self.fd, offset, bytes) == true { return }
                let n = bytes.withUnsafeBytes { pwrite(self.fd, $0.baseAddress, bytes.count, off_t(offset)) }
                guard n == bytes.count else { throw BlockJournalError.unavailable }
            }, flush: {
                guard fsync(self.fd) == 0, fcntl(self.fd, F_FULLFSYNC) == 0 else { throw BlockJournalError.unavailable }
            }, stopWrites: {}, release: { self.close() })
    }
    private func observe() throws -> BlockJournalDeviceObservation {
        guard !closed, fd >= 0 else { throw BlockJournalError.failed }
        var held = stat(), named = stat(), parent = stat()
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path,
              fstat(fd, &held) == 0, lstat(path, &named) == 0,
              lstat(url.deletingLastPathComponent().path, &parent) == 0,
              parent.st_dev == parentIdentity.st_dev, parent.st_ino == parentIdentity.st_ino,
              parent.st_mode & S_IFMT == S_IFDIR,
              held.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              held.st_dev == fileIdentity.st_dev, held.st_ino == fileIdentity.st_ino,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino,
              held.st_size == binding.deviceSize, held.st_uid == getuid(), held.st_nlink == 1 else {
            throw BlockJournalError.unavailable
        }
        // A fresh open file description must NOT acquire the cooperating lock.
        // dup() above retains the driver's original flock throughout this scope.
        let contender = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard contender >= 0 else { throw BlockJournalError.unavailable }
        defer { Darwin.close(contender) }
        guard flock(contender, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK else { throw BlockJournalError.unavailable }
        var boot = Data(count: 512)
        guard boot.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 512, 0) }) == 512 else { throw BlockJournalError.unavailable }
        return .init(volumeIdentity: "\(held.st_dev):\(held.st_ino)",
            bootSHA256: SHA256.hash(data: boot).map { String(format: "%02x", $0) }.joined(),
            deviceSize: Int64(held.st_size), blockSize: binding.blockSize,
            connectionIdentity: connection, leaseID: lease, ownsLease: true, mounted: false, writable: true)
    }
}
