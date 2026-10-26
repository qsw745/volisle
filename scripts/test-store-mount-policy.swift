import Foundation

// swiftc -D VOLISLE_STORE -parse-as-library scripts/test-store-mount-policy.swift apps/extension/Sources/StoreMount.swift
@main struct StorePolicyTests {
    static func main() {
        let serial: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        func reason(_ options: [String] = [], writable: Bool = true, serial observed: [UInt8]? = nil,
                    size: UInt64 = 2000396321280, preferReadOnly: Bool = false,
                    disk: StoreDiskPreference? = nil) -> StoreMountPolicy.ReadOnlyReason? {
            StoreMountPolicy.readOnlyReason(options: options, writable: writable, serial: observed ?? serial,
                                            byteCount: size, preferReadOnly: preferReadOnly, disk: disk)
        }
        precondition(reason() == nil, "系统自动挂载不带选项，应可读写")
        precondition(reason(["nobrowse", "noowners"]) == nil, "无关选项不影响读写")
        precondition(reason(["rw"]) == nil, "显式读写应可读写")
        precondition(reason(["rdonly"]) == .requested, "只读选项优先")
        precondition(reason(["nobrowse,ro"]) == .requested, "逗号拼接的只读选项也要识别")
        precondition(reason(["rw", "rdonly"]) == .requested, "读写与只读同时出现时按只读")
        precondition(reason(writable: false) == .writeProtected, "写保护的介质不能读写")
        precondition(reason(["ro"], writable: false) == .requested, "明确要求只读时不报写保护")
        precondition(reason(preferReadOnly: true) == .preference, "用户选了默认只读")
        precondition(reason(["rw"], preferReadOnly: true) == .preference, "系统可能总带 rw，不能盖过用户的只读选择")
        precondition(reason(writable: false, preferReadOnly: true) == .writeProtected, "写保护比偏好更该告诉用户")
        precondition(reason(serial: []) == .unsupported, "没有序列号不能读写")
        precondition(reason(serial: [1, 2, 3, 4, 5, 6, 7]) == .unsupported, "序列号必须是 8 字节")
        precondition(reason(serial: [1, 2, 3, 4, 5, 6, 7, 8, 9]) == .unsupported, "序列号必须是 8 字节")
        precondition(reason(size: 512) == nil, "最小的合法容量")
        precondition(reason(serial: [0, 0, 0, 0, 0, 0, 0, 0]) == .unsupported, "全零序列号不能读写")
        precondition(reason(size: 0) == .unsupported, "容量为零不能读写")
        precondition(reason(size: 1000) == .unsupported, "容量不是扇区整数倍不能读写")
        precondition(reason(size: UInt64(Int64.max) + 513) == .unsupported, "容量超出范围不能读写")

        // One disk's own setting (Pro) replaces the general preference and nothing else.
        precondition(reason(disk: .readOnly) == .diskPreference, "这块盘设成总是只读")
        precondition(reason(["rw"], disk: .readOnly) == .diskPreference, "系统带的 rw 盖不过这块盘的只读")
        precondition(reason(preferReadOnly: true, disk: .readWrite) == nil, "这块盘总是读写，盖过默认只读")
        precondition(reason(preferReadOnly: false, disk: .readOnly) == .diskPreference)
        precondition(reason(["rdonly"], disk: .readWrite) == .requested, "明确要求只读时，总是读写不起作用")
        precondition(reason(writable: false, disk: .readWrite) == .writeProtected, "总是读写盖不过写保护")
        precondition(reason(serial: [], disk: .readWrite) == .unsupported, "总是读写盖不过认不出的盘")
        precondition(reason(size: 1000, disk: .readWrite) == .unsupported)
        precondition(reason(writable: false, disk: .readOnly) == .writeProtected, "写保护比这块盘的设置更该告诉用户")
        precondition(StoreDiskPreference(rawValue: "readOnly") == .readOnly && StoreDiskPreference(rawValue: "readWrite") == .readWrite)
        precondition(StoreDiskPreference(rawValue: "ReadWrite") == nil && StoreDiskPreference(rawValue: "") == nil,
                     "认不出的值等于没设置，回到默认偏好")

        // Recovery writes to the disk: it must not run for a mount that is read-only anyway.
        var calls: [String] = []
        func resolved(_ start: StoreMountPolicy.ReadOnlyReason?, refused: String? = nil, status: Int32 = 0) -> StoreMountPolicy.ReadOnlyReason? {
            calls = []
            return StoreMountPolicy.resolve(start, recover: { calls.append("recover"); return refused },
                                            inspect: { calls.append("inspect"); return status })
        }
        precondition(resolved(nil) == nil && calls == ["recover", "inspect"], "干净的盘：先恢复再预检，然后可读写")
        precondition(resolved(.requested) == .requested && calls.isEmpty, "要求只读时不能为了回滚去写盘")
        precondition(resolved(.preference) == .preference && calls.isEmpty, "默认只读时同样不恢复、不预检")
        precondition(resolved(.diskPreference) == .diskPreference && calls.isEmpty, "这块盘设成只读时同样不恢复、不预检")
        // "Always read-write" only clears the way to recovery and inspection; they can still refuse.
        precondition(resolved(reason(preferReadOnly: true, disk: .readWrite), status: 2) == .inspection(2), "总是读写盖不过休眠检查")
        precondition(resolved(reason(preferReadOnly: true, disk: .readWrite), refused: "busy") == .journal("busy"), "总是读写盖不过恢复失败")
        precondition(resolved(nil, refused: "foreignChange") == .journal("foreignChange") && calls == ["recover"], "恢复没完成就不再预检")
        precondition(resolved(nil, status: 1) == .inspection(1) && calls == ["recover", "inspect"], "预检不干净则只读")
        precondition(resolved(nil, status: 4) == .inspection(4), "未知的预检状态也只读")
        struct Unreadable: Error {}
        do {
            _ = try StoreMountPolicy.resolve(nil, recover: { nil }, inspect: { throw Unreadable() })
            preconditionFailure("预检读不了盘时要把错误交出去")
        } catch {}
        precondition(StoreMountPolicy.ReadOnlyReason.failed.token == "failed")

        // What the app reads back: a stable token per reason.
        precondition(StoreMountPolicy.ReadOnlyReason.requested.token == "requested")
        precondition(StoreMountPolicy.ReadOnlyReason.preference.token == "preference")
        precondition(StoreMountPolicy.ReadOnlyReason.diskPreference.token == "diskPreference")
        precondition(StoreMountPolicy.ReadOnlyReason.writeProtected.token == "writeProtected")
        precondition(StoreMountPolicy.ReadOnlyReason.unsupported.token == "unsupported")
        precondition(StoreMountPolicy.ReadOnlyReason.journal("foreignChange").token == "journal:foreignChange")
        precondition(StoreMountPolicy.ReadOnlyReason.inspection(1).token == "check:dirty")
        precondition(StoreMountPolicy.ReadOnlyReason.inspection(2).token == "check:hibernated")
        precondition(StoreMountPolicy.ReadOnlyReason.inspection(3).token == "check:log")
        precondition(StoreMountPolicy.ReadOnlyReason.inspection(99).token == "check:unknown")
        precondition(StoreMountPolicy.ReadOnlyReason.inspection(-1).token == "check:unknown")

        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let writable = StoreMountStatus.entry(readOnly: nil, bsdName: "disk8s2", at: at)
        precondition(writable["readOnly"] as? Bool == false && writable["reason"] == nil)
        precondition(writable["at"] as? Double == 1_791_000_000 && writable["bsd"] as? String == "disk8s2")
        let refused = StoreMountStatus.entry(readOnly: .inspection(1), bsdName: "disk8s2", at: at)
        precondition(refused["readOnly"] as? Bool == true && refused["reason"] as? String == "check:dirty")

        // The label comes from the disk and names the mount point: nothing in it may act as a path.
        precondition(StoreMountPolicy.mountName(label: "PLAIN") == "PLAIN")
        precondition(StoreMountPolicy.mountName(label: "移动硬盘 2T") == "移动硬盘 2T")
        precondition(StoreMountPolicy.mountName(label: "") == "NTFS", "没有卷标")
        precondition(StoreMountPolicy.mountName(label: "   ") == "NTFS")
        precondition(StoreMountPolicy.mountName(label: "a/b:c") == "a-b-c")
        precondition(StoreMountPolicy.mountName(label: "../../etc") == "..-..-etc")
        precondition(StoreMountPolicy.mountName(label: ".") == "NTFS" && StoreMountPolicy.mountName(label: "..") == "NTFS")
        precondition(StoreMountPolicy.mountName(label: "a\u{0}b\nc\u{7f}d") == "abcd", "控制字符去掉")
        precondition(StoreMountPolicy.mountName(label: "盘\u{FFFD}") == "盘", "截断的字节不留替换符")
        let long = StoreMountPolicy.mountName(label: String(repeating: "盘", count: 200))
        precondition(long.utf8.count <= 96 && long.allSatisfy { $0 == "盘" } && !long.isEmpty, "按整字截短")
        precondition(StoreMountStatus.key(serial: [0xAB, 0x01, 0, 0, 0, 0, 0, 0xFF]) == "MountStatus.ab010000000000ff")
        precondition(StoreMountStatus.diskPreferenceKey(serial: [0xAB, 0x01, 0, 0, 0, 0, 0, 0xFF]) == "DiskPreference.ab010000000000ff")
        precondition(StoreMountStatus.activityKey(serial: [0xAB, 0x01, 0, 0, 0, 0, 0, 0xFF]) == "Activity.ab010000000000ff")

        // Writing: unsaved changes, or a write within the last few seconds.
        precondition(StoreWriteActivity.isWriting(hasUncheckpointedWrites: true, idleSeconds: 60), "还有没做检查点的写入")
        precondition(StoreWriteActivity.isWriting(hasUncheckpointedWrites: false, idleSeconds: 0.5), "刚写过")
        precondition(!StoreWriteActivity.isWriting(hasUncheckpointedWrites: false, idleSeconds: 3), "空闲满 3 秒")
        precondition(!StoreWriteActivity.isWriting(hasUncheckpointedWrites: false, idleSeconds: 600))
        let busy = StoreMountStatus.activityEntry(writing: true, bsdName: "disk8s2", at: at)
        precondition(busy["writing"] as? Bool == true && busy["bsd"] as? String == "disk8s2" && busy["at"] as? Double == 1_791_000_000)
        print("商店版读写策略场景通过；未访问磁盘。")
    }
}
