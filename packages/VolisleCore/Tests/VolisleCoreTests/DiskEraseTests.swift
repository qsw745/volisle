import Foundation
import Testing
@testable import VolisleCore

private func info(isInternal: Bool = false, bus: String = "USB", physical: Bool = true, name: String = "Expansion",
                  size: Int64 = 2_000_398_933_504) -> [String: Any] {
    ["WholeDisk": true, "Internal": isInternal, "BusProtocol": bus, "VirtualOrPhysical": physical ? "Physical" : "Virtual",
     "MediaName": name, "IORegistryEntryName": name + " Media", "Size": NSNumber(value: size), "DeviceBlockSize": NSNumber(value: 512)]
}

private func partition(_ id: String, _ content: String, name: String? = nil, mount: String? = nil, size: Int64 = 1_000_000) -> [String: Any] {
    var p: [String: Any] = ["DeviceIdentifier": id, "Content": content, "Size": NSNumber(value: size)]
    if let name { p["VolumeName"] = name }
    if let mount { p["MountPoint"] = mount }
    return p
}

/// Mirrors this development Mac: internal system disk, the qsw USB NTFS disk,
/// and an external USB APFS work disk whose Data volume is mounted.
private var list: [String: Any] { ["AllDisksAndPartitions": [
    ["DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme", "Partitions": [partition("disk0s2", "Apple_APFS")]],
    ["DeviceIdentifier": "disk3", "APFSPhysicalStores": [["DeviceIdentifier": "disk0s2"]],
     "APFSVolumes": [["DeviceIdentifier": "disk3s1s1", "VolumeName": "Macintosh HD", "MountPoint": "/"]]],
    ["DeviceIdentifier": "disk4", "Content": "FDisk_partition_scheme", "Partitions": [partition("disk4s1", "Windows_NTFS", name: "qsw", mount: "/Volumes/qsw")]],
    ["DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme", "Partitions": [partition("disk6s1", "EFI", name: "EFI"), partition("disk6s2", "Apple_APFS")]],
    ["DeviceIdentifier": "disk7", "APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"]],
     "APFSVolumes": [["DeviceIdentifier": "disk7s1", "VolumeName": "Data", "MountPoint": "/Volumes/Data"]]],
    ["DeviceIdentifier": "disk11", "Content": "GUID_partition_scheme", "Partitions": [partition("disk11s1", "Microsoft Basic Data", name: "IMG")]],
    ["DeviceIdentifier": "disk12", "Content": "GUID_partition_scheme", "Partitions": [partition("disk12s1", "Microsoft Basic Data", name: "TB")]],
    ["DeviceIdentifier": "disk13", "Content": "GUID_partition_scheme", "Partitions": [partition("disk13s1", "EFI", name: "EFI"), partition("disk13s2", "Apple_APFS")]],
    ["DeviceIdentifier": "disk14", "APFSPhysicalStores": [["DeviceIdentifier": "disk13s2"]],
     "APFSVolumes": [["DeviceIdentifier": "disk14s1", "VolumeName": "Old Backup"]]],
]] }

private var infos: [String: [String: Any]] { [
    "disk0": info(isInternal: true, bus: "Apple Fabric", name: "APPLE SSD"),
    "disk4": info(),
    "disk6": info(name: "Samsung SSD 980", size: 1_000_204_886_016),
    "disk11": info(bus: "Virtual Interface", physical: false, name: "Disk Image"),
    "disk12": info(bus: "Thunderbolt", name: "TB Drive"),
    "disk13": info(name: "Backup Drive"),
] }

private func targets() -> [String: EraseTarget] {
    Dictionary(uniqueKeysWithValues: DiskErasePlanner.catalog(list: list, info: { infos[$0] }).map { ($0.bsdName, $0) })
}

