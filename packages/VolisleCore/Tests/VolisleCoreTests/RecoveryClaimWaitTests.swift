import Foundation
import Testing
@testable import VolisleCore

@MainActor struct RecoveryClaimWaitTests {
    @Test func immediateSystemReplyCompletesOnce() async throws {
        var replies: [(Int32, Bool)] = [], stops = 0
        let wait = RecoveryClaimWait(onAbandon: { stops += 1 }, onReply: { replies.append(($0, $1)) })
        let status = try await wait.start(timeout: .seconds(1)) { wait.complete(0) }
        wait.complete(7); wait.cancel()
        #expect(status == 0 && stops == 0 && replies.count == 1 && replies[0].1)
        await #expect(throws: RecoveryClaimWait.Failure.alreadyStarted) { try await wait.start(timeout: .seconds(1)) {} }
    }
    @Test func nativeRefusalIsPreserved() async throws {
        let wait = RecoveryClaimWait(onAbandon: {}, onReply: { _, _ in })
        #expect(try await wait.start(timeout: .seconds(1)) { wait.complete(-123) } == -123)
    }
    @Test func deadlineReturnsBeforeLateSuccessAndLateReplyOnlyCleansUp() async {
        var stops = 0, replies: [(Int32, Bool)] = [], submitted = 0
        let wait = RecoveryClaimWait(onAbandon: { stops += 1 }, onReply: { replies.append(($0, $1)) })
        await #expect(throws: RecoveryClaimWait.Failure.timedOut) {
            try await wait.start(timeout: .milliseconds(20)) { submitted += 1 }
        }
        #expect(stops == 1 && submitted == 1 && replies.isEmpty)
        wait.complete(0); wait.complete(0); wait.cancel()
        #expect(replies.count == 1 && !replies[0].1 && stops == 1)
    }
    @Test func pendingCancellationReturnsWithoutNativeReply() async throws {
        var submitted = false, stops = 0, late = false
        let wait = RecoveryClaimWait(onAbandon: { stops += 1 }, onReply: { _, active in late = !active })
        let task = Task { @MainActor in try await wait.start(timeout: .seconds(5)) { submitted = true } }
        while !submitted { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stops == 1 && !late)
        wait.complete(-1)
        #expect(late && stops == 1)
    }
    @Test func alreadyCancelledTaskNeverSubmits() async {
        var submissions = 0
        let wait = RecoveryClaimWait(onAbandon: {}, onReply: { _, _ in Issue.record("Unexpected reply") })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await wait.start(timeout: .seconds(1)) { submissions += 1 }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        wait.complete(0)
        #expect(submissions == 0)
    }
    @Test(arguments: [Duration.zero, .milliseconds(-1), .seconds(61)])
    func invalidDeadlineNeverSubmits(_ timeout: Duration) async {
        let wait = RecoveryClaimWait(onAbandon: {}, onReply: { _, _ in })
        await #expect(throws: RecoveryClaimWait.Failure.invalidTimeout) {
            try await wait.start(timeout: timeout) { Issue.record("Invalid timeout submitted") }
        }
    }
    @Test func successBeforeDeadlineCancelsTimer() async throws {
        var stopped = false
        let wait = RecoveryClaimWait(onAbandon: { stopped = true }, onReply: { _, active in #expect(active) })
        _ = try await wait.start(timeout: .milliseconds(20)) { wait.complete(0) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!stopped)
    }
    @Test func cleanupRunsBeforeCallerResumes() async throws {
        var cleaned = false
        let wait = RecoveryClaimWait(onAbandon: {}, onReply: { _, _ in cleaned = true })
        _ = try await wait.start(timeout: .seconds(1)) { wait.complete(0) }
        #expect(cleaned)
    }
    @Test func reservationBlocksSameDeviceAndBoundsUnresolvedSessions() throws {
        var pool = RecoveryClaimReservations(limit: 2)
        let first = UUID(), second = UUID(), third = UUID()
        try pool.reserve(media: 1, token: first)
        #expect(throws: (any Error).self) { try pool.reserve(media: 1, token: first) }
        #expect(throws: (any Error).self) { try pool.reserve(media: 1, token: second) }
        try pool.reserve(media: 2, token: second)
        #expect(throws: (any Error).self) { try pool.reserve(media: 3, token: third) }
        let unrelated = pool.release(media: 1, token: third)
        #expect(!unrelated && pool.count == 2)
        let released = pool.release(media: 1, token: first)
        #expect(released)
        try pool.reserve(media: 1, token: third)
        let stale = pool.release(media: 1, token: first)
        #expect(!stale && pool.count == 2)
        let finalFirst = pool.release(media: 1, token: third)
        let finalSecond = pool.release(media: 2, token: second)
        #expect(finalFirst && finalSecond && pool.count == 0)
    }
    @Test(arguments: [0, 17]) func invalidReservationCapacityFailsClosed(_ capacity: Int) {
        var pool = RecoveryClaimReservations(limit: capacity)
        #expect(throws: (any Error).self) { try pool.reserve(media: 1, token: UUID()) }
    }
}
