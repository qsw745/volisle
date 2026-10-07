import Foundation

/// BSD 名称仅在本次连接中定位；连接令牌在消失后永不复用。
public struct VolumeIdentity: Hashable, Sendable, Codable {
    public let volumeUUID: String?
    public let mediaUUID: String?
    public let devicePath: String
    public let connection: UUID
    public let mediaRegistryID: UInt64?
    public let mediaFingerprint: String?
    public init(volumeUUID: String?, mediaUUID: String?, devicePath: String, connection: UUID = UUID(),
                mediaRegistryID: UInt64? = nil, mediaFingerprint: String? = nil) {
        self.volumeUUID = volumeUUID; self.mediaUUID = mediaUUID
        self.devicePath = devicePath; self.connection = connection
        self.mediaRegistryID = mediaRegistryID; self.mediaFingerprint = mediaFingerprint
    }
    public var persistentKey: PersistentVolumeKey? {
        guard let volume = Self.nonempty(volumeUUID) else { return nil }
        if let media = Self.nonempty(mediaUUID) { return .init(volumeUUID: volume.lowercased(), media: "uuid:" + media.lowercased()) }
        guard let fingerprint = mediaFingerprint, fingerprint.hasPrefix("usb-v1:"),
              fingerprint.count == 71, fingerprint.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { return nil }
        return .init(volumeUUID: volume.lowercased(), media: fingerprint)
    }
    public var supportsPersistentPreference: Bool { persistentKey != nil && !devicePath.isEmpty }
    /// Names this partition across reconnections, for copies that continue
    /// after an unplug. macOS reports no volume UUID for NTFS, so the partition's
    /// own GUID comes first, then the USB fingerprint; a volume UUID only if
    /// neither exists. The partition, not the mount: the same either way it is mounted.
    public var resumeKey: String? {
        if let media = Self.nonempty(mediaUUID) { return "media:" + media.lowercased() }
        if let fingerprint = mediaFingerprint, fingerprint.hasPrefix("usb-v1:") { return fingerprint }
        if let volume = Self.nonempty(volumeUUID) { return "volume:" + volume.lowercased() }
        return nil
    }
    public var supportsCurrentOperation: Bool {
        Self.nonempty(volumeUUID) != nil && !devicePath.isEmpty &&
        (Self.nonempty(mediaUUID) != nil || (mediaRegistryID ?? 0) > 0)
    }
    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
public enum MountState: String, Sendable, Codable { case unmounted, readOnly, readWrite, unknown }
public enum SafetyStatus: Equatable, Sendable { case unknown, clean, risk(String) }
public enum OperationState: Equatable, Sendable {
    case idle, authorizing, mounting, unmounting, busy, failed(String), awaitingVerification
}
public struct VolumeSnapshot: Identifiable, Equatable, Sendable {
    public var id: VolumeIdentity { identity }
    public let identity: VolumeIdentity
    public let bsdName: String
    public let name: String
    public let fileSystem: String
    public let deviceName: String
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let mountURL: URL?
    public let mountState: MountState
    public let isExternal: Bool
    public let isProtected: Bool
    public let safety: SafetyStatus
    /// How the device is attached (Disk Arbitration's protocol, e.g. "USB").
    public let deviceProtocol: String?
    /// Another NTFS driver mounted (or claimed) this partition; Volisle leaves it alone.
    public let foreignDriver: ForeignNTFSDriver?
    public init(identity: VolumeIdentity, bsdName: String, name: String, fileSystem: String,
                deviceName: String, totalBytes: Int64?, availableBytes: Int64?, mountURL: URL?,
                mountState: MountState, isExternal: Bool, isProtected: Bool, safety: SafetyStatus = .unknown,
                deviceProtocol: String? = nil, foreignDriver: ForeignNTFSDriver? = nil) {
        self.deviceProtocol = deviceProtocol; self.foreignDriver = foreignDriver
        self.identity = identity; self.bsdName = bsdName; self.name = name; self.fileSystem = fileSystem
        self.deviceName = deviceName; self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.mountURL = mountURL; self.mountState = mountState; self.isExternal = isExternal
        self.isProtected = isProtected; self.safety = safety
    }
    public var isNTFS: Bool { fileSystem.lowercased() == "ntfs" }
    /// What the user knows the disk as: another driver's kind ("ttntfs") is still NTFS.
    public var displayFileSystem: String { foreignDriver == nil ? fileSystem.uppercased() : "NTFS" }
    /// An external Windows data partition in which macOS found no file system:
    /// BitLocker, when the helper confirms it.
    public static let unrecognizedWindowsKind = "windows-unrecognized"
    public var isUnrecognizedWindows: Bool { fileSystem == Self.unrecognizedWindowsKind }
    // 无设备关系时不能将不同磁盘错误合并。
    public var deviceGroup: String { identity.devicePath.isEmpty ? identity.connection.uuidString : identity.devicePath }
}
public enum VolumeError: Error, Equatable, Sendable, LocalizedError {
    case engineUnavailable, unsupportedSystem, unsupportedFileSystem, protectedVolume, identityChanged
    case unstableIdentity, safetyUnknown, unsafeVolume(String), busy, disconnected, mountNotVerified
    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: String(localized: "读写引擎尚未接入并验证，当前版本不能启用 NTFS 读写。")
        case .unsupportedSystem: String(localized: "当前系统不在该引擎已验证的支持范围内。")
        case .unsupportedFileSystem: String(localized: "该操作仅适用于受支持的 NTFS 卷。")
        case .protectedVolume: String(localized: "禁止对系统卷、启动卷或内部磁盘执行此操作。")
        case .identityChanged: String(localized: "磁盘身份已变化，请重新选择当前连接的卷。")
        case .unstableIdentity: String(localized: "缺少可靠的磁盘身份，无法安全执行写入或保存自动挂载设置。")
        case .safetyUnknown: String(localized: "尚未完成休眠、脏标记及日志检查，拒绝启用写入。")
        case .unsafeVolume(let reason): String(localized: "检测到风险：\(reason)")
        case .busy: String(localized: "该物理设备正在操作，请等待完成。")
        case .disconnected: String(localized: "磁盘已断开连接。")
        case .mountNotVerified: String(localized: "尚未确认磁盘已经可读写，请刷新状态。不会自动重试或强制卸载。")
        }
    }
}
public enum WritePolicy {
    /// 引擎检查前只核对目标身份和范围；未知风险必须交给真实引擎检查，不能据此允许写入。
    public static func validateTarget(expected: VolumeIdentity, current: VolumeSnapshot) throws {
        guard expected == current.identity else { throw VolumeError.identityChanged }
        guard current.isExternal && !current.isProtected else { throw VolumeError.protectedVolume }
        guard current.identity.supportsCurrentOperation else { throw VolumeError.unstableIdentity }
        guard current.isNTFS else { throw VolumeError.unsupportedFileSystem }
    }
    public static func validate(expected: VolumeIdentity, current: VolumeSnapshot) throws {
        try validateTarget(expected: expected, current: current)
        switch current.safety {
        case .unknown: throw VolumeError.safetyUnknown
        case .risk(let reason): throw VolumeError.unsafeVolume(reason)
        case .clean: break
        }
    }
}
