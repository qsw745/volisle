import Foundation
import CryptoKit
import Testing
@testable import VolisleCore

#if VOLISLE_BLOCK_JOURNAL_TESTING
@Suite(.serialized)
@MainActor struct NativeRecoveryReconnectTests {
    private enum Rejected: Error { case changedCheckpoint }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_RECONNECT_FIXTURE"] != nil))
    func reconnectUsesStoredAuthenticatedIdentity() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOLISLE_RECONNECT_FIXTURE"])
        let values = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath:path)))
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let root = image.deletingLastPathComponent(), name = try #require(values["bsdName"])
        let phase = try #require(values["phase"]), mode = try #require(values["mode"])
        let successfulRecovery = mode == "same" || mode == "renumbered"
        let boot = try #require(values["bootSHA256"]), baseline = try #require(values["baselineSHA256"])
        let registry = try DeviceMetadata.read(name).registryID
        let original = Self.digest(try Data(contentsOf:image))
        if phase == "restore" {
            let previous = try JSONDecoder().decode([String:String].self, from: Data(contentsOf:root.appendingPathComponent("prepared.json")))
            try #require(previous["registry"] != String(registry))
        }
        try await NativeRecoveryDiskClaim.withWritableFixtureConnection(image:image, bsdName:name, bootSHA256:boot) { connection in
            let logs = root.appendingPathComponent("logs"), database = root.appendingPathComponent("authority")
            if phase == "prepare" {
                for directory in [logs,database] {
                    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
                }
            }
            let pool = try BlockJournalStore.pool(directory:logs)
            let authority = try BlockJournalAuthority.fixture(directory:database, pool:pool)
            defer { authority.close() }
            if phase == "prepare" {
                let binding = try authority.newBinding(volumeIdentity:connection.volumeIdentity, bootSHA256:boot,
                    deviceSize:connection.byteCount, blockSize:4096, recoveryBaselineSHA256:baseline)
                let store = try BlockJournalStore(directory:logs, binding:binding, key:authority.key(), expectedPool:pool, failClosed:{})
                defer { store.close() }
                let first = try authority.save(binding, previous:nil, next:store.seal)
                try store.record(offset:16*1024*1024, before:Data(count:4096), after:Data(repeating:0xa5,count:4096))
                _ = try authority.save(binding, previous:first, next:store.seal)
                try JSONEncoder().encode(["registry":String(registry), "identity":connection.volumeIdentity]).write(to:root.appendingPathComponent("prepared.json"))
                return
            }
            // The log binding is loaded from authenticated authority state in a
            // fresh process, not recreated from the newly connected disk.
            let bindings = try authority.bindings()
            try #require(bindings.count == 1)
            let binding = try #require(bindings.first)
            let same = binding.volumeIdentity == connection.volumeIdentity
            #expect(same == (mode != "clone"))
            var validators = 0, factories = 0, blocks = 0
            do {
                let result = try BlockJournalDeviceRecovery.restore(authority:authority, binding:binding, logDirectory:logs,
                    openDevice:{ permit in factories += 1; return try connection.openDevice(permit) },
                    validateRestoredView:{ read, expected in
                        validators += 1
                        var hash = SHA256(), offset:Int64 = 0
                        while offset < connection.byteCount {
                            let bytes = try read(offset,min(1024*1024,Int(connection.byteCount-offset)))
                            hash.update(data:bytes); offset += Int64(bytes.count)
                        }
                        guard hash.finalize().map({String(format:"%02x",$0)}).joined() == expected else { throw Rejected.changedCheckpoint }
                    })
                blocks = result.restoredBlocks
                try #require(successfulRecovery && blocks == 1 && result.completion.checkpoint == baseline)
            } catch {
                if successfulRecovery { throw error }
                if mode == "clone" { try #require(error is RecoveryWriteAdmission.Failure) }
                else { try #require(error is Rejected) }
            }
            #expect(factories == 1)
            #expect(validators == (successfulRecovery ? 2 : mode == "clone" ? 0 : 1))
            try JSONEncoder().encode(["registry":String(registry),"validators":String(validators),"factories":String(factories),
                "blocks":String(blocks),"identity":connection.volumeIdentity]).write(to:root.appendingPathComponent("restored.json"))
        }
        let final = Self.digest(try Data(contentsOf:image))
        #expect(final == (phase == "restore" && successfulRecovery ? baseline : original))
        if phase == "restore" {
            let pool = try BlockJournalStore.pool(directory:root.appendingPathComponent("logs"))
            let reopened = try BlockJournalAuthority.fixture(directory:root.appendingPathComponent("authority"),pool:pool)
            defer { reopened.close() }
            let binding = try #require(reopened.bindings().first)
            #expect((try reopened.recoveryCompletion(binding) != nil) == (successfulRecovery))
        }
    }
    nonisolated private static func digest(_ data:Data)->String { SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined() }
}
#endif
