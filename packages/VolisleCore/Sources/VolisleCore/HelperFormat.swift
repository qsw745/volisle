import Foundation
import DiskArbitration
import Darwin
import OSLog

/// The helper's only destructive request: write a new NTFS file system into one
/// unmounted USB partition whose type already holds NTFS. It carries the device
/// identity and a volume name, nothing else; the app confirmed with the user
/// and re-read the disk before asking, and the helper checks the device again.
public struct HelperFormatRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let bsdName: String
    public let registryID: UInt64
    public let byteCount: UInt64
    public let label: String
    public init(bsdName: String, registryID: UInt64, byteCount: UInt64, label: String) throws {
        self.version = 1; self.bsdName = bsdName; self.registryID = registryID
        self.byteCount = byteCount; self.label = label
        try validate()
    }
    private func validate() throws {
        guard version == 1, bsdName.utf8.count <= 32,
              bsdName.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil,
              registryID > 0, byteCount >= 1_048_576, byteCount <= UInt64(Int64.max), byteCount % 512 == 0 else {
            throw HelperServiceError.invalidRequest
        }
        do { try DiskErasePlanner.validate(name: label) } catch { throw HelperServiceError.invalidRequest }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidRequest }
        do { let request = try JSONDecoder().decode(Self.self, from: data); try request.validate(); return request }
        catch { throw HelperServiceError.invalidRequest }
    }
}

struct HelperFormatReply: Codable, Sendable {
    let formatted: Bool
    let failure: HelperDiskFailure?
    static func decode(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.formatted == (value.failure == nil) else { throw HelperServiceError.invalidReply }
        if let failure = value.failure { throw failure }
    }
}

/// What the helper reads about the partition right before formatting.
struct FormatTargetFacts: Equatable, Sendable {
    let registryID: UInt64
    let byteCount: UInt64
    let internalDevice: Bool?
    let deviceProtocol: String?
    let whole: Bool?
    let writable: Bool?
    /// DiskArbitration's media content: a GPT type GUID or an MBR type name.
    let content: String?
    let mounted: Bool
}

enum HelperFormatPolicy {
    /// GPT Microsoft Basic Data and MBR 0x07, the partition types NTFS lives in.
    static let ntfsContents: Set<String> = ["EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Windows_NTFS"]

    static func check(_ facts: FormatTargetFacts, against request: HelperFormatRequest) throws {
        try check(facts, registryID: request.registryID, byteCount: request.byteCount)
    }

    /// `writable: false` for read-only work (BitLocker), which a write-protected disk allows.
    static func check(_ facts: FormatTargetFacts, registryID: UInt64, byteCount: UInt64, writable: Bool = true) throws {
        guard facts.registryID == registryID, facts.byteCount == byteCount else { throw VolumeError.identityChanged }
        guard HelperDiskPolicy.allows(internalDevice: facts.internalDevice, deviceProtocol: facts.deviceProtocol, whole: facts.whole),
              !writable || facts.writable == true else { throw VolumeError.protectedVolume }
        guard let content = facts.content, ntfsContents.contains(content) else { throw HelperDiskFailure.unsupportedPartition }
        guard !facts.mounted else { throw VolumeError.busy }
    }
}

/// Maintenance through an open raw partition. Only the root helper installs
/// one: it alone links the NTFS engine. This goes around FSKit because on
/// macOS 26 a module that declares format options is dropped entirely.
public protocol PartitionMaintenanceEngine: Sendable {
    /// `descriptor` is the verified raw device, open read-write. Throws a
    /// `HelperDiskFailure` on failure; returns once the result is on disk and verified.
    func format(descriptor: Int32, blockSize: Int, byteCount: UInt64, label: String) throws
    /// Clears the NTFS "needs check" marker after a read-only walk of the
    /// whole volume found nothing wrong. Returns the files and folders checked.
    func clearCheckMarker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Int64
    /// `descriptor` is open read-only: whether the partition holds BitLocker.
    func isBitLocker(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> Bool
    /// `descriptor` is open read-only. Unlocks with the user's secret and
    /// returns the volume master key as 64 lowercase hex digits.
    func bitLockerKey(descriptor: Int32, blockSize: Int, byteCount: UInt64, kind: BitLockerSecretKind, secret: String) throws -> String
}

public enum HelperMaintenanceEngine {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var engine: (any PartitionMaintenanceEngine)?
    /// Set once by the helper at launch.
    public static func install(_ engine: any PartitionMaintenanceEngine) { lock.withLock { self.engine = engine } }
    static var current: (any PartitionMaintenanceEngine)? { lock.withLock { engine } }
}

/// Root side. One operation at a time per device, excluded from mount cycles
/// by the process-wide device gate.
enum HelperPartitionFormatter {
    private static let logger = Logger(subsystem: "top.qisw.volisle", category: "format")

    static func format(_ input: HelperFormatRequest) async throws {
        let request = try HelperFormatRequest.decode(JSONEncoder().encode(input))
        let started = Date()
        try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount) {
            engine, descriptor, blockSize in
            try engine.format(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount, label: request.label)
        }
        logger.notice("格式化完成：设备=\(request.bsdName, privacy: .public) 用时=\(Int(Date().timeIntervalSince(started)), privacy: .public)s")
    }

