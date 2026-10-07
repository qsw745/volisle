import Darwin
import Foundation
import Testing
@testable import VolisleCore

private let legacyPoint = BitLockerMountPoint.root + "/11111111-1111-1111-1111-111111111111"
private let legacyDevice = "/dev/disk8s2"
private let legacySafe = UInt32(MNT_NOSUID | MNT_NODEV)
private func legacyRecord(_ flags: UInt32 = 0) -> SystemMountRecord {
    .init(source: legacyDevice, path: legacyPoint, type: "volisle", flags: flags)
}
@MainActor private func modeEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
}

private final class ModeThread: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadReads: [Bool] = []
    func read() -> FSKitMountMode? {
        lock.withLock { mainThreadReads.append(Thread.isMainThread) }
        return .readWrite
    }
    var reads: [Bool] { lock.withLock { mainThreadReads } }
}

@MainActor @Test("旧系统模式读取离开主线程，核实前保持不可写")
func bitLockerModeReadLeavesMainThread() async throws {
    let thread = ModeThread()
    let controller = BitLockerController(mounts: { [(legacyDevice, legacyPoint, false)] },
                                         present: { _ in true }, mode: { _ in thread.read() }, ready: { _ in true }, kernelReportsReadOnly: false)
    let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"), bsdName: "disk8s2",
        name: "test", fileSystem: VolumeSnapshot.unrecognizedWindowsKind, deviceName: "USB", totalBytes: nil,
        availableBytes: nil, mountURL: nil, mountState: .unmounted, isExternal: true, isProtected: false)
    #expect(!controller.isWritable(volume) && controller.unverified.contains("disk8s2"))
    try await modeEventually { controller.isWritable(volume) }
    #expect(controller.isWritable(volume))
    #expect(!thread.reads.isEmpty && thread.reads.allSatisfy { !$0 })
}

@MainActor @Test("失败或未完成挂载的持久标记跨应用重启保持不可写，所有内核均核实标记")
func bitLockerPendingMountSurvivesControllerRestart() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VolislePending-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(chmod(parent.path, 0o711) == 0)
    let pending = try BitLockerPendingMount(parent: parent.path, name: URL(filePath: legacyPoint).lastPathComponent, owner: geteuid())
    #expect(pending.isReady)
    try pending.begin()
    #expect(!pending.isReady)
    let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"), bsdName: "disk8s2",
        name: "test", fileSystem: VolumeSnapshot.unrecognizedWindowsKind, deviceName: "USB", totalBytes: nil,
        availableBytes: nil, mountURL: nil, mountState: .unmounted, isExternal: true, isProtected: false)
    for kernel in [false, true] {
        for _ in 0..<2 { // a fresh controller has no previous failure in memory
            let restarted = BitLockerController(mounts: { [(legacyDevice, legacyPoint, false)] }, present: { _ in true },
                mode: { _ in .readWrite }, ready: { _ in pending.isReady }, kernelReportsReadOnly: kernel)
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(2)) }
            #expect(!restarted.isWritable(volume) && restarted.unverified.contains("disk8s2"))
        }
    }
    try pending.finish()
    #expect(pending.isReady)
    for kernel in [false, true] {
        let finished = BitLockerController(mounts: { [(legacyDevice, legacyPoint, false)] }, present: { _ in true },
            mode: { _ in .readWrite }, ready: { _ in pending.isReady }, kernelReportsReadOnly: kernel)
        try await modeEventually { finished.isWritable(volume) }
    }
}

