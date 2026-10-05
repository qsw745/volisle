import Foundation
import CryptoKit
import Darwin
import Testing
@testable import VolisleCore

#if VOLISLE_BLOCK_JOURNAL_TESTING
@Suite(.serialized)
@MainActor struct NativeRecoveryWriteTests {
    private enum Rejected: Error { case independentValidator }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_NATIVE_WRITE_FIXTURE"] != nil))
    func authenticatedRawDeviceRestore() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOLISLE_NATIVE_WRITE_FIXTURE"])
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let name = try #require(values["bsdName"])
        let baseline = try #require(values["baselineSHA256"])
        let boot = try #require(values["bootSHA256"])
        let mode = try #require(values["mode"])
        let root = image.deletingLastPathComponent()
        let initial = try Self.descriptors(name)
        let initialHash = Self.digest(try Data(contentsOf: image))
        #expect(initialHash != baseline)
        var completed = false
        do {
            try await NativeRecoveryDiskClaim.withWritableFixtureConnection(image: image, bsdName: name,
                bootSHA256: mode == "wrong-boot" ? String(repeating: "f", count: 64) : boot) { connection in
                var stage = "connection", validators = 0
                defer {
                    try? JSONSerialization.data(withJSONObject: ["stage": stage, "validators": validators], options: [.sortedKeys]).write(to: root.appendingPathComponent("stages.json"))
                }
                let logs = root.appendingPathComponent("logs"), database = root.appendingPathComponent("authority")
                for directory in [logs, database] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                let pool = try BlockJournalStore.pool(directory: logs)
                let authority = try BlockJournalAuthority.fixture(directory: database, pool: pool)
                defer { authority.close() }
                let binding = try authority.newBinding(volumeIdentity: connection.volumeIdentity,
                    bootSHA256: mode == "wrong-boot" ? String(repeating: "f", count: 64) : boot,
                    deviceSize: connection.byteCount, blockSize: 4096, recoveryBaselineSHA256: baseline)
                // Seed a log for the fixture's pre-existing interrupted block.
                // This does not pretend that a production transaction wrote it.
                stage = "seed-log"
                let store = try BlockJournalStore(directory: logs, binding: binding, key: authority.key(), expectedPool: pool, failClosed: {})
                do {
                    let first = try authority.save(binding, previous: nil, next: store.seal)
                    try store.record(offset: 16 * 1024 * 1024, before: Data(count: 4096), after: Data(repeating: 0xa5, count: 4096))
                    _ = try authority.save(binding, previous: first, next: store.seal)
                } catch { store.close(); throw error }
                store.close()
                var saved: BlockJournalRecoveryPermit?
                stage = "authenticate"
                let result = try BlockJournalDeviceRecovery.restore(authority: authority, binding: binding, logDirectory: logs,
                    openDevice: { permit in
                        stage = "open-device"; saved = permit
                        let device = try connection.openDevice(permit)
                        stage = "opened-device"
                        return device
                    },
                    validateRestoredView: { read, expected in
                        validators += 1; stage = "validate-\(validators)"
                        let actualBoot = try read(0, 512)
                        #expect(try read(3, 8) == actualBoot.subdata(in: 3..<11))
                        let head = try read(0, 1024 * 1024), next = try read(1024 * 1024, 512)
                        #expect(try read(1, 1024 * 1024) == Data(head.dropFirst()) + Data(next.prefix(1)))
                        let tail = try read(connection.byteCount - 512, 512)
                        #expect(try read(connection.byteCount - 1, 1) == Data(tail.suffix(1)))
                        #expect(try read(connection.byteCount, 0).isEmpty)
                        var hash = SHA256(), offset: Int64 = 0
                        while offset < connection.byteCount {
                            let data = try read(offset, min(1024 * 1024, Int(connection.byteCount - offset)))
                            hash.update(data: data); offset += Int64(data.count)
                        }
                        try #require(hash.finalize().map { String(format: "%02x", $0) }.joined() == expected)
                        guard mode != "validator-reject" else { throw Rejected.independentValidator }
                    })
                stage = "restored"
                #expect(result.restoredBlocks == 1 && result.completion.checkpoint == baseline && validators == 2)
                #expect(try authority.recoveryCompletion(binding)?.checkpoint == baseline)
                let expired = try #require(saved)
                #expect(throws: (any Error).self) { try expired.verify() }
                #expect(throws: (any Error).self) { _ = try connection.openDevice(expired) }
            }
            completed = true
        } catch {
            guard mode != "success" else { throw error }
            if mode == "wrong-boot" { #expect(error is NativeRecoveryConnection.Failure) }
            else { #expect(error is Rejected) }
        }
        let stages = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("stages.json"))) as? [String: Any])
        #expect(stages["stage"] as? String == (mode == "success" ? "restored" : mode == "wrong-boot" ? "open-device" : "validate-1"))
        #expect(stages["validators"] as? Int == (mode == "success" ? 2 : mode == "wrong-boot" ? 0 : 1))
        #expect(completed == (mode == "success"))
        #expect(try Self.descriptors(name) == initial)
        #expect(Self.digest(try Data(contentsOf: image)) == (mode == "success" ? baseline : initialHash))
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func descriptors(_ name: String) throws -> Set<Int32> {
        var named = stat()
        guard lstat("/dev/r" + name, &named) == 0, named.st_mode & S_IFMT == S_IFCHR else { throw BlockJournalError.unavailable }
        return Set(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { text -> Int32? in
            guard let fd = Int32(text) else { return nil }; var info = stat()
            return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFCHR && info.st_rdev == named.st_rdev ? fd : nil
        })
    }
}
#endif
