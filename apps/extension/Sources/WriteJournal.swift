// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

/// Fixed cache-block device. A write may stay in the system cache until
/// `journalFlush`, the durable barrier (unavailable before a kernel mount,
/// where `flushIsDurable` is false).
protocol JournalBlockDevice: AnyObject {
    var journalBlockSize: Int { get }
    var journalDeviceSize: Int64 { get }
    var flushIsDurable: Bool { get }
    func journalRead(into block: UnsafeMutableRawBufferPointer, at offset: Int64) throws
    /// Uncached read of whole aligned blocks. Only used for blocks with no
    /// unflushed write, whose device content therefore equals the cache.
    func journalReadRun(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws
    func journalWrite(_ block: UnsafeRawBufferPointer, at offset: Int64) throws
    func journalFlush() throws
    /// Starts writing cached blocks to the device without waiting. Only a hint:
    /// durability still comes from journalFlush.
    func journalStartFlush()
}

extension JournalBlockDevice {
    func journalStartFlush() {}
}

enum WriteJournalLimits {
    /// Pending device blocks held in memory before one durable group.
    static let groupBytes = 8 * 1024 * 1024
    /// Before-images after which a checkpoint is requested at the next
    /// operation boundary.
    static let checkpointBytes = 32 * 1024 * 1024
    /// Hard cap: further writes fail and the session stops, so recovery
    /// time, host disk use and recovery memory stay bounded.
    static let epochBytes = 256 * 1024 * 1024
    /// Device bytes written after which a checkpoint is requested, so the
    /// unflushed cache stays bounded when free space needs no before-images.
    static let checkpointWrittenBytes = 128 * 1024 * 1024
    /// Checkpointed epochs stay this long. The checkpoint flush only hands the
    /// data to the drive; a USB drive's own write cache is lost when it loses
    /// power, so recovery rolls back over everything this recent.
    static let retentionSeconds: TimeInterval = 20
    /// Before-images kept across retained epochs; beyond this the oldest go first.
    /// Recovery reads them all into memory.
    static let retainedBytes = 128 * 1024 * 1024
}

/// Where the volume's cluster bitmap lies on the device (from nk_bitmap_layout).
/// A block whose clusters were free at the last checkpoint and at the start of
/// every retained epoch needs no before-image: rolling back (always to the
/// oldest retained boundary, which only ever moves forward) restores the
/// bitmap, which frees those clusters again, and their content means nothing.
struct FreeSpaceMap {
    let clusterSize: Int64
    let clusters: Int64
    /// Bitmap bytes in order: each run is `length` bytes at device `offset`.
    let runs: [(offset: Int64, length: Int64)]

    init?(clusterSize: Int64, clusters: Int64, runs: [(offset: Int64, length: Int64)], deviceSize: Int64) {
        guard clusterSize >= 512, clusterSize.nonzeroBitCount == 1, clusters > 0,
              clusters <= deviceSize / clusterSize, !runs.isEmpty,
              runs.allSatisfy({ $0.offset >= 0 && $0.length > 0 && $0.length <= deviceSize - $0.offset }),
              runs.reduce(0, { $0 + $1.length }) == (clusters + 7) / 8 else { return nil }
        self.clusterSize = clusterSize; self.clusters = clusters; self.runs = runs
    }

    /// Device offset of bitmap byte `index`.
    func location(ofByte index: Int64) -> Int64? {
        var start: Int64 = 0
        for run in runs {
            if index < start + run.length { return index >= start ? run.offset + index - start : nil }
            start += run.length
        }
        return nil
    }

