// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Which mounted volumes are the store extension's, and which NTFS volume each is.
enum StoreVolumeIdentity {
    /// "VOLISLE\0": the extension reports the NTFS serial followed by this as the volume UUID.
    private static let marker: [UInt8] = [0x56, 0x4f, 0x4c, 0x49, 0x53, 0x4c, 0x45, 0]

    static func serial(volumeUUID: UUID) -> [UInt8]? {
        let bytes = withUnsafeBytes(of: volumeUUID.uuid) { Array($0) }
        return Array(bytes[8...]) == marker ? Array(bytes[..<8]) : nil
    }
}

/// What the extension recorded about a mount (StoreMountStatus), as the app reads it back.
struct StoreVolumeStatus: Equatable {
    let readOnly: Bool
    let reason: String?
    /// StoreMountStatus.Recovery's raw value: what the recovery before this mount undid.
    let recovery: String?
    let bsdName: String
    let at: Date

    init?(entry: Any?) {
        guard let entry = entry as? [String: Any], let readOnly = entry["readOnly"] as? Bool,
              let bsdName = entry["bsd"] as? String,
              let at = entry["at"] as? Double, at.isFinite else { return nil }
        self.readOnly = readOnly
        self.reason = entry["reason"] as? String
        self.recovery = entry["recovery"] as? String
        self.bsdName = bsdName
        self.at = Date(timeIntervalSince1970: at)
    }

    /// Records outlive the mount they describe. This one counts only for the
    /// device node it was written for and only while it agrees with what the
    /// system reports now.
    func describes(mountedReadOnly: Bool, bsdName: String) -> Bool {
        readOnly == mountedReadOnly && self.bsdName == bsdName
    }
}

struct StoreExplanation: Equatable {
    let title: String
    let advice: String
}

/// Writes the recovery before this mount had to undo: the owner may be missing recent files.
enum StoreRecoveryText {
    static func explanation(recovery: String) -> StoreExplanation? {
        let advice = String(localized: "请检查最近拷贝或修改的文件，没有的重新拷贝一次。")
        switch recovery {
        case "interrupted":
            return .init(title: String(localized: "上次读写这块盘时被中断了（盘屿更新、磁盘被拔下或断电都会这样），最后约 20 秒写入的内容已退回，磁盘恢复到了中断前的一致状态。"),
                         advice: advice)
        case "after-end":
            return .init(title: String(localized: "上次推出后磁盘拔得太快，最后的改动还没写进磁盘，已退回到推出前的一致状态。"),
                         advice: advice)
        default:
            return nil
        }
    }
}

/// Why a volume is read-only and what its owner can do, from the extension's token.
enum StoreReadOnlyText {
    /// Read-only with no record about this mount: say only what is known.
    static let unexplained = StoreExplanation(
        title: String(localized: "这块盘现在是只读的。"),
        advice: String(localized: "推出后重新接上再试一次；仍然只读时，接回 Windows 检查磁盘。"))

    static func explanation(token: String) -> StoreExplanation {
        switch token {
        case "requested":
            return .init(title: String(localized: "这次是按只读方式挂载的。"),
                         advice: String(localized: "推出后重新接上，就会按盘屿的设置挂载。"))
        case "preference":
            return .init(title: String(localized: "盘屿设置成了“默认只读”。"),
                         advice: String(localized: "想写入这块盘，在设置里关掉“默认只读”，推出后重新接上。"))
        case "diskPreference":
            return .init(title: String(localized: "这块盘设成了“总是只读”。"),
                         advice: String(localized: "想写入这块盘，在下面“这块盘”里改成别的读写方式，推出后重新接上。"))
        case "writeProtected":
            return .init(title: String(localized: "磁盘处于写保护状态。"),
                         advice: String(localized: "检查磁盘、存储卡或读卡器上的写保护开关。"))
        case "check:dirty":
            return .init(title: String(localized: "这块盘被标记为需要检查，为保护数据暂时只读。"),
                         advice: String(localized: "接回 Windows 检查磁盘，安全弹出后再接回 Mac。"))
        case "check:hibernated":
            return .init(title: String(localized: "这块盘来自处于休眠或“快速启动”状态的 Windows，为保护数据暂时只读。"),
                         advice: String(localized: "请在 Windows 中完全关机后再接回 Mac。"))
        case "check:log":
            return .init(title: String(localized: "这块盘上次在 Windows 中没有安全弹出，为保护数据暂时只读。"),
                         advice: String(localized: "接回 Windows，用“安全删除硬件”弹出后再接回 Mac。"))
        case let token where token.hasPrefix("journal:"):
            return .init(title: String(localized: "上次在这台 Mac 上写入时被打断，自动恢复没有完成，暂时只读。"),
                         advice: String(localized: "推出后重新接上再试一次；仍然只读时，接回 Windows 检查磁盘。"))
        default:
            return .init(title: String(localized: "无法确认这块盘可以安全写入，暂时只读。"),
                         advice: String(localized: "接回 Windows 检查磁盘，安全弹出后再接回 Mac。"))
        }
    }
}
