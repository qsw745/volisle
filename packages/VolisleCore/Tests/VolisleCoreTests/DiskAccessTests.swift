import Foundation
import Testing
@testable import VolisleCore

struct DiskAccessTests {
    private func volume() -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "test-device", mediaRegistryID: 123),
              bsdName: "disk999s1", name: "测试", fileSystem: "ntfs", deviceName: "测试",
              totalBytes: 4096, availableBytes: nil, mountURL: nil, mountState: .unmounted,
              isExternal: true, isProtected: false)
    }
    @Test func permissionPromptCompletionIsNotDiskAccessSuccess() async {
        let original = volume(), backend = AccessBackend(denied: true), gate = DeviceOperationGate()
        let check = DiskAccessCoordinator(backend: backend, gate: gate)
        await #expect(throws: HelperDiskFailure.permissionDenied) {
            _ = try await check.check(original.identity, resolver: AccessResolver([original, original, original]))
        }
        #expect(await backend.inspections == 1)
        #expect(!gate.isBusy("test-device"))
    }
    @Test func disconnectWhilePromptIsOpenPreventsHelperRead() async {
        let original = volume(), replacement = volume(), backend = AccessBackend()
        let check = DiskAccessCoordinator(backend: backend, gate: DeviceOperationGate())
        await #expect(throws: VolumeError.identityChanged) {
            _ = try await check.check(original.identity, resolver: AccessResolver([original, replacement]))
        }
        #expect(await backend.inspections == 0)
    }
    @Test func confirmedReadAccessDoesNotGrantWriteOrHealthApproval() async throws {
        let original = volume(), backend = AccessBackend()
        let check = DiskAccessCoordinator(backend: backend, gate: DeviceOperationGate())
        let result = try await check.check(original.identity, resolver: AccessResolver([original, original, original]))
        #expect(result.effectiveUID == 0)
        #expect(!result.writeAccessAvailable && !result.fileSystemHealthChecked)
        #expect(await backend.inspections == 1)
    }
    @Test func deviceAlreadyOperatingCannotTriggerAnotherPermissionPrompt() async throws {
        let original = volume(), backend = AccessBackend(), gate = DeviceOperationGate()
        let lease = try gate.acquire("test-device")
        defer { gate.release(lease) }
        let check = DiskAccessCoordinator(backend: backend, gate: gate)
        await #expect(throws: VolumeError.busy) {
            _ = try await check.check(original.identity, resolver: AccessResolver([original]))
        }
        #expect(await backend.prompts == 0)
    }
}

private actor AccessResolver: VolumeResolver {
    var values: [VolumeSnapshot]
    init(_ values: [VolumeSnapshot]) { self.values = values }
    func resolve(_ identity: VolumeIdentity) throws -> VolumeSnapshot {
        guard !values.isEmpty else { throw VolumeError.disconnected }
        return values.removeFirst()
    }
}
private actor AccessBackend: DiskAccessBackend {
    var inspections = 0
    var prompts = 0
    let denied: Bool
    init(denied: Bool = false) { self.denied = denied }
    func prepare(_ volume: VolumeSnapshot) throws -> HelperDiskRequest {
        try .init(bsdName: volume.bsdName, registryID: 123, byteCount: 4096)
    }
    func requestAuthorization(_ request: HelperDiskRequest) { prompts += 1 }
    func inspect(_ request: HelperDiskRequest) throws -> HelperDiskReport {
        inspections += 1
        if denied { throw HelperDiskFailure.permissionDenied }
        return .init(version: 1, bsdName: "disk999s1", registryID: 123, byteCount: 4096,
                     bootSHA256: String(repeating: "a", count: 64), effectiveUID: 0,
                     writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
}