    func overlapsBitmap(_ offset: Int64, _ length: Int) -> Bool {
        runs.contains { offset < $0.offset + $0.length && $0.offset < offset + Int64(length) }
    }
}

/// Undo journal for one writable mount. Serialized by the engine queue.
/// Recovery rolls back the unfinished epoch and every retained checkpointed
/// one, returning the device to the oldest retained checkpoint; checkpoints
/// are always taken at an operation boundary after nk_sync.
final class WriteJournalSession {
    let store: WriteJournalStore
    let record: WriteJournalSessionRecord
    private let device: JournalBlockDevice
    private let kind: WriteJournalEpoch.Kind
    private(set) var epoch: UInt64
    private var file: Int32 = -1
    private var fileName = ""
    private var previous = Data()
    private var overlay: [Int64: Data] = [:]
    private var overlayBytes = 0
    /// First writes of this epoch in the current group: offset → length.
    /// Their before-images are read in runs when the group is recorded.
    private var pendingBefore: [Int64: Int] = [:]
    private var logged: Set<Int64> = []
    /// Set once the writable engine is open; nil keeps every before-image.
    var freeSpace: FreeSpaceMap?
    /// Checkpoint-time content of the bitmap blocks consulted this epoch.
    private var checkpointBitmap: [Int64: Data] = [:]
    /// Bitmap blocks as they were when this epoch began (its before-images).
    private var epochBitmapBefore: [Int64: Data] = [:]
    /// False once a group was recorded before the bitmap layout was known.
    private var epochBitmapKnown = true
    private struct RetainedEpoch { let epoch: UInt64; let name: String; let at: TimeInterval; let bitmap: [Int64: Data]; let bitmapKnown: Bool; let bytes: Int }
    /// Checkpointed epochs still on record, oldest first.
    private var retained: [RetainedEpoch] = []
    var retention = WriteJournalLimits.retentionSeconds
    /// Uptime, not wall time: a clock set back would otherwise keep epochs (and
    /// roll back writes) far beyond the window; sleep does not count either.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) var skippedBytes = 0
    private var writtenBytes = 0
    private(set) var epochBytes = 0
    private(set) var failed = false
    /// Uptime of the last write and of this epoch's first group: the idle and
    /// age triggers for a checkpoint, on the same clock as the retention window.
    private var lastWrite: TimeInterval = -.infinity
    private var epochStarted: TimeInterval = -.infinity
    /// Uptime of the last completed checkpoint.
    private var lastCheckpoint: TimeInterval = -.infinity
    var idleSeconds: TimeInterval { clock() - lastWrite }
    var epochSeconds: TimeInterval { clock() - epochStarted }
    var checkpointSeconds: TimeInterval { clock() - lastCheckpoint }
    #if VOLISLE_WRITE_JOURNAL_TESTING
    var boundary: ((String) throws -> Void)?
    #endif

    init(store: WriteJournalStore, record: WriteJournalSessionRecord, device: JournalBlockDevice,
         epoch: UInt64, kind: WriteJournalEpoch.Kind = .normal) {
        self.store = store; self.record = record; self.device = device; self.epoch = epoch; self.kind = kind
    }
    deinit { if file >= 0 { Darwin.close(file) } }

    var hasUncheckpointedWrites: Bool { file >= 0 || !overlay.isEmpty }
    /// What an unplug can no longer undo, so the app can confirm a finished copy
    /// as soon as that is true instead of after a fixed wait. Everything written
    /// to the journal so far lies in epochs below `writtenBelow`; epochs below
    /// `durableBelow` are no longer on record, and recovery rolls back only what
    /// is. Only a normal session's epochs are pruned this way; nil otherwise.
    var durability: (writtenBelow: UInt64, durableBelow: UInt64)? {
        guard kind == .normal, !failed else { return nil }
        return (hasUncheckpointedWrites ? epoch + 1 : epoch, retained.first?.epoch ?? epoch)
    }
    /// Not written by this journal since the last checkpoint's device flush: the
    /// device holds exactly what the cache would return.
    func unchangedSinceCheckpoint(_ offset: Int64) -> Bool {
        !failed && overlay[offset] == nil && pendingBefore[offset] == nil && !logged.contains(offset)
    }
    /// About to be written in part, and holding nothing worth keeping: not
    /// written since the last checkpoint and free then, the reason its
    /// before-image is skipped too. The unwritten rest of such a block need not
    /// be read: an unreadable spot in free space (a bad sector) cannot fail a
    /// write there, and the write lets the drive remap it.
    func isFreeAndUnwritten(_ offset: Int64, _ length: Int) -> Bool {
        unchangedSinceCheckpoint(offset) && freeAtCheckpoint(offset, length)
    }
    var checkpointDue: Bool {
        epochBytes + overlayBytes >= WriteJournalLimits.checkpointBytes ||
            writtenBytes + overlayBytes >= WriteJournalLimits.checkpointWrittenBytes
    }

    func read(into block: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        if let pending = overlay[offset] {
            guard pending.count == block.count else { throw WriteJournalError.invalid }
            pending.copyBytes(to: block); return
        }
        try device.journalRead(into: block, at: offset)
    }

    func write(_ block: UnsafeRawBufferPointer, at offset: Int64) throws {
        do {
            guard !failed else { throw WriteJournalError.failed }
            if !logged.contains(offset) && pendingBefore[offset] == nil {
                guard epochBytes + overlayBytes + block.count <= WriteJournalLimits.epochBytes else {
                    throw WriteJournalError.capacity
                }
                pendingBefore[offset] = block.count
            }
            if let old = overlay[offset] { overlayBytes -= old.count }
            overlay[offset] = Data(block)
            overlayBytes += block.count
            lastWrite = clock()
            if overlayBytes >= WriteJournalLimits.groupBytes { try flushGroup() }
        } catch { stop(); throw error }
    }

