// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct BlockJournalRollbackReceipt: Sendable {
    let binding: BlockJournalBinding
    let seal: BlockJournalSeal
    let restoredBlocks: Int
}

/// One-shot, serialized recovery of an authenticated, UNCOMMITTED snapshot.
/// The owner must retain the journal/authority leases, fence the physical device
/// and verify its identity. This class neither authenticates a supplied struct
/// nor acquires that physical lease. Never use a live/failed filesystem engine.
final class BlockJournalRollback {
    typealias Read = (Int64, Int) throws -> Data
    private struct Block {
        let original: Data
        var latest: Data
        var versions: [Data]
        var observed = Data()
    }
    private var used = false
    private(set) var failed = false
    private static let maximumRead = 1024 * 1024
    private static let historyLimit = 64 * 1024 * 1024

    /// validateRestoredView MUST validate against an independently trusted
    /// checkpoint or complete filesystem recovery policy, first through a
    /// virtual overlay and then the flushed device. A no-op is not validation.
    /// This does not invent a baseline, clear dirty, or retire a journal.
    func restore(snapshot: BlockJournalSnapshot, expectedBinding: BlockJournalBinding,
                 read: @escaping Read, write: (Int64, Data) throws -> Void,
                 flush: () throws -> Void,
                 validateRestoredView: (Read) throws -> Void) throws -> BlockJournalRollbackReceipt {
        do {
            guard !used else { throw BlockJournalError.failed }; used = true
            let binding = snapshot.binding
            try BlockJournalStore.validate(binding)
            guard binding == expectedBinding, snapshot.checkpoint == nil,
                  snapshot.writes.count <= 4095,
                  snapshot.seal.sequence == snapshot.writes.count + 1 else { throw BlockJournalError.corrupt }
            var blocks: [Int64: Block] = [:], historyBytes = 0
            for entry in snapshot.writes {
                guard entry.offset >= 0, entry.offset < binding.deviceSize,
                      entry.offset % Int64(binding.blockSize) == 0,
                      entry.before.count == entry.after.count,
                      entry.before.count == Int(min(Int64(binding.blockSize), binding.deviceSize-entry.offset)),
                      entry.before.count * 2 <= Self.historyLimit - historyBytes else { throw BlockJournalError.corrupt }
                historyBytes += entry.before.count * 2
                if var block = blocks[entry.offset] {
                    guard block.latest == entry.before else { throw BlockJournalError.corrupt }
                    block.latest = entry.after; block.versions.append(entry.after); blocks[entry.offset] = block
                } else {
                    blocks[entry.offset] = Block(original: entry.before, latest: entry.after, versions: [entry.before, entry.after])
                }
            }
            func checkedRead(_ offset: Int64, _ count: Int) throws -> Data {
                guard !self.failed else { throw BlockJournalError.failed }
                guard offset >= 0, offset <= binding.deviceSize, count >= 0, count <= Self.maximumRead,
                      Int64(count) <= binding.deviceSize-offset else { throw BlockJournalError.invalid }
                let bytes = try read(offset, count)
                guard !self.failed else { throw BlockJournalError.failed }
                guard bytes.count == count else { throw BlockJournalError.unavailable }
                return bytes.withUnsafeBytes { Data($0) }
            }
            let offsets = blocks.keys.sorted()
            // Verify ALL histories and current bytes before writing anything.
            // Known per-byte mixtures allow a torn write or interrupted rollback;
            // unexplained bytes stop recovery, even in a later block.
            for offset in offsets {
                var block = blocks[offset]!
                let current = try checkedRead(offset, block.original.count)
                var explained = [Bool](repeating: false, count: current.count)
                current.withUnsafeBytes { observed in
                    let observed = observed.bindMemory(to: UInt8.self)
                    for version in block.versions {
                        version.withUnsafeBytes { candidate in
                            let candidate = candidate.bindMemory(to: UInt8.self)
                            for i in 0..<observed.count where observed[i] == candidate[i] { explained[i] = true }
                        }
                    }
                }
                guard explained.allSatisfy({ $0 }) else { throw BlockJournalError.corrupt }
                block.observed = current; blocks[offset] = block
            }
            try validateRestoredView { offset, count in
                var result = try checkedRead(offset, count)
                var consumed = 0
                while consumed < count {
                    let position = offset + Int64(consumed)
                    let start = position / Int64(binding.blockSize) * Int64(binding.blockSize)
                    let skip = Int(position-start)
                    let length = min(count-consumed, binding.blockSize-skip)
                    if let block = blocks[start] {
                        result.replaceSubrange(consumed..<consumed+length, with: block.original.dropFirst(skip).prefix(length))
                    }
                    consumed += length
                }
                return result
            }
            guard !failed else { throw BlockJournalError.failed }
            // Detect changes during validation before the first mutation.
            for offset in offsets {
                guard try checkedRead(offset, blocks[offset]!.original.count) == blocks[offset]!.observed else { throw BlockJournalError.corrupt }
            }
            var restored = 0
            for offset in offsets {
                let block = blocks[offset]!
                guard try checkedRead(offset, block.original.count) == block.observed else { throw BlockJournalError.corrupt }
                if block.observed != block.original {
                    try write(offset, block.original)
                    guard !failed else { throw BlockJournalError.failed }
                    restored += 1
                }
            }
            try flush()
            guard !failed else { throw BlockJournalError.failed }
            for offset in offsets {
                guard try checkedRead(offset, blocks[offset]!.original.count) == blocks[offset]!.original else { throw BlockJournalError.corrupt }
            }
            try validateRestoredView(checkedRead)
            guard !failed else { throw BlockJournalError.failed }
            return .init(binding: binding, seal: snapshot.seal, restoredBlocks: restored)
        } catch { failed = true; throw error }
    }
}
