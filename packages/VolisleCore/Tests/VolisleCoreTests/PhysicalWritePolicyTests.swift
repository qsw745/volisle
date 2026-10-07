import Foundation
import Testing
@testable import VolisleCore

struct PhysicalWritePolicyTests {
    private func policy() throws -> PhysicalWritePolicy {
        try PhysicalWritePolicy.decode(Data("""
        {"schema":1,"ownerUID":501,"bsdName":"disk7s1","registryID":123,"byteCount":4096,"bootSession":"11111111-1111-1111-1111-111111111111","bootSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","option":"volisle-test-0123456789abcdef0123456789abcdef","root":"/Volisle-Test-20260923-0123456789abcdef0123456789abcdef","expiresAt":10000}
        """.utf8))
    }
    @Test func scopeRequiresOwnerSameBootAndExactMedia() throws {
        let p = try policy(), disk = try HelperDiskRequest(bsdName: "disk7s1", registryID: 123, byteCount: 4096)
        #expect(p.allows(disk, owner: 501, boot: p.bootSession, now: 9999, restoring: false))
        #expect(!p.allows(disk, owner: 502, boot: p.bootSession, now: 9999, restoring: false))
        #expect(!p.allows(disk, owner: 501, boot: "other-boot", now: 9999, restoring: false))
        #expect(!p.allows(try .init(bsdName: "disk7s1", registryID: 124, byteCount: 4096), owner: 501, boot: p.bootSession, now: 9999, restoring: false))
        #expect(!p.allows(disk, owner: 501, boot: p.bootSession, now: 10000, restoring: false))
        #expect(!p.allows(disk, owner: 501, boot: p.bootSession, now: 0, restoring: false))
        #expect(p.allows(disk, owner: 501, boot: p.bootSession, now: 10001, restoring: true))
    }
    @Test func displayedFilesystemCapacityMustNotReplaceMediaSizeInWriteBinding() throws {
        let p = try policy()
        let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb", mediaRegistryID: 123),
            bsdName: "disk7s1", name: "test", fileSystem: "ntfs", deviceName: "USB", totalBytes: 3584,
            availableBytes: 1024, mountURL: URL(filePath: "/Volumes/test"), mountState: .readOnly, isExternal: true, isProtected: false)
        let metadata = DeviceMetadata(registryID: 123, byteCount: 4096, blockSize: 512, internalDevice: false, virtual: false, deviceProtocol: "USB", whole: false, writable: true)
        #expect(PhysicalWriteAvailability.directory(for: volume, metadata: metadata, policy: p, owner: 501, boot: p.bootSession, now: 9999) == p.root)
        let replacement = DeviceMetadata(registryID: 124, byteCount: 4096, blockSize: 512, internalDevice: false, virtual: false, deviceProtocol: "USB", whole: false, writable: true)
        #expect(PhysicalWriteAvailability.directory(for: volume, metadata: replacement, policy: p, owner: 501, boot: p.bootSession, now: 9999) == nil)
    }
    @Test func physicalMountKeepsRootDeviceAccessWhileImageMountDropsPrivileges() throws {
        let physical = HelperMountOperation(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096), ownerUID: 501,
            bootSession: "test", phase: .mountingWrite, restoreRequired: true)
        #expect(!SystemHelperWriteMountBackend.mountsAsOwner(physical, rootFindsModules: true))
        let args = SystemHelperWriteMountBackend.mountArguments(for: physical, option: "volisle-test-token", asOwner: false)
        #expect(Array(args.prefix(3)) == ["asuser", "501", "/sbin/mount"])
        #expect(!args.contains("/usr/bin/sudo"))
        #expect(SystemHelperWriteMountBackend.mountEnvironment(for: physical, asOwner: false)["SUDO_UID"] == "501")
        let image = HelperMountOperation(id: UUID(), disk: try .init(version: 2, bsdName: "disk7", registryID: 123, byteCount: 67108864), ownerUID: 501,
            bootSession: "test", phase: .mountingWrite, restoreRequired: true)
        #expect(SystemHelperWriteMountBackend.mountsAsOwner(image, rootFindsModules: true))
        #expect(Array(SystemHelperWriteMountBackend.mountArguments(for: image, option: "volisle-rw", asOwner: true).prefix(8)) ==
                ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--", "/sbin/mount"])
        #expect(SystemHelperWriteMountBackend.mountEnvironment(for: image, asOwner: true)["SUDO_UID"] == nil)
    }
    /// macOS 15: root's mount(8) does not see the owner's modules, so even a
    /// physical disk mounts as the owner (with the device nodes lent to them).
    @Test func macOS15MountsPhysicalDisksAsTheOwner() throws {
        let physical = HelperMountOperation(id: UUID(), disk: try .init(bsdName: "disk7s1", registryID: 123, byteCount: 4096), ownerUID: 501,
            bootSession: "test", phase: .mountingWrite, restoreRequired: true)
        #expect(SystemHelperWriteMountBackend.mountsAsOwner(physical, rootFindsModules: false))
        let args = SystemHelperWriteMountBackend.mountArguments(for: physical, option: "volisle-test-token", asOwner: true)
        #expect(Array(args.prefix(8)) == ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--", "/sbin/mount"])
        #expect(args.suffix(2).first == "/dev/disk7s1")
        #expect(SystemHelperWriteMountBackend.mountEnvironment(for: physical, asOwner: true)["SUDO_UID"] == nil)
        // Only real device nodes owned by root can be lent.
        #expect(throws: HelperDiskFailure.self) { _ = try SystemHelperWriteMountBackend.DeviceLoan.lend("null", to: 501) }
        #expect(throws: HelperDiskFailure.self) { _ = try SystemHelperWriteMountBackend.DeviceLoan.lend("no-such-disk999", to: 501) }
    }
    @Test func malformedOptionsCannotBecomeMountArguments() throws {
        let data = try JSONEncoder().encode(policy())
        let source = String(decoding: data, as: UTF8.self)
        for bad in [source.replacingOccurrences(of: "volisle-test-", with: "rw,nobrowse,"),
                    source.replacingOccurrences(of: "disk7s1", with: "disk7"),
                    source.replacingOccurrences(of: "Volisle-Test-20260923", with: "../elsewhere"),
                    source.replacingOccurrences(of: "\"ownerUID\":501", with: "\"ownerUID\":0")] {
            #expect(throws: (any Error).self) { _ = try PhysicalWritePolicy.decode(Data(bad.utf8)) }
        }
    }
}
