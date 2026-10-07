import Foundation
import CryptoKit
import Darwin

/// A read-only identity request. There is no path, command, mount option or
/// write permission. Registry ID and size must match independently read media.
public struct HelperDiskRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let bsdName: String
    public let registryID: UInt64
    public let byteCount: UInt64
    public init(version: Int = 1, bsdName: String, registryID: UInt64, byteCount: UInt64) throws {
        self.version = version; self.bsdName = bsdName
        self.registryID = registryID; self.byteCount = byteCount
        try validate()
    }
    private func validate() throws {
        let partition = version == 1 && bsdName.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil
        // Version 2 is exclusively the fixed-size, unpartitioned image
        // envelope. Backends must still independently prove virtual ownership.
        let image = version == 2 && byteCount == 67_108_864 && bsdName.range(of: "\\Adisk[0-9]+\\z", options: .regularExpression) != nil
        guard partition || image, bsdName.utf8.count <= 32,
              registryID > 0, byteCount >= 512, byteCount <= UInt64(Int64.max), byteCount % 512 == 0 else {
            throw HelperServiceError.invalidRequest
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidRequest }
        do { let request = try JSONDecoder().decode(Self.self, from: data); try request.validate(); return request }
        catch { throw HelperServiceError.invalidRequest }
    }
}

public struct HelperDiskReport: Codable, Equatable, Sendable {
    public let version: Int
    public let bsdName: String
    public let registryID: UInt64
    public let byteCount: UInt64
    public let bootSHA256: String
    public let effectiveUID: UInt32
    public let writeAccessAvailable: Bool
    public let fileSystemHealthChecked: Bool
    public init(version: Int, bsdName: String, registryID: UInt64, byteCount: UInt64, bootSHA256: String,
                effectiveUID: UInt32, writeAccessAvailable: Bool, fileSystemHealthChecked: Bool) {
        self.version = version; self.bsdName = bsdName; self.registryID = registryID; self.byteCount = byteCount
        self.bootSHA256 = bootSHA256; self.effectiveUID = effectiveUID
        self.writeAccessAvailable = writeAccessAvailable; self.fileSystemHealthChecked = fileSystemHealthChecked
    }
    public static func decode(_ data: Data, matching request: HelperDiskRequest) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.version == request.version, report.bsdName == request.bsdName, report.registryID == request.registryID,
              report.byteCount == request.byteCount, !report.writeAccessAvailable, !report.fileSystemHealthChecked,
              report.bootSHA256.utf8.count == 64,
              report.bootSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HelperServiceError.invalidReply
        }
        return report
    }
}

