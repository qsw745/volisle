import Darwin
import Foundation
import Testing
@testable import VolisleCore

private let point = "/private/var/run/volisle-write-mounts/" + UUID().uuidString.lowercased()
private let safe = UInt32(MNT_NOSUID | MNT_NODEV)

private func record(_ path: String = point, type: String = "volisle", flags: UInt32 = safe) -> SystemMountRecord {
    SystemMountRecord(source: "/dev/disk8s3", path: path, type: type, flags: flags)
}

@Test("读写挂载后的结果：成功、扩展保持只读、挂载没有出现各自归类")
func writeMountOutcome() {
    #expect(SystemHelperWriteMountBackend.writeMountOutcome([record()], path: point) == nil)
    #expect(SystemHelperWriteMountBackend.writeMountOutcome([record(flags: safe | UInt32(MNT_RDONLY))], path: point) == .writeNotEnabled)
    for records in [[], [record("/Volumes/qsw")], [record(type: "ntfs")], [record(flags: 0)], [record(), record()]] {
        #expect(SystemHelperWriteMountBackend.writeMountOutcome(records, path: point) == .mountFailed)
    }
}

@Test("两种新失败各有具体提示，不再落到“无法核对当前磁盘”")
func specificMessages() throws {
    let generic = try #require(HelperDiskFailure.unavailable.errorDescription)
    for failure in [HelperDiskFailure.mountFailed, .writeNotEnabled] {
        let text = try #require(failure.errorDescription)
        #expect(text != generic && text.contains("数据不受影响"))
        #expect(HelperDiskFailure.from(failure) == failure)
        #expect(try JSONDecoder().decode(HelperDiskFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }
}

@Test("诊断报告包含连接方式与上次操作的归类，但不含磁盘标识")
func diagnosticsOperationAndConnection() throws {
    let secret = "PRIVATE-CANARY-不会导出"
    func volume(_ bus: String?) -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: secret, mediaUUID: nil, devicePath: secret), bsdName: secret, name: secret,
              fileSystem: "ntfs", deviceName: secret, totalBytes: nil, availableBytes: nil, mountURL: nil,
              mountState: .readOnly, isExternal: true, isProtected: false, deviceProtocol: bus)
    }
    let disk = try HelperDiskRequest(bsdName: "disk8s3", registryID: 424242, byteCount: 2_000_000_000_000)
    var operation = HelperMountOperation(id: UUID(), disk: disk, ownerUID: 501, bootSession: secret,
                                         phase: .finished, restoreRequired: true)
    operation.purpose = .readWrite
    operation.failure = .mountFailed
    let report = DiagnosticReport(volumes: [volume("USB"), volume("USB"), volume("Secure Digital"), volume(secret), volume(nil)],
                                  diskServiceRunning: true, engine: .init(available: true, finderReadWrite: true, reason: ""),
                                  lastOperation: operation)
    #expect(report.connectionCounts == ["USB": 2, "Secure Digital": 1, "other": 1, "unknown": 1])
    #expect(report.lastOperation == .init(operation))
    #expect(report.text.contains("readWrite · finished · failure=mountFailed"))
    let json = try #require(String(data: try report.jsonData(), encoding: .utf8))
    for output in [report.text, json] {
        #expect(!output.contains(secret) && !output.contains("disk8s3") && !output.contains("424242"))
        #expect(!output.contains(operation.id.uuidString))
    }
    let empty = DiagnosticReport(volumes: [], diskServiceRunning: true, engine: .init(available: true, finderReadWrite: true, reason: ""))
    #expect(empty.lastOperation == nil && empty.text.contains("上次磁盘操作：无"))
}

@Test("刚插入时系统抢着挂上的原生只读副本才算多余；读写挂载、其他磁盘与可写挂载都不碰")
func strayNativeMounts() {
    let native = record("/Volumes/qsw", type: "ntfs", flags: safe | UInt32(MNT_RDONLY))
    let records = [record(), native,
                   record("/Volumes/qsw 1", type: "ntfs", flags: safe),
                   SystemMountRecord(source: "/dev/disk9s1", path: "/Volumes/other", type: "ntfs", flags: safe | UInt32(MNT_RDONLY)),
                   record("/private/tmp/elsewhere")]
    let strays = SystemHelperWriteMountBackend.strayNativeMounts(records, device: "/dev/disk8s3", keeping: point)
    #expect(strays.map(\.path) == ["/Volumes/qsw"])
    #expect(SystemHelperWriteMountBackend.strayNativeMounts([native], device: "/dev/disk8s3", keeping: nil).map(\.path) == ["/Volumes/qsw"])
    #expect(SystemHelperWriteMountBackend.strayNativeMounts([record()], device: "/dev/disk8s3", keeping: point).isEmpty)
}

@Test("等待系统迟到的只读挂载：占用中继续等，只有卸掉后才结束")
func settleWaitsOutBusyNativeMount() {
    #expect(SystemHelperWriteMountBackend.settleDone(after: .removed))
    #expect(!SystemHelperWriteMountBackend.settleDone(after: .busy), "占用中立刻返回会让刚插入的盘开启读写失败")
    #expect(!SystemHelperWriteMountBackend.settleDone(after: .none))
}

@Test("恢复时补挂只读：原来挂着的盘总是补挂；原来没挂的盘只在开启读写失败后补挂")
func restoreMountsNativeAfterFailedStart() throws {
    let disk = try HelperDiskRequest(bsdName: "disk8s3", registryID: 42, byteCount: 2_000_000_000)
    func operation(restoreRequired: Bool, failure: HelperDiskFailure?) -> HelperMountOperation {
        var record = HelperMountOperation(id: UUID(), disk: disk, ownerUID: 501, bootSession: "boot", phase: .restoring,
                                          restoreRequired: restoreRequired)
        record.failure = failure
        return record
    }
    #expect(SystemHelperWriteMountBackend.mountsNativeAfterRestore(operation(restoreRequired: true, failure: nil)))
    #expect(SystemHelperWriteMountBackend.mountsNativeAfterRestore(operation(restoreRequired: false, failure: .mountFailed)))
    #expect(!SystemHelperWriteMountBackend.mountsNativeAfterRestore(operation(restoreRequired: false, failure: nil)),
            "用户结束一次刚插入时开启的读写，不擅自挂回")
}