    /// Engine sync callback. Consistency and durability come from the next
    /// checkpoint, so a per-operation device barrier is not needed; pending
    /// blocks stay readable through the overlay.
    func sync() throws {
        guard !failed else { throw WriteJournalError.failed }
    }

    /// Caller guarantees an operation boundary and has completed nk_sync.
    func checkpoint() throws {
        do {
            guard !failed else { throw WriteJournalError.failed }
            try flushGroup()
            guard file >= 0 else { return }
            try device.journalFlush()
            try hook("checkpoint-before-record")
            try store.appendCheckpoint(file, epoch: epoch, previous: previous)
            Darwin.close(file); file = -1
            if kind == .normal && retention > 0 {
                retained.append(.init(epoch: epoch, name: fileName, at: clock(), bitmap: epochBitmapBefore,
                                      bitmapKnown: epochBitmapKnown, bytes: epochBytes))
            } else if kind == .normal || device.flushIsDurable {
                // Recovery epochs stay until the device barrier after a kernel mount.
                store.removeEpoch(fileName)
            }
            logged.removeAll(); checkpointBitmap.removeAll(); epochBitmapBefore.removeAll(); epochBitmapKnown = true
            epochBytes = 0; writtenBytes = 0; epoch += 1
            lastCheckpoint = clock()
            pruneRetained()
        } catch { stop(); throw error }
    }

    /// Drops retained epochs past the window, oldest first. A file is forgotten
    /// only once its removal is durable: a record that reappeared after a crash
    /// would roll back past a boundary later writes no longer protected.
    func pruneRetained() {
        let cutoff = clock() - retention
        var total = retained.reduce(0) { $0 + $1.bytes }
        while let oldest = retained.first, oldest.at <= cutoff || total > WriteJournalLimits.retainedBytes {
            guard (try? store.removeEpochDurably(oldest.name)) != nil else { return }
            total -= oldest.bytes
            retained.removeFirst()
        }
    }

    /// Permanent: the records stay for the next connection's recovery.
    func stop() {
        failed = true
        overlay.removeAll(); pendingBefore.removeAll(); overlayBytes = 0; checkpointBitmap.removeAll()
    }

    private func flushGroup() throws {
        guard !overlay.isEmpty else { return }
        if file < 0 {
            (file, previous) = try store.createEpoch(serial: record.serial,
                header: .init(session: record.session, epoch: epoch, kind: kind))
            fileName = store.epochName(serial: record.serial, epoch: epoch)
            epochStarted = clock()
        }
        let offsets = overlay.keys.sorted()
        let free = pendingBefore.filter { freeAtCheckpoint($0.key, $0.value) }.map(\.key)
        for offset in free { pendingBefore.removeValue(forKey: offset) }
        let before = try readBeforeImages()
        if freeSpace == nil && !before.isEmpty { epochBitmapKnown = false }
        if let map = freeSpace {
            for item in before where map.overlapsBitmap(item.offset, item.bytes.count) {
                checkpointBitmap[item.offset] = item.bytes
                if epochBitmapBefore[item.offset] == nil { epochBitmapBefore[item.offset] = item.bytes }
            }
        }
        let group = WriteJournalEpoch.Group(
            before: before,
            after: offsets.map { ($0, Data(SHA256.hash(data: overlay[$0]!))) },
            afterSectors: Dictionary(uniqueKeysWithValues: offsets.map { ($0, WriteJournalEpoch.sectorHashes(overlay[$0]!)) }))
        try hook("group-before-record")
        previous = try store.appendGroup(file, group, previous: previous)
        try hook("group-recorded")
        for offset in offsets {
            try overlay[offset]!.withUnsafeBytes { try device.journalWrite($0, at: offset) }
        }
        // Their records are durable: the device may get them now. Writing them out
        // while the copy goes on, instead of all at the checkpoint, keeps the disk busy.
        device.journalStartFlush()
        epochBytes += before.reduce(0) { $0 + $1.bytes.count }
        writtenBytes += overlayBytes
        skippedBytes += free.reduce(0) { $0 + overlay[$1]!.count }
        logged.formUnion(pendingBefore.keys)
        logged.formUnion(free)
        overlay.removeAll(); pendingBefore.removeAll(); overlayBytes = 0
    }

