import Darwin
import Foundation
import Synchronization
import Testing
@testable import VolisleCore

@MainActor struct RecoveryClaimWorkerTests {
    @Test func synchronousWorkKeepsMainActorResponsiveAndChecksThere() async throws {
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        var validations = 0
        let job = Task { @MainActor in
            try await RecoveryClaimWorker.run(verify: {
                #expect(Thread.isMainThread); validations += 1
            }) { checkpoint in
                #expect(!Thread.isMainThread)
                entered.signal()
                guard proceed.wait(timeout: .now() + 5) == .success else { throw WorkerTestError.deadline }
                try checkpoint.verify()
                return 42
            }
        }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        #expect(validations >= 1)
        proceed.signal()
        #expect(try await job.value == 42)
        #expect(validations >= 3)
    }

    @Test func cancellationWaitsForWorkerUnwindAndStopsNextCheckpoint() async throws {
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let unwound = Mutex(false), nextIO = Mutex(false)
        var returned = false
        let job = Task { @MainActor in
            defer { returned = true }
            return try await RecoveryClaimWorker.run(verify: {}) { checkpoint in
                defer { unwound.withLock { $0 = true } }
                entered.signal()
                guard proceed.wait(timeout: .now() + 5) == .success else { throw WorkerTestError.deadline }
                try checkpoint.verify()
                nextIO.withLock { $0 = true }
            }
        }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        job.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!returned && !unwound.withLock { $0 })
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(unwound.withLock { $0 } && !nextIO.withLock { $0 })
    }

    @Test func swallowedValidationFailureCannotBecomeSuccessfulRecovery() async throws {
        var checks = 0
        await #expect(throws: (any Error).self) {
            try await RecoveryClaimWorker.run(verify: {
                checks += 1
                if checks == 2 { throw WorkerTestError.changed }
            }) { checkpoint in
                do { try checkpoint.verify() } catch { }
                return 10
            }
        }
        #expect(checks == 2)
    }

    @Test func alreadyCancelledTaskDoesNotEnterOperation() async {
        let entries = Mutex(0)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await RecoveryClaimWorker.run(verify: {}) { _ in entries.withLock { $0 += 1 } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(entries.withLock { $0 } == 0)
    }

    @Test func escapedCheckpointRefusesMainAndWorkerThreadsAfterScope() async throws {
        let escaped = try await RecoveryClaimWorker.run(verify: {}) { $0 }
        #expect(throws: (any Error).self) { try escaped.verify() }
        await #expect(throws: (any Error).self) {
            try await Task.detached { try escaped.verify() }.value
        }
    }

    @Test func crossThreadCheckpointInvalidatesWholeScope() async {
        await #expect(throws: (any Error).self) {
            try await RecoveryClaimWorker.run(verify: {}) { checkpoint in
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    defer { done.signal() }
                    #expect(throws: (any Error).self) { try checkpoint.verify() }
                }
                guard done.wait(timeout: .now() + 5) == .success else { throw WorkerTestError.deadline }
                // Even catching the offending call must not revive this scope.
            }
        }
    }

    @Test func operationErrorUnwindsBeforeReturningOriginalError() async {
        let unwound = Mutex(false)
        await #expect(throws: WorkerTestError.changed) {
            try await RecoveryClaimWorker.run(verify: {}) { _ -> Int in
                defer { unwound.withLock { $0 = true } }
                throw WorkerTestError.changed
            }
        }
        #expect(unwound.withLock { $0 })
    }

    @Test func realFileWriteCancellationStopsFlushAndClosesBeforeReturn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fixture.bin").path
        try Data(repeating: 0, count: 8192).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let stops = Mutex(0), flushes = Mutex(0), released = Mutex(false), writeRejected = Mutex(false)
        let job = Task { @MainActor in
            try await RecoveryClaimWorker.run(verify: {}) { checkpoint in
                let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw WorkerTestError.changed }
                defer { Darwin.close(fd); released.withLock { $0 = true } }
                var original = stat()
                guard fstat(fd, &original) == 0 else { throw WorkerTestError.changed }
                let id = "\(original.st_dev):\(original.st_ino)", lease = UUID()
                let binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: id,
                    bootSHA256: String(repeating: "a", count: 64), deviceSize: 8192, blockSize: 512)
                let session = try checkpoint.deviceSession(binding: binding, connectionIdentity: id, leaseID: lease,
                    observe: {
                        var held = stat(), named = stat()
                        guard fstat(fd, &held) == 0, lstat(path, &named) == 0,
                              held.st_dev == original.st_dev, held.st_ino == original.st_ino,
                              named.st_dev == held.st_dev, named.st_ino == held.st_ino,
                              held.st_size == 8192, held.st_mode & S_IFMT == S_IFREG else { throw WorkerTestError.changed }
                        return .init(volumeIdentity: id, bootSHA256: binding.bootSHA256, deviceSize: 8192,
                            blockSize: 512, connectionIdentity: id, leaseID: lease, ownsLease: true,
                            mounted: false, writable: true)
                    }, read: { offset, count in
                        var data = Data(count: count)
                        guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, count, off_t(offset)) }) == count else { throw WorkerTestError.changed }
                        return data
                    }, write: { offset, bytes in
                        guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, bytes.count, off_t(offset)) }) == bytes.count else { throw WorkerTestError.changed }
                        entered.signal()
                        guard proceed.wait(timeout: .now() + 5) == .success else { throw WorkerTestError.deadline }
                    }, flush: {
                        flushes.withLock { $0 += 1 }
                        guard fsync(fd) == 0 else { throw WorkerTestError.changed }
                    }, stopWrites: { stops.withLock { $0 += 1 } }, release: {})
                defer { session.close() }
                #expect(try session.read(offset: 512, count: 512) == Data(repeating: 0, count: 512))
                do { try session.write(offset: 512, bytes: Data(repeating: 9, count: 512)) }
                catch { writeRejected.withLock { $0 = true } }
                #expect(session.failed)
                #expect(throws: (any Error).self) { try session.flush() }
                // The worker itself must also reject an apparent successful return.
            }
        }
        defer { proceed.signal(); job.cancel() }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        job.cancel()
        #expect(!released.withLock { $0 })
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(released.withLock { $0 } && writeRejected.withLock { $0 })
        #expect(stops.withLock { $0 } == 1 && flushes.withLock { $0 } == 0)
        let actual = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(actual.subdata(in: 512..<1024) == Data(repeating: 9, count: 512))
        #expect(actual.prefix(512) == Data(repeating: 0, count: 512))
        #expect(actual.suffix(7168) == Data(repeating: 0, count: 7168))
    }

    @Test func swallowedDeviceSessionFailureRevokesWorkerSuccess() async {
        let stops = Mutex(0), releases = Mutex(0), writes = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await RecoveryClaimWorker.run(verify: {}) { checkpoint in
                let lease = UUID()
                let binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: "fixture",
                    bootSHA256: String(repeating: "a", count: 64), deviceSize: 8192, blockSize: 512)
                let session = try checkpoint.deviceSession(binding: binding, connectionIdentity: "connection", leaseID: lease,
                    observe: {
                        .init(volumeIdentity: "fixture", bootSHA256: binding.bootSHA256, deviceSize: 8192,
                            blockSize: 512, connectionIdentity: "connection", leaseID: lease,
                            ownsLease: true, mounted: false, writable: true)
                    }, read: { _, _ in throw WorkerTestError.changed },
                    write: { _, _ in writes.withLock { $0 += 1 } }, flush: {},
                    stopWrites: { stops.withLock { $0 += 1 } }, release: { releases.withLock { $0 += 1 } })
                defer { session.close() }
                // Invalid alignment fails in the real device session before transport.
                do { try session.write(offset: 1, bytes: Data(repeating: 3, count: 512)) } catch { }
                return 7
            }
        }
        #expect(stops.withLock { $0 } == 1 && releases.withLock { $0 } == 1 && writes.withLock { $0 } == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WorkerTestError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
private enum WorkerTestError: Error { case deadline, changed }
