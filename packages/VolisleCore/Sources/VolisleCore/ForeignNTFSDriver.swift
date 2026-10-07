import Foundation

/// Another NTFS driver that mounted this partition: TT NTFS, macFUSE with
/// NTFS-3G, Paragon or Tuxera. Volisle never takes over such a mount; writing,
/// permissions and errors there belong to that driver. The disk is listed with
/// how to hand it to Volisle, instead of passing as "other" and being skipped.
public struct ForeignNTFSDriver: Equatable, Sendable {
    /// A known driver name, or "other": diagnostics never carry free text.
    public let kind: String
    public var name: String { Self.names[kind] ?? String(localized: "其他 NTFS 工具") }

    /// Drivers that only mount NTFS.
    private static let ntfsDrivers: Set<String> = ["ttntfs", "ufsd_ntfs", "tuxera_ntfs", "ntfs-3g"]
    /// FUSE hosts many file systems: it counts only on a Windows partition.
    private static let fuseHosts: Set<String> = ["macfuse", "osxfuse", "fusefs"]
    private static let names: [String: String] = [
        "ttntfs": "TT NTFS", "ufsd_ntfs": "Paragon NTFS", "tuxera_ntfs": "Tuxera NTFS", "ntfs-3g": "NTFS-3G",
        "macfuse": "macFUSE / NTFS-3G", "osxfuse": "macFUSE / NTFS-3G", "fusefs": "macFUSE / NTFS-3G",
    ]

    /// Who answers for this mount, and how to give the disk to Volisle. Eject
    /// first: switching a driver off under its own live mount can leave the
    /// volume stuck; and while both are on, macOS may hand the disk to the other one again.
    public static func handOver(_ driver: String) -> String {
        String(localized: "这块盘现在交给了“\(driver)”，盘屿没有接管它，读写和权限都由“\(driver)”负责。想改用盘屿：先推出这块盘，再到“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”中关掉“\(driver)”（或退出这个工具），然后重新插上。两个工具都开着时，系统可能每次都把盘交给“\(driver)”。")
    }

    /// `volumeKind` is Disk Arbitration's (the FSKit module's short name for
    /// FSKit drivers); `mountedType` is statfs' type name while mounted.
    public static func detect(volumeKind: String?, mountedType: String?, mediaContent: String?) -> Self? {
        let kind = volumeKind?.lowercased(), mounted = mountedType?.lowercased()
        // Apple's driver and Volisle's own mounts both report the kind "ntfs".
        guard kind != "ntfs" else { return nil }
        if let known = [kind, mounted].compactMap({ $0 }).first(where: ntfsDrivers.contains) { return .init(kind: known) }
        guard let mediaContent, HelperFormatPolicy.ntfsContents.contains(mediaContent) else { return nil }
        if let host = [kind, mounted].compactMap({ $0 }).first(where: fuseHosts.contains) { return .init(kind: host) }
        return mounted == "ntfs" ? .init(kind: "other") : nil
    }
}
