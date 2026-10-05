import Foundation
import Darwin
import CryptoKit

private enum Fault: Error { case injected }
@main struct PublicationTests {
    static func binding(_ id: UUID) -> BlockJournalBinding {
        .init(transactionID: id, volumeIdentity: "fixture", bootSHA256: String(repeating: "a", count: 64), deviceSize: 16384, blockSize: 4096)
    }
    static func rejected(_ work: () throws -> Void) throws {
        do { try work() } catch { return }; throw Fault.injected
    }
    static func main() throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--recover" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]), stage = CommandLine.arguments[3]
            let r = try BlockJournalAuthority.fixture(directory: root.appendingPathComponent("authority"), recovering: true)
            r.storageBoundary = { if $0 == stage { _exit(86) } }
            try r.finishInterruptedPublication(logDirectory: root.appendingPathComponent("logs")); _exit(87)
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]), mode = CommandLine.arguments[3]
            let b = binding(UUID(uuidString: CommandLine.arguments[4])!)
            let a = try BlockJournalAuthority.fixture(directory: root.appendingPathComponent("authority"))
            let s = try BlockJournalStore(directory: root.appendingPathComponent("logs"), binding: b, key: a.key(), failClosed: {})
            if mode != "initial" {
                _ = try a.save(b, previous: nil, next: s.seal)
                if mode == "commit" { try s.commit(checkpoint: String(repeating: "b", count: 64), flushDevice: {}) }
                else { try s.record(offset: 0, before: Data(count: 4096), after: Data(repeating: 3, count: 4096)) }
            }
            let old = try a.read(b)
            a.storageBoundary = { if $0 == "file-durable" { _exit(86) } }
            _ = try a.save(b, previous: old, next: s.seal); _exit(87)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/publication-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        for mode in ["initial", "write", "commit", "tampered-temp", "partial-temp", "missing-log", "tampered-log", "wrong-log", "second-temp", "temp-symlink", "temp-hardlink", "temp-permissions", "ordinary-access", "stale", "removed-entry", "skip-sequence", "identity-change", "two-updates", "wrong-prefix", "log-active", "before-rename", "after-rename", "after-durable", "process-before-rename", "process-after-rename", "process-after-durable"] {
            let dir = root.appendingPathComponent(mode), auth = dir.appendingPathComponent("authority"), logs = dir.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let a = try BlockJournalAuthority.fixture(directory: auth); a.close()
            let b = binding(UUID())
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--child", dir.path, ["initial", "commit"].contains(mode) ? mode : "write", b.transactionID.uuidString]
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 86)
            let files = try FileManager.default.contentsOfDirectory(at: auth, includingPropertiesForKeys: nil)
            let temp = files.first { $0.pathExtension == "tmp" }!
            let journal = logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")
            let originalState = try Data(contentsOf: auth.appendingPathComponent("anchors.json"))
            try rejected { _ = try BlockJournalAuthority.fixture(directory: auth) }
            switch mode {
            case "tampered-temp": var bytes = try Data(contentsOf: temp); bytes[bytes.count/2] ^= 1; try bytes.write(to: temp)
            case "partial-temp": let bytes = try Data(contentsOf: temp); try bytes.prefix(bytes.count/2).write(to: temp)
            case "missing-log": try FileManager.default.removeItem(at: journal)
            case "tampered-log": var bytes = try Data(contentsOf: journal); bytes[bytes.count-12] ^= 1; try bytes.write(to: journal)
            case "wrong-log": try FileManager.default.moveItem(at: journal, to: logs.appendingPathComponent(UUID().uuidString.lowercased()+".blocklog"))
            case "second-temp": try FileManager.default.copyItem(at: temp, to: auth.appendingPathComponent("anchor-"+UUID().uuidString.lowercased()+".tmp"))
            case "temp-symlink": try FileManager.default.removeItem(at: temp); try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: auth.appendingPathComponent("anchors.json"))
            case "temp-hardlink": try FileManager.default.linkItem(at: temp, to: dir.appendingPathComponent("alias"))
            case "temp-permissions": precondition(chmod(temp.path, 0o644) == 0)
            default: break
            }
            if mode == "stale" { try originalState.write(to: temp) }
            if ["removed-entry", "skip-sequence", "identity-change", "two-updates", "wrong-prefix"].contains(mode) {
                // Deliberately valid authentication tests transition validation,
                // not just rejection of a broken MAC. This is a fixture key.
                let target = mode == "wrong-prefix" ? auth.appendingPathComponent("anchors.json") : temp
                let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as! [String: Any]
                var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
                var values = payload["entries"] as! [[String: Any]]
                if mode == "removed-entry" { values = [] }
                if mode == "skip-sequence" { values[0]["sequence"] = 4 }
                if mode == "wrong-prefix" { values[0]["authentication"] = String(repeating: "f", count: 64) }
                if mode == "identity-change" {
                    var identity = values[0]["binding"] as! [String: Any]; identity["volumeIdentity"] = "other"; values[0]["binding"] = identity
                }
                if mode == "two-updates" {
                    var extra = values[0], identity = extra["binding"] as! [String: Any]
                    identity["transactionID"] = UUID().uuidString; extra["binding"] = identity; extra["sequence"] = 1; values.append(extra)
                }
                payload["entries"] = values
                let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let key = try Data(contentsOf: auth.appendingPathComponent("key.bin"))
                let tag = Data(HMAC<SHA256>.authenticationCode(for: Data("VolisleBlockAuthority/v1|".utf8)+raw, using: SymmetricKey(data: key)))
                try JSONSerialization.data(withJSONObject: ["payload": raw.base64EncodedString(), "authentication": tag.base64EncodedString()], options: [.sortedKeys]).write(to: target)
            }
            let expectedState = try Data(contentsOf: auth.appendingPathComponent("anchors.json"))
            if ["initial", "write", "commit"].contains(mode) {
                let r = try BlockJournalAuthority.fixture(directory: auth, recovering: true)
                precondition(r.hasInterruptedPublication)
                try r.finishInterruptedPublication(logDirectory: logs)
                precondition(!r.hasInterruptedPublication)
                let seal = try r.read(b)!
                let snapshot = try BlockJournalStore.inspect(directory: logs, binding: b, key: r.key(), expectedSeal: seal)
                precondition((snapshot.checkpoint != nil) == (mode == "commit"))
                r.close()
                let reopened = try BlockJournalAuthority.fixture(directory: auth)
                let saved = try reopened.read(b); precondition(saved == seal); reopened.close()
            } else if ["before-rename", "after-rename", "after-durable", "process-before-rename", "process-after-rename", "process-after-durable"].contains(mode) {
                if mode.hasPrefix("process-") {
                    let crash = Process(); crash.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    crash.arguments = ["--recover", dir.path, "recovery-"+String(mode.dropFirst(8))]
                    try crash.run(); crash.waitUntilExit(); precondition(crash.terminationStatus == 86)
                } else {
                    let r = try BlockJournalAuthority.fixture(directory: auth, recovering: true)
                    r.storageBoundary = { if $0 == "recovery-"+mode { throw Fault.injected } }
                    try rejected { try r.finishInterruptedPublication(logDirectory: logs) }; precondition(r.failed); r.close()
                }
                let retry = try BlockJournalAuthority.fixture(directory: auth, recovering: true)
                if retry.hasInterruptedPublication { try retry.finishInterruptedPublication(logDirectory: logs) }
                let seal = try retry.read(b)!; _ = try BlockJournalStore.inspect(directory: logs, binding: b, key: retry.key(), expectedSeal: seal)
                retry.close()
            } else {
                let lock = mode == "log-active" ? open(logs.path, O_RDONLY | O_DIRECTORY) : -1
                if lock >= 0 { precondition(flock(lock, LOCK_EX | LOCK_NB) == 0) }
                defer { if lock >= 0 { _ = flock(lock, LOCK_UN); Darwin.close(lock) } }
                try rejected {
                    let r = try BlockJournalAuthority.fixture(directory: auth, recovering: true); defer { r.close() }
                    if mode == "ordinary-access" { _ = try r.key() }
                    else { try r.finishInterruptedPublication(logDirectory: logs) }
                }
                let after = try Data(contentsOf: auth.appendingPathComponent("anchors.json")); precondition(after == expectedState)
                precondition(FileManager.default.fileExists(atPath: temp.path))
            }
            checks.append(mode)
        }
        try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks, "deviceWritten": false], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) publication checks; report: \(root.path)/result.json")
    }
}
