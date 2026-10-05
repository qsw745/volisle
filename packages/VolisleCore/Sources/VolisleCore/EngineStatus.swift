import Foundation
import Observation

/// 产品自身适配器的能力，不扫描或借用第三方已安装驱动。
@MainActor @Observable
public final class EngineStatus {
    public private(set) var capability = EngineCapability(available: false, finderReadWrite: false, reason: String(localized: "尚未检查产品引擎。"))
    public private(set) var isChecking = false
    public private(set) var checkedAt: Date?
    private let engine: any FileSystemAdapter

    public init(engine: any FileSystemAdapter) { self.engine = engine }

    public func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let result = await engine.capability()
        guard !Task.isCancelled else { return }
        capability = result
        checkedAt = Date()
    }

    public var title: String {
        if isChecking { return String(localized: "正在检查") }
        guard checkedAt != nil else { return String(localized: "尚未检查") }
        if !capability.available { return String(localized: "不可用") }
        return capability.finderReadWrite ? String(localized: "具备读写能力") : String(localized: "读写不可用")
    }
}
