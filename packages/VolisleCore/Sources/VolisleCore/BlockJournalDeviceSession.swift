// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Fresh observations from a held transport, never assertions from an IPC caller.
/// connectionIdentity binds this boot/connection; volumeIdentity binds the log.
/// The transport owns the OS exclusion mechanism and must keep it until release.
struct BlockJournalDeviceObservation: Equatable {
    var volumeIdentity: String
    var bootSHA256: String
    var deviceSize: Int64
    var blockSize: Int
    var connectionIdentity: String
    var leaseID: UUID
    var ownsLease: Bool
    var mounted: Bool
    var writable: Bool
}

/// Serialized recovery I/O fence. This is NOT an OS device-lease acquisition API.
/// Admission requires an already acquired, unmounted, identity-bound transport.
/// In particular, supplying ownsLease=true does not establish raw-device exclusion.
/// The owner must authenticate the journal and independently validate recovery.
/// Do not share with a running filesystem engine or between executors.
final class BlockJournalDeviceSession {
    private let binding: BlockJournalBinding
    private let connectionIdentity: String
    private let leaseID: UUID
    private let observe: () throws -> BlockJournalDeviceObservation
    private let transportRead: (Int64, Int) throws -> Data
    private let transportWrite: (Int64, Data) throws -> Void
    private let transportFlush: () throws -> Void
    private let stopWrites: () -> Void
    private let release: () -> Void
    private var running = false
    private var closed = false
    private var released = false
    private(set) var failed = false

    init(binding: BlockJournalBinding, connectionIdentity: String, leaseID: UUID,
         observe: @escaping () throws -> BlockJournalDeviceObservation,
         read: @escaping (Int64, Int) throws -> Data,
         write: @escaping (Int64, Data) throws -> Void,
         flush: @escaping () throws -> Void,
         stopWrites: @escaping () -> Void, release: @escaping () -> Void) throws {
        self.binding = binding; self.connectionIdentity = connectionIdentity; self.leaseID = leaseID
        self.observe = observe; transportRead = read; transportWrite = write; transportFlush = flush
        self.stopWrites = stopWrites; self.release = release
        do {
            try BlockJournalStore.validate(binding)
            guard !connectionIdentity.isEmpty, connectionIdentity.utf8.count <= 512,
                  !connectionIdentity.contains("\0") else { throw BlockJournalError.invalid }
            try verify()
        } catch { fail(); close(); throw error }
    }
    deinit { if !released { release() } }

    func verify() throws { try perform {} }

    /// Match the entire authenticated transaction, not only geometry/volume.
    func requireBinding(_ expected: BlockJournalBinding) throws {
        try perform {
            guard binding == expected else { throw BlockJournalError.corrupt }
        }
    }

    func read(offset: Int64, count: Int) throws -> Data {
        try perform {
            guard offset >= 0, offset <= binding.deviceSize, count >= 0, count <= 1024 * 1024,
                  Int64(count) <= binding.deviceSize-offset else { throw BlockJournalError.invalid }
            if count == 0 { return Data() }
            let bytes = try transportRead(offset, count)
            guard bytes.count == count else { throw BlockJournalError.unavailable }
            return bytes.withUnsafeBytes { Data($0) }
        }
    }

    /// Exactly one complete journal block. A throwing callback may have written
    /// some/all bytes; failure locks the session instead of retrying or clearing dirty.
    func write(offset: Int64, bytes: Data) throws {
        try perform {
            guard offset >= 0, offset < binding.deviceSize,
                  offset % Int64(binding.blockSize) == 0,
                  bytes.count == Int(min(Int64(binding.blockSize), binding.deviceSize-offset)),
                  Int64(bytes.count) <= binding.deviceSize-offset else { throw BlockJournalError.invalid }
            try transportWrite(offset, bytes.withUnsafeBytes { Data($0) })
        }
    }

    func flush() throws { try perform { try transportFlush() } }

    /// Keep the transport held after failure until the recovery owner has unwound
    /// its authority/log scopes. Closing during a callback defers actual release.
    func close() {
        guard !closed else { return }
        closed = true
        if running { fail() }
        else { releaseOnce() }
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        guard !closed, !failed else { throw BlockJournalError.failed }
        guard !running else { fail(); throw BlockJournalError.failed }
        running = true
        defer { running = false; if closed { releaseOnce() } }
        do {
            try check()
            let result = try operation()
            try check()
            return result
        } catch { fail(); throw error }
    }
    private func check() throws {
        guard !closed, !failed else { throw BlockJournalError.failed }
        let current = try observe()
        // Reentrant callbacks may swallow their error: never trust their return.
        guard !closed, !failed else { throw BlockJournalError.failed }
        guard current.volumeIdentity == binding.volumeIdentity,
              current.bootSHA256 == binding.bootSHA256,
              current.deviceSize == binding.deviceSize, current.blockSize == binding.blockSize,
              current.connectionIdentity == connectionIdentity, current.leaseID == leaseID,
              current.ownsLease, !current.mounted, current.writable else { throw BlockJournalError.unavailable }
    }
    private func fail() {
        guard !failed else { return }
        failed = true; stopWrites()
    }
    private func releaseOnce() {
        guard !released else { return }
        released = true; release()
    }
}
