import Foundation
import Darwin
import Testing
@testable import VolisleCore

@Suite struct VisibleWriteMountTests {
    func savedOperation(name: String = "希捷 2T") throws -> HelperMountOperation {
        let disk = try HelperDiskRequest(version: 1, bsdName: "disk8s2", registryID: 42, byteCount: 1 << 30)
        let operation = HelperMountOperation(id: UUID(), disk: disk, ownerUID: 501,
            bootSession: UUID().uuidString, phase: .queued, restoreRequired: true, purpose: .readWrite)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any])
        json["writeLocation"] = ["name": name, "device": 1, "inode": 2]
        return try JSONDecoder().decode(HelperMountOperation.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func savedVisibleLocationIsUsedByMountCommandAfterRestart() throws {
        let operation = try savedOperation()
        let args = SystemHelperWriteMountBackend.mountArguments(for: operation, option: "volisle-rw", asOwner: false)
        #expect(args.last == "/Volumes/希捷 2T")
        #expect(args.contains("volisle-rw,nosuid,nodev"))
        let copy = try JSONDecoder().decode(HelperMountOperation.self, from: JSONEncoder().encode(operation))
        #expect(SystemHelperWriteMountBackend.mountArguments(for: copy, option: "volisle-rw", asOwner: false).last == "/Volumes/希捷 2T")
    }

    @Test func savedLocationsCannotEscapeVolumesOrUseHiddenNames() throws {
        for name in ["", ".", "..", ".hidden", "../other", "one/two", "one\0two", "one\ntwo", String(repeating: "a", count: 256)] {
            let operation = try savedOperation(name: name)
            #expect(throws: (any Error).self) { try operation.validate() }
        }
    }

    @Test func visibleAndLegacyMountsUseExactDeviceAndRejectAmbiguity() throws {
        let operation = try savedOperation(), location = try #require(operation.writeLocation)
        let id = operation.id, device = "/dev/disk8s2", path = "/Volumes/希捷 2T"
        func record(_ path: String, source: String = "/dev/disk8s2", type: String = "volisle", flags: UInt32 = 0) -> SystemMountRecord {
            .init(source: source, path: path, type: type, flags: flags)
        }
        #expect(try FSKitMountPoint.writePath(id, device: device, records: [record(path)], location: location) == path)
        #expect(try FSKitMountPoint.writePath(id, device: device, records: [], location: location) == path)
        for records in [[record(path, source: "/dev/disk9s2")], [record(path, type: "apfs")],
                        [record(path), record(FSKitMountPoint.write.path(id))], [record("/Volumes/other")]] {
            #expect(throws: HelperDiskFailure.busy) {
                try FSKitMountPoint.writePath(id, device: device, records: records, location: location)
            }
        }
        let native = record(path, type: "ntfs", flags: UInt32(MNT_RDONLY))
        #expect(SystemHelperWriteMountBackend.nativeRestoreIsGoal([native], operation: operation))
        #expect(!SystemHelperWriteMountBackend.nativeRestoreIsGoal([record(path)], operation: operation))
        #expect(!SystemHelperWriteMountBackend.nativeRestoreIsGoal([record(path, source: "/dev/disk9s2", type: "ntfs", flags: UInt32(MNT_RDONLY))], operation: operation))
        #expect(throws: HelperDiskFailure.busy) { try FSKitMountPoint.writePath(id, device: device, records: [native], location: location) }
        #expect(try FSKitMountPoint.writePath(id, device: device, records: [native], location: location, allowRestoredNative: true) == path)
        #expect(throws: HelperDiskFailure.busy) {
            try FSKitMountPoint.writePath(id, device: device, records: [record(path, type: "ntfs")], location: location, allowRestoredNative: true)
        }
    }

    func directory(_ body: (VisibleWriteMountDirectory, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visible-mount-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(.init(root: root, rootOwner: getuid()), root)
    }

    @Test func reservesVolumeLabelAndSkipsExistingDirectoriesSymlinksAndMounts() throws {
        try directory { directory, root in
            try FileManager.default.createDirectory(atPath: root + "/希捷 2T", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: root + "/希捷 2T 1", withDestinationPath: "/tmp")
            let location = try directory.reserve(label: "希捷 2T", owner: getuid(), mounted: [root + "/希捷 2T 2"])
            #expect(location.name == "希捷 2T 3")
            try directory.verify(location, owner: getuid(), mounted: [])
            try directory.remove(location, owner: getuid(), mounted: [])
            #expect(!FileManager.default.fileExists(atPath: root + "/希捷 2T 3"))
            #expect(FileManager.default.fileExists(atPath: root + "/希捷 2T"))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/希捷 2T 1") == "/tmp")
        }
    }

    @Test func cleanupRefusesReplacementBusyAndNonemptyDirectories() throws {
        try directory { directory, root in
            let location = try directory.reserve(label: "测试盘", owner: getuid(), mounted: [])
            let path = root + "/测试盘"
            #expect(throws: (any Error).self) { try directory.remove(location, owner: getuid(), mounted: [path]) }
            try Data([1]).write(to: URL(filePath: path + "/keep"))
            #expect(throws: (any Error).self) { try directory.remove(location, owner: getuid(), mounted: []) }
            try FileManager.default.moveItem(atPath: path, toPath: root + "/original")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            #expect(throws: (any Error).self) { try directory.verify(location, owner: getuid(), mounted: []) }
            #expect(throws: (any Error).self) { try directory.remove(location, owner: getuid(), mounted: []) }
            #expect(FileManager.default.fileExists(atPath: root + "/original/keep"))
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func unsafeParentIsRejectedAndInvalidLabelsGetVisibleSingleComponents() throws {
        try directory { directory, root in
            for label in [nil, "", ".", "..", ".hidden", "one/two", "line\nbreak", String(repeating: "盘", count: 200)] as [String?] {
                let location = try directory.reserve(label: label, owner: getuid(), mounted: [])
                #expect(HelperWriteMountLocation.validName(location.name))
                try directory.remove(location, owner: getuid(), mounted: [])
            }
            #expect(chmod(root, 0o777) == 0)
            #expect(throws: (any Error).self) { try directory.reserve(label: "盘", owner: getuid(), mounted: []) }
        }
    }
}
