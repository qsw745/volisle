import Foundation
import Darwin
import CryptoKit

private enum Fault: Error { case injected }
@main struct CompletionTests {
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
            let a = try BlockJournalAuthority.fixture(directory: root.appendingPathComponent("authority"), recovering: stage.hasPrefix("recovery-"))
            a.storageBoundary = { if $0 == stage { _exit(86) } }
            if stage.hasPrefix("recovery-") {
                try a.finishInterruptedPublication(logDirectory: root.appendingPathComponent("logs"), validateRecovery: { _, cp in precondition(cp == checkpoint) })
            } else {
                _ = try a.recover(binding(UUID(uuidString: args[3])!), logDirectory: root.appendingPathComponent("logs"), checkpoint: checkpoint, restoreAndValidate: { _ in })
            }
            _exit(87)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/completion-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        func setup(_ name: String, committed: Bool = false) throws -> (URL, BlockJournalBinding) {
            let dir = root.appendingPathComponent(name), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            for p in [auth, logs] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let a = try BlockJournalAuthority.fixture(directory: auth), b = binding()
            let s = try BlockJournalStore(directory: logs, binding: b, key: a.key(), failClosed: {})
            _ = try a.save(b, previous: nil, next: s.seal)
            let old = s.seal
            if committed { try s.commit(checkpoint: checkpoint, flushDevice: {}) }
            else { try s.record(offset: 0, before: Data(count: 4096), after: Data(repeating: 1, count: 4096)) }
            _ = try a.save(b, previous: old, next: s.seal)
            s.close(); a.close(); return (dir, b)
        }
        func child(_ dir: URL, _ b: BlockJournalBinding, _ stage: String) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = [dir.path, stage, b.transactionID.uuidString]
            try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 86)
        }
        do {
            let (dir, b) = try setup("roundtrip"), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            let seal = try a.read(b)!, before = try Data(contentsOf: logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog"))
            var called = 0
            let completed = try a.recover(b, logDirectory: logs, checkpoint: checkpoint) { snapshot in
                precondition(snapshot.seal == seal && snapshot.checkpoint == nil); called += 1
                try rejected { _ = try BlockJournalStore.inspect(directory: logs, binding: b, key: Data(count: 32), expectedSeal: seal) }
            }
            precondition(called == 1 && completed.seal == seal && completed.checkpoint == checkpoint)
            a.close()
            let r = try BlockJournalAuthority.fixture(directory: auth)
            let saved = try r.recoveryCompletion(b); precondition(saved == completed)
            let pending = try r.unresolvedBindings(); precondition(pending.isEmpty)
            let next = binding(); try r.requireNewTransaction(next)
            _ = try r.save(next, previous: nil, next: .init(sequence: 1, authentication: String(repeating: "b", count: 64)))
            let after = try Data(contentsOf: logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")); precondition(before == after)
            r.close(); checks.append("completion-durable-new-session-admitted-old-log-preserved")
            for operation in ["read", "save", "recover", "reuse"] {
                let q = try BlockJournalAuthority.fixture(directory: auth)
                var restored = false
                try rejected {
                    switch operation {
                    case "read": _ = try q.read(b)
                    case "save": _ = try q.save(b, previous: seal, next: .init(sequence: seal.sequence+1, authentication: String(repeating: "e", count: 64)))
                    case "reuse": try q.requireNewTransaction(b)
                    default: _ = try q.recover(b, logDirectory: logs, checkpoint: checkpoint) { _ in restored = true }
                    }
                }
                precondition(!restored && q.failed); q.close(); checks.append("completed-old-transaction-"+operation+"-refused")
            }
        }
        for mode in ["admission", "direct-save", "changed-geometry", "committed", "bad-checkpoint", "callback-error", "reentrant", "log-mutated", "wrong-binding", "missing-log", "different-volume"] {
            let (dir, b) = try setup(mode, committed: mode == "committed")
            let auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            if mode == "different-volume" {
                let other = binding(volume: "another"); try a.requireNewTransaction(other)
                _ = try a.save(other, previous: nil, next: .init(sequence: 1, authentication: String(repeating: "b", count: 64)))
            } else {
                var invoked = false
                try rejected {
                    if mode == "admission" { try a.requireNewTransaction(binding()) }
                    else if mode == "direct-save" { _ = try a.save(binding(), previous: nil, next: .init(sequence: 1, authentication: String(repeating: "b", count: 64))) }
                    else if mode == "changed-geometry" {
                        let changed = BlockJournalBinding(transactionID: UUID(), volumeIdentity: b.volumeIdentity, bootSHA256: String(repeating: "f", count: 64), deviceSize: 16384, blockSize: 4096)
                        try a.requireNewTransaction(changed)
                    } else {
                        if mode == "missing-log" { try FileManager.default.removeItem(at: logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")) }
                        _ = try a.recover(mode == "wrong-binding" ? binding(b.transactionID, volume: "other") : b, logDirectory: logs, checkpoint: mode == "bad-checkpoint" ? "bad" : checkpoint) { _ in
                            invoked = true
                            if mode == "log-mutated" {
                                let file = logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")
                                var bytes = try Data(contentsOf: file); bytes[bytes.count-1] ^= 1; try bytes.write(to: file)
                            }
                            if mode == "callback-error" { throw Fault.injected }
                            if mode == "reentrant" { try? a.requireNewTransaction(binding(volume: "other")) }
                        }
                    }
                }
                precondition(a.failed)
                if !["callback-error", "reentrant", "log-mutated"].contains(mode) { precondition(!invoked) }
            }
            a.close()
            let reopened = try BlockJournalAuthority.fixture(directory: auth)
            let completed = try reopened.recoveryCompletion(b); precondition(completed == nil); reopened.close()
            checks.append(mode+"-fenced")
        }
        for stage in ["before-write", "written", "file-durable", "renamed", "directory-durable"] {
            let (dir, b) = try setup("throw-"+stage), auth = dir.appendingPathComponent("authority")
            let a = try BlockJournalAuthority.fixture(directory: auth)
            a.storageBoundary = { if $0 == stage { throw Fault.injected } }
            try rejected { _ = try a.recover(b, logDirectory: dir.appendingPathComponent("logs"), checkpoint: checkpoint) { _ in } }
            precondition(a.failed); a.close()
            let r = try BlockJournalAuthority.fixture(directory: auth)
            let value = try r.recoveryCompletion(b); precondition((value != nil) == ["renamed", "directory-durable"].contains(stage)); r.close()
            checks.append("publication-throw-"+stage)
        }
        for mode in ["written", "file-durable", "renamed", "directory-durable", "no-validator", "validator-fails", "missing-log", "recovery-before-rename", "recovery-after-rename", "recovery-after-durable"] {
            let (dir, b) = try setup("crash-"+mode), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            try child(dir, b, ["renamed", "directory-durable", "written"].contains(mode) ? mode : "file-durable")
            if mode.hasPrefix("recovery-") { try child(dir, b, mode) }
            let r = try BlockJournalAuthority.fixture(directory: auth, recovering: true)
            if ["no-validator", "validator-fails", "missing-log"].contains(mode) {
                if mode == "missing-log" { try FileManager.default.removeItem(at: logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")) }
                try rejected {
                    if mode == "no-validator" { try r.finishInterruptedPublication(logDirectory: logs) }
                    else { try r.finishInterruptedPublication(logDirectory: logs, validateRecovery: { _, _ in throw Fault.injected }) }
                }
                precondition(r.failed && r.hasInterruptedPublication)
            } else {
                var checksDevice = 0
                if r.hasInterruptedPublication { try r.finishInterruptedPublication(logDirectory: logs, validateRecovery: { observed, cp in
                    precondition(observed == b && cp == checkpoint); checksDevice += 1
                }) }
                let saved = try r.recoveryCompletion(b); precondition(saved?.checkpoint == checkpoint)
                if ["written", "file-durable", "recovery-before-rename"].contains(mode) { precondition(checksDevice == 1) }
            }
            r.close(); checks.append("process-exit-"+mode)
        }
        for mode in ["legacy-upgrade", "legacy-terminal", "terminal-seal-changed", "terminal-new-entry", "terminal-rewritten", "terminal-reopened", "unresolved-new-session", "bad-checkpoint-value", "retained-capacity"] {
            let (dir, b) = try setup("format-"+mode), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            let state = auth.appendingPathComponent("anchors.json")
            if ["terminal-rewritten", "terminal-reopened", "retained-capacity"].contains(mode) {
                let a = try BlockJournalAuthority.fixture(directory: auth)
                _ = try a.recover(b, logDirectory: logs, checkpoint: checkpoint) { _ in }; a.close()
            }
            if mode == "retained-capacity" {
                let a = try BlockJournalAuthority.fixture(directory: auth, capacity: 1)
                try rejected { try a.requireNewTransaction(binding(volume: "other")) }; a.close()
                let r = try BlockJournalAuthority.fixture(directory: auth, capacity: 1)
                let completed = try r.recoveryCompletion(b); precondition(completed != nil); r.close()
            } else {
                let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
                var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
                var values = payload["entries"] as! [[String: Any]]
                if mode == "legacy-upgrade" { payload["version"] = 1 }
                else if mode == "unresolved-new-session" || mode == "terminal-new-entry" {
                    var extra = values[0], identity = extra["binding"] as! [String: Any]
                    identity["transactionID"] = UUID().uuidString; extra["binding"] = identity; extra["sequence"] = 1
                    if mode == "terminal-new-entry" { extra["recoveryCheckpoint"] = checkpoint }
                    values.append(extra)
                } else {
                    values[0]["recoveryCheckpoint"] = checkpoint
                    if mode == "legacy-terminal" { payload["version"] = 1 }
                    if mode == "terminal-seal-changed" { values[0]["authentication"] = String(repeating: "e", count: 64) }
                    if mode == "terminal-rewritten" { values[0]["recoveryCheckpoint"] = String(repeating: "e", count: 64) }
                    if mode == "terminal-reopened" { values[0].removeValue(forKey: "recoveryCheckpoint"); values[0]["sequence"] = 3; values[0]["authentication"] = String(repeating: "e", count: 64) }
                    if mode == "bad-checkpoint-value" { values[0]["recoveryCheckpoint"] = "bad" }
                }
                payload["entries"] = values
                let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let key = try Data(contentsOf: auth.appendingPathComponent("key.bin"))
                let tag = Data(HMAC<SHA256>.authenticationCode(for: Data("VolisleBlockAuthority/v1|".utf8)+raw, using: SymmetricKey(data: key)))
                let bytes = try JSONSerialization.data(withJSONObject: ["payload": raw.base64EncodedString(), "authentication": tag.base64EncodedString()], options: [.sortedKeys])
                let target = mode == "legacy-upgrade" ? state : auth.appendingPathComponent("anchor-"+UUID().uuidString.lowercased()+".tmp")
                try bytes.write(to: target); precondition(chmod(target.path, 0o600) == 0)
                if mode == "legacy-upgrade" {
                    let a = try BlockJournalAuthority.fixture(directory: auth)
                    _ = try a.recover(b, logDirectory: logs, checkpoint: checkpoint) { _ in }; a.close()
                    let r = try BlockJournalAuthority.fixture(directory: auth)
                    let completed = try r.recoveryCompletion(b); precondition(completed != nil); r.close()
                    let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
                    let upgraded = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded["payload"] as! String)!) as! [String: Any]
                    precondition(upgraded["version"] as! Int == 4)
                } else {
                    let original = try Data(contentsOf: state)
                    try rejected { _ = try BlockJournalAuthority.fixture(directory: auth, recovering: true) }
                    let unchanged = try Data(contentsOf: state); precondition(original == unchanged)
                }
            }
            checks.append(mode+"-authenticated-format-transition")
        }
        let report: [String: Any] = ["passed": checks.count, "checks": checks, "productionDeviceLease": false]
        let url = root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("\(checks.count) passed: \(url.path)")
    }
}
