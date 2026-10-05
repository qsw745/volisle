import Foundation
import Darwin

private enum Fault: Error { case injected }
@main struct AuthorityTests {
    static func rejected(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "expected-rejection", code: 1)
    }
    static func binding(_ id: UUID = UUID(), volume: String = "fixture") -> BlockJournalBinding {
        .init(transactionID: id, volumeIdentity: volume, bootSHA256: String(repeating: "a", count: 64), deviceSize: 64*1024*1024, blockSize: 4096)
    }
    static func seal(_ n: Int) -> BlockJournalSeal { .init(sequence: n, authentication: String(repeating: n == 1 ? "b" : "c", count: 64)) }
    static func main() throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]), mode = CommandLine.arguments[3]
            let b = binding(UUID(uuidString: CommandLine.arguments[4])!)
            let a = try BlockJournalAuthority.fixture(directory: root)
            a.storageBoundary = { if $0 == mode { _exit(86) } }
            _ = try a.save(b, previous: nil, next: seal(1)); _exit(86)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/block-authority-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        func dir(_ name: String) throws -> URL {
            let p = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return p
        }
        do {
            let p = try dir("roundtrip"), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p)
            let key = try a.key(); precondition(key.count == 32 && key != Data(count: 32))
            let initially = try a.read(b); precondition(initially == nil)
            _ = try a.save(b, previous: nil, next: seal(1))
            _ = try a.save(b, previous: seal(1), next: seal(2))
            try rejected { _ = try BlockJournalAuthority.fixture(directory: p) }
            a.close()
            let reopened = try BlockJournalAuthority.fixture(directory: p)
            let sameKey = try reopened.key(), sameSeal = try reopened.read(b)
            let bindings = try reopened.bindings()
            precondition(sameKey == key && sameSeal == seal(2) && bindings == [b])
            reopened.close()
            checks.append("durable-key-and-CAS-roundtrip-exclusive-lease")
            let other = try BlockJournalAuthority.fixture(directory: dir("other-key"))
            let otherKey = try other.key(); precondition(otherKey != key); other.close()
            checks.append("independent-authorities-generate-distinct-keys")
        }
        for mode in ["missing-key", "missing-state", "short-key", "long-key", "wrong-key", "bad-state", "truncated-state", "oversize-state", "key-link", "state-link", "key-symlink", "state-symlink", "key-permissions", "state-permissions", "directory-permissions"] {
            let p = try dir(mode), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p); _ = try a.save(b, previous: nil, next: seal(1)); a.close()
            let key = p.appendingPathComponent("key.bin"), state = p.appendingPathComponent("anchors.json")
            switch mode {
            case "missing-key": try FileManager.default.removeItem(at: key)
            case "missing-state": try FileManager.default.removeItem(at: state)
            case "short-key": try Data(count: 31).write(to: key)
            case "long-key": try Data(count: 33).write(to: key)
            case "wrong-key": try Data(repeating: 1, count: 32).write(to: key)
            case "bad-state": var data = try Data(contentsOf: state); data[data.count/2] ^= 1; try data.write(to: state)
            case "truncated-state": var data = try Data(contentsOf: state); data.removeLast(); try data.write(to: state)
            case "oversize-state": try Data(count: 1024*1024).write(to: state)
            case "key-link", "state-link": try FileManager.default.linkItem(at: mode == "key-link" ? key : state, to: p.appendingPathComponent("alias"))
            case "key-symlink", "state-symlink":
                let target = mode == "key-symlink" ? key : state, moved = p.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: target, to: moved); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            case "key-permissions", "state-permissions": precondition(chmod((mode == "key-permissions" ? key : state).path, 0o644) == 0)
            default: precondition(chmod(p.path, 0o755) == 0)
            }
            let before = try? Data(contentsOf: key)
            try rejected { _ = try BlockJournalAuthority.fixture(directory: p) }
            let after = try? Data(contentsOf: key); precondition(before == after)
            checks.append(mode + "-refused-without-key-regeneration")
        }
        for mode in ["unknown-file", "orphan-temp", "directory-symlink", "ancestor-symlink"] {
            let p = try dir(mode)
            var target = p
            if mode == "unknown-file" || mode == "orphan-temp" {
                try Data("old-state".utf8).write(to: p.appendingPathComponent(mode == "unknown-file" ? "unknown" : "anchors.tmp"))
            } else {
                let link = root.appendingPathComponent(mode + "-link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: p)
                target = link
                if mode == "ancestor-symlink" {
                    try FileManager.default.createDirectory(at: p.appendingPathComponent("nested"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    target = link.appendingPathComponent("nested")
                }
            }
            try rejected { _ = try BlockJournalAuthority.fixture(directory: target) }
            precondition(!FileManager.default.fileExists(atPath: p.appendingPathComponent("key.bin").path))
            checks.append(mode + "-refused-before-bootstrap")
        }
        for mode in ["duplicate", "stale", "skip", "wrong-binding", "bad-seal", "invalid-binding", "capacity", "live-state-change", "live-key-change", "live-dir-rename", "closed"] {
            let p = try dir(mode), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p, capacity: 1)
            _ = try a.save(b, previous: nil, next: seal(1))
            try rejected {
                switch mode {
                case "duplicate": _ = try a.save(b, previous: nil, next: seal(1))
                case "stale": _ = try a.save(b, previous: seal(2), next: seal(3))
                case "skip": _ = try a.save(b, previous: seal(1), next: seal(3))
                case "wrong-binding": _ = try a.save(binding(b.transactionID, volume: "other"), previous: seal(1), next: seal(2))
                case "bad-seal": _ = try a.save(b, previous: seal(1), next: .init(sequence: 2, authentication: "bad"))
                case "invalid-binding": _ = try a.save(binding(volume: ""), previous: nil, next: seal(1))
                case "capacity": _ = try a.save(binding(), previous: nil, next: seal(1))
                case "live-state-change": try Data("changed".utf8).write(to: p.appendingPathComponent("anchors.json")); _ = try a.save(b, previous: seal(1), next: seal(2))
                case "live-key-change": try Data(repeating: 0, count: 32).write(to: p.appendingPathComponent("key.bin")); _ = try a.save(b, previous: seal(1), next: seal(2))
                case "live-dir-rename": try FileManager.default.moveItem(at: p, to: p.appendingPathExtension("moved")); _ = try a.save(b, previous: seal(1), next: seal(2))
                default: a.close(); _ = try a.save(b, previous: seal(1), next: seal(2))
                }
            }
            precondition(a.failed)
            try rejected { _ = try a.key() }; a.close()
            if mode == "capacity" {
                let reopened = try BlockJournalAuthority.fixture(directory: p)
                let retained = try reopened.read(b); precondition(retained == seal(1)); reopened.close()
            }
            checks.append(mode + "-fails-closed")
        }
        for stage in ["before-write", "written", "file-durable", "renamed", "directory-durable"] {
            let p = try dir("fault-"+stage), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p)
            a.storageBoundary = { if $0 == stage { throw Fault.injected } }
            try rejected { _ = try a.save(b, previous: nil, next: seal(1)) }
            precondition(a.failed); a.close()
            let reopened = try BlockJournalAuthority.fixture(directory: p)
            let saved = try reopened.read(b)
            precondition(saved == (["renamed", "directory-durable"].contains(stage) ? seal(1) : nil))
            reopened.close(); checks.append("write-fault-"+stage+"-no-false-success")
        }
        for stage in ["written", "file-durable", "renamed", "directory-durable"] {
            let p = try dir("process-"+stage), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p); a.close()
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--child", p.path, stage, b.transactionID.uuidString]
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 86)
            // A pre-rename process death leaves an orphan temp. Refuse and retain
            // it for reconciliation rather than silently discarding evidence.
            if stage == "written" || stage == "file-durable" {
                try rejected { _ = try BlockJournalAuthority.fixture(directory: p) }
            } else {
                let reopened = try BlockJournalAuthority.fixture(directory: p)
                let saved = try reopened.read(b); precondition(saved == seal(1)); reopened.close()
            }
            checks.append("process-exit-"+stage)
        }
        do {
            let p = try dir("transaction"), logs = try dir("transaction-logs"), b = binding()
            let a = try BlockJournalAuthority.fixture(directory: p)
            let key = try a.key()
            let t = try BlockJournalTransaction(directory: logs, binding: b, key: key, saveAnchor: { try a.save($0, previous: $1, next: $2) }, stopWrites: {})
            var device = Data(count: 4096)
            try t.write(offset: 0, before: device, after: Data(repeating: 2, count: 4096)) { _, data in
                let saved = try a.read(b); precondition(saved == t.trustedSeal); device = data
            }
            let receipt = try t.commit(checkpoint: String(repeating: "f", count: 64), prepare: {}, flushDevice: {})
            t.close(); a.close()
            let reopened = try BlockJournalAuthority.fixture(directory: p)
            let trusted = try reopened.read(b)!
            let snapshot = try BlockJournalStore.inspect(directory: logs, binding: b, key: reopened.key(), expectedSeal: trusted)
            precondition(snapshot.seal == receipt.seal && snapshot.checkpoint == receipt.checkpoint && device == Data(repeating: 2, count: 4096))
            reopened.close(); checks.append("real-authority-transaction-reopen-authenticated-inspection")
        }
        if getuid() != 0 {
            try rejected { _ = try BlockJournalAuthority.system() }
            checks.append("non-root-cannot-open-production-authority")
        }
        try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks, "rootServiceInstalled": false, "hardwarePowerLossTested": false], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) authority checks; report: \(root.path)/result.json")
    }
}