    /// Every cluster the block covers was free in the bitmap as of the last
    /// checkpoint. Anything uncertain keeps the before-image.
    private func freeAtCheckpoint(_ offset: Int64, _ length: Int) -> Bool {
        guard let map = freeSpace, offset >= 0, length > 0 else { return false }
        let first = offset / map.clusterSize, last = (offset + Int64(length) - 1) / map.clusterSize
        guard last < map.clusters else { return false }
        var cluster = first
        while cluster <= last {
            guard let byte = checkpointBitmapByte(cluster / 8, map) else { return false }
            let low = Int(cluster % 8), high = Int(min(7, Int64(low) + last - cluster))
            let mask = UInt8(truncatingIfNeeded: (0xff << low) & (0xff >> (7 - high)))
            if byte & mask != 0 { return false }
            guard freeInRetained(cluster / 8, mask, map) else { return false }
            cluster += Int64(high - low + 1)
        }
        return true
    }

    /// The byte is free under `mask` at the start of every retained epoch that
    /// changed its bitmap block (the others started as their successor did).
    private func freeInRetained(_ index: Int64, _ mask: UInt8, _ map: FreeSpaceMap) -> Bool {
        guard !retained.isEmpty else { return true }
        guard let at = map.location(ofByte: index) else { return false }
        let size = Int64(device.journalBlockSize), block = at / size * size
        for epoch in retained {
            guard epoch.bitmapKnown else { return false }
            guard let data = epoch.bitmap[block] else { continue }
            guard Int(at - block) < data.count, data[data.startIndex + Int(at - block)] & mask == 0 else { return false }
        }
        return true
    }

    /// From this epoch's kept before-image, else from the device, which still
    /// holds the checkpoint state of any block not yet written this epoch.
    private func checkpointBitmapByte(_ index: Int64, _ map: FreeSpaceMap) -> UInt8? {
        guard let at = map.location(ofByte: index) else { return nil }
        let size = Int64(device.journalBlockSize), block = at / size * size
        if checkpointBitmap[block] == nil {
            guard !logged.contains(block), block < device.journalDeviceSize else { return nil }
            var data = Data(count: Int(min(size, device.journalDeviceSize - block)))
            do { try data.withUnsafeMutableBytes { try device.journalReadRun(into: $0, at: block) } } catch { return nil }
            checkpointBitmap[block] = data
        }
        guard let data = checkpointBitmap[block], Int(at - block) < data.count else { return nil }
        return data[data.startIndex + Int(at - block)]
    }

    /// Contiguous runs of up to 1 MiB, one uncached read each.
    private func readBeforeImages() throws -> [(offset: Int64, bytes: Data)] {
        var result: [(offset: Int64, bytes: Data)] = []
        var run: [(Int64, Int)] = []
        func read() throws {
            guard let first = run.first else { return }
            let total = run.reduce(0) { $0 + $1.1 }
            var data = Data(count: total)
            try data.withUnsafeMutableBytes { try device.journalReadRun(into: $0, at: first.0) }
            var at = 0
            for (offset, length) in run { result.append((offset, data.subdata(in: at..<at + length))); at += length }
            run.removeAll()
        }
        for offset in pendingBefore.keys.sorted() {
            let length = pendingBefore[offset]!
            if let last = run.last, last.0 + Int64(last.1) != offset || run.reduce(0, { $0 + $1.1 }) + length > 1024 * 1024 {
                try read()
            }
            run.append((offset, length))
        }
        try read()
        return result
    }

    private func hook(_ name: String) throws {
        #if VOLISLE_WRITE_JOURNAL_TESTING
        try boundary?(name)
        #endif
    }
}

/// All engine device I/O of a volume. Without a session every write is refused.
final class JournaledIO {
    /// Unowned: the FSKit volume owns this object and is the device.
    unowned let device: JournalBlockDevice
    private let pipeline = MetadataWritePipeline()
    var session: WriteJournalSession?
    /// BitLocker: the volume master key (64 hex digits). The journal itself
    /// always works on the device's ciphertext; only reads of the NTFS volume
    /// (its flags, log and header) go through the decrypted view.
    var bitLockerKey: String?

    init(device: JournalBlockDevice) { self.device = device }

