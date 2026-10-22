import Foundation

/// One reply, even when a long-running disk operation outlives its wait hint.
/// A soft deadline observes the original request; it never starts another one.
final class HelperReplyWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var reportedSlow = false
    private let onFinish: @Sendable () -> Void
    private let onSlowReply: (@Sendable () -> Void)?

    init(continuation: CheckedContinuation<Data, any Error>, onFinish: @escaping @Sendable () -> Void,
         onSlowReply: (@Sendable () -> Void)? = nil) {
        self.continuation = continuation; self.onFinish = onFinish; self.onSlowReply = onSlowReply
    }

    func deadlineReached() {
        guard let onSlowReply else { finish(.failure(HelperServiceError.timedOut)); return }
        let notify = lock.withLock {
            guard continuation != nil, !reportedSlow else { return false }
            reportedSlow = true
            return true
        }
        if notify { onSlowReply() }
    }

    func finish(_ result: Result<Data, any Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let pending else { return }
        onFinish()
        pending.resume(with: result)
    }
}
