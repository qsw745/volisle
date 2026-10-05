// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct BlockJournalDeviceRecoveryResult: Sendable {
    let completion: BlockJournalRecoveryCompletion
    let restoredBlocks: Int
}

/// Non-serializable, single recovery-scope permission. Only authenticated
/// orchestration in this file can create one; it expires before publication.
final class BlockJournalRecoveryPermit {
    let binding: BlockJournalBinding
    private let validate: () throws -> Void
    private var active = true
    fileprivate init(binding: BlockJournalBinding, validate: @escaping () throws -> Void) {
        self.binding = binding; self.validate = validate
    }
    func verify() throws {
        guard active else { throw BlockJournalError.failed }
        try validate()
        guard active else { throw BlockJournalError.failed }
    }
    fileprivate func revoke() { active = false }
}

/// Serialized recovery orchestration, not an IPC authorization endpoint.
/// The owner first holds the native disk claim and enters its recovery worker.
/// openDevice must acquire a fresh identity-bound transport without writing.
/// The trusted validator checks both virtual and flushed views against the stored
/// independent baseline and filesystem health. No caller-provided baseline,
/// snapshot, key, or claimed "authenticated" flag is accepted here.
enum BlockJournalDeviceRecovery {
    static func restore(authority: BlockJournalAuthority, binding: BlockJournalBinding,
        logDirectory: URL,
        openDevice: (BlockJournalRecoveryPermit) throws -> BlockJournalDeviceSession,
        validateRestoredView: @escaping (BlockJournalRollback.Read, String) throws -> Void
    ) throws -> BlockJournalDeviceRecoveryResult {
        var held: BlockJournalDeviceSession?
        // Retain the transport through durable completion publication, including
        // error paths; releasing it inside the restore callback would be too soon.
        defer { held?.close() }
        do {
            var restoredBlocks = 0
            let completion = try authority.recoverUsingStoredBaseline(binding, logDirectory: logDirectory) { snapshot, baseline in
                try authority.verifyRecoveryLease()
                let permit = BlockJournalRecoveryPermit(binding: snapshot.binding) { try authority.verifyRecoveryLease() }
                defer { permit.revoke() }
                let device = try openDevice(permit)
                held = device
                try authority.verifyRecoveryLease()
                try device.requireBinding(snapshot.binding)
                func fenced<T>(_ operation: () throws -> T) throws -> T {
                    try authority.verifyRecoveryLease()
                    let value = try operation()
                    try authority.verifyRecoveryLease()
                    return value
                }
                let receipt = try BlockJournalRollback().restore(snapshot: snapshot, expectedBinding: snapshot.binding,
                    read: { offset, count in try fenced { try device.read(offset: offset, count: count) } },
                    write: { offset, bytes in try fenced { try device.write(offset: offset, bytes: bytes) } },
                    flush: { try fenced { try device.flush() } },
                    validateRestoredView: { read in
                        try authority.verifyRecoveryLease()
                        try validateRestoredView(read, baseline)
                        try authority.verifyRecoveryLease()
                    })
                try fenced { try device.verify() }
                restoredBlocks = receipt.restoredBlocks
            }
            guard let held else { throw BlockJournalError.failed }
            // Publication can take time. Refuse to report current success if the
            // device disappeared meanwhile, even if historical receipt is durable.
            try held.verify()
            return .init(completion: completion, restoredBlocks: restoredBlocks)
        } catch { authority.invalidateRecovery(); throw error }
    }
}
