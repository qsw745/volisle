import Foundation

@main struct StoreWriteStoppedTests {
    static func main() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let entry = StoreMountStatus.entry(readOnly: nil, bsdName: "disk8s2", at: at)
        precondition(entry["stopped"] as? Bool == false,
                     "正常挂载必须明确发布未停止状态，不能让失败状态残留")
        func status(_ id: String, stopped: Bool, at date: Date? = nil) -> StoreVolumeStatus {
            StoreVolumeStatus(entry: StoreMountStatus.entry(readOnly: nil, bsdName: "disk8s2", at: date ?? at,
                                                           mountID: id, stopped: stopped))!
        }
        let healthy = status("first", stopped: false)
        let stopped = status("first", stopped: true)
        precondition(StoreVolumeStatus.resolved(current: healthy, previous: stopped)?.stopped == true,
                     "同次挂载的迟到健康记录不能清除失败")
        precondition(StoreVolumeStatus.resolved(current: nil, previous: stopped)?.stopped == true,
                     "偏好记录暂缺不能清除失败")
        let next = status("second", stopped: false, at: at.addingTimeInterval(1))
        precondition(StoreVolumeStatus.resolved(current: next, previous: stopped)?.stopped == false,
                     "确认新挂载后允许正常状态")
        precondition(StoreVolumeStatus.resolved(current: stopped, previous: next)?.mountID == "second",
                     "旧挂载的迟到失败记录不能污染新挂载")
        let oldFormat: [String: Any] = ["readOnly": false, "bsd": "disk8s2", "at": at.timeIntervalSince1970]
        precondition(StoreVolumeStatus(entry: oldFormat)?.stopped == false)
        var malformed = oldFormat; malformed["stopped"] = "yes"
        precondition(StoreVolumeStatus(entry: malformed) == nil)
        malformed = oldFormat; malformed["mount"] = 42
        precondition(StoreVolumeStatus(entry: malformed) == nil)
        malformed = oldFormat; malformed["at"] = Double.nan
        precondition(StoreVolumeStatus(entry: malformed) == nil)
        precondition(!stopped.describes(mountedReadOnly: false, bsdName: "disk9s2"))
        print("商店版挂载停止状态通过。")
    }
}
