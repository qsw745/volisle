import Foundation
import Darwin
import Testing
@testable import VolisleCore

@Suite struct FSKitMountPointTests {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let device = "/dev/disk8s2"
    func record(_ path: String, source: String = "/dev/disk8s2", type: String = "volisle") -> SystemMountRecord {
        .init(source: source, path: path, type: type, flags: UInt32(MNT_NOSUID | MNT_NODEV))
    }
    @Test func newMountsUseVolumesAndOldMountsKeepTheirActualPath() throws {
        #expect(FSKitMountPoint.write.path(id) == "/Volumes/.volisle-write-mounts/" + id.uuidString.lowercased())
        #expect(BitLockerMountPoint.root == "/Volumes/.volisle-bitlocker")
        for base in ["/Volumes/.volisle-write-mounts", "/private/var/run/volisle-write-mounts", "/var/run/volisle-write-mounts"] {
            let path = base + "/" + id.uuidString.lowercased()
            #expect(try FSKitMountPoint.writePath(id, device: device, records: [record(path)]) == path)
        }
        #expect(try FSKitMountPoint.writePath(id, device: device, records: []) == FSKitMountPoint.write.path(id))
        #expect(try FSKitMountPoint.writePath(id, device: device, records: [record("/Volumes/NTFS", type: "ntfs")]) == FSKitMountPoint.write.path(id))
    }
    @Test func ambiguousForeignAndUnrecognizedMountsAreRejected() {
        let new = FSKitMountPoint.write.path(id)
        let old = "/private/var/run/volisle-write-mounts/" + id.uuidString.lowercased()
        for records in [[record(new), record(old)], [record(new, source: "/dev/disk9s2")],
                        [record(new, type: "apfs")], [record("/Volumes/unrelated")]] {
            #expect(throws: HelperDiskFailure.busy) { try FSKitMountPoint.writePath(id, device: device, records: records) }
        }
    }
    @Test func bitLockerOldAndNewPathsRemainSeparateAndStrict() {
        for base in ["/Volumes/.volisle-bitlocker", "/private/var/run/volisle-bitlocker", "/var/run/volisle-bitlocker"] {
            let path = base + "/" + id.uuidString.lowercased()
            #expect(BitLockerMountPoint.owns(path))
            #expect(BitLockerMountPoint.canonicalPath(path)?.hasPrefix(base == "/var/run/volisle-bitlocker" ? "/private/var/run/" : base) == true)
            for bad in [path + "/child", path + "/..", path.uppercased(), base + "/../other", path + "/"] {
                #expect(!BitLockerMountPoint.owns(bad))
            }
        }
        #expect(!BitLockerMountPoint.owns(FSKitMountPoint.write.path(id)))
    }
    @Test func mountCommandUsesNewRootWithoutChangingIdentityOrSafetyFlags() throws {
        let disk = try HelperDiskRequest(version: 1, bsdName: "disk8s2", registryID: 42, byteCount: 1 << 30)
        let operation = HelperMountOperation(id: id, disk: disk, ownerUID: 501, bootSession: UUID().uuidString,
                                            phase: .mountingWrite, restoreRequired: true, purpose: .readWrite)
        let args = SystemHelperWriteMountBackend.mountArguments(for: operation, option: "volisle-rw", asOwner: false)
        #expect(args.last == FSKitMountPoint.write.path(id))
        #expect(args.contains("volisle-rw,nosuid,nodev"))
        #expect(Array(args.prefix(2)) == ["asuser", "501"])
    }
    @Test func bitLockerPendingMarkersStayBesideTheActualOldOrNewMount() throws {
        let name = id.uuidString.lowercased()
        for base in ["/Volumes/.volisle-bitlocker", "/private/var/run/volisle-bitlocker", "/var/run/volisle-bitlocker"] {
            let pending = try BitLockerMountPoint.pendingMount(base + "/" + name)
            let expected = base == "/var/run/volisle-bitlocker" ? "/private/var/run/volisle-bitlocker" : base
            #expect(pending.parent == expected)
            #expect(pending.marker == expected + "/.pending-" + name)
        }
    }
}

