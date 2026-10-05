import Foundation
import Testing
@testable import VolisleCore

private func volume(bsd: String = "disk8s1", fileSystem: String = "ntfs", external: Bool = true, protected: Bool = false,
                    state: MountState = .readOnly) -> VolumeSnapshot {
    .init(identity: .init(volumeUUID: "v", mediaUUID: "m", devicePath: "usb"), bsdName: bsd, name: "移动存储",
          fileSystem: fileSystem, deviceName: "BUP Slim BK", totalBytes: nil, availableBytes: nil, mountURL: nil,
          mountState: state, isExternal: external, isProtected: protected)
}

private final class Runner: EraseCommandRunner, @unchecked Sendable {
    var calls: [[String]] = []
    var unmountStatus: Int32 = 0
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        calls.append(arguments)
        return arguments.first == "unmount" ? (unmountStatus, unmountStatus == 0 ? "unmounted" : "dissented by mdworker") : (0, "")
    }
}

private final class Clear: @unchecked Sendable {
    var calls: [String] = []
    var result: Result<Int64, HelperDiskFailure> = .success(1234)
    func callAsFunction(_ bsd: String) throws -> Int64 { calls.append(bsd); return try result.get() }
}

@MainActor @Test("在 Mac 上检查：卸载 → 检查并清除 → 重新挂载，返回检查数量")
func checkMarkerClears() async throws {
    let runner = Runner(), clear = Clear()
    let clearer = CheckMarkerClearer(runner: runner, retryDelay: .zero, isMounted: { _ in true }, clear: { try clear($0) })
    #expect(try await clearer.run(partition: "disk8s1") == 1234)
    #expect(runner.calls == [["unmount", "disk8s1"], ["mount", "disk8s1"]])
    #expect(clear.calls == ["disk8s1"])
}

@MainActor @Test("检查发现问题：仍然重新挂载，报告原因")
func checkMarkerProblemsRemount() async throws {
    let runner = Runner(), clear = Clear()
    clear.result = .failure(.checkFoundProblems)
    let clearer = CheckMarkerClearer(runner: runner, retryDelay: .zero, isMounted: { _ in true }, clear: { try clear($0) })
    await #expect(throws: CheckMarkerError.failed(HelperDiskFailure.checkFoundProblems.errorDescription!)) {
        try await clearer.run(partition: "disk8s1")
    }
    #expect(runner.calls.last == ["mount", "disk8s1"])
}

@MainActor @Test("卸载一直失败：重试 3 次后放弃，不请求后台")
func checkMarkerUnmountFails() async throws {
    let runner = Runner(), clear = Clear()
    runner.unmountStatus = 1
    let clearer = CheckMarkerClearer(runner: runner, retryDelay: .zero, isMounted: { _ in true }, clear: { try clear($0) })
    await #expect(throws: CheckMarkerError.unmountFailed("dissented by mdworker")) { try await clearer.run(partition: "disk8s1") }
    #expect(runner.calls.filter { $0.first == "unmount" }.count == 3 && clear.calls.isEmpty)
}

@MainActor @Test("只接受分区名；未挂载的分区不再卸载")
func checkMarkerScope() async throws {
    for bad in [volume(fileSystem: "exfat"), volume(external: false), volume(protected: true), volume(bsd: "disk8")] {
        #expect(!CheckMarkerClearer.applies(to: bad))
    }
    for bad in ["disk8", "/dev/disk8s1", "disk8s1/../x", ""] {
        let clear = Clear()
        let clearer = CheckMarkerClearer(runner: Runner(), retryDelay: .zero, isMounted: { _ in true }, clear: { try clear($0) })
        await #expect(throws: CheckMarkerError.unsupported) { try await clearer.run(partition: bad) }
        #expect(clear.calls.isEmpty)
    }
    let runner = Runner(), clear = Clear()
    let clearer = CheckMarkerClearer(runner: runner, retryDelay: .zero, isMounted: { _ in false }, clear: { try clear($0) })
    _ = try await clearer.run(partition: "disk8s1")
    #expect(runner.calls == [["mount", "disk8s1"]])
}
