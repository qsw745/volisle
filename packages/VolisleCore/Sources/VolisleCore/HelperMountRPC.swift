import Foundation
import Darwin

public struct HelperMountCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case start, startWrite, status, recover, latest, quiesce, resume, resolve, resolveWrite, list }
    public let action: Action
    public let id: UUID?
    public let disk: HelperDiskRequest?
    public init(action: Action, id: UUID? = nil, disk: HelperDiskRequest? = nil) {
        self.action = action; self.id = id; self.disk = disk
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        switch value.action {
        case .start, .startWrite, .resolve, .resolveWrite:
            guard value.id != nil, let disk = value.disk else { throw HelperServiceError.invalidRequest }
            _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        case .status, .recover:
            guard value.id != nil, value.disk == nil else { throw HelperServiceError.invalidRequest }
        case .latest, .quiesce, .resume, .list:
            guard value.id == nil, value.disk == nil else { throw HelperServiceError.invalidRequest }
        }
        return value
    }
}
struct HelperMountReply: Codable, Sendable {
    let operation: HelperMountOperation?
    let failure: HelperDiskFailure?
    var resolved: HelperMountReceipt? = nil
    /// `list` only: the caller's records, oldest first.
    var operations: [HelperMountOperation]? = nil
}
public extension HelperRPC {
    static func mountCycle(_ command: HelperMountCommand) async throws -> HelperMountOperation? {
        let data = try JSONEncoder().encode(command)
        _ = try HelperMountCommand.decode(data)
        let response = try await request(over: NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)) {
            proxy, reply in proxy.mountCycle(data, reply: reply)
        }
        return try decodeMountReply(response, command: command, uid: geteuid())
    }
    /// The caller's records, oldest first: every unfinished one and the newest finished one.
    public static func mountCycleList() async throws -> [HelperMountOperation] {
        let command = HelperMountCommand(action: .list)
        let data = try JSONEncoder().encode(command)
        let response = try await request(over: NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)) {
            proxy, reply in proxy.mountCycle(data, reply: reply)
        }
        return try decodeMountListReply(response, uid: geteuid())
    }
    internal static func decodeMountListReply(_ response: Data, uid: UInt32) throws -> [HelperMountOperation] {
        guard !response.isEmpty, response.count <= 16_384 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(HelperMountReply.self, from: response)
        if let failure = value.failure {
            guard value.operation == nil, value.resolved == nil, value.operations == nil else { throw HelperServiceError.invalidReply }
            throw failure
        }
        guard value.operation == nil, value.resolved == nil, let records = value.operations,
              records.count <= HelperMountCycleService.maximumActive + 1,
              Set(records.map(\.id)).count == records.count else { throw HelperServiceError.invalidReply }
        for record in records {
            try record.validate()
            guard record.ownerUID == uid else { throw HelperServiceError.invalidReply }
        }
        return records
    }
    internal static func decodeMountReply(_ response: Data, command: HelperMountCommand, uid: UInt32) throws -> HelperMountOperation? {
        guard !response.isEmpty, response.count <= 16_384 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(HelperMountReply.self, from: response)
        if let failure = value.failure {
            guard value.operation == nil, value.resolved == nil else { throw HelperServiceError.invalidReply }
            throw failure
        }
        if let receipt = value.resolved {
            try receipt.validate()
            guard value.operation == nil, [.resolve, .resolveWrite].contains(command.action),
                  receipt.id == command.id, receipt.disk == command.disk, receipt.ownerUID == uid,
                  receipt.write == (command.action == .resolveWrite) else { throw HelperServiceError.invalidReply }
            return nil
        }
        guard value.operations == nil, command.action != .list else { throw HelperServiceError.invalidReply }
        guard let record = value.operation else {
            guard [.latest, .quiesce, .resume].contains(command.action) else { throw HelperServiceError.invalidReply }
            return nil
        }
        try record.validate()
        guard record.ownerUID == uid, command.id == nil || record.id == command.id,
              command.disk == nil || record.disk == command.disk else { throw HelperServiceError.invalidReply }
        if [.resolve, .resolveWrite].contains(command.action) {
            guard record.isWrite == (command.action == .resolveWrite) else { throw HelperServiceError.invalidReply }
        }
        return record
    }
}

enum SystemHelperMountService {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var created: HelperMountCycleService?
    // Lazy creation: a nonprivileged integration host cannot instantiate a
    // system transaction service. Nothing mutates disks at helper launch.
    // A failure is not kept: the daemon lives until the Mac restarts, and one
    // failed read of its records (e.g. a full disk at boot) would refuse every
    // later request. Creating it again only repeats the same record checks.
    static func shared() throws -> HelperMountCycleService {
        lock.lock(); defer { lock.unlock() }
        if let created { return created }
        guard geteuid() == 0 else { throw HelperServiceError.wrongPrivileges }
        let service = try HelperMountCycleService(journal: .system(), backend: SystemHelperWriteMountBackend(), bootSession: currentBootSession())
        created = service
        return service
    }
    static func currentBootSession() throws -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        var count = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { throw HelperServiceError.unavailable }
        let boot = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard UUID(uuidString: boot) != nil else { throw HelperServiceError.unavailable }
        return boot
    }
}
