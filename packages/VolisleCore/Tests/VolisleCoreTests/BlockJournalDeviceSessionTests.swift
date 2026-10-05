import Foundation
import Testing
@testable import VolisleCore

private final class RecoveryTransport {
    var binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: "fixture-volume",
        bootSHA256: String(repeating: "a", count: 64), deviceSize: 8192, blockSize: 512)
    var connection = "boot-and-media-instance"
    let lease = UUID()
    var observation: BlockJournalDeviceObservation
    var bytes = Data(repeating: 7, count: 8192)
    var reads = 0, writes = 0, flushes = 0, releases = 0, stops = 0
    var observeHook: (() throws -> Void)?
    var readHook: (() throws -> Void)?
    var writeHook: (() throws -> Void)?
    var flushHook: (() throws -> Void)?
    var returnedCount: Int?
    init() {
        observation = .init(volumeIdentity: "fixture-volume", bootSHA256: String(repeating: "a", count: 64),
            deviceSize: 8192, blockSize: 512, connectionIdentity: "boot-and-media-instance",
            leaseID: lease, ownsLease: true, mounted: false, writable: true)
    }
    func session() throws -> BlockJournalDeviceSession {
        try .init(binding: binding, connectionIdentity: connection, leaseID: lease,
            observe: { try self.observeHook?(); return self.observation },
            read: { offset, count in
                self.reads += 1; try self.readHook?()
                return self.bytes.subdata(in: Int(offset)..<Int(offset)+count).prefix(self.returnedCount ?? count)
            }, write: { offset, data in
                self.writes += 1; try self.writeHook?()
                self.bytes.replaceSubrange(Int(offset)..<Int(offset)+data.count, with: data)
            }, flush: { self.flushes += 1; try self.flushHook?() },
            stopWrites: { self.stops += 1 }, release: { self.releases += 1 })
    }
}