@Test("完成标记要求可信父目录、独占创建与原始 root 文件属性")
func bitLockerPendingMountRejectsUnsafeFilesystemState() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VolislePendingTrust-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let pending = try BitLockerPendingMount(parent: parent.path, name: URL(filePath: legacyPoint).lastPathComponent, owner: geteuid())
    #expect(!pending.isReady)
    #expect(throws: HelperDiskFailure.unavailable) { try pending.begin() }
    #expect(chmod(parent.path, 0o711) == 0)
    #expect(pending.isReady)
    let wrongOwner = try BitLockerPendingMount(parent: parent.path, name: pending.name, owner: uid_t.max)
    #expect(!wrongOwner.isReady)
    try pending.begin()
    #expect(throws: HelperDiskFailure.unavailable) { try pending.begin() }
    #expect(chmod(pending.marker, 0o644) == 0)
    #expect(throws: HelperDiskFailure.unavailable) { try pending.finish() }
    #expect(!pending.isReady)
    #expect(chmod(pending.marker, 0o600) == 0)
    try pending.finish()
    let alias = parent.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    let symlinked = try BitLockerPendingMount(parent: alias.path, name: pending.name, owner: geteuid())
    #expect(!symlinked.isReady)
}

@Test("macOS 15 的 BitLocker 挂载使用拥有者，26 仍保留 root 设备访问")
func bitLockerMountIdentityBySystemVersion() throws {
    let request = try HelperBitLockerRequest(bsdName: "disk8s2", registryID: 42, byteCount: 1 << 20,
                                            kind: .password, secret: "test", writable: true)
    let key = String(repeating: "a", count: 64)
    let old = HelperBitLockerService.mountCommand(request, key: key, uid: 501, path: legacyPoint,
                                                  writable: true, rootFindsModules: false)
    #expect(old.asOwner)
    #expect(Array(old.arguments.prefix(8)) == ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--", "/sbin/mount"])
    #expect(old.environment["SUDO_UID"] == nil)
    #expect(old.arguments.suffix(2) == [legacyDevice, legacyPoint])
    let current = HelperBitLockerService.mountCommand(request, key: key, uid: 501, path: legacyPoint,
                                                      writable: false, rootFindsModules: true)
    #expect(!current.asOwner && !current.arguments.contains("/usr/bin/sudo"))
    #expect(current.environment["SUDO_UID"] == "501")
    #expect(current.arguments.contains("rdonly,nosuid,nodev,volisle-bde=" + key))
}

@Test("旧内核无挂载标志时以扩展实际模式确认读写和只读回退")
func bitLockerLegacyMountMode() throws {
    #expect(try HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
        requestedWritable: true, mode: .readWrite, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false))
    #expect(try !HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
        requestedWritable: true, mode: .readOnly, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false))
    #expect(try !HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
        requestedWritable: false, mode: .readOnly, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false))
    for mode in [FSKitMountMode?.none, .stopped] {
        #expect(throws: VolumeError.mountNotVerified) {
            try HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
                requestedWritable: true, mode: mode, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false)
        }
    }
    #expect(throws: VolumeError.mountNotVerified) {
        try HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
            requestedWritable: false, mode: .readWrite, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false)
    }
}

@Test("模式属性不能代替真实设备、挂载点、类型与新内核安全标志核验")
func bitLockerMountModeKeepsIdentityChecks() throws {
    let records = [[], [legacyRecord(), legacyRecord()],
                   [SystemMountRecord(source: "/dev/disk9s2", path: legacyPoint, type: "volisle", flags: 0)],
                   [SystemMountRecord(source: legacyDevice, path: "/Volumes/elsewhere", type: "volisle", flags: 0)],
                   [SystemMountRecord(source: legacyDevice, path: legacyPoint, type: "ntfs", flags: 0)]]
    for rows in records {
        #expect(throws: VolumeError.mountNotVerified) {
            try HelperBitLockerService.mountWritable(rows, device: legacyDevice, path: legacyPoint,
                requestedWritable: true, mode: .readWrite, kernelReflectsSafetyFlags: false, kernelReportsReadOnly: false)
        }
    }
    #expect(throws: VolumeError.mountNotVerified) {
        try HelperBitLockerService.mountWritable([legacyRecord()], device: legacyDevice, path: legacyPoint,
            requestedWritable: true, mode: .readWrite, kernelReflectsSafetyFlags: true, kernelReportsReadOnly: true)
    }
    #expect(try HelperBitLockerService.mountWritable([legacyRecord(legacySafe)], device: legacyDevice, path: legacyPoint,
        requestedWritable: true, mode: nil, kernelReflectsSafetyFlags: true, kernelReportsReadOnly: true))
    #expect(try !HelperBitLockerService.mountWritable([legacyRecord(legacySafe | UInt32(MNT_RDONLY))], device: legacyDevice,
        path: legacyPoint, requestedWritable: true, mode: nil, kernelReflectsSafetyFlags: true, kernelReportsReadOnly: true))
}