@Test("只有外接 USB 物理盘可抹掉；内置、虚拟、非 USB、挂着 Mac 卷的盘都被拒绝")
func catalogRules() {
    let t = targets()
    #expect(t["disk4"]?.isEligible == true)
    #expect(t["disk0"]?.refusal == .internalDisk)
    #expect(t["disk6"]?.refusal == .macVolumeMounted(["Data"]))
    #expect(t["disk11"]?.refusal == .virtualDisk)
    #expect(t["disk12"]?.refusal == .notUSB)
    #expect(t["disk13"]?.isEligible == true)
    #expect(t["disk3"] == nil && t["disk7"] == nil, "合成的 APFS 容器不是可抹掉目标")
}

@Test("Mac 格式内容需要输入卷名确认；NTFS 盘不需要")
func confirmationRules() throws {
    let t = targets()
    let backup = try #require(t["disk13"])
    #expect(backup.hasMacContent)
    #expect(DiskErasePlanner.confirmationName(target: backup, scope: .wholeDisk(.gpt)) == "Backup Drive")
    let qsw = try #require(t["disk4"])
    #expect(DiskErasePlanner.confirmationName(target: qsw, scope: .wholeDisk(.mbr)) == nil)
    #expect(DiskErasePlanner.confirmationName(target: qsw, scope: .partition("disk4s1")) == nil)
    #expect(backup.partitions.first { $0.bsdName == "disk13s1" }?.isSelectable == false, "EFI 分区不可单独抹掉")
}

@Test("卷名遵循 Windows 规则", arguments: [
    ("", EraseNameError.empty), ("   ", .empty), (String(repeating: "A", count: 33), .tooLong), ("a/b", .invalidCharacter),
    ("a:b", .invalidCharacter), ("a\"b", .invalidCharacter), ("a\u{7}b", .invalidCharacter),
])
func invalidNames(name: String, error: EraseNameError) {
    #expect(throws: error) { try DiskErasePlanner.validate(name: name) }
}

@Test("32 个中文字符和普通名称可用")
func validNames() throws {
    try DiskErasePlanner.validate(name: String(repeating: "盘", count: 32))
    try DiskErasePlanner.validate(name: "My Drive 2026")
}

/// `list` with disk4's entry replaced, as after a layout step.
private func withDisk4(_ partitions: [[String: Any]], content: String) -> [String: Any] {
    var entries = list["AllDisksAndPartitions"] as! [[String: Any]]
    entries[2] = ["DeviceIdentifier": "disk4", "Content": content, "Partitions": partitions]
    return ["AllDisksAndPartitions": entries]
}

private var gptLaidOut: [String: Any] {
    withDisk4([partition("disk4s1", "EFI", name: "EFI"), partition("disk4s2", "Microsoft Basic Data")], content: "GUID_partition_scheme")
}

@Test("建分区命令：一个不格式化、不挂载的 Windows 数据分区")
func arguments() throws {
    let qsw = try #require(targets()["disk4"])
    #expect(DiskErasePlanner.layoutArguments(target: qsw, scheme: .gpt) == ["partitionDisk", "disk4", "1", "GPT", "%Windows_NTFS%", "%noformat%", "100%"])
    #expect(DiskErasePlanner.layoutArguments(target: qsw, scheme: .mbr) == ["partitionDisk", "disk4", "1", "MBR", "%Windows_NTFS%", "%noformat%", "100%"])
}

@Test("建分区后只认唯一的数据分区")
func dataPartition() {
    let gpt = DiskErasePlanner.catalog(list: gptLaidOut, info: { infos[$0] }).first { $0.bsdName == "disk4" }!
    #expect(DiskErasePlanner.dataPartition(of: gpt, scope: .wholeDisk(.gpt)) == "disk4s2")
    #expect(DiskErasePlanner.dataPartition(of: gpt, scope: .partition("disk4s1")) == nil, "EFI 不是数据分区")
    let two = withDisk4([partition("disk4s1", "Windows_NTFS"), partition("disk4s2", "Windows_NTFS")], content: "FDisk_partition_scheme")
    let twoTarget = DiskErasePlanner.catalog(list: two, info: { infos[$0] }).first { $0.bsdName == "disk4" }!
    #expect(DiskErasePlanner.dataPartition(of: twoTarget, scope: .wholeDisk(.mbr)) == nil)
    #expect(DiskErasePlanner.dataPartition(of: twoTarget, scope: .partition("disk4s2")) == "disk4s2")
    let fat = ErasePartition(bsdName: "disk4s1", name: nil, content: "DOS_FAT_32", size: 1, mountPoint: nil)
    #expect(!fat.isSelectable, "单分区不改分区类型，MBR FAT 分区要整盘抹掉")
}

