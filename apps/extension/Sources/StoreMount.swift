// SPDX-License-Identifier: GPL-2.0-only
#if VOLISLE_STORE
#if VOLISLE_DAILY_WRITES
#error("VOLISLE_STORE 与 VOLISLE_DAILY_WRITES 不能同时定义：后者按后台组件的写入请求决定读写")
#endif
import Foundation

/// Store build: the system mounts the volume itself and no background
/// component passes `volisle-rw`. This decides whether such a mount may ask
/// for write access; journal recovery and the read-only inspection still run
/// afterwards and can only take write access away. No FSKit or device access.
enum StoreMountPolicy {
    enum ReadOnlyReason: Equatable {
        case requested, preference, writeProtected, unsupported
        /// Activation was refused: this module mounted nothing.
        case failed
        case journal(String)
        /// An NK_CHECK_* status other than CLEAN.
        case inspection(Int32)

        /// What the app reads back; never localized.
        var token: String {
            switch self {
            case .requested: return "requested"
            case .preference: return "preference"
            case .writeProtected: return "writeProtected"
            case .unsupported: return "unsupported"
            case .failed: return "failed"
            case .journal(let reason): return "journal:\(reason)"
            case .inspection(1): return "check:dirty"
            case .inspection(2): return "check:hibernated"
            case .inspection(3): return "check:log"
            case .inspection: return "check:unknown"
            }
        }
    }

    /// nil: the mount may go on to recovery and inspection as writable.
    /// The preference outranks an explicit `rw`: the system may add one to
    /// every mount, and the owner's "read-only" choice must still hold.
    static func readOnlyReason(options: [String], writable: Bool, serial: [UInt8],
                               byteCount: UInt64, preferReadOnly: Bool) -> ReadOnlyReason? {
        let opts = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        if opts.contains("ro") || opts.contains("rdonly") { return .requested }
        guard writable else { return .writeProtected }
        guard byteCount >= 512, byteCount <= UInt64(Int64.max), byteCount % 512 == 0,
              serial.count == 8, serial.contains(where: { $0 != 0 }) else { return .unsupported }
        return preferReadOnly ? .preference : nil
    }

    /// The mount point is named after the volume label, which is whatever the
    /// disk says: no path separators, no control characters, a bounded length.
    static func mountName(label: String) -> String {
        let kept = label.unicodeScalars.filter { $0.properties.generalCategory != .control && $0 != "\u{FFFD}" }
        var name = String(String.UnicodeScalarView(kept)).map { $0 == "/" || $0 == ":" ? "-" : $0 }
        while String(name).utf8.count > 96 { name.removeLast() }
        let trimmed = String(name).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "NTFS" : trimmed
    }

    /// Recovery rolls back by writing, so it and the inspection run only for a
    /// mount that may still write: never for one asked to be read-only.
    static func resolve(_ reason: ReadOnlyReason?, recover: () -> String?,
                        inspect: () throws -> Int32) rethrows -> ReadOnlyReason? {
        if let reason { return reason }
        if let refused = recover() { return .journal(refused) }
        let status = try inspect()
        return status == 0 ? nil : .inspection(status)
    }
}

/// Shared with the app through the app group: the owner's preference in, the
/// outcome of each mount out. The app cannot see mount options or refusals
/// any other way once the system does the mounting.
enum StoreMountStatus {
    static let group = "6N5T3G6H33.top.qisw.volisle.mas"
    static let preferReadOnlyKey = "PreferReadOnly"
    static let changed = group + ".mount-status"

    static func key(serial: [UInt8]) -> String {
        "MountStatus." + serial.map { String(format: "%02x", $0) }.joined()
    }

    /// What the write journal undid before this mount. Either way the last
    /// writes of the earlier session are gone, and their owner should know.
    enum Recovery: String {
        /// The session was cut off: unplugged, power lost, or the extension ended (an app update ends it).
        case interrupted
        /// The session ended cleanly but the drive lost what it had not yet written out.
        case afterEnd = "after-end"
    }

    /// `bsdName` ties the record to one connection: records outlive their mount.
    static func entry(readOnly reason: StoreMountPolicy.ReadOnlyReason?, bsdName: String, at: Date,
                      recovery: Recovery? = nil, mountID: String? = nil, stopped: Bool = false) -> [String: Any] {
        var entry: [String: Any] = ["readOnly": reason != nil, "bsd": bsdName, "at": at.timeIntervalSince1970,
                                  "stopped": stopped]
        if let reason { entry["reason"] = reason.token }
        if let recovery { entry["recovery"] = recovery.rawValue }
        if let mountID { entry["mount"] = mountID }
        return entry
    }

    /// The app writes this at its first launch. Absent or unreadable (the
    /// app never ran, or the group is not shared), the owner's choice is
    /// unknown: read-only.
    static var preferReadOnly: Bool {
        UserDefaults(suiteName: group)?.object(forKey: preferReadOnlyKey) as? Bool ?? true
    }

    static func record(serial: [UInt8], bsdName: String, readOnly reason: StoreMountPolicy.ReadOnlyReason?,
                       recovery: Recovery? = nil, mountID: String? = nil, at: Date = Date(), stopped: Bool = false) {
        UserDefaults(suiteName: group)?.set(entry(readOnly: reason, bsdName: bsdName, at: at, recovery: recovery,
                                                mountID: mountID, stopped: stopped),
                                            forKey: key(serial: serial))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changed as CFString), nil, nil, true)
    }
}
#endif
