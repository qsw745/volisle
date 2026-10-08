// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import os
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
    /// When set, every write first saves what it overwrites.
    var undo: PartitionUndoLog?

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
        if let undo {
            // The before-image must be on disk before the block changes.
            if offset == span.start && Int(count) == span.length,
               !full(span.length, { pread(descriptor, scratch.baseAddress! + $0, span.length - $0, off_t(span.start) + off_t($0)) }) {
                failed = true; return -1
            }
            guard undo.save(UnsafeRawBufferPointer(start: scratch.baseAddress, count: span.length), at: span.start) else {
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
        // Record numbers and a fixed kind only: no names or contents of the disk.
        if code != EALREADY { Logger(subsystem: "top.qisw.volisle.helper", category: "check").error("在 Mac 上检查未通过：\(reason, privacy: .public)") }
        switch code {
        case EALREADY: return 0  // not marked: nothing to clear
        case EBUSY: throw reason == "hibernated" ? HelperDiskFailure.windowsHibernated : HelperDiskFailure.windowsLogUnclean
        case EIO where reason.hasPrefix("inconsistent record"):
            throw CheckMarkerRefusal(.checkFoundProblems, detail: reason) ?? HelperDiskFailure.checkFoundProblems
        case EIO where reason.hasPrefix("read failed"):
            throw CheckMarkerRefusal(.checkReadFailed, detail: reason) ?? HelperDiskFailure.checkReadFailed
        default: throw HelperDiskFailure.unavailable
        }
    }

    func examineWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> WindowsLogExamination {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        guard Self.lock.try() else { throw HelperDiskFailure.busy }
        defer { Self.lock.unlock() }
        var device = io.makeIO(readOnly: true)
        var state = nk_windows_log()
        var errbuf = [CChar](repeating: 0, count: 256)
        let rc = withExtendedLifetime(io) { nk_windows_log_examine(&device, &state, &errbuf, errbuf.count) }
        guard rc == 0 else { throw io.failed ? HelperDiskFailure.checkReadFailed : HelperDiskFailure.unavailable }
        return Self.examination(state)
    }

    func recoverWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
        try changeWindowsLog(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount, undoFile: undoFile, discard: false)
    }

    func discardWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
        try changeWindowsLog(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount, undoFile: undoFile, discard: true)
    }

    /// Replays (or, when it does not replay, gives up) the Windows log. Every
    /// write first saves what it overwrites; a result that does not verify is
    /// put back exactly.
    private func changeWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL, discard: Bool) throws -> WindowsLogRecoveryResult {
        let io = try Self.io(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        guard Self.lock.try() else { throw HelperDiskFailure.busy }
        defer { Self.lock.unlock() }
        let undo = try PartitionUndoLog(url: undoFile)
        io.undo = undo
        var device = io.makeIO()
        var before = nk_windows_log()
        var items: Int64 = 0
        var errbuf = [CChar](repeating: 0, count: 256)
        let rc = withExtendedLifetime(io) {
            discard ? nk_windows_log_discard(&device, &before, &items, &errbuf, errbuf.count)
                    : nk_windows_log_recover(&device, &before, &items, &errbuf, errbuf.count)
        }
        let code = errno
        let reason = Self.reason(errbuf)
        let log = Logger(subsystem: "top.qisw.volisle.helper", category: "windows-log")
        log.notice("ntfsrecover：\(Self.note(before), privacy: .public)")
        if rc == 0 {
            undo.discard()
            return WindowsLogRecoveryResult(replayed: discard ? 0 : before.redo_actions, checkedItems: items, discarded: discard,
                                            heldBytes: discard ? before.held_bytes : 0)
        }
        log.error("Windows 日志\(discard ? "放弃" : "补写", privacy: .public)未完成：\(reason, privacy: .public) 已写=\(undo.records, privacy: .public)")
        if undo.records == 0 {
            undo.discard()
            switch (code, reason) {
            case (EALREADY, _): return WindowsLogRecoveryResult(replayed: 0, checkedItems: 0)
            case (EBUSY, "hibernated"): throw HelperDiskFailure.windowsHibernated
            case (EBUSY, "Windows maintenance pending"): throw HelperDiskFailure.windowsMaintenancePending
            case (EBUSY, "marked for check"): throw HelperDiskFailure.ntfsDirty
            case (EBUSY, _): throw HelperDiskFailure.windowsLogUnreadable
            case (EIO, _) where reason.hasPrefix("inconsistent record"):
                throw CheckMarkerRefusal(.checkFoundProblems, detail: reason) ?? HelperDiskFailure.checkFoundProblems
            case (EIO, _) where reason.hasPrefix("read failed"):
                throw CheckMarkerRefusal(.checkReadFailed, detail: reason) ?? HelperDiskFailure.checkReadFailed
            default: throw io.failed ? HelperDiskFailure.checkReadFailed : HelperDiskFailure.unavailable
            }
        }
        // Something was written and the result did not verify: put it all back.
        var original = nk_windows_log()
        var probe = RawPartitionIO(descriptor: descriptor, blockSize: blockSize, size: io.size).makeIO(readOnly: true)
        guard undo.restore(to: descriptor), nk_windows_log_examine(&probe, &original, nil, 0) == 0,
              original.log_clean == 0, original.log_readable == 1 || discard else {
            log.fault("Windows 日志处理失败且未能还原，撤销记录保留：\(undo.url.lastPathComponent, privacy: .public)")
            throw HelperDiskFailure.windowsLogRestoreFailed
        }
        undo.discard()
        log.notice("Windows 日志处理失败，已按撤销记录还原 \(undo.records, privacy: .public) 处")
        throw CheckMarkerRefusal(.windowsLogReplayRestored, detail: reason) ?? HelperDiskFailure.windowsLogReplayRestored
    }

    private static func examination(_ s: nk_windows_log) -> WindowsLogExamination {
        WindowsLogExamination(markedForCheck: s.dirty != 0, maintenancePending: s.maintenance_pending != 0,
                              hibernated: s.hibernated != 0, logReadable: s.log_readable != 0, logClean: s.log_clean != 0,
                              logVersion: "\(s.log_major).\(s.log_minor)", replaySimulated: s.replay_simulated != 0,
                              pendingChanges: s.redo_actions, detail: Self.note(s).isEmpty ? nil : String(Self.note(s).prefix(300)),
                              discardChecked: s.discard_checked != 0, discardPassed: s.discard_ok != 0, checkedItems: s.checked_items,
                              discardDetail: Self.discardReason(s), heldBytes: s.held_bytes)
    }

    /// Only the check's fixed wording crosses XPC (a record number and a kind).
    private static func discardReason(_ s: nk_windows_log) -> String? {
        let reason = withUnsafeBytes(of: s.discard_reason) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return CheckMarkerRefusal(.checkFoundProblems, detail: reason)?.detail ?? (reason.isEmpty ? nil : String(reason.prefix(60)))
    }

    /// ntfsrecover's status lines, as the bridge kept them.
    private static func note(_ s: nk_windows_log) -> String {
        withUnsafeBytes(of: s.note) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
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
