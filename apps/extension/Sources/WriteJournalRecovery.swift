// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Darwin

/// Session lifecycle and connection-time recovery for one volume serial.
/// Every call is serialized by the volume's engine queue.
enum WriteJournalCoordinator {
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
            } else if try !store.epochs(serial: serial, session: UUID()).isEmpty {
                throw WriteJournalError.corrupt
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
        session.retention = 0  // the records go next; this epoch need not be kept
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
        guard facts.flags == record.initialFlags | dirtyFlag || legacy else { throw WriteJournalError.foreignChange }
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
    /// Blocks of the newest unfinished epoch's final group may be torn.
    private static func verify(_ targets: [WriteJournalEpoch], io: JournaledIO) throws {
        let newest = targets.first
        let torn = newest.map { $0.checkpointed ? [] : Set($0.groups.last?.after.map(\.offset) ?? []) } ?? []
        var allowed: [Int64: Set<Data>] = [:]
        for epoch in targets {
            for group in epoch.groups {
                for item in group.after { allowed[item.offset, default: []].insert(item.sha256) }
                for item in group.before { allowed[item.offset, default: []].insert(Data(SHA256.hash(data: item.bytes))) }
            }
        }
        for epoch in targets {
            for group in epoch.groups {
                for item in group.before where !torn.contains(item.offset) {
                    let current = try readBytes(io, at: item.offset, count: item.bytes.count)
                    guard allowed[item.offset, default: []].contains(Data(SHA256.hash(data: current))) else {
                        throw WriteJournalError.foreignChange
                    }
                }
            }
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
