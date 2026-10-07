import Foundation
import Testing
@testable import VolisleCore

private func candidate(_ bsd: String = "disk8s1", connection: UUID = UUID(), kind: String = VolumeSnapshot.unrecognizedWindowsKind,
                       external: Bool = true) -> VolumeSnapshot {
    .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "usb", connection: connection), bsdName: bsd,
          name: "加密的 Windows 分区", fileSystem: kind, deviceName: "Expansion", totalBytes: nil, availableBytes: nil,
          mountURL: nil, mountState: .unmounted, isExternal: external, isProtected: false)
}

private final class Fake: @unchecked Sendable {
    var probes: [String] = []
    var probeAnswer: Result<Bool, HelperDiskFailure> = .success(true)
    var unlocks: [(String, BitLockerSecretKind, String)] = []
    var unlockResult: Result<URL, HelperDiskFailure> = .success(URL(filePath: BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()))
    var unlockWritable = true
    var unlockReason: HelperDiskFailure? = nil
    var writableRequests: [Bool] = []
    var table: [(source: String, path: String, readOnly: Bool)] = []
    var unmounts: [[String]] = []
    var unmountClears = true
    var gone: Set<String> = []
}

private final class Runner: EraseCommandRunner, @unchecked Sendable {
    let fake: Fake
    init(_ fake: Fake) { self.fake = fake }
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        fake.unmounts.append(arguments)
        if fake.unmountClears { fake.table.removeAll { $0.path == arguments.last } ; return (0, "") }
        return (1, "Unmount failed\ndissented by Preview")
    }
}

@MainActor private func controller(_ fake: Fake) -> BitLockerController {
    BitLockerController(probe: { fake.probes.append($0); return try fake.probeAnswer.get() },
                        unlock: { bsd, kind, secret, writable in
                            fake.unlocks.append((bsd, kind, secret))
                            fake.writableRequests.append(writable)
                            let url = try fake.unlockResult.get()
                            let done = writable && fake.unlockWritable
                            fake.table.append(("/dev/" + bsd, url.path, !done))
                            return BitLockerUnlock(url: url, writable: done, readOnlyReason: done ? nil : fake.unlockReason)
                        },
                        runner: Runner(fake), mounts: { fake.table }, present: { !fake.gone.contains($0) },
                        ready: { _ in true }, kernelReportsReadOnly: true)
}

@MainActor @Test("候选分区每次连接只问一次后台；未确认或非外接的不算 BitLocker")
func probesOncePerConnection() async {
    let fake = Fake(), bitLocker = controller(fake)
    let volume = candidate()
    #expect(!bitLocker.isBitLocker(volume))
    await bitLocker.check([volume, candidate("disk9s1", kind: "ntfs"), candidate("disk10s1", external: false)])
    await bitLocker.check([volume])
    #expect(fake.probes == ["disk8s1"])
    #expect(bitLocker.isBitLocker(volume))
    fake.probeAnswer = .success(false)
    let other = candidate("disk11s1")
    await bitLocker.check([other])
    #expect(!bitLocker.isBitLocker(other))
}

@MainActor @Test("后台暂不可用时下次再问")
func probeFailureRetries() async {
    let fake = Fake(), bitLocker = controller(fake)
    fake.probeAnswer = .failure(.unavailable)
    let volume = candidate()
    await bitLocker.check([volume])
    #expect(!bitLocker.isBitLocker(volume))
    fake.probeAnswer = .success(true)
    await bitLocker.check([volume])
    #expect(bitLocker.isBitLocker(volume))
    #expect(fake.probes.count == 2)
}

@MainActor @Test("解锁：恢复密钥先规整；密码原样传递；挂载点记入已解锁")
func unlockNormalizes() async throws {
    let fake = Fake(), bitLocker = controller(fake)
    let volume = candidate()
    await bitLocker.check([volume])
    let spaced = "466895 217492 569250 069608 104434 135707 527241 083622"  // every group a multiple of 11
    let url = try await bitLocker.unlock(volume, recoveryKey: true, secret: spaced).url
    #expect(fake.unlocks.map(\.0) == ["disk8s1"])
    #expect(fake.unlocks[0].1 == .recoveryKey && fake.unlocks[0].2 == spaced.replacingOccurrences(of: " ", with: "-"))
    #expect(bitLocker.mountURL(for: volume) == url)
    let other = candidate("disk9s1")
    await bitLocker.check([other])
    _ = try await bitLocker.unlock(other, recoveryKey: false, secret: " 带空格的密码 ")
    #expect(fake.unlocks[1].1 == .password && fake.unlocks[1].2 == " 带空格的密码 ")
}

@MainActor @Test("解锁前的输入检查与失败原因")
func unlockRejects() async {
    let fake = Fake(), bitLocker = controller(fake)
    let volume = candidate()
    await #expect(throws: BitLockerError.busy) { try await bitLocker.unlock(volume, recoveryKey: false, secret: "x") }
    await bitLocker.check([volume])
    await #expect(throws: BitLockerError.invalidRecoveryKey) { try await bitLocker.unlock(volume, recoveryKey: true, secret: "12345") }
    await #expect(throws: BitLockerError.emptyPassword) { try await bitLocker.unlock(volume, recoveryKey: false, secret: "") }
    #expect(fake.unlocks.isEmpty)
    fake.unlockResult = .failure(.bitLockerWrongSecret)
    await #expect(throws: BitLockerError.failed(HelperDiskFailure.bitLockerWrongSecret.errorDescription!)) {
        try await bitLocker.unlock(volume, recoveryKey: false, secret: "wrong")
    }
    #expect(bitLocker.mountURL(for: volume) == nil && !bitLocker.isWorking(volume))
}

