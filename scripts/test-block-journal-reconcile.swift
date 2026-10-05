import Foundation
import Darwin

private enum Fault: Error { case injected }
@main struct ReconcileTests {
    static let key = Data(repeating: 19, count: 32)
    static func rejected(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "expected-rejection", code: 1)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/block-reconcile-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        func fixture(_ name: String) throws -> (URL, BlockJournalBinding) {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return (dir, .init(transactionID: UUID(), volumeIdentity: "fixture", bootSHA256: String(repeating: "a", count: 64), deviceSize: 16384, blockSize: 4096))
        }
        for kind in (CommandLine.arguments.contains("--quota-only") ? [] : ["same", "write", "commit", "two-ahead", "wrong-prefix", "unknown-anchor", "anchor-ahead", "wrong-key", "wrong-binding", "truncated", "tampered", "save-before-failure", "save-after-failure", "wrong-receipt", "renamed-in-callback", "changed-in-callback"]) {
            let (dir, b) = try fixture(kind)
            let s = try BlockJournalStore(directory: dir, binding: b, key: key, failClosed: {})
            var trusted = s.seal
            if kind != "same" {
                if kind == "commit" { try s.commit(checkpoint: String(repeating: "b", count: 64), flushDevice: {}) }
                else { try s.record(offset: 0, before: Data(count: 4096), after: Data(repeating: 2, count: 4096)) }
            }
            if kind == "two-ahead" { try s.record(offset: 4096, before: Data(count: 4096), after: Data(repeating: 3, count: 4096)) }
            if kind == "wrong-prefix" { trusted = .init(sequence: trusted.sequence, authentication: String(repeating: "f", count: 64)) }
            if kind == "unknown-anchor" { trusted = .init(sequence: 0, authentication: trusted.authentication) }
            if kind == "anchor-ahead" { trusted = .init(sequence: 9, authentication: trusted.authentication) }
            let final = s.seal; s.close()
            let file = dir.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog")
            if kind == "truncated" { var bytes = try Data(contentsOf: file); bytes.removeLast(); try bytes.write(to: file) }
            if kind == "tampered" { var bytes = try Data(contentsOf: file); bytes[bytes.count-12] ^= 1; try bytes.write(to: file) }
            let before = try Data(contentsOf: file)
            var saves = 0
            let update: (BlockJournalSeal, BlockJournalSeal) throws -> BlockJournalSeal = { previous, next in
                precondition(previous == trusted && next == final); saves += 1
                // The directory lease remains held across the provider update.
                try rejected { _ = try BlockJournalStore(directory: dir, binding: b, key: key, failClosed: {}) }
                if kind == "save-before-failure" { throw Fault.injected }
                trusted = next
                if kind == "save-after-failure" { throw Fault.injected }
                if kind == "wrong-receipt" { return previous }
                if kind == "renamed-in-callback" { try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved")) }
                if kind == "changed-in-callback" { var bytes = try Data(contentsOf: file); bytes[bytes.count-12] ^= 1; try bytes.write(to: file) }
                return next
            }
            if ["same", "write", "commit"].contains(kind) {
                let result = try BlockJournalStore.reconcile(directory: dir, binding: b, key: key, expectedSeal: trusted, saveRecoveredSeal: update)
                precondition(result.seal == final && (result.checkpoint != nil) == (kind == "commit") && saves == (kind == "same" ? 0 : 1))
                _ = try BlockJournalStore.inspect(directory: dir, binding: b, key: key, expectedSeal: trusted)
            } else {
                let usedBinding = kind == "wrong-binding" ? BlockJournalBinding(transactionID: b.transactionID, volumeIdentity: "wrong", bootSHA256: b.bootSHA256, deviceSize: b.deviceSize, blockSize: b.blockSize) : b
                try rejected { _ = try BlockJournalStore.reconcile(directory: dir, binding: usedBinding, key: kind == "wrong-key" ? Data(repeating: 20, count: 32) : key, expectedSeal: trusted, saveRecoveredSeal: update) }
                precondition(saves == (["two-ahead", "wrong-prefix", "unknown-anchor", "anchor-ahead", "wrong-key", "wrong-binding", "truncated", "tampered"].contains(kind) ? 0 : 1))
                if kind == "save-after-failure" {
                    let retry = try BlockJournalStore.reconcile(directory: dir, binding: b, key: key, expectedSeal: trusted) { _, _ in preconditionFailure("must not update twice") }
                    precondition(retry.seal == final)
                    checks.append("durable-anchor-reply-loss-reconciles-without-second-update")
                }
            }
            if kind != "renamed-in-callback" && kind != "changed-in-callback" { let after = try Data(contentsOf: file); precondition(before == after) }
            checks.append("reconcile-"+kind)
        }
        for kind in ["byte-quota", "count-quota", "unknown-file", "existing-symlink", "existing-hardlink", "existing-permissions", "existing-directory"] {
            let (dir, b) = try fixture(kind)
            let old = dir.appendingPathComponent(UUID().uuidString.lowercased()+".blocklog")
            if kind == "existing-directory" {
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                try Data(count: 32768).write(to: old); precondition(chmod(old.path, 0o600) == 0)
                if kind == "unknown-file" { try Data([1]).write(to: dir.appendingPathComponent("unknown")) }
                if kind == "existing-symlink" { try FileManager.default.removeItem(at: old); try FileManager.default.createSymbolicLink(atPath: old.path, withDestinationPath: "/dev/null") }
                if kind == "existing-hardlink" { try FileManager.default.linkItem(at: old, to: dir.appendingPathComponent(UUID().uuidString.lowercased()+".blocklog")) }
                if kind == "existing-permissions" { precondition(chmod(old.path, 0o644) == 0) }
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            var stopped = 0
            try rejected { _ = try BlockJournalStore(directory: dir, binding: b, key: key, byteLimit: 16384,
                directoryByteLimit: kind == "byte-quota" ? 32768 : 65536, directoryFileLimit: kind == "count-quota" ? 1 : 256, failClosed: { stopped += 1 }) }
            let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            precondition(names.sorted() == after.sorted() && stopped == 1)
            checks.append("admission-"+kind+"-no-new-file")
        }
        do {
            let (dir, b) = try fixture("room")
            let a = try BlockJournalStore(directory: dir, binding: b, key: key, byteLimit: 16384, directoryByteLimit: 32768, failClosed: {})
            let firstSeal = a.seal; a.close()
            let other = BlockJournalBinding(transactionID: UUID(), volumeIdentity: "another", bootSHA256: b.bootSHA256, deviceSize: b.deviceSize, blockSize: b.blockSize)
            let second = try BlockJournalStore(directory: dir, binding: other, key: key, byteLimit: 16384, directoryByteLimit: 32768, failClosed: {}); second.close()
            _ = try BlockJournalStore.inspect(directory: dir, binding: b, key: key, expectedSeal: firstSeal)
            checks.append("admission-retains-prior-journal-and-accepts-available-budget")
        }
        let data: [String: Any] = ["passed": checks.count, "checks": checks, "deviceWritten": false, "automaticRetirement": false]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) reconciliation/quota checks; report: \(root.path)/result.json")
    }
}
