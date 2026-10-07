// Offline format tests: compiled together with the real WriteJournalStore.swift.
// Every key and record below belongs to this run's disposable directory.
import Foundation
import CryptoKit
import Darwin

private struct RegressionFailure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw RegressionFailure(message: message) }
}
private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private final class Fixture {
    let url: URL
    let store: WriteJournalStore
    let serial = "0123456789abcdef"
    let session = UUID()
    let key: SymmetricKey
    init(root: URL, label: String) throws {
        url = root.appendingPathComponent(label, isDirectory: true)
        store = try WriteJournalStore(directory: url)
        key = SymmetricKey(data: try Data(contentsOf: url.appendingPathComponent("key.bin")))
        try store.saveSessionRecord(record())
    }
    func record() -> WriteJournalSessionRecord {
        .init(session: session, serial: serial, deviceSize: 1 << 20, blockSize: 4096,
              bootSector: Data(repeating: 0, count: 512), initialFlags: 0, logfileOffset: 4096,
              logfileLength: 512, logfileSHA256: String(repeating: "0", count: 64), state: .active)
    }
    func header(epoch: UInt64 = 1) throws -> Data {
        try encoded(WriteJournalEpoch.Header(session: session, epoch: epoch, kind: .normal))
    }
    func frame(_ type: UInt8, _ payload: Data, previous: Data) -> (Data, Data) {
        var body = Data([type]); body.appendInteger(UInt32(payload.count)); body.append(payload)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: previous + body, using: key))
        return (body + mac, mac)
    }
    func epoch(_ frames: [(UInt8, Data)], named: UInt64 = 1, badMACAt: Int? = nil) throws {
        var contents = Data(), previous = Data(count: 32)
        for (index, entry) in frames.enumerated() {
            var (bytes, mac) = frame(entry.0, entry.1, previous: previous)
            if badMACAt == index { bytes[bytes.count - 1] ^= 0x80 }
            contents.append(bytes); previous = mac
        }
        try contents.write(to: url.appendingPathComponent(store.epochName(serial: serial, epoch: named)))
    }
    func emptyEpoch() throws {
        try Data().write(to: url.appendingPathComponent(store.epochName(serial: serial, epoch: 0)))
    }
    func sessionBody(_ body: Data, badMAC: Bool = false) throws {
        var mac = Data(HMAC<SHA256>.authenticationCode(for: Data("session|".utf8) + body, using: key))
        if badMAC { mac[mac.count - 1] ^= 0x80 }
        try (body + mac).write(to: url.appendingPathComponent(serial + ".session"))
    }
    func snapshot() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: url.path).map {
            ($0, try Data(contentsOf: url.appendingPathComponent($0)))
        })
    }
    func readEpochs() throws -> [WriteJournalEpoch] { try store.epochs(serial: serial, session: session) }
}

