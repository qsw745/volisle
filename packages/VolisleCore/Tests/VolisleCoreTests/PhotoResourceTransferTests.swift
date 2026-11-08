import Foundation
import Testing
@testable import VolisleCore

struct PhotoResourceTransferTests {
    @Test func cancellationBeforeRequestRegistrationClosesFileAndCancelsLateID() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let cancelled = IDs()
        let request = try PhotoResourceTransfer(destination: path, cancelRequest: { cancelled.add($0) })
        request.cancel()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
                #expect(!request.begin(value))
            }
        }
        request.register(42)
        request.append(Data("late bytes".utf8)); request.finish(nil)
        #expect(try Data(contentsOf: path).isEmpty)
        #expect(cancelled.values == [42])
    }

    @Test func successfulCompletionFlushesBytesAndIgnoresLateCallbacks() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let request = try PhotoResourceTransfer(destination: path, cancelRequest: { _ in })
        try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
            #expect(request.begin(value))
            request.append(Data([0, 255, 1])); request.append(Data([2, 3]))
            request.finish(nil)
        }
        request.append(Data([99])); request.cancel(); request.finish(nil)
        #expect(try Data(contentsOf: path) == Data([0, 255, 1, 2, 3]))
    }

    @Test func failureCannotBeReplacedByLaterSuccess() async throws {
        enum Unavailable: Error { case original }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let cancelled = IDs()
        let request = try PhotoResourceTransfer(destination: path, cancelRequest: { cancelled.add($0) })
        await #expect(throws: Unavailable.self) {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
                #expect(request.begin(value)); request.register(7)
                request.append(Data([1])); request.finish(Unavailable.original)
                request.finish(nil); request.append(Data([2]))
            }
        }
        #expect(cancelled.values == [7])
        #expect(try Data(contentsOf: path) == Data([1]))
    }
}

private final class IDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int32] = []
    func add(_ id: Int32) { lock.withLock { ids.append(id) } }
    var values: [Int32] { lock.withLock { ids } }
}
