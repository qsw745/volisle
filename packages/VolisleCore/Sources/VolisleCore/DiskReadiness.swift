import Foundation

/// "Why can't I write to this disk?": every condition Volisle needs, in the
/// order they have to be met, each with what the user can do about it. Shown
/// on request, so a user can solve it alone, or report exactly where it fails.
public enum DiskReadiness {
    public enum Status: String, Sendable, Equatable { case ok, problem, note }
    /// What the app offers next to an item; the app decides how to do it.
    public enum Action: String, Sendable, Equatable {
        case approveHelper, setUpHelper, reconnectHelper, fullDiskAccess, fileSystemExtensions
        case enableWriting, retry, checkOnMac, recoverOnMac, exportDiagnostics
    }
    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let status: Status
        public let detail: String
        public let action: Action?
    }
    public enum DiskErrors: Sendable, Equatable { case notChecked, checking, unreadable, found(DiskErrorSummary) }
    public struct Inputs: Sendable {
        public var helper: HelperServiceController.State
        public var helperError: String?
        public var fullDiskAccess: Bool?
        public var extensionAvailable: Bool
        public var extensionReason: String
        public var isNTFS: Bool
        public var isUnrecognizedWindows: Bool
        /// The other NTFS driver that mounted this disk (e.g. "TT NTFS").
        public var foreignDriver: String?
        /// Why this disk stays read-only by design (write-protected, not USB…).
        public var designRefusal: String?
        /// The disks holding every read-write place, already quoted and joined (“A”和“B”).
        public var writeHolder: String?
        public var writable: Bool
        /// The last refusal of writing for this disk.
        public var lastFailure: HelperDiskFailure?
        /// What the disk reported to macOS lately (read from the system log, which takes a moment).
        public var diskErrors: DiskErrors = .notChecked
        public init(helper: HelperServiceController.State, helperError: String? = nil, fullDiskAccess: Bool?,
                    extensionAvailable: Bool, extensionReason: String, isNTFS: Bool, isUnrecognizedWindows: Bool = false,
                    foreignDriver: String? = nil, designRefusal: String? = nil, writeHolder: String? = nil, writable: Bool, lastFailure: HelperDiskFailure? = nil,
                    diskErrors: DiskErrors = .notChecked) {
            self.helper = helper; self.helperError = helperError; self.fullDiskAccess = fullDiskAccess
            self.extensionAvailable = extensionAvailable; self.extensionReason = extensionReason
            self.isNTFS = isNTFS; self.isUnrecognizedWindows = isUnrecognizedWindows
            self.foreignDriver = foreignDriver; self.designRefusal = designRefusal
            self.writeHolder = writeHolder; self.writable = writable; self.lastFailure = lastFailure
            self.diskErrors = diskErrors
        }
    }

    public static func items(_ inputs: Inputs) -> [Item] {
        var items = [helper(inputs), fullDiskAccess(inputs), fileSystemExtension(inputs), disk(inputs)]
        if let errors = diskErrors(inputs) { items.append(errors) }
        if let holder = inputs.writeHolder {
            items.append(.init(id: "slot", title: String(localized: "同时读写的盘"), status: .problem,
                               detail: String(localized: "同一时间最多为 \(MountCycles.maximumSessions) 块 NTFS 盘开启读写。\(holder)正在读写，推出其中一块后这块盘才能开启。"),
                               action: nil))
        }
        items.append(result(inputs, blocked: items.contains { $0.status == .problem }))
        return items
    }

    private static func helper(_ inputs: Inputs) -> Item {
        let title = String(localized: "后台组件")
        switch inputs.helper {
        case .connected:
            return .init(id: "helper", title: title, status: .ok, detail: String(localized: "已连接。"), action: nil)
        case .requiresApproval:
            return .init(id: "helper", title: title, status: .problem,
                         detail: String(localized: "需要在“系统设置 → 通用 → 登录项与扩展”中允许盘屿在后台运行。"), action: .approveHelper)
        case .notRegistered:
            return .init(id: "helper", title: title, status: .problem,
                         detail: String(localized: "还没有设置。盘屿通过它读取和挂载磁盘。"), action: .setUpHelper)
        case .unavailable:
            return .init(id: "helper", title: title, status: .problem,
                         detail: String(localized: "这个版本无法安装后台组件，请从官网下载完整的安装版。"), action: nil)
        case .failed:
            return .init(id: "helper", title: title, status: .problem,
                         detail: inputs.helperError ?? String(localized: "暂时无法连接。"), action: .reconnectHelper)
        }
    }

    private static func fullDiskAccess(_ inputs: Inputs) -> Item {
        let title = String(localized: "完全磁盘访问")
        switch inputs.fullDiskAccess {
        case true?:
            return .init(id: "access", title: title, status: .ok, detail: String(localized: "已允许。"), action: nil)
        case false?:
            return .init(id: "access", title: title, status: .problem,
                         detail: String(localized: "盘屿读取磁盘需要这项权限：在“系统设置 → 隐私与安全性 → 完全磁盘访问”中打开“盘屿”。"),
                         action: .fullDiskAccess)
        case nil:
            return .init(id: "access", title: title, status: .note,
                         detail: String(localized: "后台组件连接后才能确认。"), action: nil)
        }
    }

    private static func fileSystemExtension(_ inputs: Inputs) -> Item {
        let title = String(localized: "文件系统扩展“盘屿 NTFS”")
        guard !inputs.extensionAvailable else {
            return .init(id: "extension", title: title, status: .ok, detail: String(localized: "已开启。"), action: nil)
        }
        return .init(id: "extension", title: title, status: .problem,
                     detail: inputs.extensionReason + " " + String(localized: "在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”中打开“盘屿 NTFS”（有的系统显示为“Volisle NTFS”）。"),
                     action: .fileSystemExtensions)
    }

    /// Bad sectors or an unsteady connection: neither can Volisle fix, and both
    /// stop writing in the middle (the disk may even drop off), so say which.
    private static func diskErrors(_ inputs: Inputs) -> Item? {
        let title = String(localized: "硬盘报告的读写错误")
        switch inputs.diskErrors {
        case .notChecked:
            return nil
        case .checking:
            return .init(id: "errors", title: title, status: .note, detail: String(localized: "正在查看最近 24 小时的系统记录…"), action: nil)
        case .unreadable:
            return .init(id: "errors", title: title, status: .note, detail: String(localized: "无法读取系统记录（需要管理员账户）。"), action: nil)
        case .found(let summary) where summary.isEmpty:
            return .init(id: "errors", title: title, status: .ok, detail: String(localized: "最近 24 小时没有记录到读写错误。"), action: nil)
        case .found(let summary) where summary.medium > 0:
            return .init(id: "errors", title: title, status: .problem, detail: String(localized: "最近 24 小时，硬盘在 \(max(summary.places, 1)) 处位置报告了无法读取的扇区（共 \(summary.medium) 次），多半是坏道。写到这些位置附近时读写会中断，硬盘可能掉线。请尽快把重要文件拷出，再用硬盘厂商的检测工具检查。"), action: .exportDiagnostics)
        case .found(let summary):
            return .init(id: "errors", title: title, status: .problem, detail: String(localized: "最近 24 小时，硬盘报告了 \(summary.other) 次读写错误（不是坏道），多半是数据线、USB 接口、扩展坞或供电不稳。换根线、换个接口，或接到带电源的扩展坞再试。"), action: nil)
        }
    }

    private static func disk(_ inputs: Inputs) -> Item {
        let title = String(localized: "这块盘")
        if let driver = inputs.foreignDriver {
            return .init(id: "disk", title: title, status: .problem, detail: ForeignNTFSDriver.handOver(driver),
                         action: .fileSystemExtensions)
        }
        if let refusal = inputs.designRefusal {
            return .init(id: "disk", title: title, status: .problem, detail: refusal, action: nil)
        }
        if inputs.isNTFS {
            return .init(id: "disk", title: title, status: .ok, detail: String(localized: "通过 USB 连接的 NTFS 分区，可以开启读写。"), action: nil)
        }
        if inputs.isUnrecognizedWindows {
            return .init(id: "disk", title: title, status: .note,
                         detail: String(localized: "macOS 读不出这个 Windows 分区，可能是 BitLocker 加密的：先在盘屿中解锁。"), action: nil)
        }
        return .init(id: "disk", title: title, status: .note, detail: String(localized: "这不是 NTFS 分区，盘屿不处理它。"), action: nil)
    }

    private static func result(_ inputs: Inputs, blocked: Bool) -> Item {
        let title = String(localized: "开启读写")
        if inputs.writable {
            return .init(id: "result", title: title, status: .ok, detail: String(localized: "已开启，可以读写。"), action: nil)
        }
        if let failure = inputs.lastFailure {
            return .init(id: "result", title: title, status: .problem,
                         detail: String(localized: "上次没有成功：") + (failure.errorDescription ?? failure.rawValue),
                         action: action(for: failure))
        }
        return .init(id: "result", title: title, status: .note,
                     detail: blocked ? String(localized: "先处理上面的问题。") : String(localized: "还没有为这块盘开启读写。"),
                     action: blocked || !inputs.isNTFS ? nil : .enableWriting)
    }

    /// What helps after this refusal: what the message itself describes stays without a button.
    static func action(for failure: HelperDiskFailure) -> Action? {
        switch failure {
        case .ntfsDirty: return .checkOnMac
        case .windowsLogUnclean: return .recoverOnMac
        case .interruptedWriteUnverified, .interruptedWriteUnsupportedFormat, .checkFoundProblems: return .exportDiagnostics
        case .interruptedWriteRetry, .mountFailed, .writeNotEnabled, .busy, .unavailable, .changedMedia: return .retry
        case .permissionDenied: return .fullDiskAccess
        case .windowsHibernated, .windowsMaintenancePending, .windowsLogUnreadable, .windowsLogReplayRestored,
             .windowsLogRestoreFailed, .checkReadFailed, .writeProtected, .protectedMedia,
             .unsupportedFileSystem, .unsupportedPartition, .invalidRequest, .notBitLocker, .bitLockerWrongSecret,
             .bitLockerUnsupported, .sameVolumeWriting, .staleEntriesNotRepairable, .staleEntriesRepairRestored,
             .staleEntriesRestoreFailed:
            return nil
        }
    }
}
