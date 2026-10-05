// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import VolisleDiskIO

/// Bound logical reads to a small sector-aligned envelope for raw device I/O.
struct RecoveryRawReadPlan {
    let start: Int64
    let length: Int
    init(offset: Int64, count: Int, geometry: RecoveryDiskGeometry) throws {
        guard offset >= 0, offset <= geometry.byteCount, count >= 0, count <= 1024 * 1024,
              Int64(count) <= geometry.byteCount - offset else { throw BlockJournalError.corrupt }
        if count == 0 { start = offset; length = 0; return }
        let sector = Int64(geometry.blockSize)
        start = offset - offset % sector
        let end = offset + Int64(count)
        let padding = (sector - end % sector) % sector
        guard padding <= geometry.byteCount - end else { throw BlockJournalError.corrupt }
        length = Int(end + padding - start)
    }
}

enum RecoveryWriteAdmission {
    enum Failure: Error { case mismatchedBinding }
    static func validate(_ binding: BlockJournalBinding, volumeIdentity: String, bootSHA256: String,
                         byteCount: Int64, sectorSize: Int) throws {
        try BlockJournalStore.validate(binding)
        // The authenticated authority checks the exact epoch. Its initial
        // generation legitimately uses nil; non-nil alone is not authentication.
        guard binding.recoveryBaselineSHA256 != nil,
              binding.volumeIdentity == volumeIdentity, binding.bootSHA256 == bootSHA256,
              binding.deviceSize == byteCount, sectorSize >= 512, sectorSize <= 65536,
              sectorSize.nonzeroBitCount == 1, binding.blockSize % sectorSize == 0 else { throw Failure.mismatchedBinding }
    }
}

/// Stable volume matching plus a fresh connection-bound recovery transport.
/// No transient device name or boot/registry instance becomes a persistent key.
/// Non-Sendable and scoped to the native claim's synchronous worker.
final class NativeRecoveryConnection {
    enum Failure: Error { case changedBoot }
    private let target: NativeRecoveryClaimTarget
    private let checkpoint: RecoveryWorkerCheckpoint
    private let bootSHA256: String
    private let leaseID: UUID
    let volumeIdentity: String
    var byteCount: Int64 { Int64(target.byteCount) }
    init(target: NativeRecoveryClaimTarget, checkpoint: RecoveryWorkerCheckpoint, bootSHA256: String, leaseID: UUID) throws {
        self.target = target; self.checkpoint = checkpoint; self.bootSHA256 = bootSHA256; self.leaseID = leaseID
        volumeIdentity = try RecoveryVolumeIdentity.make(media: target.persistentMedia, bootSHA256: bootSHA256,
            byteCount: Int64(target.byteCount), sectorSize: target.blockSize)
    }
    func openDevice(_ permit: BlockJournalRecoveryPermit) throws -> BlockJournalDeviceSession {
        try checkpoint.verify(); try permit.verify()
        try RecoveryWriteAdmission.validate(permit.binding, volumeIdentity: volumeIdentity, bootSHA256: bootSHA256,
                                           byteCount: byteCount, sectorSize: target.blockSize)
        let transport = try RecoveryWritableTransport(target: target, checkpoint: checkpoint, permit: permit,
            bootSHA256: bootSHA256, connection: target.connectionIdentity + "|" + leaseID.uuidString, leaseID: leaseID)
        return try checkpoint.deviceSession(binding: permit.binding, connectionIdentity: transport.connection, leaseID: leaseID,
            observe: { try transport.observe() }, read: { try transport.read($0, $1) },
            write: { try transport.write($0, $1) }, flush: { try transport.flush() },
            stopWrites: { transport.stop() }, release: { transport.close() })
    }
}

private final class RecoveryWritableTransport {
    private var fd: Int32 = -1
    private let path: String
    private let geometry: RecoveryDiskGeometry
    private let checkpoint: RecoveryWorkerCheckpoint
    private let permit: BlockJournalRecoveryPermit
    private let bootSHA256: String
    private let leaseID: UUID
    private var original = stat()
    private var failed = false
    let connection: String
    init(target: NativeRecoveryClaimTarget, checkpoint: RecoveryWorkerCheckpoint, permit: BlockJournalRecoveryPermit,
         bootSHA256: String, connection: String, leaseID: UUID) throws {
        self.path = "/dev/r" + target.bsdName; self.checkpoint = checkpoint; self.permit = permit
        self.bootSHA256 = bootSHA256; self.connection = connection; self.leaseID = leaseID
        geometry = try .init(blockSize: UInt32(target.blockSize), blockCount: target.byteCount / UInt64(target.blockSize))
        do {
            try permit.verify(); try checkpoint.verify()
            fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFCHR else { throw BlockJournalError.unavailable }
            _ = try observe(); try permit.verify(); try checkpoint.verify()
        } catch { stop(); close(); throw error }
    }
    deinit { close() }
    func observe() throws -> BlockJournalDeviceObservation {
        guard fd >= 0, !failed else { throw BlockJournalError.failed }
        var held = stat(), named = stat()
        let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
        guard fstat(fd, &held) == 0, lstat(path, &named) == 0,
              held.st_mode & S_IFMT == S_IFCHR, named.st_mode & S_IFMT == S_IFCHR,
              held.st_dev == original.st_dev, held.st_ino == original.st_ino, held.st_rdev == original.st_rdev,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino, named.st_rdev == held.st_rdev,
              flags >= 0, flags & O_ACCMODE == O_RDWR, descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0,
              volisle_disk_is_writable(fd) == 1, try RecoveryDiskGeometry.read(descriptor: fd) == geometry else { throw BlockJournalError.unavailable }
        let boot = try read(0, geometry.blockSize)
        guard try HelperDiskPolicy.bootHash(Data(boot.prefix(512))) == bootSHA256 else { throw NativeRecoveryConnection.Failure.changedBoot }
        return .init(volumeIdentity: permit.binding.volumeIdentity, bootSHA256: bootSHA256, deviceSize: geometry.byteCount,
            blockSize: permit.binding.blockSize, connectionIdentity: connection, leaseID: leaseID,
            ownsLease: true, mounted: false, writable: true)
    }
    func read(_ offset: Int64, _ count: Int) throws -> Data {
        guard fd >= 0, !failed else { throw BlockJournalError.failed }
        let plan = try RecoveryRawReadPlan(offset: offset, count: count, geometry: geometry)
        if count == 0 { return Data() }
        var data = Data(count: plan.length)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < plan.length {
                let chunk = min(1024 * 1024, plan.length - done)
                guard pread(fd, buffer.baseAddress!.advanced(by: done), chunk, off_t(plan.start + Int64(done))) == chunk else {
                    throw BlockJournalError.unavailable
                }
                done += chunk
            }
        }
        let skip = Int(offset - plan.start)
        return data.subdata(in: skip..<skip + count)
    }
    func write(_ offset: Int64, _ data: Data) throws {
        try permit.verify()
        guard fd >= 0, !failed else { throw BlockJournalError.failed }
        try geometry.validateRead(offset: offset, count: data.count)
        guard data.count > 0, data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }) == data.count else {
            throw BlockJournalError.unavailable
        }
        try permit.verify()
    }
    func flush() throws {
        try permit.verify()
        guard fd >= 0, !failed, volisle_sync_disk(fd) == 0 else { throw BlockJournalError.unavailable }
        try permit.verify()
    }
    func stop() { failed = true; checkpoint.revoke() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
}
