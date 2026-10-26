import Foundation

// swiftc -swift-version 6 -D VOLISLE_STORE -parse-as-library scripts/test-store-pro.swift apps/extension/Sources/StoreMount.swift apps/store/Sources/StoreProSettings.swift
// What the app hands the extension follows the purchase; the owner's choices survive losing it.
@main struct StoreProTests {
    static func main() {
        let a = "0102030405060708", b = "a1a2a3a4a5a6a7a8", c = "ffffffffffffff00"
        let choices: [String: StoreDiskChoice] = [
            a: StoreDiskChoice(preference: .readOnly, name: "照片"),
            b: StoreDiskChoice(preference: .readWrite, revealsOnConnect: true, name: "工作"),
            c: StoreDiskChoice(preference: nil, revealsOnConnect: true, name: "只显示"),
        ]
        let shared = StoreProSync.sharedDiskPreferences(unlocked: true, choices: choices)
        precondition(shared == ["DiskPreference.\(a)": "readOnly", "DiskPreference.\(b)": "readWrite"],
                     "买了以后：只把设了读写方式的盘交给扩展")
        precondition(StoreProSync.sharedDiskPreferences(unlocked: false, choices: choices).isEmpty, "没买或已退款：扩展什么都拿不到")
        precondition(StoreProSync.sharedDiskPreferences(unlocked: true, choices: [:]).isEmpty)
        // The extension reads back exactly what the app writes.
        for (key, value) in shared {
            precondition(key.hasPrefix(StoreMountStatus.diskPreferencePrefix) && StoreDiskPreference(rawValue: value) != nil)
        }
        precondition(StoreMountStatus.diskPreferenceKey(serial: [1, 2, 3, 4, 5, 6, 7, 8]) == "DiskPreference.\(a)",
                     "应用和扩展用同一种写法命名一块盘")

        precondition(StoreDiskChoice(preference: nil, name: "x").isEmpty, "什么都没设的盘不留在列表里")
        precondition(!StoreDiskChoice(preference: nil, revealsOnConnect: true, name: "x").isEmpty)
        precondition(!StoreDiskChoice(preference: .readOnly, name: "x").isEmpty)

        // Kept as JSON in the app's preferences: an older or newer build must read it back.
        let data = try! JSONEncoder().encode(choices)
        precondition(try! JSONDecoder().decode([String: StoreDiskChoice].self, from: data) == choices, "存取后不变")
        let unknown = #"{"x":{"preference":"sometimes","revealsOnConnect":true,"name":"x"},"y":{"preference":"readOnly","name":"y"}}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([String: StoreDiskChoice].self, from: unknown)
        precondition(decoded["x"] == StoreDiskChoice(preference: nil, revealsOnConnect: true, name: "x"),
                     "认不出的读写方式只丢这一项：回到跟随默认，而不是猜，其他设置保留")
        precondition(decoded["y"] == StoreDiskChoice(preference: .readOnly, name: "y"), "旧版本没写的字段取默认值")

        print("商店版 Pro 场景通过；未访问磁盘，也未连接 App Store。")
    }
}
