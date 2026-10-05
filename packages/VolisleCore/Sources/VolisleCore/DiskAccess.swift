import Foundation

public protocol DiskAccessBackend: Sendable {
    func prepare(_ volume: VolumeSnapshot) async throws -> HelperDiskRequest
    func requestAuthorization(_ request: HelperDiskRequest) async throws
    func inspect(_ request: HelperDiskRequest) async throws -> HelperDiskReport
}

/// Explicit user action only. An OS prompt completing is never proof of access:
/// require a real helper read and revalidate the original connection afterwards.
public actor DiskAccessCoordinator {
    private let backend: any DiskAccessBackend
    private let gate: DeviceOperationGate
    public init(backend: any DiskAccessBackend = SystemDiskAccessBackend(), gate: DeviceOperationGate = .shared) {
        self.backend = backend; self.gate = gate
    }
    public func check(_ expected: VolumeIdentity, resolver: any VolumeResolver) async throws -> HelperDiskReport {
        let original = try await resolver.resolve(expected)
        try Self.validate(original, expected: expected)
        let lease = try gate.acquire(original.deviceGroup)
        defer { gate.release(lease) }
        let request = try await backend.prepare(original)
        guard request.bsdName == original.bsdName, request.registryID == expected.mediaRegistryID else {
            throw VolumeError.identityChanged
        }
        try Task.checkCancellation()
        try await backend.requestAuthorization(request)
        let refreshed = try await resolver.resolve(expected)
        try Self.validate(refreshed, expected: expected)
        guard refreshed.bsdName == original.bsdName, refreshed.deviceGroup == original.deviceGroup else {
            throw VolumeError.identityChanged
        }
        try Task.checkCancellation()
        let received = try await backend.inspect(request)
        let report = try HelperDiskReport.decode(JSONEncoder().encode(received), matching: request)
        guard report.effectiveUID == 0 else { throw HelperServiceError.wrongPrivileges }
        let final = try await resolver.resolve(expected)
        try Self.validate(final, expected: expected)
        guard final.bsdName == original.bsdName, final.deviceGroup == original.deviceGroup else {
            throw VolumeError.identityChanged
        }
        return report
    }
    private static func validate(_ volume: VolumeSnapshot, expected: VolumeIdentity) throws {
        guard volume.identity == expected else { throw VolumeError.identityChanged }
        guard volume.isExternal, !volume.isProtected else { throw VolumeError.protectedVolume }
        guard volume.isNTFS else { throw VolumeError.unsupportedFileSystem }
        guard (expected.mediaRegistryID ?? 0) > 0 else { throw VolumeError.unstableIdentity }
        guard volume.mountState == .readOnly || volume.mountState == .unmounted else { throw VolumeError.busy }
    }
}

public struct SystemDiskAccessBackend: DiskAccessBackend {
    public init() {}
    public func prepare(_ volume: VolumeSnapshot) async throws -> HelperDiskRequest {
        try HelperPackage.validate()
        _ = try await HelperRPC.systemStatus()
        return try RemovableVolumeAccess.capture(volume)
    }
    public func requestAuthorization(_ request: HelperDiskRequest) async throws {
        // The responsible process is the GUI app; a worker avoids freezing its
        // UI while the system presents its own consent prompt. Await completion.
        try await Task.detached { try RemovableVolumeAccess.requestFromApplication(request) }.value
    }
    public func inspect(_ request: HelperDiskRequest) async throws -> HelperDiskReport {
        try await HelperRPC.inspectSystemDisk(request)
    }
}
