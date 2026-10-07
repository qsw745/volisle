// SPDX-License-Identifier: GPL-2.0-only
import Foundation
/// Explicit experimental write intent; no FSKit or device access in this policy.
enum WriteMountPolicy {
    /// A qualifying write request must pass a read-only inspection before
    /// activation reports writable intent. The C bridge repeats that check
    /// when opening the eventual write session; this is not a cached permit.
    static func requiresReadOnly(options: [String], writable: Bool, serial: [UInt8],
                                 byteCount: UInt64, allowedSerial: [UInt8], allowedByteCount: UInt64 = 64 * 1024 * 1024,
                                 inspect: () throws -> Int32) throws -> Bool {
        guard allows(options: options, writable: writable, serial: serial,
                     byteCount: byteCount, allowedSerial: allowedSerial, allowedByteCount: allowedByteCount) else { return true }
        // Values are the NK_CHECK_* ABI from ntfs_bridge.h. Only CLEAN (0)
        // permits activation; future/invalid values must fail closed.
        try validateInspection(inspect())
        return false
    }

    static func validateInspection(_ status: Int32) throws {
        guard status == 0 else {
            let reason: String
            switch status {
            case 1: reason = "NTFS 卷带有脏标记，拒绝可写挂载。"
            case 2: reason = "无法排除 Windows 休眠风险，拒绝可写挂载。"
            case 3: reason = "NTFS 日志未通过安全检查，拒绝可写挂载。"
            default: reason = "无法确认 NTFS 卷安全，拒绝可写挂载。"
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS),
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// Refusals the background component recognises by the bracketed token at
    /// the end; the words before it are for the log only.
    static func recoveryRefused(_ reason: WriteJournalError) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS), userInfo: [NSLocalizedDescriptionKey:
            "上次写入中断后的自动恢复没有完成，拒绝可写挂载。[journal:\(reason)]"])
    }

    static func writeProtected() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS), userInfo: [NSLocalizedDescriptionKey:
            "磁盘处于写保护状态，拒绝可写挂载。[media:writeProtected]"])
    }

    static func requestsWrite(_ options: [String]) -> Bool {
        let opts = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        return opts.contains("volisle-rw") && !opts.contains("ro") && !opts.contains("rdonly")
    }

    static func allowsDaily(options: [String], writable: Bool, serial: [UInt8], byteCount: UInt64) -> Bool {
        let opts = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        return writable && byteCount >= 512 && byteCount <= UInt64(Int64.max) && byteCount % 512 == 0 &&
            serial.count == 8 && serial.contains(where: { $0 != 0 }) &&
            opts.contains("volisle-rw") && !opts.contains("ro") && !opts.contains("rdonly")
    }

    /// BitLocker carries no NTFS serial before decryption; the key in the
    /// options (checked separately) is what ties the mount to this volume.
    static func allowsBitLocker(options: [String], writable: Bool, byteCount: UInt64) -> Bool {
        let opts = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        return writable && byteCount >= 1_048_576 && byteCount <= UInt64(Int64.max) && byteCount % 512 == 0 &&
            opts.contains("volisle-rw") && !opts.contains("ro") && !opts.contains("rdonly")
    }

    static func allows(options: [String], writable: Bool, serial: [UInt8],
                       byteCount: UInt64, allowedSerial: [UInt8], allowedByteCount: UInt64 = 64 * 1024 * 1024) -> Bool {
        let opts = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        guard [64 * 1024 * 1024, 512 * 1024 * 1024].contains(allowedByteCount),
              byteCount == allowedByteCount,
              serial.count == 8, serial.contains(where: { $0 != 0 }),
              serial == allowedSerial else { return false }
        return writable && opts.contains("volisle-rw") && !opts.contains("ro") && !opts.contains("rdonly")
    }
}
