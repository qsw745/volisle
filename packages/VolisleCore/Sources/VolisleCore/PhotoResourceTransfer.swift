import Foundation
import Darwin

/// Serializes streaming callbacks, including cancellation before the provider
/// returns its request ID. No callback may write after the continuation resumes.
public final class PhotoResourceTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelRequest: @Sendable (Int32) -> Void
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var requestID: Int32?
    private var ended = false
    private var terminalError: (any Error)?
    private typealias Completion = (CheckedContinuation<Void, any Error>?, (any Error)?, Int32?)

    public init(destination: URL, cancelRequest: @escaping @Sendable (Int32) -> Void) throws {
        self.cancelRequest = cancelRequest
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func begin(_ value: CheckedContinuation<Void, any Error>) -> Bool {
        let result = lock.withLock { () -> (Bool, (any Error)?) in
            guard !ended else { return (false, terminalError ?? CancellationError()) }
            continuation = value
            return (true, nil)
        }
        if let error = result.1 { value.resume(throwing: error) }
        return result.0
    }

    public func register(_ id: Int32) {
        let cancel = lock.withLock { () -> Bool in requestID = id; return ended && terminalError != nil }
        if cancel { cancelRequest(id) }
    }

    public func append(_ data: Data) {
        let result: Completion? = lock.withLock {
            guard !ended else { return nil }
            do { try handle?.write(contentsOf: data); return nil }
            catch { return terminateLocked(error) }
        }
        if let result { deliver(result) }
    }

    public func finish(_ error: (any Error)?) {
        let result: Completion? = lock.withLock { ended ? nil : terminateLocked(error) }
        if let result { deliver(result) }
    }
    public func cancel() { finish(CancellationError()) }

    /// Called under lock, so a write failure cannot race a successful finish.
    private func terminateLocked(_ error: (any Error)?) -> Completion {
        ended = true
        var outcome = error
        if outcome == nil { do { try handle?.synchronize() } catch { outcome = error } }
        do { try handle?.close() } catch { if outcome == nil { outcome = error } }
        handle = nil; terminalError = outcome
        let value = continuation; continuation = nil
        return (value, outcome, outcome == nil ? nil : requestID)
    }
    private func deliver(_ result: Completion) {
        if let id = result.2 { cancelRequest(id) }
        if let value = result.0 {
            if let error = result.1 { value.resume(throwing: error) } else { value.resume() }
        }
    }
}
