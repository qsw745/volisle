import Foundation
import Darwin

/// Before-images of a raw partition, appended (and flushed) ahead of each
/// write; restored newest first, the disk returns to exactly what it was.
/// Record: offset (8 bytes), length (4), the bytes.
public final class PartitionUndoLog {
    private static let magic = Data("VOLISLE-UNDO-1\n".utf8)
    public let url: URL
    private let fd: Int32
    public private(set) var records = 0
    /// Bytes of complete records: a record cut short (a full disk) is cut off
    /// again, so every earlier one can still be restored.
    private var length: off_t

    public init(url: URL) throws {
        self.url = url
        length = off_t(Self.magic.count)
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HelperDiskFailure.unavailable }
        guard Self.magic.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == Self.magic.count, Self.flush(fd) else {
            Darwin.close(fd); unlink(url.path); throw HelperDiskFailure.unavailable
        }
    }
    deinit { Darwin.close(fd) }

    public func save(_ bytes: UnsafeRawBufferPointer, at offset: Int64) -> Bool {
        var header = Data(count: 12)
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt64(offset).littleEndian, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: UInt32(bytes.count).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        let wrote = header.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, 12) } == 12 &&
            Darwin.write(fd, bytes.baseAddress, bytes.count) == bytes.count
        guard wrote, Self.flush(fd) else {
            _ = ftruncate(fd, length); _ = lseek(fd, length, SEEK_SET); _ = Self.flush(fd)
            return false
        }
        records += 1
        length += off_t(12 + bytes.count)
        return true
    }

    /// Through the drive's own cache: the before-image must survive a power cut.
    private static func flush(_ fd: Int32) -> Bool {
        fcntl(fd, F_FULLFSYNC) == 0 || (errno == ENOTSUP || errno == ENOTTY) && fsync(fd) == 0
    }

    /// Puts every saved range back, newest first, straight to the device.
    public func restore(to descriptor: Int32) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path), data.starts(with: Self.magic) else { return false }
        var entries: [(offset: Int64, range: Range<Int>)] = []
        var at = Self.magic.count
        while at < data.count {
            guard at + 12 <= data.count else { return false }
            let offset = data.subdata(in: at..<at + 8).withUnsafeBytes { Int64(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
            let length = Int(data.subdata(in: at + 8..<at + 12).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard at + 12 + length <= data.count else { return false }
            entries.append((offset, at + 12..<at + 12 + length)); at += 12 + length
        }
        guard entries.count == records else { return false }
        for entry in entries.reversed() {
            let ok = data[entry.range].withUnsafeBytes { bytes -> Bool in
                var done = 0
                while done < bytes.count {
                    let n = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t(entry.offset) + off_t(done))
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
            if !ok { return false }
        }
        if fsync(descriptor) != 0 { return false }
        if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != ENOTSUP && errno != ENOTTY { return false }
        return true
    }

    public func discard() { unlink(url.path) }
}
