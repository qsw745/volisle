import Foundation
import Security

/// Fixed identities for the website's Developer ID build. Signature and
/// package validation reject builds that do not match these identities.
public enum HelperIdentity {
    public static let team = "6N5T3G6H33"
    public static let application = "top.qisw.volisle"
    public static let service = "top.qisw.volisle.mount-helper"
    public static let plistName = service + ".plist"
    public static let executablePath = "Contents/Library/LaunchServices/VolisleMountHelper"
    public enum Peer { case application, service }
    public static func requirement(for peer: Peer) -> String {
        let identifier = peer == .application ? application : service
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and " +
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(identifier)\" and " +
            "!(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }
    public static func acceptsClient(uid: UInt32, auditSession: UInt32) -> Bool {
        uid != 0 && uid != .max && auditSession != 0 && auditSession != .max
    }
}

/// Status, USB partition inspection, mount cycles, formatting one checked USB
/// partition as NTFS, clearing its "needs check" marker after a read-only
/// walk, and unlocking a BitLocker partition read-only. No arbitrary path,
/// command or mount flags; requests are a device identity (plus a volume name
/// for formatting, or the user's BitLocker password or recovery key).
@objc public protocol VolisleHelperProtocol {
    func status(reply: @escaping @Sendable (Data) -> Void)
    func mountCycle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func inspectDisk(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func formatPartition(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func clearCheckMarker(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func bitLocker(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serviceIdentifier: String
    public let effectiveUID: UInt32
    public let writeAccessAvailable: Bool
    /// Whether the system lets the helper read disks (Full Disk Access for 盘屿).
    /// Absent from older helpers.
    public let fullDiskAccess: Bool?
    public init(protocolVersion: Int, serviceIdentifier: String, effectiveUID: UInt32, writeAccessAvailable: Bool,
                fullDiskAccess: Bool? = nil) {
        self.protocolVersion = protocolVersion; self.serviceIdentifier = serviceIdentifier
        self.effectiveUID = effectiveUID; self.writeAccessAvailable = writeAccessAvailable
        self.fullDiskAccess = fullDiskAccess
    }
    /// Run by the helper itself, the process that needs the permission: the
    /// system's privacy database opens only with Full Disk Access. Nothing is read.
    static func probeFullDiskAccess(path: String = "/Library/Application Support/com.apple.TCC/TCC.db") -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let status = try JSONDecoder().decode(Self.self, from: data)
        guard status.protocolVersion == 1, status.serviceIdentifier == HelperIdentity.service,
              !status.writeAccessAvailable else { throw HelperServiceError.invalidReply }
        return status
    }
    public func validateSystemService() throws {
        guard effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
    }
}

public enum HelperServiceError: Error, Equatable, LocalizedError, Sendable {
    case unavailable, invalidReply, invalidRequest, wrongPrivileges, timedOut, untrustedPackage
    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "后台组件暂时无法连接，请检查系统授权。")
        case .invalidReply: String(localized: "后台组件版本或响应不匹配，请使用配套安装包。")
        case .invalidRequest: String(localized: "后台组件请求无效。")
        case .wrongPrivileges: String(localized: "连接的组件没有系统服务权限。")
        case .timedOut: String(localized: "后台组件响应超时，请稍后检查。")
        case .untrustedPackage: String(localized: "请使用包含后台组件的完整签名安装版。")
        }
    }
}

/// Public for the separate integration runner; callers still need to validate
/// the returned privilege state. A decoded status is never write permission.
public enum HelperRPC {
    public static func status(over connection: NSXPCConnection) async throws -> HelperStatus {
        try HelperStatus.decode(await request(over: connection) { proxy, reply in proxy.status(reply: reply) })
    }
    public static func inspectDisk(_ request: HelperDiskRequest, over connection: NSXPCConnection) async throws -> HelperDiskReport {
        let data = try JSONEncoder().encode(request)
        _ = try HelperDiskRequest.decode(data)
        let response = try await self.request(over: connection) { proxy, reply in proxy.inspectDisk(data, reply: reply) }
        return try HelperDiskReply.decode(response, matching: request)
    }
    public static func inspectSystemDisk(_ request: HelperDiskRequest) async throws -> HelperDiskReport {
        let report = try await inspectDisk(request, over: NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged))
        guard report.effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
        return report
    }
    static func request(over connection: NSXPCConnection, timeout: TimeInterval = 5,
        send: (any VolisleHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingHelperReply(connection: connection, continuation: continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: VolisleHelperProtocol.self)
            connection.setCodeSigningRequirement(HelperIdentity.requirement(for: .service))
            connection.invalidationHandler = { pending.finish(.failure(HelperServiceError.unavailable)) }
            connection.interruptionHandler = { pending.finish(.failure(HelperServiceError.unavailable)) }
            connection.activate()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                pending.finish(.failure(HelperServiceError.timedOut))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                pending.finish(.failure(HelperServiceError.unavailable))
            }) as? VolisleHelperProtocol else {
                pending.finish(.failure(HelperServiceError.unavailable)); return
            }
            send(proxy) { data in
                guard data.count <= 8192 else { pending.finish(.failure(HelperServiceError.invalidReply)); return }
                pending.finish(.success(data))
            }
        }
    }
    public static func systemStatus() async throws -> HelperStatus {
        let status = try await status(over: NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged))
        try status.validateSystemService()
        return status
    }
}