    static func clearCheckMarker(_ input: HelperDiskRequest) async throws -> Int64 {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard request.version == 1 else { throw HelperServiceError.invalidRequest }
        let started = Date()
        let items = try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount) {
            engine, descriptor, blockSize in
            try engine.clearCheckMarker(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount)
        }
        logger.notice("检查标记已清除：设备=\(request.bsdName, privacy: .public) 项目=\(items, privacy: .public) 用时=\(Int(Date().timeIntervalSince(started)), privacy: .public)s")
        return items
    }

    static func withVerifiedPartition<T: Sendable>(_ bsdName: String, registryID: UInt64, byteCount: UInt64, writable: Bool = true,
        _ body: @escaping @Sendable (any PartitionMaintenanceEngine, Int32, Int) throws -> T) async throws -> T {
        let lease = try DeviceOperationGate.shared.acquire(bsdName)
        defer { DeviceOperationGate.shared.release(lease) }
        return try await openVerifiedPartition(bsdName, registryID: registryID, byteCount: byteCount, writable: writable, body)
    }

    /// Identity, USB, partition type and "unmounted" are checked before the raw
    /// node is opened and again after, so the node belongs to this partition.
    /// The caller holds the device gate.
    static func openVerifiedPartition<T: Sendable>(_ bsdName: String, registryID: UInt64, byteCount: UInt64, writable: Bool,
        _ body: @escaping @Sendable (any PartitionMaintenanceEngine, Int32, Int) throws -> T) async throws -> T {
        guard geteuid() == 0, let engine = HelperMaintenanceEngine.current else { throw HelperDiskFailure.unavailable }
        let before = try facts(bsdName)
        try HelperFormatPolicy.check(before.facts, registryID: registryID, byteCount: byteCount, writable: writable)
        let path = "/dev/r" + bsdName
        let descriptor = Darwin.open(path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        // The node we opened must still be this partition, and still unmounted.
        var held = Darwin.stat(), named = Darwin.stat()
        guard fstat(descriptor, &held) == 0, held.st_mode & S_IFMT == S_IFCHR,
              lstat(path, &named) == 0, named.st_mode & S_IFMT == S_IFCHR, named.st_rdev == held.st_rdev else {
            throw VolumeError.identityChanged
        }
        try HelperFormatPolicy.check(try facts(bsdName).facts, registryID: registryID, byteCount: byteCount, writable: writable)
        let blockSize = before.blockSize
        return try await Task.detached { try body(engine, descriptor, blockSize) }.value
    }

    private static func facts(_ bsdName: String) throws -> (facts: FormatTargetFacts, blockSize: Int) {
        let metadata = try DeviceMetadata.read(bsdName)
        guard let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, bsdName),
              let description = DADiskCopyDescription(disk) as NSDictionary? else { throw VolumeError.disconnected }
        let mounted = try SystemMountRecord.current().contains { $0.source == "/dev/" + bsdName }
        return (FormatTargetFacts(registryID: metadata.registryID, byteCount: metadata.byteCount,
                                  internalDevice: metadata.internalDevice, deviceProtocol: metadata.deviceProtocol,
                                  whole: metadata.whole, writable: metadata.writable,
                                  content: description[kDADiskDescriptionMediaContentKey] as? String, mounted: mounted),
                metadata.blockSize)
    }
}

/// The helper's refusal with its technical reason: a record number and a
/// fixed kind, never a name or content of the disk. Shown under the message so
/// a screenshot of it tells whether the check misjudged the disk.
public struct CheckMarkerRefusal: Error, Equatable, LocalizedError {
    public let failure: HelperDiskFailure
    public let detail: String
    public init?(_ failure: HelperDiskFailure, detail: String?) {
        guard let detail, detail.count <= 120,
              detail.wholeMatch(of: /(inconsistent record [0-9]+: [a-z ,]+|read failed at record [0-9]+)/) != nil else { return nil }
        self.failure = failure; self.detail = detail
    }
    public var errorDescription: String? {
        (failure.errorDescription ?? "") + "\n" + String(localized: "技术信息：\(detail)")
    }
}

struct HelperCheckMarkerReply: Codable, Sendable {
    let items: Int64?
    let failure: HelperDiskFailure?
    var detail: String? = nil
    static func decode(_ data: Data) throws -> Int64 {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (value.items == nil) != (value.failure == nil) else { throw HelperServiceError.invalidReply }
        if let failure = value.failure { throw CheckMarkerRefusal(failure, detail: value.detail) ?? failure }
        guard let items = value.items, items >= 0 else { throw HelperServiceError.invalidReply }
        return items
    }
}

/// App side: identifies the partition independently, then asks the helper.
public enum HelperFormatClient {
    /// Writing NTFS over a whole 2 TB partition takes a while.
    static let timeout: TimeInterval = 600

    public static func format(partition bsdName: String, label: String) async throws {
        let metadata = try DeviceMetadata.read(bsdName)
        let request = try HelperFormatRequest(bsdName: bsdName, registryID: metadata.registryID,
                                              byteCount: metadata.byteCount, label: label)
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        let reply = try await HelperRPC.request(over: connection, timeout: timeout) { proxy, reply in
            proxy.formatPartition(data, reply: reply)
        }
        try HelperFormatReply.decode(reply)
    }
}

public enum HelperCheckMarkerClient {
    /// The read-only walk reads every file record of the volume.
    static let timeout: TimeInterval = 1800

    /// The partition must be unmounted. Returns the files and folders checked.
    public static func clear(partition bsdName: String) async throws -> Int64 {
        let metadata = try DeviceMetadata.read(bsdName)
        let request = try HelperDiskRequest(bsdName: bsdName, registryID: metadata.registryID, byteCount: metadata.byteCount)
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        let reply = try await HelperRPC.request(over: connection, timeout: timeout) { proxy, reply in
            proxy.clearCheckMarker(data, reply: reply)
        }
        return try HelperCheckMarkerReply.decode(reply)
    }
}
