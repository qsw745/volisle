// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// One native request, one caller result, and one eventual cleanup callback.
/// Timing out abandons admission, not the native request or its callback context.
@MainActor final class RecoveryClaimWait {
    enum Failure: Error, Equatable { case invalidTimeout, alreadyStarted, timedOut }
    private let onAbandon: () -> Void
    private let onReply: (Int32, Bool) -> Void
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var timer: Task<Void, Never>?
    private var started = false
    private var submitted = false
    private var replied = false

    init(onAbandon: @escaping () -> Void, onReply: @escaping (Int32, Bool) -> Void) {
        self.onAbandon = onAbandon; self.onReply = onReply
    }
    deinit { timer?.cancel() }
    func start(timeout: Duration, submit: () -> Void) async throws -> Int32 {
        guard !started else { throw Failure.alreadyStarted }; started = true
        guard timeout > .zero, timeout <= .seconds(60) else { throw Failure.invalidTimeout }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { cancel(); return }
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.abandon(Failure.timedOut)
                }
                submitted = true
                submit()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }
    func cancel() { abandon(CancellationError()) }
    private func abandon(_ error: any Error) {
        guard !replied, let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        onAbandon()
        continuation.resume(throwing: error)
    }
    func complete(_ status: Int32) {
        guard submitted, !replied else { return }; replied = true
        let caller = continuation; continuation = nil
        timer?.cancel(); timer = nil
        onReply(status, caller != nil)
        caller?.resume(returning: status)
    }
}

/// Local process reservation, retained while a late native reply is unresolved.
/// Not a substitute for DA ownership or persistent journal/device identity.
struct RecoveryClaimReservations {
    enum Failure: Error { case invalid, busy, capacity }
    private var owners: [UInt64: UUID] = [:]
    private let limit: Int
    init(limit: Int = 16) { self.limit = limit }
    var count: Int { owners.count }
    func contains(media: UInt64) -> Bool { owners[media] != nil }
    mutating func reserve(media: UInt64, token: UUID) throws {
        guard media != 0, (1...16).contains(limit) else { throw Failure.invalid }
        guard owners[media] == nil else { throw Failure.busy }
        guard owners.count < limit else { throw Failure.capacity }
        owners[media] = token
    }
    @discardableResult mutating func release(media: UInt64, token: UUID) -> Bool {
        guard owners[media] == token else { return false }
        owners.removeValue(forKey: media); return true
    }
}
