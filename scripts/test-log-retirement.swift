import Foundation
import Darwin

private enum Fault: Error { case injected }
@main struct RetirementTests {
    static let checkpoint = String(repeating: "d", count: 64)
    static func binding(_ id: UUID = UUID(), volume: String = "fixture") -> BlockJournalBinding {
        .init(transactionID: id, volumeIdentity: volume, bootSHA256: String(repeating: "a", count: 64), deviceSize: 8192, blockSize: 4096)
    }
    static func rejected(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw Fault.injected
    }
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4 {
            let root = URL(fileURLWithPath: args[1]), stage = args[2]
            let a = try BlockJournalAuthority.fixture(directory: root.appendingPathComponent("authority"))
            a.storageBoundary = { if $0 == stage { _exit(86) } }
            _ = try a.retireLog(binding(UUID(uuidString: args[3])!), logDirectory: root.appendingPathComponent("logs")); _exit(87)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/log-retirement-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        func setup(_ name: String, kind: String = "committed") throws -> (URL, BlockJournalBinding) {
            let dir = root.appendingPathComponent(name), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            for p in [auth, logs] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let a = try BlockJournalAuthority.fixture(directory: auth), b = binding()
            let s = try BlockJournalStore(directory: logs, binding: b, key: a.key(), failClosed: {})
            _ = try a.save(b, previous: nil, next: s.seal)
            var old = s.seal
            try s.record(offset: 0, before: Data(count: 4096), after: Data(repeating: 1, count: 4096))
            _ = try a.save(b, previous: old, next: s.seal)
            if kind == "committed" || kind == "commit-only" {
                old = s.seal; try s.commit(checkpoint: checkpoint, flushDevice: {})
                _ = try a.save(b, previous: old, next: s.seal)
            }
            s.close()
            if kind == "committed" { _ = try a.completeCommit(b, logDirectory: logs, checkpoint: checkpoint) { _ in } }
            if kind == "recovered" { _ = try a.recover(b, logDirectory: logs, checkpoint: checkpoint) { _ in } }
            a.close(); return (dir, b)
        }
        for kind in ["committed", "recovered"] {
            let (dir,b) = try setup(kind, kind: kind), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            let state = try Data(contentsOf: auth.appendingPathComponent("anchors.json"))
            try rejected { _ = try BlockJournalStore(directory: logs, binding: binding(), key: a.key(), directoryFileLimit: 1, failClosed: {}) }
            let removed = try a.retireLog(b, logDirectory: logs); precondition(removed)
            let names = try FileManager.default.contentsOfDirectory(atPath: logs.path); precondition(names.isEmpty)
            let unchanged = try Data(contentsOf: auth.appendingPathComponent("anchors.json")); precondition(state == unchanged)
            a.close()
            let reopened = try BlockJournalAuthority.fixture(directory: auth)
            let again = try reopened.retireLog(b, logDirectory: logs); precondition(!again)
            let next = binding(); try reopened.requireNewTransaction(next)
            let s = try BlockJournalStore(directory: logs, binding: next, key: reopened.key(), directoryFileLimit: 1, failClosed: {})
            s.close(); reopened.close()
            checks.append(kind+"-retired-restart-idempotent-quota-reused-tombstone-kept")
            let stale = try BlockJournalAuthority.fixture(directory: auth)
            try rejected { _ = try stale.read(b) }; stale.close()
            checks.append(kind+"-retired-transaction-still-fenced")
            let capped = try BlockJournalAuthority.fixture(directory: auth, capacity: 1)
            try rejected { try capped.requireNewTransaction(binding()) }; capped.close()
            checks.append(kind+"-retirement-does-not-evict-full-authority")
        }
        for mode in ["active", "commit-only", "unknown", "wrong-binding", "tampered", "truncated", "hardlink", "symlink", "permissions", "directory-symlink", "directory-permissions", "log-lock", "reentrant", "rename-before-unlink", "replace-before-unlink", "directory-replaced"] {
            let (dir,b) = try setup(mode, kind: ["active","commit-only"].contains(mode) ? mode : "committed")
            let auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let journal = logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            let original = try Data(contentsOf: journal)
            var selectedLogs = logs, lock: Int32 = -1
            switch mode {
            case "tampered": var bytes = original; bytes[bytes.count-1] ^= 1; try bytes.write(to: journal)
            case "truncated": try original.dropLast().write(to: journal)
            case "hardlink": try FileManager.default.linkItem(at: journal, to: dir.appendingPathComponent("alias"))
            case "symlink": try FileManager.default.moveItem(at: journal, to: dir.appendingPathComponent("original")); try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: dir.appendingPathComponent("original"))
            case "permissions": precondition(chmod(journal.path,0o644)==0)
            case "directory-permissions": precondition(chmod(logs.path,0o755)==0)
            case "directory-symlink": selectedLogs = dir.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: selectedLogs, withDestinationURL: logs)
            case "log-lock": lock = open(logs.path,O_RDONLY|O_DIRECTORY); precondition(lock >= 0 && flock(lock,LOCK_EX|LOCK_NB)==0)
            default: break
            }
            a.storageBoundary = { stage in
                guard stage == "retirement-before-unlink" else { return }
                if mode == "reentrant" { _ = try? a.retireLog(b, logDirectory: logs) }
                if mode == "rename-before-unlink" { try FileManager.default.moveItem(at: journal, to: dir.appendingPathComponent("moved")) }
                if mode == "replace-before-unlink" {
                    try FileManager.default.moveItem(at: journal, to: dir.appendingPathComponent("moved"))
                    try Data("must-not-delete".utf8).write(to: journal)
                }
                if mode == "directory-replaced" {
                    try FileManager.default.moveItem(at: logs, to: dir.appendingPathComponent("moved-logs"))
                    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
                    try Data("must-not-delete".utf8).write(to: journal)
                }
            }
            try rejected { _ = try a.retireLog(mode == "unknown" ? binding() : (mode == "wrong-binding" ? binding(b.transactionID,volume:"other") : b), logDirectory: selectedLogs) }
            precondition(a.failed); a.close()
            if lock >= 0 { close(lock) }
            if ["replace-before-unlink","directory-replaced"].contains(mode) {
                let data = try Data(contentsOf: journal); precondition(data == Data("must-not-delete".utf8))
            } else if mode == "rename-before-unlink" {
                let data = try Data(contentsOf: dir.appendingPathComponent("moved")); precondition(data == original)
            } else { precondition(FileManager.default.fileExists(atPath: journal.path)) }
            checks.append(mode+"-refused-without-unlinking-target")
        }
        for stage in ["retirement-before-unlink", "retirement-unlinked", "retirement-before-directory-sync", "retirement-directory-durable"] {
            for crash in [false,true] {
                let (dir,b) = try setup(stage+"-"+String(crash)), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
                if crash {
                    let child = Process(); child.executableURL = URL(fileURLWithPath: args[0]); child.arguments = [dir.path, stage, b.transactionID.uuidString]
                    try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 86)
                } else {
                    let a = try BlockJournalAuthority.fixture(directory: auth)
                    a.storageBoundary = { if $0 == stage { throw Fault.injected } }
                    try rejected { _ = try a.retireLog(b,logDirectory:logs) }; precondition(a.failed); a.close()
                }
                let r = try BlockJournalAuthority.fixture(directory: auth)
                let removed = try r.retireLog(b,logDirectory:logs); precondition(removed == (stage == "retirement-before-unlink"))
                let tombstone = try r.commitCompletion(b); precondition(tombstone != nil); r.close()
                checks.append(stage+"-"+String(crash)+"-resumes-without-forgetting-terminal")
            }
        }
        do {
            let (dir,b) = try setup("lease-through-directory-flush"), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            var verified = false
            a.storageBoundary = { stage in
                if stage == "retirement-before-directory-sync" {
                    let rival = open(logs.path,O_RDONLY|O_DIRECTORY); precondition(rival >= 0); defer { close(rival) }
                    precondition(flock(rival,LOCK_EX|LOCK_NB) != 0); verified = true
                }
            }
            let removed = try a.retireLog(b,logDirectory:logs); precondition(removed && verified); a.close()
            checks.append("directory-lease-retained-through-unlink-and-flush")
        }
        do {
            let (dir,b) = try setup("reappeared-name"), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            _ = try a.retireLog(b,logDirectory:logs)
            let journal = logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")
            a.storageBoundary = { if $0 == "retirement-directory-durable" { try Data("preserve-reappeared-name".utf8).write(to:journal) } }
            try rejected { _ = try a.retireLog(b,logDirectory:logs) }; precondition(a.failed); a.close()
            let bytes = try Data(contentsOf:journal); precondition(bytes == Data("preserve-reappeared-name".utf8))
            checks.append("absent-retry-reappeared-name-refused-and-preserved")
        }
        let report: [String:Any] = ["passed":checks.count,"checks":checks,"automaticProductionCleanup":false]
        let url = root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url)
        print("\(checks.count) passed: \(url.path)")
    }
}
