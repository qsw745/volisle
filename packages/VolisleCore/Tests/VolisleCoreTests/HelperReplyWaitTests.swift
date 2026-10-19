import Foundation
import Testing
@testable import VolisleCore

struct HelperReplyWaitTests {
    @Test func slowDeadlineKeepsTheOriginalReply() async throws {
        let events = WaitEvents()
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let wait = HelperReplyWait(continuation: continuation, onFinish: { events.add("finished") },
                                      onSlowReply: { events.add("slow") })
            wait.deadlineReached()
            wait.finish(.success(Data([7])))
            wait.finish(.failure(HelperServiceError.unavailable))
        }
        #expect(result == Data([7]))
        #expect(events.values == ["slow", "finished"])
    }

    @Test func aReplyBeforeTheDeadlineNeverReportsSlow() async throws {
        let events = WaitEvents()
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let wait = HelperReplyWait(continuation: continuation, onFinish: { events.add("finished") },
                                      onSlowReply: { events.add("slow") })
            wait.finish(.success(Data([9])))
            wait.deadlineReached()
        }
        #expect(result == Data([9]))
        #expect(events.values == ["finished"])
    }

    @Test func ordinaryRequestsStillFailAtTheirDeadline() async {
        await #expect(throws: HelperServiceError.timedOut) {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let wait = HelperReplyWait(continuation: continuation, onFinish: {})
                wait.deadlineReached()
                wait.finish(.success(Data([7])))
            }
        }
    }
}

private final class WaitEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
