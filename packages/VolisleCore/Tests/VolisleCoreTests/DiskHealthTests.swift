import Foundation
import Testing
@testable import VolisleCore

/// The disk's own error reports, from today's kernel log on a failing drive:
/// bad sectors (sense key 3) at two neighbouring addresses, then the drive
/// dropping off the bus. Another disk's errors stay out.
struct DiskHealthTests {
    private let lines: [(time: Date, message: String)] = [
        "[Expansion] I/O error! Opcode 0x28, Service response 0x02, Task status 0x02, Sense Data 0x03, 0x11, 0x00",
        "[Expansion]: I/O error [0xe00002ca] dir 0x1 lba 0x1d763500 count 0x80, retry 1 ...",
        "[Expansion]: I/O error [0xe00002ca] dir 0x1 lba 0x1d763600 count 0x80, retry 1 ...",
        "[Expansion]: I/O error [0xe00002ca] dir 0x1 lba 0x1d763600 count 0x80, retry 2 ...",
        "[Expansion] I/O error! Opcode 0x28, Service response 0x02, Task status 0x02, Sense Data: 0x03, 0x11, 0x00, happened 9 times",
        "[Expansion] I/O error! Opcode 0x28, Service response 0x01, Task status 0x04",
        "[Other Disk] I/O error! Opcode 0x2a, Service response 0x02, Task status 0x02, Sense Data 0x03, 0x0c, 0x00",
        "disk4s3: I/O error.",
    ].enumerated().map { (Date(timeIntervalSince1970: 1_791_000_000 + Double($0.offset)), $0.element) }

    @Test func badSectorsAndOtherErrorsAreToldApart() {
        let summary = DiskHealth.summarize(lines, model: "Expansion")
        #expect(summary.medium == 10, "one, then nine folded into one line")
        #expect(summary.other == 1)
        #expect(summary.places == 2)
        #expect(summary.last == lines[5].time)
        #expect(DiskHealth.summarize(lines, model: "Other Disk").medium == 1)
        #expect(DiskHealth.summarize(lines, model: "Exp").isEmpty, "the bracketed model must match whole")
        #expect(DiskHealth.summarize([], model: "Expansion").isEmpty)
    }

    @Test func theSelfCheckSaysWhichKindOfFailureItIs() {
        func errors(_ state: DiskReadiness.DiskErrors) -> DiskReadiness.Item? {
            DiskReadiness.items(.init(helper: .connected, fullDiskAccess: true, extensionAvailable: true, extensionReason: "",
                                      isNTFS: true, writable: false, diskErrors: state)).first { $0.id == "errors" }
        }
        #expect(errors(.notChecked) == nil)
        #expect(errors(.checking)?.status == .note)
        #expect(errors(.unreadable)?.status == .note)
        #expect(errors(.found(DiskErrorSummary()))?.status == .ok)
        var bad = DiskErrorSummary(); bad.medium = 10; bad.places = 2
        let sectors = errors(.found(bad))
        #expect(sectors?.status == .problem && sectors?.detail.contains("坏道") == true && sectors?.action == .exportDiagnostics)
        var loose = DiskErrorSummary(); loose.other = 3
        let cable = errors(.found(loose))
        #expect(cable?.status == .problem && cable?.detail.contains("数据线") == true && cable?.detail.contains("不是坏道") == true)
    }

    /// Seen in a real report: the three partitions of one failing disk each showed
    /// its errors, as if three disks had failed. Errors are the disk's, listed once.
    @Test func theReportCountsErrorsOncePerPhysicalDiskWithoutNamingIt() throws {
        func volume(_ bsd: String, _ path: String, _ model: String, _ kind: String, _ size: Int64) -> VolumeSnapshot {
            VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: bsd, devicePath: path), bsdName: bsd, name: bsd,
                           fileSystem: kind, deviceName: model, totalBytes: size, availableBytes: 1, mountURL: nil,
                           mountState: .readOnly, isExternal: true, isProtected: false, deviceProtocol: "USB")
        }
        let volumes = [volume("disk7s1", "/usb/a", "Samsung SSD", "apfs", 1_000_000_000_000),
                       volume("disk4s1", "/usb/b", "Expansion", "msdos", 209_000_000),
                       volume("disk4s3", "/usb/b", "Expansion", "ntfs", 2_000_000_000_000)]
        #expect(DiagnosticReport.diskModels(volumes) == ["Samsung SSD", "Expansion"])
        var report = DiagnosticReport(volumes: volumes, diskServiceRunning: true, engine: .init(available: true, finderReadWrite: true, reason: ""))
        var bad = DiskErrorSummary(); bad.medium = 10; bad.places = 2; bad.other = 1
        report.diskErrors = [DiskErrorSummary(), bad]
        let text = report.text
        #expect(text.contains("#3 盘2 · ntfs · readOnly · USB · 0.5–2 TB"))
        #expect(text.contains("盘1（#1）：无读写错误"))
        #expect(text.contains("盘2（#2、#3）：介质错误 10 次（2 处），其他错误 1 次"))
        #expect(text.components(separatedBy: "介质错误 10 次").count == 2, "listed once")
        #expect(!text.contains("Expansion") && !text.contains("Samsung"))
    }
}