private final class FakeRunner: EraseCommandRunner, @unchecked Sendable {
    var list: [String: Any]
    var afterLayout: [String: Any]?
    var calls: [[String]] = []
    var layoutStatus: Int32 = 0
    var formatStatus: Int32 = 0
    var unmountStatus: Int32 = 0
    init(list: [String: Any], afterLayout: [String: Any]? = nil) { self.list = list; self.afterLayout = afterLayout }
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        calls.append(arguments)
        switch arguments.first {
        case "list": return (0, xml(list))
        case "info": return infos[arguments[2]].map { (0, xml($0)) } ?? (1, "")
        case "partitionDisk":
            if layoutStatus == 0, let afterLayout { list = afterLayout }
            return (layoutStatus, layoutStatus == 0 ? "Finished partitioning" : "Error: busy")
        case "unmount": return (unmountStatus, unmountStatus == 0 ? "unmounted" : "failed to unmount: dissented by mdsync")
        default: return (0, "")
        }
    }
    /// Stands in for the root helper; recorded like a newfs_fskit call.
    func format(_ partition: String, _ label: String) throws {
        calls.append(["-t", "volisle", "-v", label, "/dev/" + partition])
        if formatStatus != 0 { throw HelperDiskFailure.unavailable }
    }
    var erased: Bool { calls.contains { $0.first == "partitionDisk" } }
    var formatted: Bool { calls.contains { $0.first == "-t" } }
    private func xml(_ object: [String: Any]) -> String {
        String(decoding: try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
    }
}

@MainActor private func makeEraser(_ runner: FakeRunner) -> DiskEraser {
    DiskEraser(runner: runner, unmountRetryDelay: .zero, formatPartition: { try runner.format($0, $1) })
}

@MainActor @Test("整盘：重新核对、结束读写、建分区、写入 NTFS、挂载")
func eraseSucceeds() async throws {
    let runner = FakeRunner(list: list, afterLayout: gptLaidOut)
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    var prepared = false
    try await eraser.erase(qsw, scope: .wholeDisk(.gpt), name: "测试", typedConfirmation: "") { prepared = true }
    #expect(prepared)
    let steps = runner.calls.filter { !["list", "info"].contains($0.first ?? "") }
    #expect(steps == [["partitionDisk", "disk4", "1", "GPT", "%Windows_NTFS%", "%noformat%", "100%"],
                      ["-t", "volisle", "-v", "测试", "/dev/disk4s2"], ["mount", "disk4s2"]])
}

@MainActor @Test("单分区：保留分区类型，先卸载再写入 NTFS")
func erasePartition() async throws {
    let runner = FakeRunner(list: list)
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    try await eraser.erase(qsw, scope: .partition("disk4s1"), name: "单分区", typedConfirmation: "") {}
    let steps = runner.calls.filter { !["list", "info"].contains($0.first ?? "") }
    #expect(steps == [["unmount", "disk4s1"], ["-t", "volisle", "-v", "单分区", "/dev/disk4s1"], ["mount", "disk4s1"]])
}

@MainActor @Test("单分区卸载一直失败：重试 3 次后放弃，未写入任何内容")
func erasePartitionUnmountFails() async throws {
    let runner = FakeRunner(list: list)
    runner.unmountStatus = 1
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    await #expect(throws: EraseError.failed("failed to unmount: dissented by mdsync")) {
        try await eraser.erase(qsw, scope: .partition("disk4s1"), name: "X", typedConfirmation: "") {}
    }
    #expect(runner.calls.filter { $0.first == "unmount" }.count == 3)
    #expect(!runner.erased && !runner.formatted)
}

