// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// An acknowledgement of a durable commit, not evidence of a clean NTFS volume.
struct BlockJournalCommitReceipt: Equatable, Sendable {
    let binding: BlockJournalBinding
    let seal: BlockJournalSeal
    let checkpoint: String
}

/// Coordinates one serialized operation. Its owner must hold the device lease
/// and route EVERY physical write (including metadata drain writes) through it.
/// This is not Sendable: calls belong to the engine's serial executor.
final class BlockJournalTransaction {
    enum State: Equatable { case active, preparing, committing, committed, failed }

    /// Must durably compare-and-swap a separately trusted anchor, bound to the
    /// entire binding. nil means the transaction must not already exist. Return
    /// only after persistence, with the exact saved seal; errors may be ambiguous.
    /// A returned seal is an assertion by the provider, not proof of durability.
    typealias SaveAnchor = (BlockJournalBinding, BlockJournalSeal?, BlockJournalSeal) throws -> BlockJournalSeal

    private(set) var state: State = .active
    private(set) var trustedSeal: BlockJournalSeal?
    private(set) var receipt: BlockJournalCommitReceipt?
    private let binding: BlockJournalBinding
    private let store: BlockJournalStore
    private let saveAnchor: SaveAnchor
    private let stopWrites: () -> Void
    private var writing = false
    private var closed = false

    init(directory: URL, binding: BlockJournalBinding, key: Data,
         byteLimit: Int = 64 * 1024 * 1024, recordLimit: Int = 4096,
         expectedPool: BlockJournalPool? = nil, saveAnchor: @escaping SaveAnchor, stopWrites: @escaping () -> Void) throws {
        self.binding = binding; self.saveAnchor = saveAnchor; self.stopWrites = stopWrites
        do {
            store = try BlockJournalStore(directory: directory, binding: binding, key: key,
                                          byteLimit: byteLimit, recordLimit: recordLimit, expectedPool: expectedPool, failClosed: {})
        } catch { stopWrites(); throw error }
        do { try advanceAnchor() }
        catch { abort(); store.close(); throw error }
    }

    deinit { close() }

    /// The before image must come from the current, exclusively held device;
    /// this API cannot verify physical identity or exclude another writer.
    func write(offset: Int64, before: Data, after: Data,
               writeDevice: (Int64, Data) throws -> Void) throws {
        do {
            guard !closed, !writing, state == .active || state == .preparing else {
                throw BlockJournalError.failed
            }
            writing = true
            defer { writing = false }
            try store.record(offset: offset, before: before, after: after)
            try advanceAnchor()
            try requireLive()
            try writeDevice(offset, after)
            // A callback may catch a nested failure. Never allow that to erase
            // an abort, close, or reentrant protocol violation.
            try requireLive()
        } catch { abort(); throw error }
    }

    /// Drain the engine first: it may issue additional journalled writes.
    /// flushDevice must then flush only, with no further writes. The receipt
    /// is published only after the terminal record AND its anchor are durable.
    func commit(checkpoint: String, prepare: () throws -> Void,
                flushDevice: () throws -> Void) throws -> BlockJournalCommitReceipt {
        do {
            guard !closed, !writing, state == .active,
                  checkpoint.utf8.count == 64,
                  checkpoint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw BlockJournalError.failed
            }
            state = .preparing
            try prepare()
            try requireLive()
            state = .committing
            try store.commit(checkpoint: checkpoint) {
                try flushDevice()
                try self.requireLive()
            }
            try advanceAnchor()
            try requireLive()
            let result = BlockJournalCommitReceipt(binding: binding, seal: store.seal, checkpoint: checkpoint)
            receipt = result
            state = .committed
            return result
        } catch { abort(); throw error }
    }

    /// Errors are sticky, including errors after a possibly durable commit.
    /// No automatic retry, rollback, log deletion, or dirty-flag clearing.
    func abort() {
        guard state != .failed, state != .committed else { return }
        state = .failed
        store.abort()
        stopWrites()
    }

    func close() {
        guard !closed else { return }
        closed = true
        abort()
        store.close()
    }

    private func requireLive() throws {
        guard !closed, state != .failed, !store.failed else { throw BlockJournalError.failed }
    }

    private func advanceAnchor() throws {
        try requireLive()
        let next = store.seal
        let saved = try saveAnchor(binding, trustedSeal, next)
        guard saved == next else { throw BlockJournalError.corrupt }
        try requireLive()
        trustedSeal = saved
    }

    #if VOLISLE_BLOCK_JOURNAL_TESTING
    var storageBoundary: ((String) throws -> Void)? {
        get { store.storageBoundary }
        set { store.storageBoundary = newValue }
    }
    #endif
}
