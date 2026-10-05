import Foundation
import Darwin

@main struct JournalTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        // Exercise the real bounded reader, including short reads and a final
        // partial chunk. The oracle uses independent CryptoKit whole-data SHA.
        let payload = Data((0..<(20 * 1024 * 1024 + 37)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var largestRead = 0
        let streamed = try ReplacementFingerprint.read(size: UInt64(payload.count)) { offset, buffer in
            largestRead = max(largestRead, buffer.count)
            let count = min(buffer.count, 65533)
            payload.withUnsafeBytes { bytes in
                buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: Int(offset)), byteCount: count)
            }
            return count
        }
        precondition(streamed == ReplacementFingerprint.of(payload))
        precondition(largestRead <= 256 * 1024)
        let empty = try ReplacementFingerprint.read(size: 0) { _, _ in fatalError("空文件不能发起读取") }
        precondition(empty == .of(Data()))
        for mode in 0..<3 {
            do {
                _ = try ReplacementFingerprint.read(size: 12) { _, buffer in
                    if mode == 2 { throw POSIXError(.EIO) }
                    return mode == 0 ? 0 : buffer.count + 1
                }
                fatalError("无效或失败读取返回了可用指纹")
            } catch {}
        }
        do {
            _ = try ReplacementFingerprint.read(size: UInt64.max) { _, _ in fatalError() }
            fatalError("有符号偏移溢出必须在读取前拒绝")
        } catch {}
        let binding = ReplacementBinding(serial: "1234567890abcdef", bootHash: String(repeating: "a", count: 64),
            directory: "/", source: "draft", target: "document", backup: ".old",
            oldReference: 0x1000000000040, newReference: 0x1000000000041)
        let before = streamed
        let after = ReplacementFingerprint.of(Data("new".utf8))
        var failed = false
        let journal = try ReplacementJournal(at: root.appendingPathComponent("normal"), binding: binding,
            before: before, after: after, failClosed: { failed = true })
        var mutated = false
        try journal.publish { mutated = true }
        precondition(mutated && journal.state.phase == "published")
        var removed = false
        let proof = ReplacementProof(oldReference: binding.oldReference, newReference: binding.newReference,
            old: before, new: after, sourceAbsent: true)
        do {
            try journal.cleanup(verify: { proof }, removeAndSync: { removed = true })
            fatalError("旧对象未回收时不能清理")
        } catch {}
        precondition(!removed && !failed)
        let edited = ReplacementFingerprint.of(Data("old-edited".utf8))
        try journal.write(.old) { edited }
        precondition(journal.state.before == edited)
        try journal.oldItemReclaimed()
        do { try journal.write(.old) { fatalError("回收后旧对象仍可写") }; fatalError() } catch {}
        do { try journal.cleanup(verify: { proof }, removeAndSync: { removed = true }); fatalError("过期指纹获准清理") } catch {}
        precondition(!removed && !failed)
        let current = ReplacementProof(oldReference: binding.oldReference, newReference: binding.newReference,
            old: edited, new: after, sourceAbsent: true)
        try journal.cleanup(verify: { current }, removeAndSync: { removed = true })
        precondition(removed && journal.state.phase == "cleaned")
        journal.close()
        let loaded = try ReplacementJournal.inspect(at: journal.url, serial: binding.serial, bootHash: binding.bootHash)
        precondition(loaded.valid && loaded.state?.phase == "cleaned" && !loaded.cleanupAuthorized && !loaded.blocksWriting)
        do {
            _ = try ReplacementJournal(at: journal.url, binding: binding, before: before, after: after, failClosed: {})
            fatalError("已有记录被当作新会话重用")
        } catch {}

        // An actual O_EXCL collision models a journal persistence failure.
        // Intent failure must prevent the mutation, poison the live session,
        // and keep both the colliding file and previously durable records.
        let broken = try ReplacementJournal(at: root.appendingPathComponent("collision"), binding: binding,
            before: before, after: after, failClosed: { failed = true })
        try Data("occupied".utf8).write(to: broken.url.appendingPathComponent("000002.json"))
        mutated = false; failed = false
        do { try broken.publish { mutated = true }; fatalError("记录失败后仍发布") } catch {}
        precondition(!mutated && failed && broken.failed)
        try FileManager.default.removeItem(at: broken.url.appendingPathComponent("000002.json"))
        do { try broken.publish { mutated = true }; fatalError("失败会话自动恢复写入") } catch {}
        precondition(!mutated)
        broken.close()

        // Read-only replay must reject a truncated tail, a missing middle
        // record, an identity mismatch, and a record replaced by a symlink.
        for mode in ["truncated", "gap", "symlink", "hardlink", "wrong-volume", "tampered"] {
            let copy = root.appendingPathComponent(mode)
            try FileManager.default.copyItem(at: journal.url, to: copy)
            let files = try FileManager.default.contentsOfDirectory(atPath: copy.path).sorted()
            if mode == "truncated" { try Data("{".utf8).write(to: copy.appendingPathComponent(files.last!)) }
            if mode == "gap" { try FileManager.default.removeItem(at: copy.appendingPathComponent(files[1])) }
            if mode == "symlink" {
                try FileManager.default.removeItem(at: copy.appendingPathComponent(files.last!))
                try FileManager.default.createSymbolicLink(atPath: copy.appendingPathComponent(files.last!).path,
                    withDestinationPath: journal.url.appendingPathComponent(files.last!).path)
            }
            if mode == "hardlink" {
                try FileManager.default.linkItem(at: copy.appendingPathComponent(files.last!),
                    to: root.appendingPathComponent("extra-hardlink"))
            }
            if mode == "tampered" {
                let path = copy.appendingPathComponent(files.last!)
                var data = try Data(contentsOf: path); data[data.count / 2] ^= 1; try data.write(to: path)
            }
            let result = try ReplacementJournal.inspect(at: copy,
                serial: mode == "wrong-volume" ? "0000000000000001" : binding.serial, bootHash: binding.bootHash)
            precondition(!result.valid && !result.cleanupAuthorized, "无效记录仍被信任：\(mode)")
            precondition(result.blocksWriting == (mode != "wrong-volume"))
        }
        let cross = ReplacementBinding(serial: binding.serial, bootHash: binding.bootHash,
            directory: "/saved", source: "document", target: "document", backup: ".old",
            oldReference: binding.oldReference, newReference: binding.newReference, sourceDirectory: "/incoming")
        let crossJournal = try ReplacementJournal(at: root.appendingPathComponent("cross"), binding: cross,
            before: before, after: after, failClosed: {})
        try crossJournal.publish {}; crossJournal.close()
        let crossReplay = try ReplacementJournal.inspect(at: crossJournal.url, serial: binding.serial, bootHash: binding.bootHash)
        precondition(crossReplay.valid && crossReplay.state?.binding.sourcePath == "/incoming/document" && crossReplay.blocksWriting)
        let emptyJournal = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyJournal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unknown = try ReplacementJournal.inspect(at: emptyJournal, serial: binding.serial, bootHash: binding.bootHash)
        precondition(unknown.belongsToVolume == nil && unknown.blocksWriting)
        for parent in ["", "relative", "/incoming/..", "/incoming//child", "/incoming/"] {
            var bad = cross; bad.sourceDirectory = parent
            do {
                _ = try ReplacementJournal(at: root.appendingPathComponent(UUID().uuidString), binding: bad,
                    before: before, after: after, failClosed: {})
                fatalError("非法源目录被写入恢复记录")
            } catch {}
        }
        // Ordinary long-lived open files must not exhaust host metadata.
        let sustained = try ReplacementJournal(at: root.appendingPathComponent("sustained"), binding: binding,
            before: before, after: after, failClosed: { fatalError("正常持续写入被中止") })
        try sustained.publish {}
        var latest = after
        for n in 0..<1200 {
            latest = .of(Data("edit-\(n)".utf8))
            try sustained.write(.new) { latest }
        }
        sustained.close()
        let sustainedReplay = try ReplacementJournal.inspect(at: sustained.url, serial: binding.serial, bootHash: binding.bootHash)
        precondition(sustainedReplay.valid && sustainedReplay.records == 2403 && sustainedReplay.state?.after == latest)
        precondition(sustainedReplay.blocksWriting && !sustainedReplay.cleanupAuthorized)
        let otherVolume = try ReplacementJournal.inspect(at: sustained.url, serial: "0000000000000001", bootHash: binding.bootHash)
        precondition(!otherVolume.valid && otherVolume.belongsToVolume == false && !otherVolume.blocksWriting)
        let retained = try FileManager.default.contentsOfDirectory(atPath: sustained.url.path)
        precondition(retained.count <= 130)
        print("恢复记录检查通过：完成链、写后指纹、回收门禁、过期证明、持久化失败、只读重放与损坏拒绝。")
    }
}