    func pread(_ buffer: UnsafeMutableRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        let size = device.journalDeviceSize, bs = Int64(device.journalBlockSize)
        guard bs > 0, size > 0, offset >= 0, count >= 0, offset <= size, count <= size - offset else { return -1 }
        let end = offset + count
        guard end > offset else { return 0 }
        let start = offset / bs * bs
        let alignedEnd = min((end + bs - 1) / bs * bs, size)
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(alignedEnd - start), alignment: Int(bs))
        defer { scratch.deallocate() }
        do {
            if scratch.count >= Self.directReadMinimum { try readRuns(into: scratch, at: start, blockSize: Int(bs), deviceSize: size) }
            else {
                try MetadataBlocks.forEach(start: start, length: scratch.count, blockSize: Int(bs), deviceSize: size) { at, skip, length in
                    try readBlock(into: UnsafeMutableRawBufferPointer(rebasing: scratch[skip..<skip + length]), at: at)
                }
            }
            memcpy(buffer, scratch.baseAddress!.advanced(by: Int(offset - start)), Int(count))
            return count
        } catch { return -1 }
    }

    /// File data comes in large reads. One block at a time through the cache
    /// read a USB disk at about half its speed; blocks the journal has not
    /// written since its last checkpoint read in one uncached run instead (the
    /// device holds what the cache holds; nothing new enters the cache). Small
    /// reads, mostly metadata read again and again, stay cached.
    static let directReadMinimum = 256 * 1024
    private func readRuns(into scratch: UnsafeMutableRawBufferPointer, at start: Int64, blockSize: Int, deviceSize: Int64) throws {
        var run: (skip: Int, length: Int)?
        func flushRun() throws {
            guard let current = run else { return }
            try device.journalReadRun(into: UnsafeMutableRawBufferPointer(rebasing: scratch[current.skip..<current.skip + current.length]),
                                      at: start + Int64(current.skip))
            run = nil
        }
        try MetadataBlocks.forEach(start: start, length: scratch.count, blockSize: blockSize, deviceSize: deviceSize) { at, skip, length in
            if session?.unchangedSinceCheckpoint(at) ?? true {
                if let current = run { run = (current.skip, current.length + length) } else { run = (skip, length) }
            } else {
                try flushRun()
                try readBlock(into: UnsafeMutableRawBufferPointer(rebasing: scratch[skip..<skip + length]), at: at)
            }
        }
        try flushRun()
    }

    func readBlock(into block: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        if let session { try session.read(into: block, at: offset) }
        else { try device.journalRead(into: block, at: offset) }
    }

    func pwrite(_ buffer: UnsafeRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        guard let session, let length = Int(exactly: count), length >= 0 else { return -1 }
        do {
            try pipeline.write(UnsafeRawBufferPointer(start: buffer, count: length), offset: offset,
                blockSize: device.journalBlockSize, deviceSize: device.journalDeviceSize,
                read: { at, block in
                    // Free space keeps nothing: zeros, rather than reading what may not be readable.
                    if session.isFreeAndUnwritten(at, block.count) {
                        _ = block.initializeMemory(as: UInt8.self, repeating: 0)
                    } else {
                        try self.readBlock(into: block, at: at)
                    }
                },
                write: { at, block in try session.write(block, at: at) })
            return count
        } catch { session.stop(); return -1 }
    }

    func sync() -> Int32 {
        guard let session else { return -1 }
        do { try session.sync(); return 0 } catch { return -1 }
    }

    func makeIO(writable: Bool) -> nk_io {
        nk_io(ctx: Unmanaged.passUnretained(self).toOpaque(), pread: journaledPread, pwrite: journaledPwrite,
              size: device.journalDeviceSize, readonly: writable ? 0 : 1, sync: journaledSync)
    }

    /// The NTFS volume as the engine sees it: this device, or BitLocker's
    /// decrypted view of it (writes encrypted, so they still land here as ciphertext).
    func withVolume<T>(writable: Bool, _ body: (inout nk_io) throws -> T) throws -> T {
        var io = makeIO(writable: writable)
        guard let key = bitLockerKey else { return try body(&io) }
        guard let handle = nk_bde_open(&io, Int32(NK_BDE_KEY), key, nil, 0) else { throw WriteJournalError.unavailable }
        defer { nk_bde_close(handle) }
        var view = nk_bde_io(handle)
        return try body(&view)
    }
}

private let journaledPread: nk_pread_cb = { ctx, buffer, count, offset in
    guard let ctx, let buffer else { return -1 }
    return Unmanaged<JournaledIO>.fromOpaque(ctx).takeUnretainedValue().pread(buffer, count, offset)
}
private let journaledPwrite: nk_pwrite_cb = { ctx, buffer, count, offset in
    guard let ctx, let buffer else { return -1 }
    return Unmanaged<JournaledIO>.fromOpaque(ctx).takeUnretainedValue().pwrite(buffer, count, offset)
}
private let journaledSync: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { ctx in
    guard let ctx else { return -1 }
    return Unmanaged<JournaledIO>.fromOpaque(ctx).takeUnretainedValue().sync()
}

func writeJournalHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