private final class PendingHelperReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<Data, any Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func finish(_ result: Result<Data, any Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let pending else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        pending.resume(with: result)
    }
}

/// Shared by the root daemon and the separate nonprivileged integration host.
/// NSXPC enforces the exact client signature before invoking exported methods.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard HelperIdentity.acceptsClient(uid: connection.effectiveUserIdentifier,
                                           auditSession: UInt32(bitPattern: connection.auditSessionIdentifier)) else { return false }
        connection.setCodeSigningRequirement(HelperIdentity.requirement(for: .application))
        connection.exportedInterface = NSXPCInterface(with: VolisleHelperProtocol.self)
        connection.exportedObject = HelperStatusEndpoint(uid: connection.effectiveUserIdentifier)
        connection.activate()
        return true
    }
}

private final class HelperStatusEndpoint: NSObject, VolisleHelperProtocol {
    private let uid: UInt32
    init(uid: UInt32) { self.uid = uid }
    func mountCycle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let uid = self.uid
        Task {
            let result: HelperMountReply
            do {
                let command = try HelperMountCommand.decode(request)
                let service = try SystemHelperMountService.shared()
                let operation: HelperMountOperation?
                switch command.action {
                case .start: operation = try await service.start(id: command.id!, disk: command.disk!, uid: uid)
                case .startWrite: operation = try await service.startWrite(id: command.id!, disk: command.disk!, uid: uid)
                case .status: operation = try await service.status(id: command.id!, uid: uid)
                case .recover: operation = try await service.recover(id: command.id!, uid: uid)
                case .resolve, .resolveWrite:
                    operation = try await service.resolve(id: command.id!, disk: command.disk!, uid: uid, write: command.action == .resolveWrite)
                case .latest: operation = try await service.latest(uid: uid)
                case .quiesce: try await service.quiesce(); operation = nil
                case .resume: await service.resume(); operation = nil
                }
                let resolved: HelperMountReceipt? = operation == nil && [.resolve, .resolveWrite].contains(command.action)
                    ? .init(id: command.id!, disk: command.disk!, ownerUID: uid, write: command.action == .resolveWrite) : nil
                result = .init(operation: operation, failure: nil, resolved: resolved)
            } catch { result = .init(operation: nil, failure: .from(error)) }
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
    func formatPartition(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            let result: HelperFormatReply
            do {
                try await HelperPartitionFormatter.format(HelperFormatRequest.decode(request))
                result = .init(formatted: true, failure: nil)
            } catch { result = .init(formatted: false, failure: .from(error)) }
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
    func clearCheckMarker(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            let result: HelperCheckMarkerReply
            do {
                result = .init(items: try await HelperPartitionFormatter.clearCheckMarker(HelperDiskRequest.decode(request)), failure: nil)
            } catch let refusal as CheckMarkerRefusal {
                result = .init(items: nil, failure: refusal.failure, detail: refusal.detail)
            } catch { result = .init(items: nil, failure: .from(error)) }
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
    func bitLocker(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let uid = self.uid
        Task {
            let result: HelperBitLockerReply
            do {
                let decoded = try HelperBitLockerRequest.decode(request)
                if decoded.kind == nil {
                    result = .init(isBitLocker: try await HelperBitLockerService.probe(decoded), mountPath: nil, failure: nil)
                } else {
                    let mounted = try await HelperBitLockerService.unlock(decoded, uid: uid)
                    result = .init(isBitLocker: nil, mountPath: mounted.path, failure: nil, writable: mounted.writable,
                                   readOnlyReason: mounted.reason)
                }
            } catch { result = .init(isBitLocker: nil, mountPath: nil, failure: .from(error)) }
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
    func inspectDisk(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let result: HelperDiskReply
        do { result = .init(report: try HelperDiskInspector.inspect(HelperDiskRequest.decode(request)), failure: nil) }
        catch { result = .init(report: nil, failure: .from(error)) }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }
    func status(reply: @escaping @Sendable (Data) -> Void) {
        let status = HelperStatus(protocolVersion: 1, serviceIdentifier: HelperIdentity.service,
                                  effectiveUID: geteuid(), writeAccessAvailable: false,
                                  fullDiskAccess: HelperStatus.probeFullDiskAccess())
        reply((try? JSONEncoder().encode(status)) ?? Data())
    }
}
