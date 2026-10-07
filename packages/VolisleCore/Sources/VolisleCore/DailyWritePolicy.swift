import Foundation

/// A signed build choice, never an IPC parameter or a user-editable preference.
struct DailyWritePolicy: Codable {
    let schema: Int
    let mode: String
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 else { throw HelperDiskFailure.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.mode == "external-usb-ntfs" else { throw HelperDiskFailure.invalidRequest }
        return value
    }
    static func exists(in bundle: Bundle) throws -> Bool {
        let file = bundle.bundleURL.appendingPathComponent("Contents/Resources/DailyWritePolicy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        _ = try decode(Data(contentsOf: file))
        return true
    }
}

/// Why this NTFS volume is not opened for writing, in words for the user.
public struct DailyWriteRefusal: LocalizedError, Equatable, Sendable {
    public let errorDescription: String?
}

public enum DailyWriteAvailability {
    public static var enabled: Bool { (try? DailyWritePolicy.exists(in: .main)) == true }
    /// Nil when writing can be turned on (or the build has no daily writing).
    /// Said instead of a vague "busy" or "not checked yet" for disks the
    /// policy leaves read-only, so the user knows it is the disk, not a fault.
    public static func refusal(_ volume: VolumeSnapshot) -> DailyWriteRefusal? {
        guard enabled, volume.isNTFS, volume.isExternal, !volume.isProtected,
              let media = try? DeviceMetadata.read(volume.bsdName), media.registryID == volume.identity.mediaRegistryID else { return nil }
        let reason: String
        if media.virtual { reason = String(localized: "磁盘映像只能读取，盘屿不为它开启读写。") }
        else if media.writable != true { reason = String(localized: "这块盘处于写保护状态（例如 SD 卡侧面的锁定开关拨到了 Lock），只能读取。") }
        else if media.whole == true { reason = String(localized: "这块盘没有分区表，整块盘直接格式化成了 NTFS，盘屿暂不为这种盘开启读写，可以正常读取。") }
        else if media.internalDevice != false || media.deviceProtocol != "USB" {
            reason = String(localized: "盘屿目前只为通过 USB 连接的硬盘和 U 盘开启读写；雷雳、内置读卡器等连接方式尚未验证，这块盘可以正常读取。")
        } else { return nil }
        return DailyWriteRefusal(errorDescription: reason)
    }
    public static func allows(_ volume: VolumeSnapshot) -> Bool {
        guard enabled, volume.isNTFS, volume.isExternal, !volume.isProtected,
              let media = try? DeviceMetadata.read(volume.bsdName) else { return false }
        return media.registryID == volume.identity.mediaRegistryID && !media.virtual && media.writable == true &&
            HelperDiskPolicy.allows(internalDevice: media.internalDevice, deviceProtocol: media.deviceProtocol, whole: media.whole)
    }
}
