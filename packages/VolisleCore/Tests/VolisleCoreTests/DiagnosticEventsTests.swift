import Foundation
import Testing
@testable import VolisleCore

/// The run log in a diagnostic report: Volisle's own lines only, and nothing
/// that names the user's disks, files or folders.
struct DiagnosticEventsTests {
    @Test func identifyingDetailsAreRemovedAndTheStoryStays() {
        let cases: [(String, String)] = [
            ("恢复记录只读复核：卷=30b38eb9b71879a9 已完成=0", "恢复记录只读复核：卷=<id> 已完成=0"),
            ("不符块：偏移 249929793536 批次 74", "不符块：偏移 249929793536 批次 74"),
            ("Unmounting /private/var/run/volisle-write-mounts/62af683f-e4c5-4fde-8e67-ad0f4b6617d0 how 02", "Unmounting <路径> how 02"),
            ("拷贝到“我的照片”出错", "拷贝到“<名称>”出错"),
            ("挂载 /dev/disk4s3 于 /Volumes/qsw", "挂载 <路径> 于 <路径>"),
            ("设备 disk12s2 与 rdisk4 已断开", "设备 disk* 与 disk* 已断开"),
            ("会话 0B248216-872D-4DB2-AD2F-D8E78BB1802A 结束", "会话 <id> 结束"),
            ("联系 someone@example.com", "联系 <email>"),
            ("mount 失败：状态=1 输出=Operation ended with error: 拒绝可写挂载。[journal:foreignChange]",
             "mount 失败：状态=1 输出=Operation ended with error: 拒绝可写挂载。[journal:foreignChange]"),
        ]
        for (raw, cleaned) in cases { #expect(DiagnosticEvents.sanitize(raw) == cleaned, "\(raw)") }
        #expect(DiagnosticEvents.sanitize(String(repeating: "长", count: 1000)).count == 400)
    }

    @Test func onlyVolislesOwnProcessesAreKeptInOrder() throws {
        let lines = [
            #"{"timestamp":"2026-10-06 19:33:21.109000+0800","messageType":"Default","processImagePath":"~/Applications/Volisle Test.app/Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS","eventMessage":"恢复核对：1 块是断开时写到一半的本机写入，照常回滚"}"#,
            #"{"timestamp":"2026-10-06 19:33:21.200000+0800","messageType":"Error","processImagePath":"/Library/Something/swiftpm-testing-helper","eventMessage":"test noise"}"#,
            #"{"timestamp":"2026-10-06 19:33:22.000000+0800","messageType":"Error","processImagePath":"/x/VolisleMountHelper","eventMessage":"磁盘操作失败：阶段=mountingWrite 归类=writeNotEnabled"}"#,
            #"{"timestamp":"2026-10-06 19:33:23.000000+0800","messageType":"Fault","processImagePath":"/x/Volisle","eventMessage":"打开 ~/secret 失败"}"#,
            #"{"timestamp":"2026-10-06 19:33:23.500000+0800","messageType":"Default","processImagePath":"/x/VolisleMountHelper","eventMessage":"后台写入包身份已核验"}"#,
            #"{"timestamp":"2026-10-06 19:33:24.000000+0800","messageType":"Default","processImagePath":"/x/Volisle","eventMessage":"启动被推迟：initialized=true busy=false blocked=true"}"#,
            #"{"timestamp":"2026-10-06 19:33:24.500000+0800","messageType":"Default","processImagePath":"/x/Volisle","eventMessage":"启动被推迟：initialized=true busy=false blocked=true"}"#,
            #"{"count":4,"finished":1}"#,
            "not json",
        ].joined(separator: "\n")
        let events = DiagnosticEvents.parse(Data(lines.utf8))
        // The routine package check is left out; the two deferrals are one line.
        #expect(events.map(\.source) == ["extension", "helper", "app", "app"])
        #expect(events.map(\.level) == ["notice", "error", "fault", "notice"])
        #expect(events.last?.repeats == 2 && events.first?.repeats == nil)
        #expect(events[2].message == "打开 <路径> 失败")
        #expect(events[0].time < events[1].time)
    }

    @Test func theOperationHistoryKeepsEachOperationOnceNewestFirst() throws {
        let suite = "volisle-history-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let disk = try HelperDiskRequest(bsdName: "disk9s1", registryID: 7, byteCount: 1_000_000_000)
        var operations: [HelperMountOperation] = []
        for index in 0..<(OperationHistory.limit + 5) {
            var operation = HelperMountOperation(id: UUID(), disk: disk, ownerUID: 501, bootSession: "boot", phase: .finished, restoreRequired: false)
            operation.purpose = .readWrite
            if index % 2 == 0 { operation.failure = .interruptedWriteUnverified }
            operations.append(operation)
            OperationHistory.record(operation, in: defaults, at: Date(timeIntervalSince1970: Double(index)))
            OperationHistory.record(operation, in: defaults)  // a second report of the same end
        }
        let entries = OperationHistory.entries(in: defaults)
        #expect(entries.count == OperationHistory.limit)
        #expect(entries.first?.time == Date(timeIntervalSince1970: Double(OperationHistory.limit + 4)))
        #expect(entries.first?.failure == "interruptedWriteUnverified" && entries.first?.purpose == "readWrite")
    }

    @Test func theFullReportNamesNoDiskAndKeepsTheReasons() throws {
        let secret = "PRIVATE-CANARY-不会导出"
        let volume = VolumeSnapshot(identity: .init(volumeUUID: secret, mediaUUID: secret, devicePath: "/dev/disk7s3"),
            bsdName: "disk7s3", name: secret, fileSystem: "ntfs", deviceName: secret,
            totalBytes: 2_000_398_934_016, availableBytes: 1_000, mountURL: URL(fileURLWithPath: "/Volumes/\(secret)"),
            mountState: .readOnly, isExternal: true, isProtected: false, deviceProtocol: "USB")
        let disk = try HelperDiskRequest(bsdName: "disk7s3", registryID: 4242, byteCount: 2_000_398_934_016)
        var refused = HelperMountOperation(id: UUID(), disk: disk, ownerUID: 501, bootSession: secret, phase: .finished, restoreRequired: true)
        refused.purpose = .readWrite
        refused.failure = .interruptedWriteUnverified
        var report = DiagnosticReport(volumes: [volume], diskServiceRunning: true,
            engine: .init(available: true, finderReadWrite: true, reason: ""), lastRefusal: refused,
            helper: .init(state: "connected", fullDiskAccess: true, packageVerified: true), automaticWrite: true,
            history: [OperationHistory.Entry(refused, at: Date(timeIntervalSince1970: 1_791_000_000))], mac: "Mac15,7 · arm64")
        report.events = [.init(time: Date(timeIntervalSince1970: 1_791_000_100), source: "extension", level: "error",
                               message: DiagnosticEvents.sanitize("恢复核对不符：卷=30b38eb9b71879a9 于 /Volumes/\(secret)"))]
        let text = report.text
        let json = try #require(String(data: try report.jsonData(), encoding: .utf8))
        for output in [text, json] {
            #expect(!output.contains(secret) && !output.contains("disk7s3") && !output.contains("4242"))
            #expect(!output.contains("2000398934016") && !output.contains("30b38eb9b71879a9") && !output.contains("/Volumes/"))
            #expect(!output.contains(refused.id.uuidString))
            #expect(output.contains("interruptedWriteUnverified"))
        }
        #expect(text.contains("#1 盘1 · ntfs · readOnly · USB · 0.5–2 TB"))
        #expect(text.contains("上次被拒绝的操作：readWrite · finished · failure=interruptedWriteUnverified"))
        #expect(text.contains("[扩展 ERROR] 恢复核对不符：卷=<id> 于 <路径>"))
        #expect(text.contains("Mac：Mac15,7 · arm64"))
        #expect(report.schemaVersion == 4)
    }
}
