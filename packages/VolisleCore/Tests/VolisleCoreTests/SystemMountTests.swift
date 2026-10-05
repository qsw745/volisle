import Foundation
import Testing
import Darwin
@testable import VolisleCore

struct SystemMountTests {
    @Test func virtualInterfaceWithoutVerifiedReadOnlyImageIsNotExternalDisk() {
        #expect(ReadOnlyMediaPolicy.allows(internalDevice: false, virtual: false, verifiedReadOnlyImage: false))
        #expect(ReadOnlyMediaPolicy.allows(internalDevice: nil, virtual: true, verifiedReadOnlyImage: true))
        #expect(!ReadOnlyMediaPolicy.allows(internalDevice: true, virtual: true, verifiedReadOnlyImage: true))
        #expect(!ReadOnlyMediaPolicy.allows(internalDevice: nil, virtual: true, verifiedReadOnlyImage: false))
        #expect(!ReadOnlyMediaPolicy.allows(internalDevice: nil, virtual: false, verifiedReadOnlyImage: true))
        #expect(!ReadOnlyMediaPolicy.allows(internalDevice: nil, virtual: false, verifiedReadOnlyImage: false))
    }
    @Test(arguments: ["", "../disk7s1", "/dev/disk7s1", "rdisk7s1", "disk7s1;id", "disk7s1\n", "disk７s1", "disk1s", "disk1s2s3", "disk-1"])
    func invalidDeviceNameRejectedBeforeOpeningAnything(name: String) {
        #expect(throws: VolumeError.unstableIdentity) {
            _ = try ReadOnlyDeviceBinding(bsdName: name, registryID: 42, byteCount: 67_108_864,
                                         bootSHA256: String(repeating: "a", count: 64))
        }
    }
    @Test func incompleteResourceBindingIsRejected() {
        for (registryID, byteCount, hash) in [(UInt64(0), UInt64(67_108_864), String(repeating: "a", count: 64)),
                                            (42, 0, String(repeating: "a", count: 64)),
                                            (42, 513, String(repeating: "a", count: 64)),
                                            (42, 67_108_864, ""), (42, 67_108_864, String(repeating: "g", count: 64))] {
            #expect(throws: VolumeError.unstableIdentity) {
                _ = try ReadOnlyDeviceBinding(bsdName: "disk999s1", registryID: registryID, byteCount: byteCount, bootSHA256: hash)
            }
        }
    }
    @Test func mountVerificationRequiresExactDeviceTypePathAndSafetyFlags() throws {
        let binding = try ReadOnlyDeviceBinding(bsdName: "disk999s1", registryID: 42, byteCount: 67_108_864,
                                               bootSHA256: String(repeating: "a", count: 64))
        let path = "/private/tmp/volisle-owned-fixture"
        let flags = UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV)
        #expect(SystemMountRecord(source: "/dev/disk999s1", path: path, type: "volisle", flags: flags).verifies(binding, at: path))
        for record in [SystemMountRecord(source: "/dev/disk998s1", path: path, type: "volisle", flags: flags),
                       .init(source: "/dev/disk999s1", path: path + "-other", type: "volisle", flags: flags),
                       .init(source: "/dev/disk999s1", path: path, type: "ntfs", flags: flags),
                       .init(source: "/dev/disk999s1", path: path, type: "volisle", flags: UInt32(MNT_NOSUID | MNT_NODEV)),
                       .init(source: "/dev/disk999s1", path: path, type: "volisle", flags: UInt32(MNT_RDONLY))] {
            #expect(!record.verifies(binding, at: path))
        }
    }
}
