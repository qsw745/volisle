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
    /// The latest operation that was refused, and why (also after a relaunch).
    public let lastRefusal: OperationSummary?
    /// Model identifier and architecture of the Mac (no serial number).
    public let mac: String?
    public let helper: HelperSummary?
    public let automaticWrite: Bool?
    /// External volumes by position: kind, state and a size range only.
    public let volumes: [VolumeSummary]?
    /// How the last disk operations ended, newest first.
    public let history: [HistoryItem]?
    /// Volisle's own recent log lines, cleaned (see DiagnosticEvents).
    public var events: [DiagnosticEvents.Line]?
    /// Why there are no log lines, when there are none.
    public var eventsNote: String?
    /// Read and write errors each physical disk reported lately, by the disk
    /// numbers of `volumes` (nil where nothing could be matched).
    public var diskErrors: [DiskErrorSummary?]?

    /// External volumes grouped by physical disk, in the order the report numbers
    /// them; the device model of each, to look up its errors (never exported).
    public static func diskModels(_ volumes: [VolumeSnapshot]) -> [String] {
        var groups: [String] = [], models: [String] = []
        for volume in volumes where volume.isExternal && !groups.contains(volume.deviceGroup) {
            groups.append(volume.deviceGroup); models.append(volume.deviceName)
        }
        return models
    }

    public struct HelperSummary: Codable, Sendable, Equatable {
        public let state: String
        public let fullDiskAccess: Bool?
        public let packageVerified: Bool
        /// What launchd says about the background service (state, runs, last
        /// exit): whether it was started at all when the App cannot reach it.
        public let launchd: String?
        public init(state: String, fullDiskAccess: Bool?, packageVerified: Bool, launchd: String? = nil) {
            self.state = state; self.fullDiskAccess = fullDiskAccess; self.packageVerified = packageVerified
            self.launchd = launchd
        }
    }

    public struct VolumeSummary: Codable, Sendable, Equatable {
        public let kind: String
        public let mount: String
        public let connection: String
        public let size: String
        /// The physical disk it is on, numbered in order of appearance: a disk's
        /// errors belong to the disk, not to each of its partitions.
        public var disk: Int?
    }

    public struct HistoryItem: Codable, Sendable, Equatable {
        public let time: Date
        public let purpose: String
        public let phase: String
        public let failure: String?
        public let recoveryFailure: String?
    }

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
                lastOperation: HelperMountOperation? = nil, lastRefusal: HelperMountOperation? = nil,
                helper: HelperSummary? = nil, automaticWrite: Bool? = nil,
                history: [OperationHistory.Entry] = [], mac: String? = Self.macModel()) {
        schemaVersion = 4
        self.lastOperation = lastOperation.map(OperationSummary.init)
        self.lastRefusal = lastRefusal.map(OperationSummary.init)
        self.helper = helper
        self.automaticWrite = automaticWrite
        self.mac = mac
        self.history = history.map { .init(time: $0.time, purpose: $0.purpose, phase: $0.phase,
                                           failure: $0.failure, recoveryFailure: $0.recoveryFailure) }
        var groups: [String] = []
        self.volumes = volumes.filter(\.isExternal).map { volume in
            if !groups.contains(volume.deviceGroup) { groups.append(volume.deviceGroup) }
            return .init(kind: Self.fileSystemCategory(volume), mount: volume.mountState.rawValue,
                         connection: Self.connectionCategory(volume.deviceProtocol), size: Self.sizeRange(volume.totalBytes),
                         disk: (groups.firstIndex(of: volume.deviceGroup) ?? 0) + 1)
        }
        self.nativeMount = nativeMount
        self.appVersion = appVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.diskServiceRunning = diskServiceRunning
        let external = volumes.filter(\.isExternal)
        externalVolumeCount = external.count
        fileSystemCounts = Dictionary(grouping: external, by: { Self.fileSystemCategory($0) }).mapValues(\.count)
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

    /// "Mac15,7 · arm64": the model identifier, never the serial number.
    public static func macModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #if arch(arm64)
        return model + " · arm64"
        #else
        // The Intel build: on an Intel Mac, or forced through Rosetta on Apple silicon.
        var translated: Int32 = 0, length = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &length, nil, 0) == 0 && translated == 1
        return model + (rosetta ? " · x86_64 · Rosetta" : " · x86_64")
        #endif
    }

    static func sizeRange(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "unknown" }
        switch Double(bytes) / 1e9 {
        case ..<64: return "<64 GB"
        case ..<512: return "64–512 GB"
        case ..<2200: return "0.5–2 TB"
        default: return ">2 TB"
        }
    }

    private static func connectionCategory(_ value: String?) -> String {
        guard let value else { return "unknown" }
        return ["USB", "Thunderbolt", "PCI-Express", "PCI", "Secure Digital", "SATA", "FireWire", "Virtual Interface", "Disk Image"]
            .contains(value) ? value : "other"
    }

    private static func fileSystemCategory(_ volume: VolumeSnapshot) -> String {
        // NTFS that another driver mounted: name it, or the report says only "other".
        if let foreign = volume.foreignDriver { return "ntfs-by-" + foreign.kind }
        let value = volume.fileSystem.lowercased()
        return ["ntfs", "volisle", "apfs", "hfs", "hfs+", "exfat", "msdos", "fat", "fat32", VolumeSnapshot.unrecognizedWindowsKind]
            .contains(value) ? value : "other"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
        return (lines + details).joined(separator: "\n") + "\n"
    }

    /// The sections added in format 4, each only when it was collected.
    private var details: [String] {
        let none = String(localized: "无")
        let summary = { (op: OperationSummary) in
            [op.purpose, op.phase, op.failure.map { "failure=" + $0 }, op.recoveryFailure.map { "recovery=" + $0 }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        var lines: [String] = []
        if let mac { lines.append(String(localized: "Mac：\(mac)")) }
        if let helper {
            let access = helper.fullDiskAccess.map { $0 ? String(localized: "已允许") : String(localized: "未允许") } ?? String(localized: "未知")
            lines.append(String(localized: "后台组件：\(helper.state)，完全磁盘访问：\(access)，安装包校验：\(helper.packageVerified ? "ok" : "failed")"))
            if let launchd = helper.launchd { lines.append(String(localized: "后台服务（launchd）：\(launchd)")) }
        }
        if let automaticWrite { lines.append(String(localized: "自动开启读写：\(automaticWrite ? String(localized: "开") : String(localized: "关"))")) }
        if let lastRefusal { lines.append(String(localized: "上次被拒绝的操作：\(summary(lastRefusal))")) }
        if let volumes {
            lines.append("")
            lines.append(String(localized: "—— 外接卷 ——"))
            if volumes.isEmpty { lines.append(none) }
            for (index, volume) in volumes.enumerated() {
                let disk = volume.disk.map { String(localized: "盘\($0)") + " · " } ?? ""
                lines.append("#\(index + 1) \(disk)\(volume.kind) · \(volume.mount) · \(volume.connection) · \(volume.size)")
            }
            if let diskErrors, !diskErrors.isEmpty {
                lines.append("")
                lines.append(String(localized: "—— 硬盘报告的读写错误（最近 24 小时）——"))
                for (index, found) in diskErrors.enumerated() {
                    let members = volumes.enumerated().filter { $0.element.disk == index + 1 }.map { "#\($0.offset + 1)" }
                    let text = found.map { summary in
                        summary.isEmpty ? String(localized: "无读写错误")
                            : String(localized: "介质错误 \(summary.medium) 次（\(summary.places) 处），其他错误 \(summary.other) 次")
                    } ?? String(localized: "无法核对")
                    lines.append(String(localized: "盘\(index + 1)（\(members.joined(separator: "、"))）：\(text)"))
                }
            }
        }
        if let history {
            lines.append("")
            lines.append(String(localized: "—— 最近的磁盘操作（新的在前）——"))
            if history.isEmpty { lines.append(none) }
            for item in history {
                let parts = [item.purpose, item.phase, item.failure.map { "failure=" + $0 }, item.recoveryFailure.map { "recovery=" + $0 }]
                lines.append(Self.stamp(item.time, seconds: false) + " " + parts.compactMap { $0 }.joined(separator: " · "))
            }
        }
        if events != nil || eventsNote != nil {
            lines.append("")
            lines.append(String(localized: "—— 最近 24 小时的运行记录（已去掉路径、名称和标识）——"))
            if let eventsNote { lines.append(eventsNote) }
            for event in events ?? [] {
                let source = ["app": "App", "helper": String(localized: "后台"), "extension": String(localized: "扩展")][event.source] ?? event.source
                let level = event.level == "notice" ? "" : " " + event.level.uppercased()
                let repeats = event.repeats.map { " ×\($0)" } ?? ""
                lines.append("\(Self.stamp(event.time, seconds: true)) [\(source)\(level)] \(event.message)\(repeats)")
            }
        }
        return lines
    }

    private static func stamp(_ date: Date, seconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = seconds ? "MM-dd HH:mm:ss" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