@MainActor @Test("旧内核刷新保留扩展确认的只读，缺失或停止模式保持未核验")
func bitLockerLegacyControllerReadsActualMode() async throws {
    for actual in [FSKitMountMode?.some(.readOnly), nil, .stopped, .readWrite] {
        let controller = BitLockerController(mounts: { [(legacyDevice, legacyPoint, false)] },
                                             present: { _ in true }, mode: { _ in actual }, ready: { _ in true }, kernelReportsReadOnly: false)
        let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"), bsdName: "disk8s2",
            name: "test", fileSystem: VolumeSnapshot.unrecognizedWindowsKind, deviceName: "USB", totalBytes: nil,
            availableBytes: nil, mountURL: nil, mountState: .unmounted, isExternal: true, isProtected: false)
        controller.refreshMounts()
        #expect(!controller.isWritable(volume))
        if actual == .readOnly || actual == .readWrite {
            try await modeEventually { !controller.unverified.contains("disk8s2") }
        }
        #expect(controller.isWritable(volume) == (actual == .readWrite))
        #expect(controller.unverified.contains("disk8s2") == (actual == nil || actual == .stopped))
        #expect(controller.readOnly.contains("disk8s2") == (actual == .readOnly))
    }
}

@Test("挂载模式读取只接受完整协议值，缺失、坏数据与超长值不放行")
func bitLockerMountModeReadRejectsUnverifiedData() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("VolisleMode-" + UUID().uuidString)
    try Data().write(to: file, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(FSKitMountMode.read(at: file.path) == nil)
    for (bytes, expected) in [(Data("read-only".utf8), FSKitMountMode?.some(.readOnly)),
                              (Data("read-write".utf8), .readWrite), (Data("stopped".utf8), .stopped),
                              (Data("read-write\n".utf8), nil), (Data([0xff, 0xfe]), nil),
                              (Data(repeating: 0x61, count: 17), nil)] {
        let result = bytes.withUnsafeBytes {
            setxattr(file.path, FSKitMountMode.attribute, $0.baseAddress, $0.count, 0, 0)
        }
        #expect(result == 0)
        #expect(FSKitMountMode.read(at: file.path) == expected)
    }
}

private final class FailedUnlockMount: @unchecked Sendable {
    var rows: [(source: String, path: String, readOnly: Bool)] = []
}

@MainActor @Test("解锁失败产生的残留挂载不因刷新变为可写，真正卸载后解除隔离")
func failedBitLockerUnlockDoesNotPublishResidualMount() async throws {
    let table = FailedUnlockMount()
    let controller = BitLockerController(probe: { _ in true }, unlock: { _, _, _, _ in
        table.rows = [(legacyDevice, legacyPoint, false)]
        throw HelperDiskFailure.unavailable
    }, mounts: { table.rows }, present: { _ in true }, mode: { _ in .readWrite }, ready: { _ in true }, kernelReportsReadOnly: false)
    let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"), bsdName: "disk8s2",
        name: "test", fileSystem: VolumeSnapshot.unrecognizedWindowsKind, deviceName: "USB", totalBytes: nil,
        availableBytes: nil, mountURL: nil, mountState: .unmounted, isExternal: true, isProtected: false)
    await controller.check([volume])
    await #expect(throws: BitLockerError.failed(HelperDiskFailure.unavailable.errorDescription!)) {
        try await controller.unlock(volume, recoveryKey: false, secret: "test")
    }
    controller.refreshMounts()
    #expect(!controller.isWritable(volume) && controller.unverified.contains("disk8s2"))
    table.rows = []
    controller.refreshMounts()
    #expect(controller.unverified.isEmpty)
    table.rows = [(legacyDevice, BitLockerMountPoint.root + "/22222222-2222-2222-2222-222222222222", false)]
    controller.refreshMounts()
    try await modeEventually { controller.isWritable(volume) }
}

