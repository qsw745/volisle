import Foundation
import CryptoKit
import Testing
import DiskArbitration
import Darwin
import Synchronization
@testable import VolisleCore

@Suite(.serialized)
@MainActor struct NativeRecoveryClaimTests {
    @Test(arguments: ["", "../disk1", "/dev/disk1", "disk1s", "disk-1", "disk1s2evil"])
    func malformedNamesRefusedBeforeSystemAccess(_ name: String) {
        #expect(!NativeRecoveryDiskClaim.validBSDName(name))
    }
    @Test func diskFamiliesUseExactBoundaries() {
        #expect(NativeRecoveryDiskClaim.isFamily("disk12", wholeName: "disk12"))
        #expect(NativeRecoveryDiskClaim.isFamily("disk12s3", wholeName: "disk12"))
        #expect(!NativeRecoveryDiskClaim.isFamily("disk123s1", wholeName: "disk12"))
        #expect(!NativeRecoveryDiskClaim.isFamily("disk12s", wholeName: "disk12"))
        #expect(!NativeRecoveryDiskClaim.isFamily("/dev/disk12s1", wholeName: "disk12"))
    }
    @Test func physicalPolicyRequiresExplicitExternalUSBPartition() {
        #expect(NativeRecoveryDiskClaim.allowsPhysical(internalDevice: false, deviceProtocol: "USB", whole: false))
        for internalDevice: Bool? in [nil, true] {
            #expect(!NativeRecoveryDiskClaim.allowsPhysical(internalDevice: internalDevice, deviceProtocol: "USB", whole: false))
        }
        for proto: String? in [nil, "Virtual Interface", "PCI-Express"] {
            #expect(!NativeRecoveryDiskClaim.allowsPhysical(internalDevice: false, deviceProtocol: proto, whole: false))
        }
        for whole: Bool? in [nil, true] {
            #expect(!NativeRecoveryDiskClaim.allowsPhysical(internalDevice: false, deviceProtocol: "USB", whole: whole))
        }
    }
    @Test func malformedPhysicalTargetCannotAcquireClaim() async {
        await #expect(throws: (any Error).self) {
            try await NativeRecoveryDiskClaim.withPhysicalClaim(bsdName: "../disk0", registryID: 1, byteCount: 512, bootSession: UUID().uuidString) { _ in
                Issue.record("Invalid target reached operation")
            }
        }
    }
    @Test func priorBootCannotReachDeviceLookup() async {
        do {
            try await NativeRecoveryDiskClaim.withPhysicalClaim(bsdName: "disk0s1", registryID: 1,
                byteCount: 512, bootSession: UUID().uuidString) { _ in
                Issue.record("Prior boot entered claim operation")
            }
            Issue.record("Prior boot was accepted")
        } catch NativeRecoveryDiskClaim.Failure.changed { }
        catch { Issue.record("Expected boot mismatch before device lookup: \(error)") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"] != nil))
    func actualReadOnlyImageClaimLifecycle() async throws {
        let manifest = try #require(ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"])
        let url = URL(fileURLWithPath: manifest)
        #expect(url.lastPathComponent == "fixture.json")
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let name = try #require(values["bsdName"])
        var callbacks = 0
        try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { claim in
            try claim.verify(); callbacks += 1
            await #expect(throws: (any Error).self) {
                try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { _ in
                    Issue.record("Competing claimant entered protected operation")
                }
            }
            #expect(try await Self.requestMount(name, competingClaim: true) != 0)
            #expect(claim.deniedReleaseRequests > 0)
            // A real DA mount request must be refused by the registered callback.
            let status = try await Self.requestMount(name)
            #expect(status != 0)
            #expect(claim.deniedMountRequests > 0)
            let ejectStatus = try await Self.requestMount(name, eject: true)
            #expect(ejectStatus != 0 && claim.deniedEjectRequests > 0)
            try claim.verify()
        }
        #expect(callbacks == 1)
        // Closing the first scope must allow another independent session to claim.
        try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { claim in
            try claim.verify(); callbacks += 1
        }
        #expect(callbacks == 2)
        enum ExpectedFailure: Error { case operation }
        await #expect(throws: ExpectedFailure.self) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { claim in
                try claim.verify(); throw ExpectedFailure.operation
            }
        }
        let cancelled = Task { @MainActor in
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let escaped = try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { $0 }
        #expect(throws: (any Error).self) { try escaped.verify() }
        // All claim and approval registrations must be gone after scope exit.
        #expect(try await Self.requestMount(name) == 0)
        let mounts = try SystemMountRecord.current().filter { $0.source == "/dev/" + name }
        #expect(mounts.count == 1 && mounts[0].flags & UInt32(MNT_RDONLY) != 0)
        let metadata = try DeviceMetadata.read(name)
        await #expect(throws: (any Error).self) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { _ in
                Issue.record("Mounted image reached recovery operation")
            }
        }
        try await NativeReadOnlyDisk(bsdName: name, registryID: metadata.registryID).unmount()
        #expect(try !SystemMountRecord.current().contains { $0.source == "/dev/" + name })
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"] != nil))
    func actualWaitingCancellationAndLateCleanup() async throws {
        let manifest = try #require(ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"])
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: String])
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let name = try #require(values["bsdName"])
        let initialReservations = NativeRecoveryDiskClaim.fixtureReservationCount
        let initialReplies = NativeRecoveryDiskClaim.fixturePendingNativeReplies
        var operations = 0
        let clock = ContinuousClock(), began = clock.now
        await #expect(throws: RecoveryClaimWait.Failure.timedOut) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name,
                waitTimeout: .milliseconds(80), callbackDelay: .seconds(5)) { _ in operations += 1 }
        }
        #expect(began.duration(to: clock.now) < .seconds(1))
        #expect(operations == 0 && NativeRecoveryDiskClaim.fixtureReservationCount == initialReservations + 1)
        await #expect(throws: RecoveryClaimReservations.Failure.busy) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { _ in operations += 1 }
        }
        // Another DA client may legitimately take ownership after timeout.
        // The abandoned session's late cleanup must not unclaim that client.
        try await Self.withIndependentClaim(name) { holder in
            #expect(NativeRecoveryDiskClaim.fixturePendingNativeReplies == initialReplies + 1)
            try await Self.waitForCleanup(reservations: initialReservations, replies: initialReplies)
            #expect(try await Self.requestMount(name, competingClaim: true) != 0)
            #expect(holder.deniedTransfers > 0)
        }
        #expect(operations == 0)
        let task = Task { @MainActor in
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name,
                waitTimeout: .seconds(10), callbackDelay: .seconds(2)) { _ in operations += 1 }
        }
        let pendingDeadline = clock.now.advanced(by: .seconds(10))
        while NativeRecoveryDiskClaim.fixturePendingNativeReplies == initialReplies && clock.now < pendingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeRecoveryDiskClaim.fixturePendingNativeReplies == initialReplies + 1)
        let cancelledAt = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
        #expect(operations == 0 && NativeRecoveryDiskClaim.fixtureReservationCount == initialReservations + 1)
        await #expect(throws: RecoveryClaimReservations.Failure.busy) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { _ in operations += 1 }
        }
        try await Self.waitForCleanup(reservations: initialReservations, replies: initialReplies)
        let escaped = try await NativeRecoveryDiskClaim.withReadOnlyFixtureClaim(image: image, bsdName: name) { claim in
            try claim.verify(); operations += 1; return claim
        }
        #expect(operations == 1)
        #expect(throws: (any Error).self) { try escaped.verify() }
        #expect(NativeRecoveryDiskClaim.fixtureReservationCount == initialReservations)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"] != nil))
    func actualWorkerRetainsClaimUntilUnwind() async throws {
        let manifest = try #require(ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"])
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: String])
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let name = try #require(values["bsdName"])
        let entered = Mutex(false), proceed = DispatchSemaphore(value: 0)
        let unwound = Mutex(false), nextIO = Mutex(false)
        let before = NativeRecoveryDiskClaim.fixtureReservationCount
        let job = Task { @MainActor in
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureWorker(image: image, bsdName: name) { checkpoint in
                defer { unwound.withLock { $0 = true } }
                #expect(!Thread.isMainThread)
                try checkpoint.verify()
                entered.withLock { $0 = true }
                guard proceed.wait(timeout: .now() + 20) == .success else { throw NativeRecoveryDiskClaim.Failure.unavailable }
                try checkpoint.verify()
                nextIO.withLock { $0 = true }
            }
        }
        defer { proceed.signal(); job.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { throw NativeRecoveryDiskClaim.Failure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The worker is blocked, but DA approval callbacks must still execute.
        #expect(try await Self.requestMount(name) != 0)
        #expect(try await Self.requestMount(name, eject: true) != 0)
        job.cancel()
        #expect(try await Self.requestMount(name, competingClaim: true) != 0)
        #expect(!unwound.withLock { $0 })
        #expect(NativeRecoveryDiskClaim.fixtureReservationCount == before + 1)
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(unwound.withLock { $0 } && !nextIO.withLock { $0 })
        #expect(NativeRecoveryDiskClaim.fixtureReservationCount == before)
        let value = try await NativeRecoveryDiskClaim.withReadOnlyFixtureWorker(image: image, bsdName: name) { checkpoint in
            try checkpoint.verify(); return 17
        }
        #expect(value == 17)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"] != nil))
    func actualHeldReadOnlyDeviceLifecycle() async throws {
        let manifest = try #require(ProcessInfo.processInfo.environment["VOLISLE_NATIVE_CLAIM_FIXTURE"])
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: String])
        let image = URL(fileURLWithPath: try #require(values["image"]))
        let name = try #require(values["bsdName"])
        let original = try Data(contentsOf: image)
        let bootHash = SHA256.hash(data: original.prefix(512)).map { String(format: "%02x", $0) }.joined()
        let head = Data(original.prefix(1_048_576)), tail = Data(original.suffix(512))
        let baselineDescriptors = try Self.rawDescriptors(name)

        let bytes = try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
            bootSHA256: bootHash) { device in
            #expect(!Thread.isMainThread)
            #expect(try Self.rawDescriptors(name).count == baselineDescriptors.count + 1)
            #expect(device.byteCount == 64 * 1024 * 1024 && device.blockSize == 512)
            #expect(try device.read(offset: 0, count: 1_048_576) == head)
            #expect(try device.read(offset: device.byteCount - 512, count: 512) == tail)
            #expect(try device.read(offset: device.byteCount, count: 0).isEmpty)
            try device.verify()
            return 1_049_088
        }
        #expect(bytes == 1_049_088)
        #expect(try Self.rawDescriptors(name) == baselineDescriptors)
        await #expect(throws: (any Error).self) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
                bootSHA256: String(repeating: "0", count: 64)) { _ in
                Issue.record("Wrong boot digest admitted a held device")
            }
        }
        await #expect(throws: (any Error).self) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
                bootSHA256: bootHash) { device in
                #expect(throws: (any Error).self) { try device.read(offset: 1, count: 512) }
                #expect(throws: (any Error).self) { try device.read(offset: 0, count: 512) }
                // Catching an invalid transport request cannot restore this job.
            }
        }
        #expect(try Self.rawDescriptors(name) == baselineDescriptors)
        enum Expected: Error { case stopped }
        await #expect(throws: Expected.stopped) {
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
                bootSHA256: bootHash) { device in
                _ = try device.read(offset: 0, count: 512)
                throw Expected.stopped
            }
        }
        #expect(try Self.rawDescriptors(name) == baselineDescriptors)
        let entered = Mutex(false), proceed = DispatchSemaphore(value: 0), unwound = Mutex(false)
        let job = Task { @MainActor in
            try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
                bootSHA256: bootHash) { device in
                defer { unwound.withLock { $0 = true } }
                entered.withLock { $0 = true }
                guard proceed.wait(timeout: .now() + 20) == .success else { throw Expected.stopped }
                _ = try device.read(offset: 0, count: 512)
            }
        }
        defer { proceed.signal(); job.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { throw Expected.stopped }
            try await Task.sleep(for: .milliseconds(10))
        }
        job.cancel()
        #expect(try await Self.requestMount(name, competingClaim: true) != 0)
        #expect(!unwound.withLock { $0 })
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(unwound.withLock { $0 })
        #expect(try Self.rawDescriptors(name) == baselineDescriptors)
        let last = try await NativeRecoveryDiskClaim.withReadOnlyFixtureDevice(image: image, bsdName: name,
            bootSHA256: bootHash) { device in try device.read(offset: 0, count: 512) }
        #expect(last == original.prefix(512))
        #expect(try Self.rawDescriptors(name) == baselineDescriptors)
    }
    /// Inspect this test process only; no descriptor accessors are added to product code.
    nonisolated private static func rawDescriptors(_ name: String) throws -> Set<Int32> {
        var named = stat()
        guard lstat("/dev/r" + name, &named) == 0, named.st_mode & S_IFMT == S_IFCHR else {
            throw NativeRecoveryDiskClaim.Failure.changed
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        return Set(entries.compactMap { text -> Int32? in
            guard let fd = Int32(text) else { return nil }
            var info = stat()
            return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFCHR && info.st_rdev == named.st_rdev ? fd : nil
        })
    }
    private static func waitForCleanup(reservations: Int, replies: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while (NativeRecoveryDiskClaim.fixtureReservationCount != reservations ||
               NativeRecoveryDiskClaim.fixturePendingNativeReplies != replies) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(NativeRecoveryDiskClaim.fixtureReservationCount == reservations)
        #expect(NativeRecoveryDiskClaim.fixturePendingNativeReplies == replies)
    }
    private static func withIndependentClaim(_ name: String, operation: (NativeClaimTestHolder) async throws -> Void) async throws {
        let session = try #require(DASessionCreate(nil))
        let disk = try #require(DADiskCreateFromBSDName(nil, session, name))
        let holder = NativeClaimTestHolder()
        DASessionSetDispatchQueue(session, .main)
        defer { DADiskUnclaim(disk); DASessionSetDispatchQueue(session, nil) }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DADiskClaim(disk, DADiskClaimOptions(kDADiskClaimOptionDefault), { _, context in
                let owner = Unmanaged<NativeClaimTestHolder>.fromOpaque(context!).takeUnretainedValue()
                MainActor.assumeIsolated { owner.deniedTransfers += 1 }
                return .passRetained(DADissenterCreate(nil, DAReturn(kDAReturnBusy), nil))
            }, Unmanaged.passUnretained(holder).toOpaque(), { _, dissent, context in
                let box = Unmanaged<NativeClaimTestCallback>.fromOpaque(context!).takeRetainedValue()
                box.continuation.resume(returning: dissent.map { DADissenterGetStatus($0) } ?? 0)
            }, Unmanaged.passRetained(NativeClaimTestCallback(continuation)).toOpaque())
        }
        try #require(status == 0)
        try await operation(holder)
        withExtendedLifetime(holder) {}
    }
    private static func requestMount(_ name: String, eject: Bool = false, competingClaim: Bool = false) async throws -> Int32 {
        let session = try #require(DASessionCreate(nil))
        let disk = try #require(DADiskCreateFromBSDName(nil, session, name))
        DASessionSetDispatchQueue(session, .main)
        defer { DASessionSetDispatchQueue(session, nil) }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let box = NativeClaimTestCallback(continuation)
            let callback: DADiskMountCallback = { _, dissent, context in
                let box = Unmanaged<NativeClaimTestCallback>.fromOpaque(context!).takeRetainedValue()
                box.continuation.resume(returning: dissent.map { DADissenterGetStatus($0) } ?? 0)
            }
            let context = Unmanaged.passRetained(box).toOpaque()
            if competingClaim { DADiskClaim(disk, DADiskClaimOptions(kDADiskClaimOptionDefault), nil, nil, callback, context) }
            else if eject { DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, context) }
            else { DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, context) }
        }
        if competingClaim && result == 0 { DADiskUnclaim(disk) }
        return result
    }
}
private final class NativeClaimTestCallback {
    let continuation: CheckedContinuation<Int32, Never>
    init(_ continuation: CheckedContinuation<Int32, Never>) { self.continuation = continuation }
}

@MainActor private final class NativeClaimTestHolder { var deniedTransfers = 0 }
