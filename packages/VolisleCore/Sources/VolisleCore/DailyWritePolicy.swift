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

public enum DailyWriteAvailability {
    public static var enabled: Bool { (try? DailyWritePolicy.exists(in: .main)) == true }
    public static func allows(_ volume: VolumeSnapshot) -> Bool {
        guard enabled, volume.isNTFS, volume.isExternal, !volume.isProtected,
              let media = try? DeviceMetadata.read(volume.bsdName) else { return false }
        return media.registryID == volume.identity.mediaRegistryID && !media.virtual && media.writable == true &&
            HelperDiskPolicy.allows(internalDevice: media.internalDevice, deviceProtocol: media.deviceProtocol, whole: media.whole)
    }
}
