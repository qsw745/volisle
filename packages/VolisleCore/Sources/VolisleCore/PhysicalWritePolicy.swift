import Foundation
import Darwin

/// Signed laboratory scope, never supplied by an XPC client. Expiry stops new
/// activation but must not strand an already mounted volume during recovery.
struct PhysicalWritePolicy: Codable, Sendable {
    let schema: Int
    let ownerUID: UInt32
    let bsdName: String
    let registryID: UInt64
    let byteCount: UInt64
    let bootSession: String
    let bootSHA256: String
    let option: String
    let root: String
    let expiresAt: TimeInterval
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperDiskFailure.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try HelperDiskRequest(bsdName: value.bsdName, registryID: value.registryID, byteCount: value.byteCount)
        guard value.schema == 1, value.ownerUID != 0, value.ownerUID != .max,
              UUID(uuidString: value.bootSession) != nil, value.expiresAt.isFinite,
              value.root.range(of: "\\A/Volisle-Test-[0-9]{8}-[0-9a-f]{32}\\z", options: .regularExpression) != nil,
              value.option == "volisle-test-" + value.root.suffix(32),
              value.bootSHA256.count == 64,
              value.bootSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HelperDiskFailure.invalidRequest
        }
        return value
    }
    func allows(_ disk: HelperDiskRequest, owner: UInt32, boot: String, now: TimeInterval, restoring: Bool) -> Bool {
        disk.version == 1 && disk.bsdName == bsdName && disk.registryID == registryID && disk.byteCount == byteCount &&
        owner == ownerUID && boot == bootSession && now.isFinite &&
        (restoring || (now < expiresAt && expiresAt - now <= 7200))
    }
    static func load(_ bundle: Bundle) throws -> Self {
        try decode(Data(contentsOf: bundle.bundleURL.appendingPathComponent("Contents/Resources/PhysicalWritePolicy.json")))
    }
    static func installed() throws -> Self { try load(WriteFixturePolicy.installedBundle()) }
}

/// UI availability is scoped to the selected connection. It never changes the
/// ordinary engine's global capability or enables automatic mounting.
public enum PhysicalWriteAvailability {
    public static func testDirectory(for volume: VolumeSnapshot) -> String? {
        guard let policy = try? PhysicalWritePolicy.load(.main),
              let metadata = try? DeviceMetadata.read(volume.bsdName),
              let boot = try? SystemHelperMountService.currentBootSession() else { return nil }
        return directory(for: volume, metadata: metadata, policy: policy, owner: geteuid(), boot: boot, now: Date().timeIntervalSince1970)
    }
    static func directory(for volume: VolumeSnapshot, metadata: DeviceMetadata, policy: PhysicalWritePolicy,
                          owner: UInt32, boot: String, now: TimeInterval) -> String? {
        // totalBytes is statfs capacity for mounted volumes, not partition size.
        guard volume.isExternal, !volume.isProtected, volume.isNTFS,
              metadata.registryID == volume.identity.mediaRegistryID, !metadata.virtual, metadata.writable == true,
              HelperDiskPolicy.allows(internalDevice: metadata.internalDevice, deviceProtocol: metadata.deviceProtocol, whole: metadata.whole),
              let disk = try? HelperDiskRequest(bsdName: volume.bsdName, registryID: metadata.registryID, byteCount: metadata.byteCount),
              policy.allows(disk, owner: owner, boot: boot, now: now, restoring: false) else { return nil }
        // The backend independently validates the signed package and live disk.
        return policy.root
    }
}
