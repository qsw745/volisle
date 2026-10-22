// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Synchronous, read-only NTFS mount-safety inspection. This is not a complete
/// filesystem checker. The caller must hold a stable/exclusive device session.
enum NTFSReadOnlyInspection {
    typealias Read = (Int64, Int) throws -> Data
    static func inspect(deviceSize: Int64, readBudget: Int = 128 * 1024 * 1024,
                        read: Read) -> Int32 {
        withoutActuallyEscaping(read) { reader in
            run(deviceSize: deviceSize, readBudget: readBudget, read: reader) { nk_inspect(&$0) }
        }
    }
    #if VOLISLE_BLOCK_JOURNAL_TESTING
    static func fixture(deviceSize: Int64, readBudget: Int = 128 * 1024 * 1024,
                        read: @escaping Read, engine: (inout nk_io) -> Int32) -> Int32 {
        run(deviceSize: deviceSize, readBudget: readBudget, read: read, engine: engine)
    }
    #endif
    private final class Reader {
        let size: Int64
        let limit: Int
        let read: Read
        var used = 0, calls = 0
        var failed = false
        init(size: Int64, limit: Int, read: @escaping Read) { self.size=size; self.limit=limit; self.read=read }
        func perform(_ buffer: UnsafeMutableRawPointer?, count: Int64, offset: Int64) -> Int64 {
            guard !failed, calls < 32768, count >= 0, count <= 1024 * 1024,
                  offset >= 0, offset <= size, count <= size-offset,
                  count <= Int64(limit-used), count == 0 || buffer != nil else { failed=true; return -1 }
            calls += 1; used += Int(count)
            if count == 0 { return 0 }
            do {
                let data = try read(offset, Int(count))
                guard data.count == Int(count) else { failed=true; return -1 }
                data.withUnsafeBytes { source in buffer!.copyMemory(from: source.baseAddress!, byteCount: data.count) }
                return count
            } catch { failed=true; return -1 }
        }
    }
    private static func run(deviceSize: Int64, readBudget: Int, read: @escaping Read,
                            engine: (inout nk_io) -> Int32) -> Int32 {
        guard deviceSize >= 512, deviceSize % 512 == 0,
              (512...128 * 1024 * 1024).contains(readBudget) else { return Int32(NK_CHECK_UNKNOWN) }
        let reader = Reader(size: deviceSize, limit: readBudget, read: read)
        var io = nk_io(ctx: Unmanaged.passUnretained(reader).toOpaque(), pread: { ctx, buffer, count, offset in
            guard let ctx else { return -1 }
            return Unmanaged<Reader>.fromOpaque(ctx).takeUnretainedValue().perform(buffer, count: count, offset: offset)
        }, pwrite: nil, size: deviceSize, readonly: 1, sync: nil)
        return withExtendedLifetime(reader) {
            let status = engine(&io)
            // Optional engine probes can swallow I/O errors. They still make
            // this inspection incomplete, even if the engine returns CLEAN.
            return reader.failed ? Int32(NK_CHECK_UNKNOWN) : status
        }
    }
}
