import Foundation

/// Volisle's own recent log lines — the app, the background component and the
/// file system extension — for a diagnostic report: what each part decided and
/// why, which the support conversation otherwise has to guess. Paths, quoted
/// names, disk numbers and identifiers are removed; nothing else is read.
public enum DiagnosticEvents {
    public struct Line: Codable, Sendable, Equatable {
        public let time: Date
        /// app, helper or extension.
        public let source: String
        /// notice, error or fault.
        public let level: String
        public let message: String
        /// The same line again right after it, this many times in all (nil: once).
        public var repeats: Int?
        public init(time: Date, source: String, level: String, message: String, repeats: Int? = nil) {
            self.time = time; self.source = source; self.level = level; self.message = message; self.repeats = repeats
        }
    }
    public static let window: TimeInterval = 24 * 3600
    public static let limit = 300
    static let sources = ["Volisle": "app", "VolisleMountHelper": "helper", "VolisleFS": "extension"]
    static let predicate = #"(subsystem BEGINSWITH "top.qisw.volisle" OR subsystem == "Volisle.NTFSModule") AND (messageType == default OR messageType == error OR messageType == fault)"#

    /// Reads the system log with `log show`, which an administrator account may
    /// do for its own apps. Nil when it cannot (another account type, a timeout).
    public static func collect(since start: Date, timeout: TimeInterval = 30) async -> [Line]? {
        await Task.detached(priority: .userInitiated) { () -> [Line]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--style", "ndjson", "--start", startArgument(start), "--predicate", predicate]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            // Read to the end before waiting: a full pipe would stop the tool.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            return parse(data)
        }.value
    }

    static func startArgument(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// One JSON object per line; only lines from Volisle's own processes count.
    static func parse(_ data: Data) -> [Line] {
        let stamps = DateFormatter()
        stamps.locale = Locale(identifier: "en_US_POSIX")
        stamps.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var lines: [Line] = []
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let path = object["processImagePath"] as? String,
                  let source = sources[(path as NSString).lastPathComponent],
                  let stamp = object["timestamp"] as? String, let time = stamps.date(from: stamp) else { continue }
            let level = ["Error": "error", "Fault": "fault"][object["messageType"] as? String ?? ""] ?? "notice"
            guard level != "notice" || !routine(message) else { continue }
            let line = Line(time: time, source: source, level: level, message: sanitize(message))
            // A line repeated back to back is one line with a count.
            if let last = lines.last, last.source == line.source, last.level == line.level, last.message == line.message {
                lines[lines.count - 1].repeats = (last.repeats ?? 1) + 1
            } else {
                lines.append(line)
            }
        }
        return Array(lines.suffix(limit))
    }

    /// Said on every operation and telling nothing: left out so the lines that matter stand out.
    static func routine(_ message: String) -> Bool {
        message == "后台写入包身份已核验"
            || (message.hasPrefix("恢复记录只读复核：") && message.contains("已完成=0 未完成=0"))
    }

    /// Paths, quoted names, UUIDs, hexadecimal identifiers (volume serials,
    /// hashes), disk numbers and addresses go; numbers that tell what happened
    /// (offsets, counts, error codes) stay.
    public static func sanitize(_ message: String) -> String {
        let rules: [(String, String)] = [
            (#"/(?:Users|Volumes|private|var|tmp|dev|Library|System|Applications|opt|usr|etc|cores)(?:/[^\s，。；：“”"'()（）\[\]]*)*"#, "<路径>"),
            (#"“[^”]*”"#, "“<名称>”"),
            (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<id>"),
            (#"\b(?=[0-9A-Fa-f]*[A-Fa-f])[0-9A-Fa-f]{12,}\b"#, "<id>"),
            (#"\b(?:r?disk)[0-9]+(?:s[0-9]+)?\b"#, "disk*"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        ]
        var text = message
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(text.prefix(400))
    }
}
