import Foundation
import Darwin

private final class Fixture {
    static let key = Data(repeating: 13, count: 32) // Public fixture key only.
    let directory: URL
    let logs: URL
    let binding: BlockJournalBinding
    let anchor: Anchor
    let fd: Int32
    var stops = 0
    var writes = 0
    var events: [String] = []
    var transaction: BlockJournalTransaction?
    init(_ directory: URL, existing: UUID? = nil) throws {
        self.directory = directory
        logs = directory.appendingPathComponent("logs")
        if existing == nil {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(repeating: 1, count: 16384).write(to: directory.appendingPathComponent("device"))
        }
        binding = .init(transactionID: existing ?? UUID(), volumeIdentity: "isolated-file", bootSHA256: String(repeating: "a", count: 64), deviceSize: 16384, blockSize: 4096)
        anchor = Anchor(directory)
        fd = open(directory.appendingPathComponent("device").path, O_RDWR)
        guard fd >= 0 else { throw Injected.fault }
        anchor.trace = { [weak self] in self?.events.append($0) }
    }
    deinit { transaction?.close(); Darwin.close(fd) }
    func start(recordLimit: Int = 4096, byteLimit: Int = 64*1024*1024,
               save: BlockJournalTransaction.SaveAnchor? = nil) throws {
        transaction = try BlockJournalTransaction(directory: logs, binding: binding, key: Self.key,
            byteLimit: byteLimit, recordLimit: recordLimit,
            saveAnchor: save ?? { [anchor] in try anchor.save($0, $1, $2) },
            stopWrites: { [weak self] in self?.stops += 1 })
    }
    func block(_ offset: Int64 = 0) throws -> Data {
        var data = Data(count: 4096)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard n == 4096 else { throw Injected.fault }; return data
    }
    func put(_ offset: Int64, _ data: Data, partial: Bool = false) throws {
        events.append("device-write"); writes += 1
        let count = partial ? data.count / 2 : data.count
        let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, count, off_t(offset)) }
        guard n == count else { throw Injected.fault }
        if partial { throw Injected.fault }
    }
    func write(_ byte: UInt8 = 2, offset: Int64 = 0, partial: Bool = false) throws {
        try transaction!.write(offset: offset, before: block(offset), after: Data(repeating: byte, count: 4096)) {
            try self.put($0, $1, partial: partial)
        }
    }
    func flush() throws {
        events.append("device-flush")
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Injected.fault }
    }
    func commit(prepare: () throws -> Void = {}) throws -> BlockJournalCommitReceipt {
        try transaction!.commit(checkpoint: String(repeating: "b", count: 64), prepare: prepare, flushDevice: flush)
    }
    func inspect() throws -> BlockJournalSnapshot {
        transaction?.close()
        guard let record = try anchor.read() else { throw Injected.fault }
        return try BlockJournalStore.inspect(directory: logs, binding: binding, key: Self.key, expectedSeal: record.seal)
    }
}

