import Testing
import Foundation
@testable import VolisleCore

/// An NTFS disk another driver mounted (TT NTFS, macFUSE with NTFS-3G…) used to
/// count as "other": not listed, never written, and nothing said why.
struct ForeignNTFSDriverTests {
    private let basicData = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

    @Test func appleAndVolisleMountsAreNotForeign() {
        // Both report Disk Arbitration's kind "ntfs", ours even while write-mounted.
        #expect(ForeignNTFSDriver.detect(volumeKind: "ntfs", mountedType: "ntfs", mediaContent: basicData) == nil)
        #expect(ForeignNTFSDriver.detect(volumeKind: "ntfs", mountedType: "volisle", mediaContent: basicData) == nil)
    }

    @Test func ntfsDriversAreNamedByTheirKind() {
        // TT NTFS reports its FSShortName as the kind and "ntfs" to statfs.
        #expect(ForeignNTFSDriver.detect(volumeKind: "ttntfs", mountedType: "ntfs", mediaContent: basicData)?.kind == "ttntfs")
        #expect(ForeignNTFSDriver.detect(volumeKind: "ttntfs", mountedType: nil, mediaContent: basicData)?.name == "TT NTFS")
        #expect(ForeignNTFSDriver.detect(volumeKind: "ufsd_NTFS", mountedType: "ufsd_NTFS", mediaContent: "Windows_NTFS")?.name == "Paragon NTFS")
        #expect(ForeignNTFSDriver.detect(volumeKind: nil, mountedType: "tuxera_ntfs", mediaContent: basicData)?.name == "Tuxera NTFS")
    }

    @Test func fuseCountsOnlyOnAWindowsPartition() {
        #expect(ForeignNTFSDriver.detect(volumeKind: "macfuse", mountedType: "macfuse", mediaContent: basicData)?.kind == "macfuse")
        #expect(ForeignNTFSDriver.detect(volumeKind: nil, mountedType: "osxfuse", mediaContent: "Windows_NTFS")?.kind == "osxfuse")
        // A FUSE file system on a Linux partition is not an NTFS disk.
        #expect(ForeignNTFSDriver.detect(volumeKind: "macfuse", mountedType: "macfuse",
                                         mediaContent: "0FC63DAF-8483-4772-8E79-3D69D8477DE4") == nil)
    }

    @Test func anyDriverNamedAfterNTFSIsShownByItsOwnName() {
        // xntfs reports its own kind; no list to keep up to date.
        let xntfs = ForeignNTFSDriver.detect(volumeKind: "xntfs", mountedType: "xntfs", mediaContent: nil)
        #expect(xntfs?.kind == "xntfs" && xntfs?.name == "xntfs")
        // Odd characters never reach the screen or the diagnostics.
        #expect(ForeignNTFSDriver.detect(volumeKind: "bad ntfs!", mountedType: nil, mediaContent: nil) == nil)
    }

    @Test func anUnknownDriverReportingNTFSIsStillShown() {
        let other = ForeignNTFSDriver.detect(volumeKind: "somefs", mountedType: "ntfs", mediaContent: basicData)
        #expect(other?.kind == "other")
        #expect(other?.name == "其他 NTFS 工具")
    }

    @Test func otherFileSystemsOnWindowsPartitionsStayOther() {
        #expect(ForeignNTFSDriver.detect(volumeKind: "exfat", mountedType: "exfat", mediaContent: basicData) == nil)
        #expect(ForeignNTFSDriver.detect(volumeKind: "msdos", mountedType: "msdos", mediaContent: basicData) == nil)
        #expect(ForeignNTFSDriver.detect(volumeKind: nil, mountedType: nil, mediaContent: basicData) == nil)
    }

    @Test func theDiskIsShownAsNTFSButNotWritable() {
        let volume = foreignVolume()
        #expect(!volume.isNTFS)
        #expect(volume.displayFileSystem == "NTFS")
        #expect(throws: VolumeError.unsupportedFileSystem) {
            try WritePolicy.validateTarget(expected: volume.identity, current: volume)
        }
    }

    @Test func diagnosticsNameTheDriverInsteadOfOther() {
        let report = DiagnosticReport(volumes: [foreignVolume()], diskServiceRunning: true,
                                      engine: .init(available: true, finderReadWrite: true, reason: ""))
        #expect(report.fileSystemCounts == ["ntfs-by-ttntfs": 1])
        #expect(report.volumes?.first?.kind == "ntfs-by-ttntfs")
    }

    @Test func theSelfCheckSaysWhoMountedItAndHowToHandItOver() {
        let items = DiskReadiness.items(.init(helper: .connected, fullDiskAccess: true, extensionAvailable: true,
                                              extensionReason: "", isNTFS: false, foreignDriver: "TT NTFS", writable: false))
        let disk = items.first { $0.id == "disk" }
        #expect(disk?.status == .problem && disk?.action == .fileSystemExtensions)
        #expect(disk?.detail.contains("TT NTFS") == true)
        #expect(items.last?.action == nil)
    }

    private func foreignVolume() -> VolumeSnapshot {
        VolumeSnapshot(identity: .init(volumeUUID: "V", mediaUUID: "M", devicePath: "/dev/disk4s1", mediaRegistryID: 7),
                       bsdName: "disk4s1", name: "Samsung USB", fileSystem: "ttntfs", deviceName: "Samsung",
                       totalBytes: 128_000_000_000, availableBytes: nil, mountURL: URL(fileURLWithPath: "/Volumes/Samsung USB"),
                       mountState: .readWrite, isExternal: true, isProtected: false, deviceProtocol: "USB",
                       foreignDriver: ForeignNTFSDriver.detect(volumeKind: "ttntfs", mountedType: "ntfs", mediaContent: basicData))
    }
}
