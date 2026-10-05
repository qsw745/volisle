import Foundation
import Darwin

@main struct StoreTests {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let binding = ReplacementBinding(serial: "1234567890abcdef", bootHash: String(repeating: "a", count: 64),
            directory: "/", source: "draft", target: "document", backup: ".old",
            oldReference: 0x1000000000040, newReference: 0x1000000000041)
        let before = ReplacementFingerprint.of(Data("old".utf8)), after = ReplacementFingerprint.of(Data("new".utf8))
        func make(_ complete: Bool) throws -> URL {
            let journal = try ReplacementJournal(at: root.appendingPathComponent(UUID().uuidString), binding: binding,
                before: before, after: after, failClosed: { fatalError("正常完成记录被中止") })
            try journal.publish {}
            if complete {
                try journal.oldItemReclaimed()
                let proof = ReplacementProof(oldReference: binding.oldReference, newReference: binding.newReference,
                    old: before, new: after, sourceAbsent: true)
                try journal.cleanup(verify: { proof }, removeAndSync: {})
            }
            journal.close(); return journal.url
        }
        if mode == "seed" {
            for _ in 0..<Int(CommandLine.arguments[3])! { _ = try make(true) }
            return
        }
        if mode == "unfinished" { print(try make(false).lastPathComponent); return }
        if mode == "retire" {
            let url = try make(true)
            try ReplacementJournal.retireCompleted(at: url)
            precondition(!FileManager.default.fileExists(atPath: url.path))
            print(url.lastPathComponent); return
        }
        if mode != "audit" && mode != "audit-other" {
            ReplacementJournal.storeStorageBoundary = { point in
                if point == mode {
                    if CommandLine.arguments.last == "failure" { throw POSIXError(.EIO) }
                    _exit(86)
                }
            }
        }
        do {
            let audit = try ReplacementJournal.auditStore(at: root, serial: mode == "audit-other" ? "0000000000000001" : binding.serial, bootHash: binding.bootHash)
            precondition(mode == "audit" || mode == "audit-other")
            print("{\"completed\":\(audit.completed),\"unresolved\":\(audit.unresolved),\"blocksWriting\":\(audit.blocksWriting)}")
        } catch {
            if CommandLine.arguments.last != "failure" { throw error }
        }
    }
}
