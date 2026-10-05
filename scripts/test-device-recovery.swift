import Foundation
import Darwin
import CryptoKit

private enum Fault: Error { case expectedRejection, injected }
private final class Transport {
    let binding: BlockJournalBinding
    let lease = UUID()
    var bytes = Data(repeating: 0, count: 8192)
    var owns = true, released = 0, reads = 0, writes = 0, flushes = 0
    var beforeRead: (() throws -> Void)?
    var failFlush = false
    init(_ binding: BlockJournalBinding) { self.binding = binding }
    func session() throws -> BlockJournalDeviceSession {
        try .init(binding: binding, connectionIdentity: "this-connection", leaseID: lease,
            observe: { .init(volumeIdentity: self.binding.volumeIdentity, bootSHA256: self.binding.bootSHA256,
                deviceSize: 8192, blockSize: 4096, connectionIdentity: "this-connection", leaseID: self.lease,
                ownsLease: self.owns, mounted: false, writable: true) },
            read: { offset, count in self.reads += 1; try self.beforeRead?(); return self.bytes.subdata(in: Int(offset)..<Int(offset)+count) },
            write: { offset, data in self.writes += 1; self.bytes.replaceSubrange(Int(offset)..<Int(offset)+data.count, with: data) },
            flush: { self.flushes += 1; if self.failFlush { throw Fault.injected } },
            stopWrites: {}, release: { self.released += 1 })
    }
}
@main struct DeviceRecoveryTests {
    static func require(_ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { throw Fault.expectedRejection }
    }
    static func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw Fault.expectedRejection
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/device-recovery-"+UUID().uuidString.lowercased())
        var checks: [String] = []
        for mode in ["success", "unscoped-guard", "bad-log", "missing-baseline", "changed-binding", "committed", "unknown",
                     "wrong-device-transaction", "validator-reject", "factory-reentry", "validator-reentry",
                     "authority-changes-during-read", "flush-failure", "publication-failure", "late-disconnect"] {
            let dir = root.appendingPathComponent(mode), logs = dir.appendingPathComponent("logs"), database = dir.appendingPathComponent("authority")
            for path in [logs, database] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let pool = try BlockJournalStore.pool(directory: logs)
            let authority = try BlockJournalAuthority.fixture(directory: database, pool: pool)
            let baseline = digest(Data(count: 8192))
            let binding = try authority.newBinding(volumeIdentity: "fixture", bootSHA256: String(repeating:"a",count:64),
                deviceSize: 8192, blockSize: 4096, recoveryBaselineSHA256: mode == "missing-baseline" ? nil : baseline)
            let deviceBinding = BlockJournalBinding(transactionID: mode == "wrong-device-transaction" ? UUID() : binding.transactionID,
                volumeIdentity: binding.volumeIdentity, bootSHA256: binding.bootSHA256, deviceSize: binding.deviceSize,
                blockSize: binding.blockSize, authorityEpoch: binding.authorityEpoch, recoveryBaselineSHA256: binding.recoveryBaselineSHA256)
            let transport = Transport(deviceBinding)
            let tx = try authority.beginTransaction(binding, stopWrites: {})
            try tx.write(offset: 0, before: Data(count: 4096), after: Data(repeating: 1, count: 4096)) {
                transport.bytes.replaceSubrange(Int($0)..<Int($0)+$1.count, with: $1)
            }
            if mode == "committed" { _ = try tx.commit(checkpoint: baseline, prepare: {}, flushDevice: {}) }
            tx.close()
            let originalState = try Data(contentsOf: database.appendingPathComponent("anchors.json"))
            var requested = binding
            if mode == "changed-binding" { requested.recoveryBaselineSHA256 = String(repeating:"b",count:64) }
            if mode == "unknown" {
                requested = try authority.newBinding(volumeIdentity: "another", bootSHA256: binding.bootSHA256,
                    deviceSize: 8192, blockSize: 4096, recoveryBaselineSHA256: baseline)
            }
            if mode == "bad-log" {
                let path = logs.appendingPathComponent(binding.transactionID.uuidString.lowercased()+".blocklog")
                var data = try Data(contentsOf: path); data[data.count-1] ^= 1; try data.write(to: path)
            }
            if mode == "authority-changes-during-read" {
                transport.beforeRead = { try (originalState+Data([10])).write(to: database.appendingPathComponent("anchors.json")) }
            }
            transport.failFlush = mode == "flush-failure"
            if mode == "unscoped-guard" { try reject { try authority.verifyRecoveryLease() } }
            var factoryCalls = 0, publications = 0
            var savedPermit: BlockJournalRecoveryPermit?
            authority.storageBoundary = { stage in
                try require(transport.released == 0)
                if stage == "written", mode == "publication-failure" { throw Fault.injected }
                if stage == "directory-durable" {
                    publications += 1
                    if mode == "late-disconnect" { transport.owns = false }
                }
            }
            func execute() throws -> BlockJournalDeviceRecoveryResult {
                try BlockJournalDeviceRecovery.restore(authority: authority, binding: requested, logDirectory: logs,
                    openDevice: { authenticated in
                        try require(authenticated.binding == binding); try authenticated.verify()
                        savedPermit = authenticated; factoryCalls += 1
                        if mode == "factory-reentry" { _ = try? authority.bindings() }
                        return try transport.session()
                    }, validateRestoredView: { read, expected in
                        try require(expected == baseline && digest(try read(0,8192)) == baseline)
                        if mode == "validator-reject" { throw Fault.injected }
                        if mode == "validator-reentry" { _ = try? authority.bindings() }
                    })
            }
            if mode == "success" {
                let result = try execute()
                try require(result.restoredBlocks == 1 && result.completion.binding == binding && result.completion.checkpoint == baseline)
                try require(transport.bytes == Data(count:8192) && transport.writes == 1 && transport.flushes == 1)
                try require(factoryCalls == 1 && transport.released == 1 && publications == 1)
                try reject { _ = try execute() }
                try require(factoryCalls == 1 && transport.released == 1)
            } else {
                try reject { _ = try execute() }
                try require(authority.failed)
                let noFactory = ["unscoped-guard","bad-log","missing-baseline","changed-binding","committed","unknown"].contains(mode)
                try require(factoryCalls == (noFactory ? 0 : 1) && transport.released == (noFactory ? 0 : 1))
                if !["flush-failure","publication-failure","late-disconnect"].contains(mode) { try require(transport.writes == 0) }
                if !["authority-changes-during-read","late-disconnect"].contains(mode) {
                    try require(try Data(contentsOf: database.appendingPathComponent("anchors.json")) == originalState)
                }
            }
            if let savedPermit { try reject { try savedPermit.verify() } }
            authority.close()
            if ["success","flush-failure","publication-failure","late-disconnect"].contains(mode) {
                let reopened = try BlockJournalAuthority.fixture(directory: database, pool: pool)
                let receipt = try reopened.recoveryCompletion(binding)
                try require((receipt != nil) == ["success","late-disconnect"].contains(mode))
                reopened.close()
            }
            checks.append(mode)
        }
        let result=root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"physicalDiskTouched":false],options:[.prettyPrinted,.sortedKeys]).write(to:result)
        print("passed \(checks.count): \(result.path)")
    }
}