@main struct TransactionTests {
    static func rejected(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "expected-rejection", code: 1)
    }
    static func main() throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let mode = CommandLine.arguments[3]
            let f = try Fixture(URL(fileURLWithPath: CommandLine.arguments[2]), existing: UUID(uuidString: CommandLine.arguments[4])!)
            try f.start()
            if mode == "log-ahead" { f.anchor.fault = { stage, seal in if stage == "before" && seal.sequence == 2 { _exit(86) } } }
            if mode == "anchor-ahead" { f.anchor.fault = { stage, seal in if stage == "after" && seal.sequence == 2 { _exit(86) } } }
            if mode == "commit-log-ahead" { f.anchor.fault = { stage, seal in if stage == "before" && seal.sequence == 3 { _exit(86) } } }
            if mode == "commit-anchored" { f.anchor.fault = { stage, seal in if stage == "after" && seal.sequence == 3 { _exit(86) } } }
            if mode == "partial-device" {
                try f.transaction!.write(offset: 0, before: f.block(), after: Data(repeating: 2, count: 4096)) {
                    try? f.put($0, $1, partial: true); _exit(86)
                }
            }
            try f.write()
            if mode == "pending" { _exit(86) }
            _ = try f.commit()
            _exit(86)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/block-transaction-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        func fixture(_ name: String) throws -> Fixture { try Fixture(root.appendingPathComponent(name)) }
        do {
            let f = try fixture("ordering"); try f.start(); try f.write()
            let receipt = try f.commit { try f.write(3, offset: 4096) }
            precondition(f.events == ["anchor-start-1", "anchor-durable-1", "anchor-start-2", "anchor-durable-2", "device-write", "anchor-start-3", "anchor-durable-3", "device-write", "device-flush", "anchor-start-4", "anchor-durable-4"])
            precondition(f.transaction!.state == .committed && receipt.seal == f.transaction!.trustedSeal && f.stops == 0)
            let s = try f.inspect(); precondition(s.writes.count == 2 && s.checkpoint == receipt.checkpoint)
            checks.append("ordered-drain-write-flush-commit-and-anchor")
            try rejected { try f.write() }; try rejected { _ = try f.commit() }
            precondition(f.stops == 0 && f.transaction!.receipt == receipt)
            checks.append("committed-receipt-immutable-and-no-second-write-or-commit")
        }
        for sequence in 1...3 {
            for stage in ["before", "after", "wrong-receipt"] {
                let f = try fixture("anchor-\(sequence)-\(stage)")
                f.anchor.fault = { phase, seal in if seal.sequence == sequence && phase == stage { throw Injected.fault } }
                let saver: BlockJournalTransaction.SaveAnchor = { binding, previous, next in
                    let result = try f.anchor.save(binding, previous, next)
                    return next.sequence == sequence && stage == "wrong-receipt" ? .init(sequence: 999, authentication: next.authentication) : result
                }
                if sequence == 1 { try rejected { try f.start(save: saver) } }
                else {
                    try f.start(save: saver)
                    if sequence == 2 { try rejected { try f.write() } }
                    else { try f.write(); try rejected { _ = try f.commit() } }
                    precondition(f.transaction!.state == .failed && f.transaction!.receipt == nil)
                    try rejected { try f.write() }; try rejected { _ = try f.commit() }
                }
                precondition(f.stops == 1 && f.writes == (sequence == 3 ? 1 : 0))
                if stage == "before" { try rejected { _ = try f.inspect() } }
                else { let s = try f.inspect(); precondition((s.checkpoint != nil) == (sequence == 3)) }
                checks.append("anchor-\(sequence)-\(stage)-never-acknowledges-failed-operation")
                f.transaction?.close(); f.transaction = nil // Break fixture-owned test closure.
            }
        }
        for phase in ["before-write", "written", "durable"] {
            for terminal in [false, true] {
                let f = try fixture("log-\(phase)-\(terminal)"); try f.start()
                if terminal { try f.write() }
                f.transaction!.storageBoundary = { if $0 == phase { throw Injected.fault } }
                try rejected { if terminal { _ = try f.commit() } else { try f.write() } }
                precondition(f.stops == 1 && f.writes == (terminal ? 1 : 0) && f.transaction!.receipt == nil)
                if phase == "before-write" { _ = try f.inspect() }
                else { try rejected { _ = try f.inspect() } }
                checks.append("log-\(phase)-\(terminal)-failure-stops-before-acknowledgement")
            }
        }
        for phase in ["partial-device", "prepare", "flush", "swallowed-prepare-write", "swallowed-flush-write", "swallowed-nested-commit", "swallowed-nested-write", "close-in-device", "abort-in-anchor"] {
            let f = try fixture(phase); try f.start()
            try rejected {
                switch phase {
                case "partial-device": try f.write(partial: true)
                case "prepare": _ = try f.commit { throw Injected.fault }
                case "flush": _ = try f.transaction!.commit(checkpoint: String(repeating: "b", count: 64), prepare: {}, flushDevice: { throw Injected.fault })
                case "swallowed-prepare-write": _ = try f.commit { try? f.write(partial: true) }
                case "swallowed-flush-write": _ = try f.transaction!.commit(checkpoint: String(repeating: "b", count: 64), prepare: {}, flushDevice: { try? f.write() })
                case "swallowed-nested-commit": _ = try f.commit { _ = try? f.commit() }
                case "swallowed-nested-write":
                    try f.transaction!.write(offset: 0, before: f.block(), after: Data(repeating: 2, count: 4096)) { _, _ in try? f.write() }
                case "close-in-device":
                    try f.transaction!.write(offset: 0, before: f.block(), after: Data(repeating: 2, count: 4096)) { _, _ in f.transaction!.close() }
                default:
                    f.anchor.fault = { _, _ in f.transaction!.abort() }; try f.write()
                }
            }
            precondition(f.transaction!.state == .failed && f.transaction!.receipt == nil && f.stops == 1)
            try rejected { try f.write() }; try rejected { _ = try f.commit() }
            precondition(f.stops == 1)
            checks.append(phase + "-sticky-failure")
            f.anchor.fault = nil
        }
        for kind in ["record-budget", "byte-budget", "invalid-range", "invalid-checkpoint", "close-pending", "anchor-CAS-conflict"] {
            let f = try fixture(kind); try f.start(recordLimit: kind == "record-budget" ? 3 : 4096, byteLimit: kind == "byte-budget" ? 16384 : 64*1024*1024)
            if kind == "record-budget" { try f.write() }
            try rejected {
                switch kind {
                case "invalid-range": try f.transaction!.write(offset: 1, before: f.block(), after: f.block(), writeDevice: { _, _ in preconditionFailure() })
                case "invalid-checkpoint": _ = try f.transaction!.commit(checkpoint: "bad", prepare: { preconditionFailure() }, flushDevice: { preconditionFailure() })
                case "close-pending": f.transaction!.close(); _ = try f.commit()
                case "anchor-CAS-conflict":
                    let seal = BlockJournalSeal(sequence: 99, authentication: String(repeating: "c", count: 64))
                    _ = try f.anchor.save(f.binding, f.transaction!.trustedSeal, seal); try f.write()
                default: try f.write()
                }
            }
            precondition(f.transaction!.state == .failed && f.stops == 1 && f.writes == (kind == "record-budget" ? 1 : 0))
            checks.append(kind + "-refused")
        }
        do {
            let f = try fixture("repeated-block"); try f.start(); try f.write(2); try f.write(3)
            _ = try f.commit(); let s = try f.inspect(); let bytes = try f.block()
            precondition(s.writes[0].before == Data(repeating: 1, count: 4096) && s.writes[1].before == s.writes[0].after && s.writes[1].after == bytes)
            checks.append("repeated-block-preserves-each-before-image")
        }
        for mode in ["log-ahead", "anchor-ahead", "partial-device", "pending", "commit-log-ahead", "commit-anchored", "acknowledged"] {
            let f = try fixture("process-" + mode)
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--child", f.directory.path, mode, f.binding.transactionID.uuidString]
            try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 86)
            let bytes = try f.block()
            if mode == "log-ahead" || mode == "commit-log-ahead" { try rejected { _ = try f.inspect() } }
            else {
                let s = try f.inspect()
                precondition((s.checkpoint != nil) == ["commit-anchored", "acknowledged"].contains(mode))
                precondition(s.writes.count == 1 && s.writes[0].before == Data(repeating: 1, count: 4096))
            }
            if mode == "log-ahead" || mode == "anchor-ahead" { precondition(bytes == Data(repeating: 1, count: 4096)) }
            else if mode == "partial-device" { precondition(bytes == Data(repeating: 2, count: 2048) + Data(repeating: 1, count: 2048)) }
            else { precondition(bytes == Data(repeating: 2, count: 4096)) }
            checks.append("process-exit-" + mode)
        }
        let result: [String: Any] = ["passed": checks.count, "checks": checks, "hardwarePowerLossTested": false, "trustedProductionAnchor": false, "physicalDiskTouched": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) transaction checks; report: \(root.path)/result.json")
    }
}
