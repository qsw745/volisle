import Foundation

/// What launchd reports about the background service, for diagnostics: when
/// the App cannot reach the helper, this tells whether launchd ever started
/// it, how often, and how it last exited. No paths or names leave the Mac.
public enum HelperLaunchdState {
    /// Lines of `launchctl print` worth reporting, by their key.
    static let keys = ["state", "runs", "last exit code", "last terminating signal", "job state", "spawn type", "immediate reason"]

    /// Reads `launchctl print system/<label>` (allowed without administrator
    /// rights). Nil when it cannot run in time.
    public static func read(label: String = HelperIdentity.service, timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/" + label]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return summarize(String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    /// The service's own top-level lines only (one tab deep), first of each key.
    static func summarize(_ text: String, status: Int32) -> String {
        if status != 0 || text.contains("Could not find service") {
            return String(localized: "launchd 中没有这个服务（未注册或已被移除）")
        }
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, keys.contains(parts[0]), found[parts[0]] == nil else { continue }
            found[parts[0]] = String(parts[1].prefix(60))
        }
        let summary = keys.compactMap { key in found[key].map { "\(key)=\($0)" } }.joined(separator: "，")
        return summary.isEmpty ? String(localized: "无法读取") : summary
    }
}
