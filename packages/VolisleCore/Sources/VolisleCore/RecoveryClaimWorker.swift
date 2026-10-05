// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import Synchronization

/// A synchronous, single-thread recovery scope. No device or journal is opened here.
/// The caller must keep its native claim alive until run returns (including errors).
/// Cancellation revokes future checkpoints, but deliberately waits for in-flight
/// work to unwind: releasing the claim while a syscall is still writing is unsafe.
/// Checkpoints do not interrupt syscalls or close the gap between a check and I/O.
enum RecoveryClaimWorker {
    @MainActor static func run<T: Sendable>(
        verify: @escaping @MainActor @Sendable () throws -> Void,
        operation: @escaping @Sendable (RecoveryWorkerCheckpoint) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let checkpoint = RecoveryWorkerCheckpoint(validate: verify)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Use a dispatch worker, not a Swift cooperative-executor task
                // blocked on a semaphore needed by the main-actor callback queue.
                DispatchQueue(label: "top.qisw.volisle.recovery", qos: .utility).async {
                    let result: Result<T, any Error> = autoreleasepool {
                        defer { checkpoint.close() }
                        return Result {
                            try checkpoint.start()
                            try checkpoint.verify()
                            let value = try operation(checkpoint)
                            try checkpoint.verify()
                            return value
                        }
                    }
                    // operation's defer scopes and autoreleases have finished.
                    continuation.resume(with: result)
                }
            }
        } onCancel: { checkpoint.cancel() }
    }
}

/// Sendable only to allow the async owner to revoke it. verify() is restricted to
/// the original synchronous worker thread; escaped or cross-thread use fails shut.
final class RecoveryWorkerCheckpoint: Sendable {
    enum Failure: Error { case invalidThread, closed, revoked }
    private struct State {
        var thread: UInt64?
        var cancelled = false
        var closed = false
        var failed = false
    }
    private let state = Mutex(State())
    private let validate: @MainActor @Sendable () throws -> Void
    fileprivate init(validate: @escaping @MainActor @Sendable () throws -> Void) { self.validate = validate }

    fileprivate func start() throws {
        try state.withLock { value in
            try Self.requireActive(value)
            guard !Thread.isMainThread, value.thread == nil, let thread = Self.threadID() else {
                value.failed = true; throw Failure.invalidThread
            }
            value.thread = thread
        }
    }
    func verify() throws {
        do {
            try state.withLock { value in
                try Self.requireActive(value)
                guard !Thread.isMainThread, let thread = Self.threadID(), value.thread == thread else {
                    throw Failure.invalidThread
                }
            }
            let reply = Mutex<Result<Void, any Error>?>(nil)
            let ready = DispatchSemaphore(value: 0)
            Task { @MainActor [self] in
                let result = Result {
                    try checkActive()
                    try validate()
                    try checkActive()
                }
                reply.withLock { $0 = result }
                ready.signal()
            }
            // Never run on main; a stalled OS validation retains the claim. Do not
            // timeout and release underneath an outstanding device operation.
            ready.wait()
            let result = reply.withLock { $0 }
            guard let result else { throw Failure.revoked }
            try result.get()
            try checkActive()
        } catch {
            state.withLock { $0.failed = true }
            throw error
        }
    }
    /// Constructs the existing I/O fence on this worker. Native claim checks wrap
    /// every fresh transport observation, so each read/write/flush checks both
    /// the main-actor claim and the worker-owned descriptor before and after I/O.
    /// observe must derive identity/mount/writability from the held transport.
    /// The caller still owns journal authorization and must close the session.
    func deviceSession(binding: BlockJournalBinding, connectionIdentity: String, leaseID: UUID,
        observe: @escaping () throws -> BlockJournalDeviceObservation,
        read: @escaping (Int64, Int) throws -> Data,
        write: @escaping (Int64, Data) throws -> Void,
        flush: @escaping () throws -> Void,
        stopWrites: @escaping () -> Void, release: @escaping () -> Void) throws -> BlockJournalDeviceSession {
        try BlockJournalDeviceSession(binding: binding, connectionIdentity: connectionIdentity, leaseID: leaseID,
            observe: {
                try self.verify()
                let observation = try observe()
                try self.verify()
                return observation
            }, read: read, write: write, flush: flush, stopWrites: {
                // A swallowed transport/session error must poison the entire job.
                self.state.withLock { $0.failed = true }
                stopWrites()
            }, release: release)
    }
    func revoke() { state.withLock { $0.failed = true } }
    fileprivate func cancel() { state.withLock { $0.cancelled = true } }
    fileprivate func close() { state.withLock { $0.closed = true } }
    private func checkActive() throws { try state.withLock { try Self.requireActive($0) } }
    private static func requireActive(_ state: State) throws {
        if state.cancelled { throw CancellationError() }
        guard !state.closed else { throw Failure.closed }
        guard !state.failed else { throw Failure.revoked }
    }
    private static func threadID() -> UInt64? {
        var value: UInt64 = 0
        return pthread_threadid_np(nil, &value) == 0 && value != 0 ? value : nil
    }
}