@Suite struct HelperMountDirectoryTests {
    @Test func legacyRootOwnedByRootWithDaemonGroupRemainsTrusted() {
        var info = stat()
        info.st_mode = mode_t(S_IFDIR) | 0o711; info.st_uid = 0; info.st_gid = 1
        #expect(HelperMountDirectory.trustedRoot(info, owner: 0))
        info.st_uid = 501
        #expect(!HelperMountDirectory.trustedRoot(info, owner: 0))
        info.st_uid = 0; info.st_mode = mode_t(S_IFDIR) | 0o771
        #expect(!HelperMountDirectory.trustedRoot(info, owner: 0))
    }
    func fixture(_ body: (HelperMountDirectory, String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mount-directory-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/root"
        try body(HelperMountDirectory(root: root, rootOwner: getuid()), root)
    }
    @Test func createsRestrictedRootAndLeafAndOnlyRemovesEmptyLeaves() throws {
        try fixture { directory, root in
            try directory.prepare()
            var info = stat()
            #expect(lstat(root, &info) == 0 && info.st_mode & 0o7777 == 0o711)
            let id = UUID(), leaf = root + "/" + id.uuidString.lowercased()
            try directory.createLeaf(id, owner: getuid(), mounted: [])
            #expect(lstat(leaf, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o7777 == 0o700)
            // An empty leftover for this exact operation can be reused after a failed start.
            try directory.createLeaf(id, owner: getuid(), mounted: [])
            let file = leaf + "/keep.txt"
            try Data("不要删除".utf8).write(to: URL(filePath: file))
            #expect(throws: (any Error).self) { try directory.removeLeaf(id, owner: getuid(), mounted: []) }
            #expect(FileManager.default.fileExists(atPath: file))
        }
    }
    @Test func refusesSymlinkRootsLeavesAndUnsafePermissions() throws {
        try fixture { directory, root in
            try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: "/tmp")
            #expect(throws: (any Error).self) { try directory.prepare() }
            try FileManager.default.removeItem(atPath: root)
            try directory.prepare()
            #expect(throws: (any Error).self) { try HelperMountDirectory(root: root, rootOwner: .max).prepare() }
            let id = UUID(), leaf = root + "/" + id.uuidString.lowercased()
            try FileManager.default.createSymbolicLink(atPath: leaf, withDestinationPath: "/tmp")
            #expect(throws: (any Error).self) { try directory.createLeaf(id, owner: getuid(), mounted: []) }
            #expect(throws: (any Error).self) { try directory.removeLeaf(id, owner: getuid(), mounted: []) }
            try FileManager.default.removeItem(atPath: leaf)
            try directory.createLeaf(id, owner: getuid(), mounted: [])
            #expect(chmod(leaf, 0o755) == 0)
            #expect(throws: (any Error).self) { try directory.removeLeaf(id, owner: getuid(), mounted: []) }
            #expect(chmod(root, 0o777) == 0)
            #expect(throws: (any Error).self) { try directory.prepare() }
            #expect(chmod(root, 0o1711) == 0)
            #expect(throws: (any Error).self) { try directory.prepare() }
        }
    }
    @Test func cleanupPreservesActiveRecentNonemptyAndNonUUIDEntries() throws {
        try fixture { directory, root in
            try directory.prepare()
            let stale = UUID(), active = UUID(), nonempty = UUID(), recent = UUID()
            for id in [stale, active, nonempty, recent] { try directory.createLeaf(id, owner: getuid(), mounted: []) }
            let path: (UUID) -> String = { root + "/" + $0.uuidString.lowercased() }
            try Data([1]).write(to: URL(filePath: path(nonempty) + "/keep"))
            try FileManager.default.createDirectory(atPath: root + "/other", withIntermediateDirectories: false)
            // Future clock makes entries old; first preserve all while they are recent.
            try directory.prune(owner: getuid(), mounted: [], now: time(nil))
            #expect(FileManager.default.fileExists(atPath: path(recent)))
            try directory.prune(owner: getuid(), mounted: [path(active)], now: time(nil) + 1000)
            #expect(!FileManager.default.fileExists(atPath: path(stale)))
            #expect(FileManager.default.fileExists(atPath: path(active)))
            #expect(FileManager.default.fileExists(atPath: path(nonempty) + "/keep"))
            #expect(FileManager.default.fileExists(atPath: root + "/other"))
            #expect(throws: (any Error).self) { try directory.createLeaf(active, owner: getuid(), mounted: [path(active)]) }
            #expect(throws: (any Error).self) { try directory.removeLeaf(active, owner: getuid(), mounted: [path(active)]) }
        }
    }
}
