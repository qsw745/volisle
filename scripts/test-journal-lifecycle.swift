import Foundation
import Darwin

@main struct LifecycleTests {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let binding = ReplacementBinding(serial: "1234567890abcdef", bootHash: String(repeating: "a", count: 64),
            directory: "/", source: "draft", target: "document", backup: ".old",
            oldReference: 0x1000000000040, newReference: 0x1000000000041)
        let before = ReplacementFingerprint.of(Data("old".utf8)), after = ReplacementFingerprint.of(Data("new".utf8))
        if mode == "inspect" {
            let result = try ReplacementJournal.inspect(at: root.appendingPathComponent("journal"), serial: binding.serial, bootHash: binding.bootHash)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); return
        }
        var poisoned = false
        let journal = try ReplacementJournal(at: root.appendingPathComponent("journal"), binding: binding,
            before: before, after: after, failClosed: { poisoned = true })
        try journal.publish {}
        // Checkpoint 129 and then checkpoint 257. Exercising both matters:
        // the second replaces an existing checkpoint rather than creating it.
        let round = Int(CommandLine.arguments[3])!
        let edits = round == 1 ? 63 : 127
        for n in 0..<edits { try journal.write(.new) { .of(Data("edit-\(n)".utf8)) } }
        journal.storageBoundary = { boundary in
            if boundary == mode {
                if CommandLine.arguments.last == "failure" { throw POSIXError(.EIO) }
                _exit(86)
            }
        }
        var mutated = false
        do {
            try journal.write(.new) { mutated = true; return after }
            precondition(mode == "normal")
        } catch {
            precondition(CommandLine.arguments.last == "failure" && poisoned && !mutated)
            do { try journal.write(.new) { fatalError("失败会话重新进入写入") }; fatalError() } catch {}
        }
        journal.close()
    }
}
