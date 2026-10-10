import Foundation
import Darwin

/// Which volume an undo record belongs to, and how its Windows log began when
/// the change started. A record an interruption leaves behind (the helper
/// killed, the disk pulled, the power cut) is put back only onto that same
/// volume, and only while nothing has mounted it since: Windows rewrites the
/// first bytes of $LogFile whenever it mounts a disk, and the changes saved
/// here never write them.
public struct PartitionUndoIdentity: Equatable, Sendable {
    /// The NTFS volume serial number (boot sector offset 0x48).
    public let serial: UInt64
    public let byteCount: UInt64
    /// Where $LogFile's first bytes are on the partition, and their SHA-256.
    public let logOffset: Int64
    public let logLength: Int64
    public let logDigest: Data
    public init(serial: UInt64, byteCount: UInt64, logOffset: Int64, logLength: Int64, logDigest: Data) {
        self.serial = serial; self.byteCount = byteCount
        self.logOffset = logOffset; self.logLength = logLength; self.logDigest = logDigest
    }
    static let encodedSize = 8 * 4 + 32
    var encoded: Data {
        var data = Data()
        for value in [serial, byteCount, UInt64(bitPattern: logOffset), UInt64(bitPattern: logLength)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data + logDigest.prefix(32) + Data(count: max(0, 32 - logDigest.count))
    }
    init?(decoding data: Data) {
        guard data.count == Self.encodedSize else { return nil }
        let words = (0..<4).map { i in
            data.subdata(in: data.startIndex + i * 8..<data.startIndex + i * 8 + 8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }
        self.init(serial: words[0], byteCount: words[1], logOffset: Int64(bitPattern: words[2]), logLength: Int64(bitPattern: words[3]),
                  logDigest: data.suffix(32))
    }
}

/// Before-images of a raw partition, appended (and flushed) ahead of each
/// write; restored newest first, the disk returns to exactly what it was.
/// Record: offset (8 bytes), length (4), the bytes. With an identity the file
/// also says which volume it belongs to, so it can be put back after an
/// interruption (see `leftover(at:)`).
public final class PartitionUndoLog {
    private static let magic = Data("VOLISLE-UNDO-1\n".utf8)
    /// The same records after a PartitionUndoIdentity.
    private static let magicWithIdentity = Data("VOLISLE-UNDO-2\n".utf8)
    public let url: URL
    private let fd: Int32
    public private(set) var records = 0
    /// Bytes of complete records: a record cut short (a full disk) is cut off
    /// again, so every earlier one can still be restored.
    private var length: off_t

    public init(url: URL, identity: PartitionUndoIdentity? = nil) throws {
        self.url = url
        let header = identity.map { Self.magicWithIdentity + $0.encoded } ?? Self.magic
        length = off_t(header.count)
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HelperDiskFailure.unavailable }
        guard header.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == header.count, Self.flush(fd) else {
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

    public typealias Entry = (offset: Int64, bytes: Data)

    /// The identity (nil for a file without one) and the records. `partial`:
    /// a last record cut short is dropped, not an error. Nil when malformed.
    private static func parse(_ data: Data, partial: Bool) -> (identity: PartitionUndoIdentity?, entries: [Entry])? {
        var at: Int
        var identity: PartitionUndoIdentity?
        if data.starts(with: magic) {
            at = magic.count
        } else if data.starts(with: magicWithIdentity), data.count >= magicWithIdentity.count + PartitionUndoIdentity.encodedSize,
                  let decoded = PartitionUndoIdentity(decoding: data.subdata(in: magicWithIdentity.count..<magicWithIdentity.count + PartitionUndoIdentity.encodedSize)) {
            identity = decoded
            at = magicWithIdentity.count + PartitionUndoIdentity.encodedSize
        } else {
            return nil
        }
        var entries: [Entry] = []
        while at < data.count {
            if at + 12 > data.count { if partial { break }; return nil }
            let offset = data.subdata(in: at..<at + 8).withUnsafeBytes { Int64(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
            let length = Int(data.subdata(in: at + 8..<at + 12).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            if at + 12 + length > data.count { if partial { break }; return nil }
            entries.append((offset, data.subdata(in: at + 12..<at + 12 + length))); at += 12 + length
        }
        return (identity, entries)
    }

    /// Puts every saved range back, newest first, straight to the device.
    public func restore(to descriptor: Int32) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              let parsed = Self.parse(data, partial: false), parsed.entries.count == records else { return false }
        return Self.write(parsed.entries, to: descriptor, limit: nil)
    }

    public func discard() { unlink(url.path) }

    /// A file an interrupted change left behind: its volume and its records.
    /// A last record cut short was never followed by its write (each record is
    /// flushed before the write it precedes) and is dropped. Nil for a file
    /// without an identity, or a damaged one.
    public static func leftover(at url: URL) -> (identity: PartitionUndoIdentity, entries: [Entry])? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let parsed = parse(data, partial: true), let identity = parsed.identity else { return nil }
        return (identity, parsed.entries)
    }

    /// Newest first; every range must lie within `limit` bytes when given.
    public static func write(_ entries: [Entry], to descriptor: Int32, limit: UInt64?) -> Bool {
        if let limit, entries.contains(where: { $0.offset < 0 || UInt64($0.offset) + UInt64($0.bytes.count) > limit }) { return false }
        for entry in entries.reversed() {
            let ok = entry.bytes.withUnsafeBytes { bytes -> Bool in
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
}