@MainActor @Test("已解锁状态来自挂载表：应用重开后仍识别，Finder 推出后清除")
func unlockedFromMountTable() async throws {
    let fake = Fake()
    let point = BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()
    fake.table = [("/dev/disk8s1", point, false), ("/dev/disk9s1", "/private/var/run/volisle-write-mounts/" + UUID().uuidString.lowercased(), false)]
    let bitLocker = controller(fake)
    let volume = candidate()
    #expect(bitLocker.isBitLocker(volume), "已挂载的分区不必再问后台（后台会因已挂载拒绝）")
    #expect(bitLocker.mountURL(for: volume)?.path == point)
    #expect(!bitLocker.isBitLocker(candidate("disk9s1")), "NTFS 读写挂载不是 BitLocker")
    await bitLocker.check([volume])
    #expect(fake.probes.isEmpty)
    fake.table.removeAll()
    bitLocker.refreshMounts()
    #expect(bitLocker.mountURL(for: volume) == nil)
}

@MainActor @Test("推出：卸载挂载点；被占用时报告原因且保持已解锁")
func lockUnmounts() async throws {
    let fake = Fake(), bitLocker = controller(fake)
    let volume = candidate()
    await bitLocker.check([volume])
    let url = try await bitLocker.unlock(volume, recoveryKey: false, secret: "p").url
    fake.unmountClears = false
    await #expect(throws: BitLockerError.lockFailed("dissented by Preview")) { try await bitLocker.lock(volume) }
    #expect(bitLocker.mountURL(for: volume)?.path == url.path)
    fake.unmountClears = true
    try await bitLocker.lock(volume)
    #expect(fake.unmounts.last == [url.path])
    #expect(bitLocker.mountURL(for: volume) == nil)
    try await bitLocker.lock(volume)
    #expect(fake.unmounts.count == 2, "未解锁时无需操作")
}

@MainActor @Test("默认按读写解锁；挂载表决定读写状态；只读时记住原因，锁定后清除")
func unlockWritableOrReadOnly() async throws {
    let fake = Fake(), bitLocker = controller(fake)
    let volume = candidate()
    await bitLocker.check([volume])
    let first = try await bitLocker.unlock(volume, recoveryKey: false, secret: "p")
    #expect(fake.writableRequests == [true] && first.writable)
    for _ in 0..<200 where !bitLocker.isWritable(volume) { try await Task.sleep(for: .milliseconds(2)) }
    #expect(bitLocker.isWritable(volume) && bitLocker.readOnlyReason(for: volume) == nil)
    try await bitLocker.lock(volume)
    #expect(!bitLocker.isWritable(volume))

    fake.unlockWritable = false
    fake.unlockReason = .windowsHibernated
    let second = try await bitLocker.unlock(volume, recoveryKey: false, secret: "p")
    #expect(!second.writable && second.readOnlyReason == .windowsHibernated)
    #expect(!bitLocker.isWritable(volume) && bitLocker.readOnlyReason(for: volume) == .windowsHibernated)
    try await bitLocker.lock(volume)
    #expect(bitLocker.readOnlyReason(for: volume) == nil && bitLocker.readOnlyReasons.isEmpty)

    _ = try await bitLocker.unlock(volume, recoveryKey: false, secret: "p", writable: false)
    #expect(fake.writableRequests.last == false && !bitLocker.isWritable(volume))
}

@Test("后台回复：只有挂载结果可以带读写信息；可写时不能带只读原因")
func bitLockerReplyShape() throws {
    let path = BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()
    let ok = try HelperBitLockerReply.decode(JSONEncoder().encode(HelperBitLockerReply(isBitLocker: nil, mountPath: path, failure: nil,
        writable: false, readOnlyReason: .ntfsDirty)))
    #expect(ok.writable == false && ok.readOnlyReason == .ntfsDirty)
    #expect(throws: HelperServiceError.invalidReply) {
        try HelperBitLockerReply.decode(JSONEncoder().encode(HelperBitLockerReply(isBitLocker: nil, mountPath: path, failure: nil,
            writable: true, readOnlyReason: .ntfsDirty)))
    }
    #expect(throws: HelperServiceError.invalidReply) {
        try HelperBitLockerReply.decode(JSONEncoder().encode(HelperBitLockerReply(isBitLocker: true, mountPath: nil, failure: nil,
            writable: true)))
    }
    #expect(throws: HelperServiceError.invalidRequest) {
        try HelperBitLockerRequest(bsdName: "disk8s2", registryID: 1, byteCount: 1 << 20, writable: true)
    }
    let request = try HelperBitLockerRequest(bsdName: "disk8s2", registryID: 1, byteCount: 1 << 20, kind: .password, secret: "p", writable: true)
    #expect(try HelperBitLockerRequest.decode(JSONEncoder().encode(request)).writable == true)
}

@MainActor @Test("拔掉的盘留下的解锁挂载被强制卸载；仍在的盘不动")
func removesDisconnectedMounts() async throws {
    let fake = Fake(), bitLocker = controller(fake)
    let a = candidate("disk8s2"), b = candidate("disk9s2")
    await bitLocker.check([a, b])
    let urlA = try await bitLocker.unlock(a, recoveryKey: false, secret: "p").url
    fake.unlockResult = .success(URL(filePath: BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()))
    _ = try await bitLocker.unlock(b, recoveryKey: false, secret: "p")
    await bitLocker.removeDisconnected()
    #expect(fake.unmounts.isEmpty, "设备都在时不卸载")
    fake.gone = ["disk8s2"]
    await bitLocker.removeDisconnected()
    #expect(fake.unmounts == [["-f", urlA.path]])
    #expect(bitLocker.mountURL(for: a) == nil && bitLocker.mountURL(for: b) != nil)
}
