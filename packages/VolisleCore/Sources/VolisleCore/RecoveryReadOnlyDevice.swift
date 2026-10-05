// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import VolisleDiskIO

struct RecoveryDiskGeometry: Equatable, Sendable {
    let blockSize: Int
    let byteCount: Int64
    init(blockSize: UInt32, blockCount: UInt64) throws {
        guard blockSize >= 512, blockSize <= 65536, blockSize.nonzeroBitCount == 1,
              blockCount > 0, blockCount <= UInt64(Int64.max) / UInt64(blockSize) else {
            throw RecoveryReadOnlyDevice.Failure.invalid
        }
        self.blockSize = Int(blockSize)
        byteCount = Int64(blockCount * UInt64(blockSize))
    }
    static func read(descriptor: Int32) throws -> Self {
        var size: UInt32 = 0, count: UInt64 = 0
        guard volisle_read_disk_geometry(descriptor, &size, &count) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try .init(blockSize: size, blockCount: count)
    }
    func validateRead(offset: Int64, count: Int) throws {
        guard offset >= 0, offset <= byteCount, count >= 0, count <= 1024 * 1024,
              offset % Int64(blockSize) == 0, count % blockSize == 0,
              Int64(count) <= byteCount - offset else { throw RecoveryReadOnlyDevice.Failure.invalid }
    }
}

/// Held raw character device, only O_RDONLY. Constructed and destroyed on the
/// recovery worker while its DA claim is held. No descriptor or write API escapes.
/// Claim checks + descriptor checks do not constitute kernel-wide exclusion.
final class RecoveryReadOnlyDevice {
    enum Failure: Error { case invalid, changed, closed, shortRead }
    private var descriptor: Int32 = -1
    private let path: String
    private let geometry: RecoveryDiskGeometry
    private let bootSHA256: String
    private let checkpoint: RecoveryWorkerCheckpoint
    private var original = stat()
    private var failed = false
    let byteCount: Int64
    let blockSize: Int

    static func validBootHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func withDevice<T: Sendable>(target: NativeRecoveryClaimTarget, bootSHA256: String,
        checkpoint: RecoveryWorkerCheckpoint, operation: (RecoveryReadOnlyDevice) throws -> T) throws -> T {
        let device = try Self(target: target, bootSHA256: bootSHA256, checkpoint: checkpoint)
        defer { device.close() }
        let result = try operation(device)
        try device.verify()
        return result
    }
    private init(target: NativeRecoveryClaimTarget, bootSHA256: String, checkpoint: RecoveryWorkerCheckpoint) throws {
        guard Self.validBootHash(bootSHA256), target.byteCount % UInt64(target.blockSize) == 0 else { throw Failure.invalid }
        geometry = try .init(blockSize: UInt32(target.blockSize), blockCount: target.byteCount / UInt64(target.blockSize))
        byteCount = geometry.byteCount; blockSize = geometry.blockSize
        path = "/dev/r" + target.bsdName
        self.bootSHA256 = bootSHA256; self.checkpoint = checkpoint
        do {
            try checkpoint.verify()
            descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fstat(descriptor, &original) == 0, original.st_mode & S_IFMT == S_IFCHR else { throw Failure.changed }
            try verify()
        } catch { checkpoint.revoke(); close(); throw error }
    }
    deinit { close() }

    func read(offset: Int64, count: Int) throws -> Data {
        do {
            try verify()
            try geometry.validateRead(offset: offset, count: count)
            let result = count == 0 ? Data() : try readExact(offset: offset, count: count)
            try verify()
            return result
        } catch { fail(); throw error }
    }
    func verify() throws {
        do {
            try checkpoint.verify()
            guard descriptor >= 0, !failed else { throw Failure.closed }
            try checkDescriptor()
            let boot = try readExact(offset: 0, count: blockSize)
            guard try HelperDiskPolicy.bootHash(Data(boot.prefix(512))) == bootSHA256 else { throw Failure.changed }
            try checkDescriptor()
            try checkpoint.verify()
        } catch { fail(); throw error }
    }
    private func checkDescriptor() throws {
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, lstat(path, &named) == 0,
              held.st_mode & S_IFMT == S_IFCHR, named.st_mode & S_IFMT == S_IFCHR,
              held.st_dev == original.st_dev, held.st_ino == original.st_ino, held.st_rdev == original.st_rdev,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino, named.st_rdev == held.st_rdev,
              fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY,
              fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0,
              try RecoveryDiskGeometry.read(descriptor: descriptor) == geometry else { throw Failure.changed }
    }
    private func readExact(offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard actual == count else {
            if actual < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw Failure.shortRead
        }
        return data
    }
    private func fail() { failed = true; checkpoint.revoke() }
    private func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
}
