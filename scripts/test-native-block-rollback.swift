import Foundation

private enum Fault: Error { case injected }
@main struct RollbackTests {
    static let binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: "memory-device", bootSHA256: String(repeating: "a", count: 64), deviceSize: 8192, blockSize: 4096)
    static func snapshot(_ writes: [BlockJournalWrite], committed: Bool = false, identity: BlockJournalBinding = binding) -> BlockJournalSnapshot {
        .init(binding: identity, writes: writes, checkpoint: committed ? String(repeating: "b", count: 64) : nil,
              seal: .init(sequence: writes.count+1, authentication: String(repeating: "c", count: 64)))
    }
    static func rejected(_ run: () throws -> Void) throws {
        do { try run() } catch { return }; throw Fault.injected
    }
    static func main() throws {
        let zero = Data(count: 4096), one = Data(repeating: 1, count: 4096), two = Data(repeating: 2, count: 4096)
        let base = zero + zero
        let history = [BlockJournalWrite(offset: 0, before: zero, after: one),
                       BlockJournalWrite(offset: 4096, before: zero, after: two)]
        var checks: [String] = []
        for mode in ["normal", "half-written", "already-restored", "repeated-block", "empty", "unknown-byte", "broken-history", "invalid-offset", "short-record", "committed", "wrong-binding", "read-failure", "short-read", "virtual-validation-failure", "unlogged-change", "preflight-change", "partial-recovery-write", "write-failure", "flush-failure", "final-readback-change", "final-validation-failure", "swallowed-nested-restore"] {
            var device = one+two, records = history
            var writes = 0, reads = 0, flushes = 0, validations = 0
            if mode == "half-written" { device = one.prefix(2048) + zero.prefix(2048) + two }
            if mode == "already-restored" || mode == "empty" { device = base }
            if mode == "empty" { records = [] }
            if mode == "repeated-block" { records.append(.init(offset: 0, before: one, after: two)); device = two+two }
            if mode == "unknown-byte" { device[8191] = 99 }
            if mode == "broken-history" { records.append(.init(offset: 0, before: zero, after: two)) }
            if mode == "invalid-offset" { records[0] = .init(offset: 1, before: zero, after: one) }
            if mode == "short-record" { records[0] = .init(offset: 0, before: Data(count: 2), after: Data(count: 2)) }
            if mode == "unlogged-change" { records = [history[0]]; device[8191] = 99 }
            let engine = BlockJournalRollback()
            let log = snapshot(records, committed: mode == "committed")
            let identity = mode == "wrong-binding" ? BlockJournalBinding(transactionID: UUID(), volumeIdentity: binding.volumeIdentity, bootSHA256: binding.bootSHA256, deviceSize: binding.deviceSize, blockSize: binding.blockSize) : binding
            let attempt = {
                try engine.restore(snapshot: log, expectedBinding: identity, read: { offset, count in
                    reads += 1
                    if mode == "read-failure" { throw Fault.injected }
                    if mode == "short-read" { return Data(count: count-1) }
                    return device.subdata(in: Int(offset)..<Int(offset)+count)
                }, write: { offset, bytes in
                    writes += 1
                    if mode == "write-failure" { throw Fault.injected }
                    if mode == "partial-recovery-write" && writes == 1 {
                        device.replaceSubrange(Int(offset)..<Int(offset)+bytes.count/2, with: bytes.prefix(bytes.count/2)); throw Fault.injected
                    }
                    device.replaceSubrange(Int(offset)..<Int(offset)+bytes.count, with: bytes)
                }, flush: {
                    flushes += 1
                    if mode == "flush-failure" { throw Fault.injected }
                    if mode == "final-readback-change" { device[0] = 88 }
                }, validateRestoredView: { read in
                    validations += 1
                    if mode == "swallowed-nested-restore" {
                        _ = try? engine.restore(snapshot: log, expectedBinding: binding, read: { _, n in Data(count: n) }, write: { _, _ in }, flush: {}, validateRestoredView: { _ in })
                    }
                    if mode == "virtual-validation-failure" || (mode == "final-validation-failure" && validations == 2) { throw Fault.injected }
                    // Read across both cache blocks, exercising overlay splitting.
                    let restored = try read(0, 8192)
                    guard restored == base else { throw Fault.injected }
                    if mode == "preflight-change" && validations == 1 { device[4096] = 99 }
                })
            }
            if ["normal", "half-written", "already-restored", "repeated-block", "empty"].contains(mode) {
                let result = try attempt()
                precondition(device == base && result.restoredBlocks == writes && flushes == 1 && validations == 2)
                try rejected { _ = try attempt() }
            } else {
                try rejected { _ = try attempt() }; precondition(engine.failed)
                if !["partial-recovery-write", "write-failure", "flush-failure", "final-readback-change", "final-validation-failure"].contains(mode) { precondition(writes == 0) }
                let oldWrites = writes; try rejected { _ = try attempt() }; precondition(writes == oldWrites)
                if mode == "partial-recovery-write" || mode == "flush-failure" {
                    let retry = BlockJournalRollback()
                    _ = try retry.restore(snapshot: log, expectedBinding: binding,
                        read: { device.subdata(in: Int($0)..<Int($0)+$1) },
                        write: { device.replaceSubrange(Int($0)..<Int($0)+$1.count, with: $1) }, flush: {},
                        validateRestoredView: { read in guard try read(0, 8192) == base else { throw Fault.injected } })
                    precondition(device == base); checks.append(mode+"-new-instance-resumes")
                }
            }
            checks.append(mode)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/native-rollback-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) native rollback checks; report: \(root.path)/result.json")
    }
}
