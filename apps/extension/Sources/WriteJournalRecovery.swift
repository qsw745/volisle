// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin
import os

/// Session lifecycle and connection-time recovery for one volume serial.
/// Every call is serialized by the volume's engine queue.
enum WriteJournalCoordinator {
    private static let log = Logger(subsystem: "Volisle.NTFSModule", category: "journal")
    enum Outcome: Equatable {
        case none
        case recovered
        /// The volume was used elsewhere since the interruption: the records no
        /// longer describe it, were archived, and the volume is judged as it is now.
        case superseded
        case refused(WriteJournalError)
    }
    private static let dirtyFlag: UInt16 = 0x0001
    /// VOLUME_FLAGS_MASK: the $Volume flag bits NTFS-3G knows.
    private static let knownFlags: UInt16 = 0xc03f

    /// Before the writable engine opens. A retained, already recovered
    /// session is discarded only after a durable device barrier.
    static func begin(store: WriteJournalStore, serial: String, io: JournaledIO) throws -> (WriteJournalSession, Int32) {
        let lock = try store.lock(serial: serial)
        do {
            if let old = try store.sessionRecord(serial: serial) {
                guard old.state == .recovered, io.device.flushIsDurable else { throw WriteJournalError.busy }
                try io.device.journalFlush()
                try store.removeAll(serial: serial)
            } else {
                // Left by a cleanup that was interrupted after the session record went.
                try store.removeOrphanEpochs(serial: serial)
            }
            let facts = try volumeFacts(io)
            let record = WriteJournalSessionRecord(session: UUID(), serial: serial,
                deviceSize: io.device.journalDeviceSize, blockSize: io.device.journalBlockSize,
                bootSector: facts.boot, initialFlags: facts.flags, logfileOffset: facts.logfileOffset,
                logfileLength: facts.logfileLength, logfileSHA256: facts.logfileSHA256, state: .active)
            guard record.initialFlags & dirtyFlag == 0 else { throw WriteJournalError.invalid }
            try store.saveSessionRecord(record)
            let session = WriteJournalSession(store: store, record: record, device: io.device, epoch: 1)
            io.session = session
            return (session, lock)
        } catch {
            Darwin.close(lock)
            throw error
        }
    }

    /// After a successful nk_umount only. Anything else keeps the records.
    static func finish(store: WriteJournalStore, io: JournaledIO, lock: Int32) throws {
        defer { Darwin.close(lock); io.session = nil }
        guard let session = io.session else { throw WriteJournalError.failed }
        // Keep every epoch until the device barrier below: removing the newest
        // first (as the retention window would) and then being interrupted would
        // leave an older subset that recovery rolls back over newer data.
        session.retention = .infinity
        try session.checkpoint()
        guard io.device.flushIsDurable else { throw WriteJournalError.unavailable }
        try io.device.journalFlush()
        try store.removeAll(serial: session.record.serial)
    }