@MainActor @Test("磁盘变化、被拒绝、确认名不符、结束读写失败时都不会发出抹掉命令")
func eraseRefusesWithoutErasing() async throws {
    let runner = FakeRunner(list: list)
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    let work = try #require(eraser.targets.first { $0.bsdName == "disk6" })
    let backup = try #require(eraser.targets.first { $0.bsdName == "disk13" })

    await #expect(throws: EraseError.refused(.macVolumeMounted(["Data"]))) {
        try await eraser.erase(work, scope: .wholeDisk(.gpt), name: "X", typedConfirmation: "Samsung SSD 980") {}
    }
    await #expect(throws: EraseError.confirmationMismatch) {
        try await eraser.erase(backup, scope: .wholeDisk(.gpt), name: "X", typedConfirmation: "backup drive") {}
    }
    await #expect(throws: EraseError.invalidName(.tooLong)) {
        try await eraser.erase(qsw, scope: .wholeDisk(.gpt), name: String(repeating: "A", count: 40), typedConfirmation: "") {}
    }
    struct Busy: Error {}
    await #expect(throws: EraseError.failed(Busy().localizedDescription)) {
        try await eraser.erase(qsw, scope: .wholeDisk(.gpt), name: "X", typedConfirmation: "") { throw Busy() }
    }
    // Another disk now answers to disk4 (different layout): refuse.
    runner.list = withDisk4([partition("disk4s1", "Microsoft Basic Data", size: 5)], content: "GUID_partition_scheme")
    await #expect(throws: EraseError.changed) {
        try await eraser.erase(qsw, scope: .wholeDisk(.gpt), name: "X", typedConfirmation: "") {}
    }
    #expect(!runner.erased && !runner.formatted)
}

@MainActor @Test("建分区失败时报告最后一行输出，且不写入 NTFS")
func eraseReportsLayoutFailure() async throws {
    let runner = FakeRunner(list: list)
    runner.layoutStatus = 1
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    await #expect(throws: EraseError.failed("Error: busy")) {
        try await eraser.erase(qsw, scope: .wholeDisk(.mbr), name: "X", typedConfirmation: "") {}
    }
    #expect(!runner.formatted)
}

@MainActor @Test("建分区后布局不对或换了一块盘：不写入 NTFS")
func eraseRefusesUnexpectedLayout() async throws {
    let twoData = withDisk4([partition("disk4s1", "Windows_NTFS"), partition("disk4s2", "Windows_NTFS")], content: "FDisk_partition_scheme")
    var otherDisk = gptLaidOut
    var entries = otherDisk["AllDisksAndPartitions"] as! [[String: Any]]
    entries.remove(at: 2)
    otherDisk["AllDisksAndPartitions"] = entries
    for after in [twoData, otherDisk] {
        let runner = FakeRunner(list: list, afterLayout: after)
        let eraser = makeEraser(runner)
        await eraser.refresh()
        let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
        await #expect(throws: EraseError.formatFailed("找不到刚建立的分区")) {
            try await eraser.erase(qsw, scope: .wholeDisk(.mbr), name: "X", typedConfirmation: "") {}
        }
        #expect(runner.erased && !runner.formatted)
    }
}

@MainActor @Test("写入 NTFS 失败：说明磁盘已是 exFAT，可重试")
func eraseReportsFormatFailure() async throws {
    let runner = FakeRunner(list: list, afterLayout: gptLaidOut)
    runner.formatStatus = 5
    let eraser = makeEraser(runner)
    await eraser.refresh()
    let qsw = try #require(eraser.targets.first { $0.bsdName == "disk4" })
    await #expect(throws: EraseError.formatFailed(HelperDiskFailure.unavailable.errorDescription!)) {
        try await eraser.erase(qsw, scope: .wholeDisk(.gpt), name: "X", typedConfirmation: "") {}
    }
    #expect(!runner.calls.contains(["mount", "disk4s2"]))
}