/// Keeps the real synchronous-query boundary while allowing the test to choose
/// when each response arrives; a cancelled task cannot unblock this reader.
private final class SlowMode: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0, active = 0, maximum = 0, returned = 0, released = 0
    func read(_ path: String) -> FSKitMountMode? {
        condition.lock()
        calls += 1; active += 1; maximum = max(maximum, active)
        let call = calls
        while released < call { condition.wait() }
        active -= 1; returned += 1
        condition.unlock()
        return path == legacyPoint ? .readWrite : .readOnly
    }
    func release(_ count: Int) { condition.lock(); released = count; condition.broadcast(); condition.unlock() }
    var counts: (calls: Int, maximum: Int, returned: Int) {
        condition.lock(); defer { condition.unlock() }
        return (calls, maximum, returned)
    }
}

@MainActor @Test("慢属性查询始终只有一个，旧响应不能核实更换后的挂载")
func bitLockerSlowModeRefreshIsBoundedAndRejectsStaleResults() async throws {
    let reader = SlowMode(), table = FailedUnlockMount()
    defer { reader.release(Int.max) }
    table.rows = [(legacyDevice, legacyPoint, false)]
    let controller = BitLockerController(mounts: { table.rows }, present: { _ in true },
        mode: { reader.read($0) }, ready: { _ in true }, kernelReportsReadOnly: false)
    let volume = VolumeSnapshot(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb"), bsdName: "disk8s2",
        name: "test", fileSystem: VolumeSnapshot.unrecognizedWindowsKind, deviceName: "USB", totalBytes: nil,
        availableBytes: nil, mountURL: nil, mountState: .unmounted, isExternal: true, isProtected: false)
    try await modeEventually { reader.counts.calls == 1 }
    let replacement = BitLockerMountPoint.root + "/22222222-2222-2222-2222-222222222222"
    table.rows = [(legacyDevice, replacement, false)]
    for _ in 0..<20 { controller.refreshMounts() }
    try await Task.sleep(for: .milliseconds(10))
    #expect(reader.counts.calls == 1 && reader.counts.maximum == 1)
    #expect(!controller.isWritable(volume))
    reader.release(1)
    try await modeEventually { reader.counts.calls == 2 }
    #expect(controller.mountURL(for: volume)?.path == replacement)
    #expect(!controller.isWritable(volume) && controller.unverified.contains("disk8s2"))
    reader.release(2)
    try await modeEventually { controller.readOnly.contains("disk8s2") && controller.unverified.isEmpty }
    #expect(!controller.isWritable(volume) && reader.counts.maximum == 1)
}

@MainActor @Test("慢查询完成时已卸载的卷不能被旧响应重新标成可写")
func bitLockerSlowModeDoesNotReviveDisconnectedMount() async throws {
    let reader = SlowMode(), table = FailedUnlockMount()
    defer { reader.release(Int.max) }
    table.rows = [(legacyDevice, legacyPoint, false)]
    let controller = BitLockerController(mounts: { table.rows }, present: { _ in true },
        mode: { reader.read($0) }, ready: { _ in true }, kernelReportsReadOnly: false)
    try await modeEventually { reader.counts.calls == 1 }
    table.rows = []
    controller.refreshMounts()
    reader.release(1)
    try await modeEventually { reader.counts.returned == 1 }
    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(controller.unlocked.isEmpty && controller.unverified.isEmpty && controller.readOnly.isEmpty)
    #expect(reader.counts.calls == 1)
}