    /// Roll back to the oldest retained checkpoint and release this host's own dirty
    /// marker. Refuses (without device writes) if the volume changed outside
    /// this journal, e.g. was mounted by Windows after the interruption.
    static func recover(store: WriteJournalStore, serial: String, io: JournaledIO) -> Outcome {
        do {
            guard var record = try store.sessionRecord(serial: serial) else { return .none }
            let lock = try store.lock(serial: serial)
            defer { Darwin.close(lock) }
            let device = io.device
            // A BitLocker volume can only be read with its key: without it the
            // header below would never match and the records would be archived.
            if io.bitLockerKey == nil, try readBytes(io, at: 0, count: 512)[3..<11] == Data("-FVE-FS-".utf8) {
                return .refused(.unavailable)
            }
            // Another system (Windows) rewrote the volume header or its $LogFile:
            // rolling back would undo its work, and refusing forever would keep the
            // disk read-only with nothing the user can do. Archive the records; the
            // writable inspection then decides from the volume itself (our unreleased
            // dirty marker, if Windows did not check the disk, keeps it read-only).
            guard record.deviceSize == device.journalDeviceSize, record.blockSize == device.journalBlockSize,
                  try io.withVolume(writable: false, { try volumeBytes(&$0, at: 0, count: 512) }) == record.bootSector else {
                try store.archive(serial: serial); return .superseded
            }
            let logfile = try io.withVolume(writable: false) { try volumeBytes(&$0, at: record.logfileOffset, count: record.logfileLength) }
            guard hex(logfile) == record.logfileSHA256 else {
                // Used elsewhere after a completed recovery is ordinary use.
                if record.state == .recovered { try store.removeAll(serial: serial); return .none }
                try store.archive(serial: serial); return .superseded
            }
            let epochs = try store.epochs(serial: serial, session: record.session)
            // Retained checkpointed epochs too: their data may have been lost in
            // the drive's own write cache when it lost power.
            let targets = epochs.sorted { $0.header.epoch > $1.header.epoch }
            if record.state == .recovered, try verifyRecovered(targets, io: io) {
                return .recovered
            }
            try verify(targets, io: io)
            // Newest first: each epoch began from the state its successor restores.
            for epoch in targets { try rollBack(epoch, device: device) }
            if device.flushIsDurable { try device.journalFlush() }
            try releaseMarker(store: store, record: record, io: io, epoch: (epochs.map(\.header.epoch).max() ?? 0) + 1)
            guard try io.withVolume(writable: false, { nk_inspect(&$0) }) == 0 else { return .refused(.corrupt) }
            if device.flushIsDurable {
                try device.journalFlush()
                try store.removeAll(serial: serial)
            } else {
                record.state = .recovered
                try store.saveSessionRecord(record)
            }
            return .recovered
        } catch let error as WriteJournalError {
            return .refused(error)
        } catch {
            return .refused(.unavailable)
        }
    }

