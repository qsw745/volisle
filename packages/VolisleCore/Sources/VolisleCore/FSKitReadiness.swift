import Foundation
import FSKit

/// Readiness of the installed copy. An enabled module is not proof of write
/// qualification. This adapter intentionally never grants write capability.
public enum ExtensionReadiness {
    /// Installed but switched off: the one state the setup guide's own step explains.
    public static let disabledReason = String(localized: "文件系统扩展还没打开：在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”里打开“盘屿 NTFS”（有的系统显示为“Volisle NTFS”）。")
    struct Module: Sendable { let url: URL; let enabled: Bool }
    static func evaluate(expected: URL, modules: [Module]) -> EngineCapability {
        // Run from the disk image, or moved without Finder and therefore app-
        // translocated: the running copy is not the one that owns the extension.
        let path = expected.standardizedFileURL.path
        let readOnlyVolume = (try? expected.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        if path.contains("/AppTranslocation/") || readOnlyVolume {
            return .init(available: false, finderReadWrite: false,
                reason: String(localized: "请先把盘屿拖到“应用程序”文件夹，再从那里打开。"))
        }
        guard modules.count == 1 else {
            return .init(available: false, finderReadWrite: false,
                reason: modules.isEmpty ? String(localized: "未检测到盘屿文件系统扩展。") : String(localized: "检测到多个扩展副本，请先检查安装状态。"))
        }
        guard modules[0].url.standardizedFileURL == expected.standardizedFileURL else {
            return .init(available: false, finderReadWrite: false, reason: String(localized: "已注册扩展属于另一个应用副本。"))
        }
        guard modules[0].enabled else {
            return .init(available: false, finderReadWrite: false, reason: disabledReason)
        }
        return .init(available: true, finderReadWrite: false, reason: String(localized: "扩展已启用；此版本仅开放读取，写入验收尚未完成。"))
    }

    /// Before macOS 26 FSKit does not list an app's own module to the app
    /// (macOS 15.6: only Apple's modules come back). There the module is found
    /// through PluginKit, and mount(8) tells whether FSKit can use it.
    static let fskitListsOwnModule = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))

    /// Paths PluginKit registered for the identifier, from `pluginkit -m -v -i`.
    /// Lines start with the election mark (`+`, `-`, …) and end with the path.
    static func registeredPaths(pluginKit output: String, identifier: String) -> [URL] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            let name = fields.first?.drop { "+-!=? ".contains($0) } ?? ""
            guard fields.count >= 2, name.hasPrefix(identifier + "("), let path = fields.last, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(path))
        }
    }

    /// mount(8) asked to mount a device that does not exist: FSKit hands the
    /// request to an enabled module (which reports the missing device), says a
    /// switched-off one is disabled, and knows nothing of an unknown name.
    /// True: on; false: off; nil: FSKit does not know the module.
    static func enabled(mountProbe output: String, identifier: String) -> Bool? {
        if output.contains("Module \(identifier) is disabled") { return false }
        if output.contains("Probing resource") { return true }
        return nil
    }

    /// The modules as macOS 15 shows them: registered copies, all switched on
    /// or off together (FSKit enables a module by identifier).
    static func legacyModules(identifier: String, shortName: String) -> [Module] {
        guard let listed = run("/usr/bin/pluginkit", ["-m", "-v", "-i", identifier]) else { return [] }
        let paths = registeredPaths(pluginKit: listed, identifier: identifier)
        guard !paths.isEmpty else { return [] }
        let point = FileManager.default.temporaryDirectory.appendingPathComponent("VolisleProbe-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: false)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: point) }
        // No such device: nothing can be mounted, only FSKit's answer comes back.
        guard let answer = run("/sbin/mount", ["-F", "-t", shortName, "-o", "rdonly", "/dev/disk999999s1", point.path]),
              let enabled = enabled(mountProbe: answer, identifier: identifier) else { return [] }
        return paths.map { Module(url: $0, enabled: enabled) }
    }

    /// Combined output of a short system tool, or nil if it could not run in time.
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ReadOnlyFSKitEngine: FileSystemAdapter {
    private let expectedExtension: URL
    private let identifier: String
    private let dailyWrites: Bool
    public init(expectedExtension: URL, identifier: String, dailyWrites: Bool = false) {
        self.expectedExtension = expectedExtension; self.identifier = identifier; self.dailyWrites = dailyWrites
    }
    public func capability() async -> EngineCapability {
        let first = await fetchCapability()
        // After a reinstall or in-place replacement, macOS may register the app
        // but not yet its bundled extension (seen on macOS 26.6). Register our
        // OWN appex once per launch, then check again.
        guard first.missing, ExtensionRegistration.claim() else { return first.capability }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        tool.arguments = ["-a", expectedExtension.standardizedFileURL.path]
        guard (try? tool.run()) != nil else { return first.capability }
        tool.waitUntilExit()
        try? await Task.sleep(for: .seconds(1))
        return await fetchCapability().capability
    }

    /// `missing` is true when no installed module carries our identifier.
    private func fetchCapability() async -> (capability: EngineCapability, missing: Bool) {
        let identifier = self.identifier, expected = self.expectedExtension, dailyWrites = self.dailyWrites
        return await withCheckedContinuation { continuation in
            let response = CapabilityResponse(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                response.finish((.init(available: false, finderReadWrite: false, reason: String(localized: "扩展状态检查超时，请稍后刷新。")), false))
            }
            FSClient.shared.fetchInstalledExtensions { modules, error in
                guard error == nil else {
                    response.finish((.init(available: false, finderReadWrite: false, reason: String(localized: "无法读取系统扩展状态，请稍后刷新。")), false))
                    return
                }
                var matching = (modules ?? []).filter { $0.bundleIdentifier == identifier }
                    .map { ExtensionReadiness.Module(url: $0.url, enabled: $0.isEnabled) }
                if matching.isEmpty && !ExtensionReadiness.fskitListsOwnModule {
                    matching = ExtensionReadiness.legacyModules(identifier: identifier, shortName: "volisle")
                }
                let readiness = ExtensionReadiness.evaluate(expected: expected, modules: matching)
                response.finish((readiness.available && dailyWrites
                    ? .init(available: true, finderReadWrite: true, reason: String(localized: "检查通过后开启读写，之后可直接在 Finder 和其他应用中编辑和保存文件。")) : readiness,
                    matching.isEmpty))
            }
        }
    }
    public func inspect(_ volume: VolumeSnapshot) async throws -> SafetyStatus { .unknown }
    public func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL { throw VolumeError.engineUnavailable }
    public func unmount(_ volume: VolumeSnapshot) async throws { throw VolumeError.engineUnavailable }
}

/// Resolve a timeout/callback race once; no task group waits on a system
/// request that has no cancellation API.
private final class CapabilityResponse: @unchecked Sendable {
    typealias Result = (capability: EngineCapability, missing: Bool)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    init(_ continuation: CheckedContinuation<Result, Never>) { self.continuation = continuation }
    func finish(_ value: Result) {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume(returning: value)
    }
}

/// At most one self-registration attempt per process.
enum ExtensionRegistration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempted = false
    static func claim() -> Bool { lock.withLock { defer { attempted = true }; return !attempted } }
}
