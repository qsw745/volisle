import Foundation

// swiftc -D VOLISLE_STORE -parse-as-library scripts/test-store-app-status.swift \
//   apps/store/Sources/StoreStatus.swift apps/extension/Sources/StoreMount.swift
@main struct StoreAppStatusTests {
    static func main() {
        // The extension reports serial + "VOLISLE\0" as the volume UUID; the app finds the serial there.
        let ours = UUID(uuidString: "3F872676-B226-7662-564F-4C49534C4500")!
        precondition(StoreVolumeIdentity.serial(volumeUUID: ours)! == [0x3f, 0x87, 0x26, 0x76, 0xb2, 0x26, 0x76, 0x62])
        precondition(StoreVolumeIdentity.serial(volumeUUID: UUID(uuidString: "3F872676-B226-7662-564F-4C49534C4501")!) == nil, "别的模块的卷")
        precondition(StoreVolumeIdentity.serial(volumeUUID: UUID(uuidString: "0E239BC6-F960-3107-89CF-1C97F78BB46B")!) == nil, "系统给的随机标识")
        precondition(StoreMountStatus.key(serial: StoreVolumeIdentity.serial(volumeUUID: ours)!) == "MountStatus.3f872676b2267662",
                     "应用与扩展用同一个键")

        // What the extension writes is what the app reads.
        let mounted = Date(timeIntervalSince1970: 1_791_000_000)
        let writable = StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: nil, bsdName: "disk8s2", at: mounted))!
        precondition(!writable.readOnly && writable.reason == nil && writable.at == mounted && writable.bsdName == "disk8s2")
        let dirty = StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: .inspection(1), bsdName: "disk8s2", at: mounted))!
        precondition(dirty.readOnly && dirty.reason == "check:dirty")
        // Shared preferences are outside the app's control: anything malformed is no status.
        precondition(StoreVolumeStatus(entry: nil) == nil)
        precondition(StoreVolumeStatus(entry: "readOnly") == nil)
        precondition(StoreVolumeStatus(entry: ["readOnly": "yes", "at": 1.0]) == nil)
        precondition(StoreVolumeStatus(entry: ["readOnly": true, "bsd": "disk8s2"]) == nil, "没有时间的记录不完整")
        precondition(StoreVolumeStatus(entry: ["readOnly": true, "at": Double.nan, "bsd": "disk8s2"]) == nil)
        precondition(StoreVolumeStatus(entry: ["readOnly": true, "at": 5.0]) == nil, "没有设备名就对不上是哪次挂载")
        precondition(StoreVolumeStatus(entry: ["readOnly": true, "at": 5.0, "bsd": "disk8s2", "reason": 7])!.reason == nil)

        // Records outlive the mount they describe: one counts only for the same device node and the same outcome.
        precondition(dirty.describes(mountedReadOnly: true, bsdName: "disk8s2"))
        precondition(!dirty.describes(mountedReadOnly: true, bsdName: "disk9s2"), "同一块盘上次接在别的位置时留下的记录")
        precondition(!dirty.describes(mountedReadOnly: false, bsdName: "disk8s2"), "系统说可写，记录却说只读")
        precondition(writable.describes(mountedReadOnly: false, bsdName: "disk8s2"))
        precondition(!writable.describes(mountedReadOnly: true, bsdName: "disk8s2"))
        let failed = StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: .failed, bsdName: "disk8s2", at: mounted))!
        precondition(failed.readOnly && failed.reason == "failed")

        // Every reason the extension can give has its own words; unknown tokens still explain something.
        var seen = Set<String>()
        for token in ["requested", "preference", "writeProtected", "check:dirty", "check:hibernated", "check:log"] {
            let text = StoreReadOnlyText.explanation(token: token)
            precondition(!text.title.isEmpty && !text.advice.isEmpty)
            precondition(seen.insert(text.title).inserted, "“\(token)”的说明与别的原因重复")
        }
        let unknown = StoreReadOnlyText.explanation(token: "check:unknown")
        precondition(StoreReadOnlyText.explanation(token: "unsupported") == unknown)
        precondition(StoreReadOnlyText.explanation(token: "something-new") == unknown)
        precondition(seen.insert(unknown.title).inserted)
        // No record for this mount is not "could not confirm it is safe": say only what is known.
        precondition(seen.insert(StoreReadOnlyText.unexplained.title).inserted)
        let journal = StoreReadOnlyText.explanation(token: "journal:foreignChange")
        precondition(StoreReadOnlyText.explanation(token: "journal:replacement") == journal)
        precondition(seen.insert(journal.title).inserted)
        // What the recovery undid reaches the app, and only known values become words.
        precondition(writable.recovery == nil, "没有恢复就不提")
        let cut = StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: nil, bsdName: "disk8s2", at: mounted, recovery: .interrupted))!
        precondition(cut.recovery == "interrupted" && !cut.readOnly && cut.describes(mountedReadOnly: false, bsdName: "disk8s2"))
        let early = StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: .preference, bsdName: "disk8s2", at: mounted, recovery: .afterEnd))!
        precondition(early.recovery == "after-end" && early.reason == "preference")
        let interrupted = StoreRecoveryText.explanation(recovery: "interrupted")!, afterEnd = StoreRecoveryText.explanation(recovery: "after-end")!
        precondition(interrupted.title != afterEnd.title && !interrupted.advice.isEmpty)
        precondition(StoreRecoveryText.explanation(recovery: "something-new") == nil)
        precondition(StoreVolumeStatus(entry: ["readOnly": false, "at": 5.0, "bsd": "disk8s2", "recovery": 1])!.recovery == nil)
        print("商店版主应用状态解析场景通过。")
    }
}