@main private struct FormatRegression {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw RegressionFailure(message: "需要一次性测试目录") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryRoot.path,
              root.lastPathComponent.hasPrefix("volisle-journal-format-") else {
            throw RegressionFailure(message: "测试仅允许在专用 /private/tmp 目录执行")
        }
        var passed: [String] = []
        func accepted(_ label: String, sectors: Bool, checkpoint: Bool) throws {
            let fixture = try Fixture(root: root, label: label)
            let before = Data(repeating: 0x11, count: 4096), after = Data(repeating: 0x22, count: 4096)
            let hashes = WriteJournalEpoch.sectorHashes(after)
            let (fd, firstMAC) = try fixture.store.createEpoch(serial: fixture.serial,
                header: .init(session: fixture.session, epoch: 1, kind: .normal))
            defer { Darwin.close(fd) }
            let group = WriteJournalEpoch.Group(before: [(4096, before)],
                after: [(4096, Data(SHA256.hash(data: after)))], afterSectors: sectors ? [4096: hashes] : [:])
            let groupMAC = try fixture.store.appendGroup(fd, group, previous: firstMAC)
            if checkpoint { try fixture.store.appendCheckpoint(fd, epoch: 1, previous: groupMAC) }
            let untouched = try fixture.snapshot()
            let epochs = try fixture.readEpochs()
            try require(epochs.count == 1 && epochs[0].groups.count == 1, label + "：组数量")
            try require(epochs[0].groups[0].before[0].bytes == before, label + "：旧块")
            try require(epochs[0].groups[0].after[0].sha256 == Data(SHA256.hash(data: after)), label + "：新块摘要")
            try require(epochs[0].groups[0].afterSectors == (sectors ? [4096: hashes] : [:]), label + "：扇区摘要")
            try require(epochs[0].checkpointed == checkpoint, label + "：确认状态")
            let data = try Data(contentsOf: fixture.url.appendingPathComponent(fixture.store.epochName(serial: fixture.serial, epoch: 1)))
            let second = 5 + Int(data.readInteger(UInt32.self, at: 1)) + 32
            try require(data[second] == (sectors ? 4 : 2), label + "：实际帧类型")
            try require(fixture.snapshot() == untouched, label + "：读取不得修改记录")
            passed.append(label)
        }
        func rejected(_ label: String, as expected: WriteJournalError,
                      session: Bool = false, prepare: (Fixture) throws -> Void) throws {
            let fixture = try Fixture(root: root, label: label)
            if !session { try fixture.emptyEpoch() }
            try prepare(fixture)
            let untouched = try fixture.snapshot()
            do {
                if session { _ = try fixture.store.sessionRecord(serial: fixture.serial) }
                else { _ = try fixture.readEpochs() }
                throw RegressionFailure(message: label + "：未拒绝记录")
            } catch let error as WriteJournalError {
                try require(error == expected, label + "：得到 \(error)，应为 \(expected)")
            }
            try require(fixture.snapshot() == untouched, label + "：拒绝不得修改或删除任何记录")
            passed.append(label)
        }
        var group = Data(); group.appendInteger(UInt32(0)); group.appendInteger(UInt32(0))
        var checkpoint = Data(); checkpoint.appendInteger(UInt64(1))

        try accepted("group-2-checkpointed", sectors: false, checkpoint: true)
        try accepted("sectorGroup-4-unfinished", sectors: true, checkpoint: false)
        try accepted("sectorGroup-4-checkpointed", sectors: true, checkpoint: true)
        try rejected("authenticated-unknown-frame", as: .unsupportedFormat) {
            try $0.epoch([(1, $0.header()), (5, Data([0x11]))])
        }
        try rejected("unknown-frame-bad-MAC", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (5, Data([0x11]))], badMACAt: 1)
        }
        try rejected("unknown-frame-followed-by-bad-MAC", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (5, Data([0x11])), (2, group)], badMACAt: 2)
        }
        try rejected("unknown-frame-followed-by-malformed-group", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (5, Data([0x11])), (2, Data([0]))])
        }
        try rejected("unknown-frame-after-checkpoint", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (3, checkpoint), (5, Data([0x11]))])
        }
        try rejected("unknown-frame-before-header", as: .corrupt) {
            try $0.epoch([(5, Data([0x11])), (1, $0.header())])
        }
        try rejected("unknown-frame-wrong-epoch-name", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (5, Data([0x11]))], named: 2)
        }
        try rejected("authenticated-malformed-header", as: .corrupt) {
            try $0.epoch([(1, Data("{".utf8))])
        }
        try rejected("known-group-bad-MAC", as: .corrupt) {
            try $0.epoch([(1, $0.header()), (2, group)], badMACAt: 1)
        }
        try rejected("authenticated-unknown-session-version", as: .unsupportedFormat, session: true) {
            var record = $0.record(); record.version = 2
            try $0.store.saveSessionRecord(record)
        }
        try rejected("unknown-session-version-bad-MAC", as: .corrupt, session: true) {
            var record = $0.record(); record.version = 2
            try $0.sessionBody(encoded(record), badMAC: true)
        }
        try rejected("unknown-session-version-malformed-boot-sector", as: .corrupt, session: true) {
            let record = $0.record()
            var value = try JSONSerialization.jsonObject(with: encoded(record)) as! [String: Any]
            value["version"] = 2; value["bootSector"] = Data(count: 8).base64EncodedString()
            try $0.sessionBody(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
        try rejected("authenticated-malformed-session", as: .corrupt, session: true) {
            try $0.sessionBody(Data("{\"version\":2}".utf8))
        }
        for label in passed { print("通过：\(label)") }
        let result: [String: Any] = ["passed": true, "checks": passed.count, "cases": passed, "fixtureRoot": root.path]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"))
        print("离线日志格式验证：\(passed.count) 项通过；所有拒绝场景的记录保持不变。")
    }
}
