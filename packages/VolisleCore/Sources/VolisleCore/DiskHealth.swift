import Foundation

/// Read and write errors a disk reported to macOS (the kernel's storage
/// driver), told apart: unreadable sectors (bad sectors) are medium errors at
/// a few addresses; a loose cable, hub or weak supply shows as other errors.
public struct DiskErrorSummary: Codable, Sendable, Equatable {
    /// Medium errors (sense key 3): the disk could not read or write a sector.
    public var medium = 0
    /// Distinct addresses among the failing requests.
    public var places = 0
    /// Other I/O errors (transport, resets, timeouts).
    public var other = 0
    public var last: Date?
    public init() {}
    public var isEmpty: Bool { medium == 0 && other == 0 }
}

public enum DiskHealth {
    public static let window: TimeInterval = 24 * 3600

    /// The errors of the disk with this model (as in Disk Arbitration's device
    /// model) since `start`. Nil when the system log cannot be read.
    public static func collect(model: String, since start: Date) async -> DiskErrorSummary? {
        await collect(models: [model], since: start)?.first ?? nil
    }

    /// One read of the log for several disks, in the order given; nil entries
    /// for models too vague to match. Nil when the system log cannot be read.
    public static func collect(models: [String], since start: Date, timeout: TimeInterval = 30) async -> [DiskErrorSummary?]? {
        let models = models.map { $0.trimmingCharacters(in: .whitespaces) }
        guard models.contains(where: { !$0.isEmpty }) else { return models.map { _ in nil } }
        return await Task.detached(priority: .userInitiated) { () -> [DiskErrorSummary?]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            // The storage drivers' own messages: filtering by sender is quick (about
            // 4 s for a day), by all kernel messages over a minute. The model is
            // matched below, never placed in the predicate.
            process.arguments = ["show", "--style", "ndjson", "--start", DiagnosticEvents.startArgument(start),
                                 "--predicate", #"senderImagePath CONTAINS "IOSCSI" AND eventMessage CONTAINS "I/O error""#]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            let found = events(data)
            return models.map { $0.isEmpty ? nil : summarize(found, model: $0) }
        }.value
    }

    static func events(_ data: Data) -> [(time: Date, message: String)] {
        let stamps = DateFormatter()
        stamps.locale = Locale(identifier: "en_US_POSIX")
        stamps.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return data.split(separator: UInt8(ascii: "\n")).compactMap { raw in
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let stamp = object["timestamp"] as? String, let time = stamps.date(from: stamp) else { return nil }
            return (time, message)
        }
    }

    /// "[Model] I/O error! … Sense Data 0x03, 0x11, 0x00[, happened 9 times]" is
    /// one failing request (repeats folded in); "[Model]: I/O error … lba 0x…"
    /// tells where.
    static func summarize(_ events: [(time: Date, message: String)], model: String) -> DiskErrorSummary {
        let tag = "[" + model + "]"
        var summary = DiskErrorSummary()
        var places = Set<Substring>()
        for event in events where event.message.hasPrefix(tag) {
            let text = event.message.dropFirst(tag.count)
            if text.hasPrefix(" I/O error!") {
                let times = text.firstMatch(of: /happened (\d+) times/).flatMap { Int($0.1) } ?? 1
                let key = text.firstMatch(of: /Sense Data:? 0x([0-9A-Fa-f]{2})/).flatMap { Int($0.1, radix: 16) }
                if let key, key & 0x0f == 3 { summary.medium += times } else { summary.other += times }
                summary.last = max(summary.last ?? event.time, event.time)
            } else if let lba = text.firstMatch(of: /lba (0x[0-9A-Fa-f]+)/) {
                places.insert(lba.1)
            }
        }
        summary.places = places.count
        return summary
    }
}
