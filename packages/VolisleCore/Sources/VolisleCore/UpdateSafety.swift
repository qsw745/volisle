import Foundation
import Observation

/// An unconfigured channel never makes a network request or claims up-to-date.
public struct UpdateChannel: Sendable {
    public let feed: URL
    public let publicKey: String
    public init(feed: String, publicKey: String) throws {
        guard let parts = URLComponents(string: feed), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url,
              let key = Data(base64Encoded: publicKey), key.count == 32,
              key.contains(where: { $0 != 0 }) else { throw UpdateSafetyError.invalidChannel }
        self.feed = url; self.publicKey = publicKey
    }
}
public enum UpdateSafetyError: Error, LocalizedError {
    case invalidChannel, diskBusy
    public var errorDescription: String? {
        switch self {
        case .invalidChannel: String(localized: "更新通道尚未配置，请等待正式发行版。")
        case .diskBusy: String(localized: "磁盘仍在使用或状态尚未确认。请结束文件操作后重试更新。")
        }
    }
}

/// Held throughout installation preparation and termination. A failed recovery
/// must not silently re-enable hotplug. No disk is forced off by this gate.
@MainActor @Observable public final class UpdateMaintenance {
    public private(set) var blocking = false
    public private(set) var ready = false
    private var preparing = false
    private var barrier: UUID?
    private let gate: DeviceOperationGate
    public init(gate: DeviceOperationGate = .shared) { self.gate = gate }
    public func prepare(settle: () async throws -> Void, stopService: () async throws -> Void,
                        verify: () throws -> Void) async throws {
        guard !preparing else { throw UpdateSafetyError.diskBusy }
        if ready {
            guard !gate.hasOtherOperations(excluding: barrier) else { throw UpdateSafetyError.diskBusy }
            try verify(); return
        }
        preparing = true; blocking = true
        if barrier == nil { barrier = gate.suspendNewOperations() }
        defer { preparing = false }
        try await settle()
        guard !gate.hasOtherOperations(excluding: barrier) else { throw UpdateSafetyError.diskBusy }
        try await stopService()
        try verify()
        guard !gate.hasOtherOperations(excluding: barrier) else { throw UpdateSafetyError.diskBusy }
        ready = true
    }
    public func cancel(restore: () async throws -> Void) async throws {
        guard !preparing else { throw UpdateSafetyError.diskBusy }
        preparing = true
        defer { preparing = false }
        try await restore()
        if let barrier { gate.resumeOperations(barrier) }
        barrier = nil; ready = false; blocking = false
    }
    public static func verifyNoMountedVolumes() throws {
        guard try !SystemMountRecord.current().contains(where: { $0.type == "volisle" }) else {
            throw UpdateSafetyError.diskBusy
        }
    }
}