    private static func releaseMarker(store: WriteJournalStore, record: WriteJournalSessionRecord,
                                      io: JournaledIO, epoch: UInt64) throws {
        let facts = try volumeFacts(io)
        if facts.flags == record.initialFlags { return }  // rolled back before the marker
        // Up to 0.5.7 the marker lost the flag bits NTFS-3G does not know (Windows 11
        // sets 0x0080), so it read back as (initial|dirty) & known; "Check on This
        // Mac" then cleared it to initial & known. Both are this host's own doing.
        let unknownBits = record.initialFlags & ~knownFlags
        if unknownBits != 0, facts.flags == record.initialFlags & knownFlags { return }
        let legacy = unknownBits != 0 && facts.flags == (record.initialFlags | dirtyFlag) & knownFlags
        guard facts.flags == record.initialFlags | dirtyFlag || legacy else {
            log.error("回滚后卷标志不符：当前 0x\(String(facts.flags, radix: 16), privacy: .public)，开始时 0x\(String(record.initialFlags, radix: 16), privacy: .public)")
            throw WriteJournalError.foreignChange
        }
        let session = WriteJournalSession(store: store, record: record, device: io.device, epoch: epoch, kind: .recovery)
        io.session = session
        defer { io.session = nil }
        let released = try io.withVolume(writable: true) { volume in
            record.bootSector.withUnsafeBytes {
                nk_release_owned_marker(&volume, record.initialFlags, $0.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard released == 0 else { session.stop(); throw WriteJournalError.failed }
        try session.checkpoint()
    }

    /// Every block must hold a value from its recorded history: any before-image
    /// or any value this journal wrote. A lost cached write leaves an earlier one.
    /// Blocks of the newest unfinished epoch may be torn: its delayed writes
    /// reach the device whenever the system flushes, not only its last group.
    /// A drive that loses power with writes in its own cache can leave any
    /// recent block half written (seen: a 24 KiB run of zeros in a block of the
    /// oldest retained epoch); such a block is this host's own, recognised sector
    /// by sector, and rolling back restores it. Anything else is someone else's.
    private static func verify(_ targets: [WriteJournalEpoch], io: JournaledIO) throws {
        let newest = targets.first
        let torn = newest.map { $0.checkpointed ? [] : Set($0.groups.flatMap { $0.after.map(\.offset) }) } ?? []
        var allowed: [Int64: Set<Data>] = [:]
        var versions: [Int64: [Data]] = [:]
        var written: [Int64: [[UInt64]]] = [:]
        // Written without a before-image: free at the start of every retained epoch,
        // so free again once rolled back, and what they hold does not matter.
        var freeWrites = Set<Int64>()
        for epoch in targets {
            var befores = Set<Int64>(), afters = Set<Int64>()
            for group in epoch.groups {
                for item in group.after { allowed[item.offset, default: []].insert(item.sha256); afters.insert(item.offset) }
                for (offset, hashes) in group.afterSectors { written[offset, default: []].append(hashes) }
                for item in group.before {
                    allowed[item.offset, default: []].insert(Data(SHA256.hash(data: item.bytes)))
                    versions[item.offset, default: []].append(item.bytes)
                    befores.insert(item.offset)
                }
            }
            freeWrites.formUnion(afters.subtracting(befores))
        }
        var checked = Set<Int64>(), partial = 0
        var mismatches: [Mismatch] = []
        for (position, epoch) in targets.enumerated() {
            for group in epoch.groups {
                for item in group.before where !torn.contains(item.offset) && !freeWrites.contains(item.offset) {
                    guard checked.insert(item.offset).inserted else { continue }
                    let current = try readBytes(io, at: item.offset, count: item.bytes.count)
                    if allowed[item.offset, default: []].contains(Data(SHA256.hash(data: current))) { continue }
                    let olds = versions[item.offset] ?? [], news = written[item.offset] ?? []
                    if sectorsAccounted(current, olds, news) { partial += 1; continue }
                    mismatches.append(.init(epoch: epoch.header.epoch, position: position, checkpointed: epoch.checkpointed,
                                            offset: item.offset, sectors: sectorPattern(current, olds, news), versions: olds.count))
                }
            }
        }
        if partial > 0 { log.notice("恢复核对：\(partial, privacy: .public) 块是断开时写到一半的本机写入，照常回滚") }
        guard !mismatches.isEmpty else { return }
        // Which blocks and how they differ tells our own torn or lost writes apart from someone else's.
        log.error("""
            恢复核对不符：\(mismatches.count, privacy: .public)/\(checked.count, privacy: .public) 块；\
            批次 \(targets.count, privacy: .public) 个，最新批次\(newest?.checkpointed == true ? "已确认" : "未完成", privacy: .public)
            """)
        for mismatch in mismatches.prefix(40) {
            log.error("""
                不符块：偏移 \(mismatch.offset, privacy: .public) 批次 \(mismatch.epoch, privacy: .public)\
                （第 \(mismatch.position + 1, privacy: .public) 新，\(mismatch.checkpointed ? "已确认" : "未完成", privacy: .public)）\
                已记旧版 \(mismatch.versions, privacy: .public) 个；扇区 \(mismatch.sectors, privacy: .public)
                """)
        }
        throw WriteJournalError.foreignChange
    }

    private struct Mismatch {
        let epoch: UInt64; let position: Int; let checkpointed: Bool; let offset: Int64; let sectors: String; let versions: Int
    }

    /// Every 512-byte sector equals that sector of a recorded earlier content or
    /// of a recorded write, or was left empty.
    static func sectorsAccounted(_ current: Data, _ versions: [Data], _ written: [[UInt64]]) -> Bool {
        sectorKinds(current, versions, written).allSatisfy { $0 != "?" }
    }

    /// The block's sectors as runs, for the log: "旧" a recorded earlier content,
    /// "新" a recorded write, "零" empty, "?" none of these.
    static func sectorPattern(_ current: Data, _ versions: [Data], _ written: [[UInt64]]) -> String {
        var runs: [(String, Int, Int)] = []
        for (index, kind) in sectorKinds(current, versions, written).enumerated() {
            if let last = runs.last, last.0 == kind, last.2 == index - 1 { runs[runs.count - 1].2 = index }
            else { runs.append((kind, index, index)) }
        }
        return runs.map { $0.1 == $0.2 ? "\($0.0)\($0.1)" : "\($0.0)\($0.1)-\($0.2)" }.joined(separator: " ")
    }

    private static func sectorKinds(_ current: Data, _ versions: [Data], _ written: [[UInt64]]) -> [String] {
        let size = WriteJournalEpoch.sectorSize, bytes = [UInt8](current)
        let olds = versions.filter { $0.count == bytes.count }.map { [UInt8]($0) }
        return stride(from: 0, to: bytes.count, by: size).map { at in
            let sector = bytes[at..<min(at + size, bytes.count)], index = at / size
            if olds.contains(where: { $0[sector.indices] == sector }) { return "旧" }
            let hash = sector.withUnsafeBytes { WriteJournalEpoch.sectorHash($0) }
            if written.contains(where: { index < $0.count && $0[index] == hash }) { return "新" }
            return sector.allSatisfy { $0 == 0 } ? "零" : "?"
        }
    }

    private static func rollBack(_ epoch: WriteJournalEpoch, device: JournalBlockDevice) throws {
        for group in epoch.groups.reversed() {
            for item in group.before { try item.bytes.withUnsafeBytes { try device.journalWrite($0, at: item.offset) } }
        }
    }

    /// A retained recovery whose device barrier was not yet confirmed.
    private static func verifyRecovered(_ targets: [WriteJournalEpoch], io: JournaledIO) throws -> Bool {
        var expected: [Int64: Data] = [:]  // newest writer wins
        for epoch in targets.reversed() {
            if epoch.header.kind == .recovery {
                guard epoch.checkpointed else { return false }
                for group in epoch.groups { for item in group.after { expected[item.offset] = item.sha256 } }
            } else {
                for group in epoch.groups { for item in group.before where expected[item.offset] == nil {
                    expected[item.offset] = Data(SHA256.hash(data: item.bytes))
                } }
            }
        }
        for (offset, digest) in expected {
            let count = Int(min(Int64(io.device.journalBlockSize), io.device.journalDeviceSize - offset))
            guard Data(SHA256.hash(data: try readBytes(io, at: offset, count: count))) == digest else { return false }
        }
        return true
    }

    struct VolumeFacts { let boot: Data; let flags: UInt16; let logfileOffset: Int64; let logfileLength: Int; let logfileSHA256: String }

    static func volumeFacts(_ io: JournaledIO) throws -> VolumeFacts {
        try io.withVolume(writable: false) { volume in
            var flags: UInt16 = 0
            var offset: Int64 = 0, length: Int64 = 0
            guard nk_volume_state(&volume, &flags, &offset, &length) == 0, length > 0, length <= Int64(Int32.max) else {
                throw WriteJournalError.unavailable
            }
            let logfile = try volumeBytes(&volume, at: offset, count: Int(length))
            return .init(boot: try volumeBytes(&volume, at: 0, count: 512), flags: flags, logfileOffset: offset,
                         logfileLength: Int(length), logfileSHA256: hex(logfile))
        }
    }

    /// Bytes of the NTFS volume (decrypted for BitLocker), not of the device.
    static func volumeBytes(_ volume: inout nk_io, at offset: Int64, count: Int) throws -> Data {
        guard let pread = volume.pread, offset >= 0, count >= 0 else { throw WriteJournalError.unavailable }
        var data = Data(count: count)
        let ctx = volume.ctx
        let got = data.withUnsafeMutableBytes { pread(ctx, $0.baseAddress, Int64(count), offset) }
        guard got == Int64(count) else { throw WriteJournalError.unavailable }
        return data
    }

    static func readBytes(_ io: JournaledIO, at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { io.pread($0.baseAddress!, Int64(count), offset) }
        guard read == Int64(count) else { throw WriteJournalError.unavailable }
        return data
    }

    private static func hex(_ data: Data) -> String { writeJournalHex(Data(SHA256.hash(data: data))) }
}
