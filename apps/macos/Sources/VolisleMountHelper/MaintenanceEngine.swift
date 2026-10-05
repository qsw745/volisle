// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin
import VolisleCore
import VolisleNTFSFormat

/// Raw partition I/O for mkntfs. The engine may ask for any byte range; a raw
/// device takes whole blocks only, so partial blocks are read, patched and
/// written back. The partition is unmounted and held by the device gate.
private final class RawPartitionIO {
    let descriptor: Int32
    let blockSize: Int
    let size: Int64
    private(set) var failed = false

    init(descriptor: Int32, blockSize: Int, size: Int64) {
        self.descriptor = descriptor; self.blockSize = blockSize; self.size = size
    }

    private func span(_ offset: Int64, _ count: Int64) -> (start: Int64, length: Int)? {
        guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { return nil }
        let bs = Int64(blockSize)
        let start = offset / bs * bs, end = (offset + count + bs - 1) / bs * bs
        guard end - start <= 64 * 1024 * 1024 else { return nil }
        return (start, Int(end - start))
    }

    private func full(_ length: Int, _ body: (Int) -> Int) -> Bool {
        var done = 0
        while done < length {
            let n = body(done)
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    func read(_ buffer: UnsafeMutableRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        guard !failed, let span = span(offset, count) else { failed = true; return -1 }
        if count == 0 { return 0 }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: span.length, alignment: blockSize)
        defer { scratch.deallocate() }
        guard full(span.length, { pread(descriptor, scratch.baseAddress! + $0, span.length - $0, off_t(span.start) + off_t($0)) }) else {
            failed = true; return -1
        }
        buffer.copyMemory(from: scratch.baseAddress! + Int(offset - span.start), byteCount: Int(count))
        return count
    }

    func write(_ buffer: UnsafeRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        guard !failed, let span = span(offset, count) else { failed = true; return -1 }
        if count == 0 { return 0 }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: span.length, alignment: blockSize)
        defer { scratch.deallocate() }
        if offset != span.start || Int(count) != span.length {
            guard full(span.length, { pread(descriptor, scratch.baseAddress! + $0, span.length - $0, off_t(span.start) + off_t($0)) }) else {
                failed = true; return -1
            }
        }
        (scratch.baseAddress! + Int(offset - span.start)).copyMemory(from: buffer, byteCount: Int(count))
        guard full(span.length, { pwrite(descriptor, scratch.baseAddress! + $0, span.length - $0, off_t(span.start) + off_t($0)) }) else {
            failed = true; return -1
        }
        return count
    }

    /// Raw writes bypass the buffer cache; still ask the drive to flush its own.
    func sync() -> Int32 {
        guard !failed, fsync(descriptor) == 0 else { failed = true; return -1 }
        if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != ENOTSUP && errno != ENOTTY { failed = true; return -1 }
        return 0
    }

    func makeIO(readOnly: Bool = false) -> nk_io {
        nk_io(ctx: Unmanaged.passUnretained(self).toOpaque(), pread: { ctx, buffer, count, offset in
            guard let ctx, let buffer else { return -1 }
            return Unmanaged<RawPartitionIO>.fromOpaque(ctx).takeUnretainedValue().read(buffer, count, offset)
        }, pwrite: { ctx, buffer, count, offset in
            guard let ctx, let buffer else { return -1 }
            return Unmanaged<RawPartitionIO>.fromOpaque(ctx).takeUnretainedValue().write(buffer, count, offset)
        }, size: size, readonly: readOnly ? 1 : 0, sync: { ctx in
            guard let ctx else { return -1 }
            return Unmanaged<RawPartitionIO>.fromOpaque(ctx).takeUnretainedValue().sync()
        })
    }
}

/// The helper's NTFS maintenance: mkntfs quick format, clearing the "needs
/// check" marker after a read-only walk, and reading a BitLocker volume's key.
/// All run through the host callbacks on the verified raw partition.
struct NTFSMaintenanceEngine: PartitionMaintenanceEngine {
    /// mkntfs keeps process-global state: one operation at a time in this process.
    private static let lock = NSLock()

    func format(descriptor: Int32, blockSize: Int, byteCount: UInt64, label: String) throws {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        guard Self.lock.try() else { throw HelperDiskFailure.busy }
        defer { Self.lock.unlock() }
        var device = io.makeIO()
        var errbuf = [CChar](repeating: 0, count: 256)
        let rc = withExtendedLifetime(io) {
            label.withCString { nk_format(&device, $0, Int32(blockSize), &errbuf, errbuf.count) }
        }
        guard rc == 0 else {
            throw Self.reason(errbuf) == "invalid volume name" ? HelperDiskFailure.invalidRequest : HelperDiskFailure.unavailable
        }
    }

    func clearCheckMarker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Int64 {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        guard Self.lock.try() else { throw HelperDiskFailure.busy }
        defer { Self.lock.unlock() }
        var device = io.makeIO()
        var errbuf = [CChar](repeating: 0, count: 256)
        var items: Int64 = 0
        let rc = withExtendedLifetime(io) { nk_clear_check_marker(&device, &items, &errbuf, errbuf.count) }
        let code = errno
        guard rc != 0 else { return items }
        let reason = Self.reason(errbuf)
        switch code {
        case EALREADY: return 0  // not marked: nothing to clear
        case EBUSY: throw reason == "hibernated" ? HelperDiskFailure.windowsHibernated : HelperDiskFailure.windowsLogUnclean
        case EIO where reason.hasPrefix("inconsistent record"): throw HelperDiskFailure.checkFoundProblems
        default: throw HelperDiskFailure.unavailable
        }
    }

    func isBitLocker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Bool {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        var device = io.makeIO(readOnly: true)
        let rc = withExtendedLifetime(io) { nk_bde_probe(&device) }
        guard rc >= 0 else { throw HelperDiskFailure.unavailable }
        return rc == 1
    }

    func bitLockerKey(descriptor: Int32, blockSize: Int, byteCount: UInt64, kind: BitLockerSecretKind, secret: String) throws -> String {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        var device = io.makeIO(readOnly: true)
        var errbuf = [CChar](repeating: 0, count: 256)
        var key = [CChar](repeating: 0, count: 65)
        defer { key.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        let method = Int32(kind == .password ? NK_BDE_PASSWORD : NK_BDE_RECOVERY)
        let rc = withExtendedLifetime(io) {
            secret.withCString { nk_bde_derive_key(&device, method, $0, &key, &errbuf, errbuf.count) }
        }
        let code = errno
        guard rc == 0 else {
            switch code {
            case EACCES: throw HelperDiskFailure.bitLockerWrongSecret
            case ENOTSUP: throw HelperDiskFailure.bitLockerUnsupported
            case EINVAL where Self.reason(errbuf) == "not BitLocker": throw HelperDiskFailure.notBitLocker
            case EINVAL: throw HelperDiskFailure.invalidRequest
            default: throw HelperDiskFailure.unavailable
            }
        }
        return String(decoding: key.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func io(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> RawPartitionIO {
        guard blockSize >= 512, blockSize <= 4096, blockSize.nonzeroBitCount == 1,
              let size = Int64(exactly: byteCount) else { throw HelperDiskFailure.invalidRequest }
        return RawPartitionIO(descriptor: descriptor, blockSize: blockSize, size: size)
    }

    private static func reason(_ errbuf: [CChar]) -> String {
        String(decoding: errbuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