struct BlockJournalDeviceSessionTests {
    @Test func validSessionReadsWritesFlushesAndClosesOnce() throws {
        let t = RecoveryTransport(), s = try t.session()
        #expect(try s.read(offset: 0, count: 512) == Data(repeating: 7, count: 512))
        try s.write(offset: 512, bytes: Data(repeating: 9, count: 512))
        try s.flush(); try s.verify()
        #expect(t.bytes[512] == 9 && t.writes == 1 && t.flushes == 1)
        s.close(); s.close()
        #expect(t.releases == 1 && t.stops == 0)
        #expect(throws: (any Error).self) { try s.read(offset: 0, count: 1) }
        #expect(t.reads == 1 && t.stops == 0)
    }
    @Test(arguments: 0..<9) func unsafeAdmissionReleasesWithoutIO(_ change: Int) {
        let t = RecoveryTransport(); mutate(t, change)
        #expect(throws: (any Error).self) { _ = try t.session() }
        #expect(t.reads == 0 && t.writes == 0 && t.flushes == 0 && t.stops == 1 && t.releases == 1)
    }
    @Test(arguments: 0..<9) func changedSessionFailsBeforeWriteAndStaysFailed(_ change: Int) throws {
        let t = RecoveryTransport(), s = try t.session(); mutate(t, change)
        #expect(throws: (any Error).self) { try s.write(offset: 0, bytes: Data(repeating: 8, count: 512)) }
        t.observation = RecoveryTransport().observation
        #expect(throws: (any Error).self) { try s.flush() }
        #expect(t.writes == 0 && t.flushes == 0 && t.stops == 1 && t.releases == 0)
        s.close(); #expect(t.releases == 1)
    }
    @Test func lossDuringReadNeverReturnsSuccessfulData() throws {
        let t = RecoveryTransport(), s = try t.session()
        t.readHook = { t.observation.ownsLease = false }
        #expect(throws: (any Error).self) { try s.read(offset: 0, count: 512) }
        #expect(s.failed && t.stops == 1)
    }
    @Test func lossDuringWriteStopsNextIOWithoutPretendingNothingWasWritten() throws {
        let t = RecoveryTransport(), s = try t.session()
        t.writeHook = { t.observation.mounted = true }
        #expect(throws: (any Error).self) { try s.write(offset: 0, bytes: Data(repeating: 8, count: 512)) }
        #expect(t.bytes[0] == 8 && t.writes == 1 && s.failed)
        #expect(throws: (any Error).self) { try s.flush() }
        #expect(t.flushes == 0)
    }
    @Test func lossDuringFlushCannotReportDurability() throws {
        let t = RecoveryTransport(), s = try t.session()
        t.flushHook = { t.observation.connectionIdentity = "replugged" }
        #expect(throws: (any Error).self) { try s.flush() }
        #expect(t.flushes == 1 && s.failed)
    }
    @Test func shortReadLocksSession() throws {
        let t = RecoveryTransport(), s = try t.session(); t.returnedCount = 511
        #expect(throws: (any Error).self) { try s.read(offset: 0, count: 512) }
        #expect(s.failed && t.stops == 1)
    }
    @Test(arguments: [(-1, 1), (8192, 1), (0, -1), (Int64.max, 1), (0, 1_048_577)])
    func invalidReadNeverReachesTransport(_ range: (Int64, Int)) throws {
        let t = RecoveryTransport(), s = try t.session()
        #expect(throws: (any Error).self) { try s.read(offset: range.0, count: range.1) }
        #expect(t.reads == 0 && s.failed)
    }
    @Test(arguments: [(Int64(1), 512), (Int64(8192), 512), (Int64(0), 0), (Int64(0), 1024)])
    func invalidWriteNeverReachesTransport(_ range: (Int64, Int)) throws {
        let t = RecoveryTransport(), s = try t.session()
        #expect(throws: (any Error).self) { try s.write(offset: range.0, bytes: Data(repeating: 8, count: range.1)) }
        #expect(t.writes == 0 && s.failed)
    }
    @Test(arguments: ["observe", "read", "write", "flush"])
    func transportErrorsAreSticky(_ phase: String) throws {
        let t = RecoveryTransport(), s = try t.session()
        let error: () throws -> Void = { throw BlockJournalError.unavailable }
        switch phase {
        case "observe": t.observeHook = error
        case "read": t.readHook = error
        case "write": t.writeHook = error
        default: t.flushHook = error
        }
        #expect(throws: (any Error).self) {
            if phase == "write" { try s.write(offset: 0, bytes: Data(repeating: 8, count: 512)) }
            else if phase == "flush" { try s.flush() }
            else { _ = try s.read(offset: 0, count: 512) }
        }
        #expect(s.failed && t.stops == 1)
    }
    @Test(arguments: ["observe", "read", "write", "flush"])
    func swallowedReentryCannotReturnSuccess(_ phase: String) throws {
        let t = RecoveryTransport(), s = try t.session()
        let reenter: () throws -> Void = { try? s.verify() }
        switch phase {
        case "observe": t.observeHook = reenter
        case "read": t.readHook = reenter
        case "write": t.writeHook = reenter
        default: t.flushHook = reenter
        }
        #expect(throws: (any Error).self) {
            if phase == "write" { try s.write(offset: 0, bytes: Data(repeating: 8, count: 512)) }
            else if phase == "flush" { try s.flush() }
            else { _ = try s.read(offset: 0, count: 512) }
        }
        #expect(s.failed && t.stops == 1)
    }
    @Test func closeDuringIODefersReleaseUntilCallbackReturns() throws {
        let t = RecoveryTransport(), s = try t.session()
        t.readHook = { s.close(); #expect(t.releases == 0) }
        #expect(throws: (any Error).self) { try s.read(offset: 0, count: 512) }
        #expect(t.releases == 1 && t.stops == 1)
    }
    @Test func emptyReadDoesNotTouchTransportButStillChecksLease() throws {
        let t = RecoveryTransport(), s = try t.session()
        #expect(try s.read(offset: 8192, count: 0).isEmpty && t.reads == 0)
        t.observation.ownsLease = false
        #expect(throws: (any Error).self) { try s.read(offset: 8192, count: 0) }
    }
    @Test func finalPartialJournalBlockUsesExactRemainingDeviceLength() throws {
        let t = RecoveryTransport()
        t.binding = .init(transactionID: UUID(), volumeIdentity: t.binding.volumeIdentity,
            bootSHA256: t.binding.bootSHA256, deviceSize: 7680, blockSize: 4096)
        t.observation.deviceSize = 7680; t.observation.blockSize = 4096
        let s = try t.session()
        try s.write(offset: 4096, bytes: Data(repeating: 9, count: 3584))
        #expect(t.writes == 1 && t.bytes[7679] == 9 && t.bytes[7680] == 7)
        #expect(throws: (any Error).self) { try s.write(offset: 4096, bytes: Data(repeating: 9, count: 4096)) }
        #expect(t.writes == 1)
    }
    private func mutate(_ t: RecoveryTransport, _ field: Int) {
        switch field {
        case 0: t.observation.volumeIdentity = "other-volume"
        case 1: t.observation.bootSHA256 = String(repeating: "b", count: 64)
        case 2: t.observation.deviceSize += 512
        case 3: t.observation.blockSize = 4096
        case 4: t.observation.connectionIdentity = "new-boot-or-media-instance"
        case 5: t.observation.leaseID = UUID()
        case 6: t.observation.ownsLease = false
        case 7: t.observation.mounted = true
        default: t.observation.writable = false
        }
    }
}
