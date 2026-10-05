import Foundation
import Testing
@testable import VolisleCore

// The OS boundary simulates unmount followed by NTFS preflight failure. The
// real coordinator must keep its device lease until recovery is verified.
private actor AtomicDisk: TransactionalFileSystemAdapter, VolumeResolver {
    let identity = VolumeIdentity(volumeUUID: "atomic", mediaUUID: "media", devicePath: UUID().uuidString)
    var state: MountState = .readOnly
    var reject = true
    var recoverable = true
    var separateInspectCalled = false
    func configure(reject: Bool = true, recoverable: Bool = true) { self.reject = reject; self.recoverable = recoverable }
    func capability() -> EngineCapability { .init(available: true, finderReadWrite: true, reason: "fixture") }
    func inspect(_ volume: VolumeSnapshot) throws -> SafetyStatus {
        separateInspectCalled = true; throw VolumeError.safetyUnknown
    }
    func mountReadWrite(_ volume: VolumeSnapshot) throws -> URL { throw VolumeError.engineUnavailable }
    func enableReadWriteTransaction(_ volume: VolumeSnapshot) throws -> URL {
        state = .unmounted
        if reject { throw VolumeError.unsafeVolume("dirty") }
        state = .readWrite
        return URL(filePath: "/fixture-atomic")
    }
    func unmount(_ volume: VolumeSnapshot) { state = .unmounted }
    func recoverFailedMount(_ volume: VolumeSnapshot) -> MountRecoveryDisposition {
        guard recoverable else { return .unresolved }
        state = .readOnly; return .settled
    }
    func resolve(_ expected: VolumeIdentity) -> VolumeSnapshot {
        .init(identity: identity, bsdName: "disk999s1", name: "fixture", fileSystem: "ntfs", deviceName: "fixture",
              totalBytes: 67108864, availableBytes: nil, mountURL: state == .unmounted ? nil : URL(filePath: "/fixture-atomic"),
              mountState: state, isExternal: true, isProtected: false)
    }
}
struct TransactionalMountTests {
    @Test func preflightFailureAfterUnmountRestoresOriginalReadOnlyState() async throws {
        let disk = AtomicDisk(), gate = DeviceOperationGate()
        let coordinator = MountCoordinator(engine: disk, resolver: disk, gate: gate)
        await #expect(throws: VolumeError.unsafeVolume("dirty")) { try await coordinator.enableReadWrite(expected: disk.identity) }
        #expect(await disk.state == .readOnly)
        #expect(await disk.separateInspectCalled == false)
        #expect(!gate.isBusy(disk.identity.devicePath))
    }
    @Test func failedAtomicPreflightCannotReleaseUnresolvedDisk() async throws {
        let disk = AtomicDisk(), gate = DeviceOperationGate()
        await disk.configure(recoverable: false)
        let coordinator = MountCoordinator(engine: disk, resolver: disk, gate: gate)
        await #expect(throws: MountRecoveryError.self) { try await coordinator.enableReadWrite(expected: disk.identity) }
        #expect(gate.requiresVerification(disk.identity.devicePath))
        await disk.configure(recoverable: true)
        #expect(try await coordinator.verifyRecovery(expected: disk.identity) == .readOnly)
        #expect(!gate.isBusy(disk.identity.devicePath))
    }
    @Test func atomicSuccessStillRequiresLiveWritableResult() async throws {
        let disk = AtomicDisk(), gate = DeviceOperationGate()
        await disk.configure(reject: false)
        let coordinator = MountCoordinator(engine: disk, resolver: disk, gate: gate)
        #expect(try await coordinator.enableReadWrite(expected: disk.identity).path == "/fixture-atomic")
        #expect(await disk.state == .readWrite)
        #expect(!gate.isBusy(disk.identity.devicePath))
    }
}