enum HelperDiskPolicy {
    static func allows(internalDevice: Bool?, deviceProtocol: String?, whole: Bool?) -> Bool {
        internalDevice == false && deviceProtocol == "USB" && whole == false
    }
    static func bootHash(_ data: Data) throws -> String {
        guard data.count == 512, Array(data[3..<11]) == Array("NTFS    ".utf8),
              data[510] == 0x55, data[511] == 0xaa else { throw VolumeError.unsupportedFileSystem }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only the narrow, predefined errors cross XPC; device contents and paths do not.
public enum HelperDiskFailure: String, Codable, Sendable, LocalizedError {
    case invalidRequest, protectedMedia, changedMedia, unavailable, permissionDenied, unsupportedFileSystem, busy
    /// Formatting only writes into partitions whose type already holds NTFS.
    case unsupportedPartition
    /// The Mac-side check found a record it could not read; nothing was changed.
    case checkFoundProblems
    /// The Mac-side check could not read part of the disk (a bad sector, a loose cable).
    case checkReadFailed
    /// The file system component refused writes after its own read-only check.
    case ntfsDirty, windowsHibernated, windowsLogUnclean
    /// BitLocker unlock: not BitLocker, wrong secret, or a form this version cannot read.
    case notBitLocker, bitLockerWrongSecret, bitLockerUnsupported
    /// Turning on writing: the system mount through Volisle's extension failed,
    /// or it succeeded but the extension kept the disk read-only.
    case mountFailed, writeNotEnabled
    /// Unplugged while writing, and the automatic rollback at reconnection did
    /// not go ahead: the disk held something it could not account for (or its
    /// records on this Mac are damaged), or it could not be done just now.
    case interruptedWriteUnverified, interruptedWriteRetry
    /// Authenticated recovery records use a format this version cannot read.
    case interruptedWriteUnsupportedFormat
    /// The disk or card reader reports itself write-protected.
    case writeProtected
    public var errorDescription: String? {
        switch self {
        case .mountFailed: String(localized: "盘屿没能以读写方式挂载这块盘，磁盘仍可只读使用，数据不受影响。请重启 Mac 后重新插入；仍然出现时，请在设置 → 支持中导出诊断并反馈。")
        case .writeNotEnabled: String(localized: "盘屿的文件系统扩展没有为这块盘开启写入，磁盘保持只读，数据不受影响。请确认磁盘或读卡器的写保护开关没有锁上；如果这块盘上次写入时被直接拔掉，请接回 Windows 打开一次，安全弹出后再插回。")
        case .interruptedWriteUnverified: String(localized: "这块盘上次读写时被直接断开。插回后盘屿要先把盘恢复到断开前的一致状态，但恢复前的安全核对没有通过，为保护数据保持只读，没有做任何修改。盘里的文件仍可只读打开和拷出。请在设置 → 支持中导出诊断并反馈；急用时可以接回 Windows 检查磁盘（属性 → 工具 → 检查），安全弹出后再插回。")
        case .interruptedWriteRetry: String(localized: "这块盘上次读写时被直接断开，盘屿这次没能完成恢复，磁盘保持只读，数据不受影响。请拔下后重新插入再试；仍然出现时，请在设置 → 支持中导出诊断并反馈。")
        case .interruptedWriteUnsupportedFormat: String(localized: "这台 Mac 上的写入恢复记录使用了当前盘屿不支持的格式，磁盘保持只读，原记录已保留。请使用支持该记录的盘屿版本恢复；需要帮助时，在设置 → 支持中导出诊断并反馈。")
        case .writeProtected: String(localized: "这块盘处于写保护状态，只能读取。请检查磁盘或读卡器上的写保护（锁定）开关，拨开后重新插入。")
        case .notBitLocker: String(localized: "这个分区不是 BitLocker 加密分区。")
        case .bitLockerWrongSecret: String(localized: "密码或恢复密钥不正确。")
        case .bitLockerUnsupported: String(localized: "暂不支持这块盘的加密方式。盘屿可以打开已完成加密、用密码或恢复密钥保护的 BitLocker 盘（XTS-AES、AES-CBC）；Windows 7 默认的“带扩散器的 AES”不支持，正在加密或解密中的盘请等 Windows 完成后再试。")
        case .invalidRequest: String(localized: "磁盘检查请求无效。")
        case .protectedMedia: String(localized: "仅支持检查外接 USB 磁盘分区。")
        case .changedMedia: String(localized: "磁盘身份已变化，请刷新后重试。")
        case .unavailable: String(localized: "无法核对当前磁盘，请检查连接。")
        case .permissionDenied: String(localized: "系统尚未允许后台组件读取此磁盘。")
        case .unsupportedFileSystem: String(localized: "该分区没有有效的 NTFS 引导标识。")
        case .unsupportedPartition: String(localized: "只能在 Windows 数据分区中写入 NTFS。")
        case .checkFoundProblems: String(localized: "检查发现这块盘的文件记录有问题，没有做任何修改。盘里的文件仍可以只读打开和拷出；要恢复读写，请在 Windows 中检查磁盘（属性 → 工具 → 检查）。")
        case .checkReadFailed: String(localized: "检查时有一部分内容读不出来（可能是坏扇区，或数据线、USB 接口不稳），检查没有完成，没有做任何修改。可以换根数据线或换个接口再试，或在 Windows 中检查磁盘（属性 → 工具 → 检查）。")
        case .busy: String(localized: "磁盘正被其他程序使用，暂时无法完成。请关闭正在使用盘内文件的应用后重试；磁盘仍可正常使用，数据不受影响。")
        case .ntfsDirty: String(localized: "这块盘被标记为需要检查，为保护数据暂时只读。可以点右边的“在 Mac 上检查…”，没有发现问题就会清除标记并开启读写；也可以在 Windows 中检查磁盘（属性 → 工具 → 检查），安全弹出后再插回。")
        case .windowsHibernated: String(localized: "这块盘来自处于休眠或“快速启动”状态的 Windows，为保护数据暂时只读。请在 Windows 中完全关机后再插回。")
        case .windowsLogUnclean: String(localized: "这块盘上次在 Windows 中没有安全弹出，为保护数据暂时只读。请接回 Windows，用“安全删除硬件”弹出后再插回。")
        }
    }
    /// `mount` reports the file system component's refusal on stderr. Only
    /// these fixed reasons are recognized; nothing else from the text crosses XPC.
    static func mountRefusal(_ stderr: String) -> Self? {
        guard let line = stderr.split(separator: "\n").first(where: { $0.contains("Operation ended with error:") }) else { return nil }
        // Reasons the extension tags; the token, not the words around it, decides.
        if line.contains("[journal:unsupportedFormat]") { return .interruptedWriteUnsupportedFormat }
        if line.contains("[journal:foreignChange]") || line.contains("[journal:corrupt]") { return .interruptedWriteUnverified }
        if line.contains("[journal:") { return .interruptedWriteRetry }
        if line.contains("[media:writeProtected]") { return .writeProtected }
        if line.contains("脏标记") { return .ntfsDirty }
        if line.contains("休眠") { return .windowsHibernated }
        if line.contains("日志") { return .windowsLogUnclean }
        return nil
    }
    static func from(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if error as? HelperServiceError == .invalidRequest { return .invalidRequest }
        if let volume = error as? VolumeError {
            switch volume {
            case .protectedVolume: return .protectedMedia
            case .identityChanged, .unstableIdentity: return .changedMedia
            case .unsupportedFileSystem: return .unsupportedFileSystem
            case .busy: return .busy
            default: return .unavailable
            }
        }
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EACCES, .EPERM: return .permissionDenied
            case .EBUSY: return .busy
            default: break
            }
        }
        return .unavailable
    }
}

struct HelperDiskReply: Codable, Sendable {
    let report: HelperDiskReport?
    let failure: HelperDiskFailure?
    static func decode(_ data: Data, matching request: HelperDiskRequest) throws -> HelperDiskReport {
        guard !data.isEmpty, data.count <= 8192 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (value.report == nil) != (value.failure == nil) else { throw HelperServiceError.invalidReply }
        if let failure = value.failure { throw failure }
        return try HelperDiskReport.decode(JSONEncoder().encode(value.report!), matching: request)
    }
}
