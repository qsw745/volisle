import Foundation

/// 只保存白名单字段和聚合数字；不接受自由文本错误、卷名、路径或引擎授权秘密。
public struct DiagnosticReport: Codable, Sendable {
    public let schemaVersion: Int
    public let appVersion: String
    public let systemVersion: String
    public let diskServiceRunning: Bool
    public let externalVolumeCount: Int
    public let fileSystemCounts: [String: Int]
    public let mountStateCounts: [String: Int]
    public let engineAvailable: Bool
    public let engineSupportsFinderReadWrite: Bool
    public let safetyCheck: String
    public let nativeMount: NativeMountPrerequisites?
    /// How external disks are attached, by whitelisted category.
    public let connectionCounts: [String: Int]?
    /// The last disk operation of the background component: enum values only.
    public let lastOperation: OperationSummary?

    public struct OperationSummary: Codable, Sendable, Equatable {
        public let purpose: String
        public let phase: String
        public let failure: String?
        public let recoveryFailure: String?
        public init(_ operation: HelperMountOperation) {
            purpose = operation.isWrite ? "readWrite" : "check"
            phase = operation.phase.rawValue
            failure = operation.failure?.rawValue
            recoveryFailure = operation.recoveryFailure?.rawValue
        }
    }

    public init(volumes: [VolumeSnapshot], diskServiceRunning: Bool, engine: EngineCapability,
                nativeMount: NativeMountPrerequisites = .current, appVersion: String = Self.bundleVersion(),
                lastOperation: HelperMountOperation? = nil) {
        schemaVersion = 3
        self.lastOperation = lastOperation.map(OperationSummary.init)
        self.nativeMount = nativeMount
        self.appVersion = appVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.diskServiceRunning = diskServiceRunning
        let external = volumes.filter(\.isExternal)
        externalVolumeCount = external.count
        fileSystemCounts = Dictionary(grouping: external, by: { Self.fileSystemCategory($0.fileSystem) }).mapValues(\.count)
        mountStateCounts = Dictionary(grouping: external, by: { $0.mountState.rawValue }).mapValues(\.count)
        connectionCounts = Dictionary(grouping: external, by: { Self.connectionCategory($0.deviceProtocol) }).mapValues(\.count)
        engineAvailable = engine.available
        engineSupportsFinderReadWrite = engine.available && engine.finderReadWrite
        // 当前发现服务不执行磁盘风险检查，不能从挂载状态或引擎存在推断安全。
        safetyCheck = "not_performed"
    }

    /// "0.3.3 (19)" from the running app's Info.plist.
    public static func bundleVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private static func connectionCategory(_ value: String?) -> String {
        guard let value else { return "unknown" }
        return ["USB", "Thunderbolt", "PCI-Express", "PCI", "Secure Digital", "SATA", "FireWire", "Virtual Interface", "Disk Image"]
            .contains(value) ? value : "other"
    }

    private static func fileSystemCategory(_ value: String) -> String {
        let value = value.lowercased()
        return ["ntfs", "apfs", "hfs", "hfs+", "exfat", "msdos", "fat", "fat32"].contains(value) ? value : "other"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public var text: String {
        let separator = String(localized: "，")
        let none = String(localized: "无")
        let count = { (name: String, value: Int) in String(localized: "\(name)：\(value)") }
        let kinds = fileSystemCounts.keys.sorted().map { count($0, fileSystemCounts[$0] ?? 0) }.joined(separator: separator)
        let mounts = mountStateCounts.keys.sorted().map { count($0, mountStateCounts[$0] ?? 0) }.joined(separator: separator)
        let connections = (connectionCounts ?? [:]).keys.sorted().map { count($0, connectionCounts?[$0] ?? 0) }.joined(separator: separator)
        let operation = lastOperation.map { op in
            [op.purpose, op.phase, op.failure.map { "failure=" + $0 }, op.recoveryFailure.map { "recovery=" + $0 }]
                .compactMap { $0 }.joined(separator: " · ")
        } ?? none
        let service = diskServiceRunning ? String(localized: "已连接") : String(localized: "未连接")
        let engine = engineAvailable ? String(localized: "可用") : String(localized: "未接入或不可用")
        let finder = engineSupportsFinderReadWrite ? String(localized: "引擎报告具备，仍须逐卷检查") : String(localized: "不可用")
        let lines = [
            String(localized: "盘屿 Volisle \(appVersion)"),
            String(localized: "诊断格式：\(schemaVersion)"),
            String(localized: "系统：\(systemVersion)"),
            String(localized: "磁盘服务：\(service)"),
            String(localized: "外接卷数量：\(externalVolumeCount)"),
            String(localized: "文件系统：\(kinds.isEmpty ? none : kinds)"),
            String(localized: "系统挂载状态：\(mounts.isEmpty ? none : mounts)"),
            String(localized: "外接卷连接方式：\(connections.isEmpty ? none : connections)"),
            String(localized: "上次磁盘操作：\(operation)"),
            String(localized: "产品引擎：\(engine)"),
            String(localized: "产品 Finder 读写能力：\(finder)"),
            String(localized: "原生挂载接入：\(nativeMount?.summary ?? String(localized: "旧诊断未记录"))"),
            String(localized: "风险检测：未执行，不代表安全"),
            String(localized: "未导出卷名、路径、UUID、设备编号、设备型号、文件内容或授权秘密。"),
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
