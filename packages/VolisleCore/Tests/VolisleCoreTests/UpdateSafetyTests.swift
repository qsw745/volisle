import Foundation
import Testing
@testable import VolisleCore

@MainActor struct UpdateSafetyTests {
    @Test func signedHTTPSChannelRequired() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(try UpdateChannel(feed: "https://updates.example.com/appcast.xml", publicKey: key).feed.host == "updates.example.com")
        for url in ["http://updates.example.com/feed", "file:///tmp/feed", "https://user:pass@example.com/feed", "https://example.com/feed?secret=x", "https://example.com/feed#x"] {
            #expect(throws: (any Error).self) { try UpdateChannel(feed: url, publicKey: key) }
        }
        #expect(throws: (any Error).self) { try UpdateChannel(feed: "https://example.com/feed", publicKey: "invalid") }
    }
    @Test func preparationBlocksHotplugAndKeepsBarrierUntilCancel() async throws {
        let gate = DeviceOperationGate()
        let update = UpdateMaintenance(gate: gate)
        var order: [String] = []
        try await update.prepare(settle: {
            #expect(throws: VolumeError.busy) { try gate.acquire("hotplug") }
            order.append("settle")
        }, stopService: { order.append("stop") }, verify: { order.append("verify") })
        #expect(order == ["settle", "stop", "verify"] && update.ready)
        #expect(gate.isBusy("any"))
        try await update.cancel { order.append("restore") }
        #expect(!gate.isBusy("any") && !update.blocking)
    }
    @Test func activeOperationPreventsStoppingService() async throws {
        let gate = DeviceOperationGate(), update = UpdateMaintenance(gate: DeviceOperationGate())
        let guarder = UpdateMaintenance(gate: gate)
        let lease = try gate.acquire("busy")
        var stopped = false
        await #expect(throws: (any Error).self) { try await guarder.prepare(settle: {}, stopService: { stopped = true }, verify: {}) }
        #expect(!stopped && guarder.blocking && !guarder.ready && !update.blocking)
        try await guarder.cancel {}
        gate.release(lease)
    }
    @Test func failedStopOrVerificationNeverBecomesReady() async throws {
        for failStop in [false, true] {
            let gate = DeviceOperationGate(), update = UpdateMaintenance(gate: DeviceOperationGate())
            let guarder = UpdateMaintenance(gate: gate)
            await #expect(throws: (any Error).self) {
                try await guarder.prepare(settle: {}, stopService: { if failStop { throw VolumeError.busy } }, verify: { throw VolumeError.mountNotVerified })
            }
            #expect(guarder.blocking && !guarder.ready && !update.ready)
            await #expect(throws: (any Error).self) { try await guarder.cancel { throw VolumeError.busy } }
            #expect(gate.isBusy("disk"))
            try await guarder.cancel {}
            #expect(!gate.isBusy("disk"))
        }
    }
    @Test func concurrentPreparationCannotFinishEarly() async throws {
        let update = UpdateMaintenance(gate: DeviceOperationGate())
        var continuation: CheckedContinuation<Void, Never>?
        let first = Task { try await update.prepare(settle: { await withCheckedContinuation { continuation = $0 } }, stopService: {}, verify: {}) }
        while continuation == nil { await Task.yield() }
        await #expect(throws: (any Error).self) { try await update.prepare(settle: {}, stopService: {}, verify: {}) }
        #expect(!update.ready)
        continuation?.resume(); try await first.value
        #expect(update.ready)
        try await update.cancel {}
    }
}
