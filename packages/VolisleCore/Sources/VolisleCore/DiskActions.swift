import Foundation
import Observation

public enum DiskAction: Sendable { case unmountVolume, ejectDevice }

@MainActor public protocol DiskActionBackend: AnyObject {
    func resolve(_ identity: VolumeIdentity) throws -> VolumeSnapshot
    func unmount(_ volume: VolumeSnapshot, wholeDevice: Bool) async throws
    func eject(_ volume: VolumeSnapshot) async throws
}

public enum DiskActionPolicy {
    public static func validate(_ expected: VolumeIdentity, current: VolumeSnapshot) throws {
        guard current.identity == expected else { throw VolumeError.identityChanged }
        guard current.isExternal, !current.isProtected else { throw VolumeError.protectedVolume }
        // Removal is bound to a live DA/IORegistry object. MBR NTFS volumes
        // can lack a volume UUID; that must disable persistent preferences,
        // not prevent safe removal of the already identified connection.
        guard !current.identity.devicePath.isEmpty,
              current.identity.supportsCurrentOperation || (current.identity.mediaRegistryID ?? 0) > 0 else {
            throw VolumeError.unstableIdentity
        }
    }
}

/// All application-initiated removals share this state, including the menu bar.
/// An OS request cannot be cancelled safely; keep the lock until its callback.
@MainActor @Observable public final class DiskActions {
    public private(set) var activeDevices: Set<String> = []
    public private(set) var lastError: String?
    public private(set) var notice: String?
    private let backend: any DiskActionBackend
    private let gate: DeviceOperationGate
    public init(backend: any DiskActionBackend, gate: DeviceOperationGate = .shared) {
        self.backend = backend; self.gate = gate
    }
    public func isBusy(_ volume: VolumeSnapshot) -> Bool { gate.isBusy(volume.deviceGroup) }
    public func clearMessage() { lastError = nil; notice = nil }
    /// A removal notice is no longer safe advice after any new connection or
    /// mount. Keep errors and notices for unchanged / disappearing volumes.
    public func reconcile(previous: [VolumeSnapshot], current: [VolumeSnapshot]) {
        guard notice != nil else { return }
        let becameAvailable = current.contains { volume in
            guard let old = previous.first(where: { $0.identity == volume.identity }) else { return true }
            return old.mountURL == nil && volume.mountURL != nil
        }
        if becameAvailable { notice = nil }
    }
    public func perform(_ action: DiskAction, on expected: VolumeIdentity) async {
        do { try await execute(action, on: expected) }
        catch { lastError = error.localizedDescription }
    }
    public func execute(_ action: DiskAction, on expected: VolumeIdentity) async throws {
        let volume = try backend.resolve(expected)
        try DiskActionPolicy.validate(expected, current: volume)
        let lease = try gate.acquire(volume.deviceGroup)
        activeDevices.insert(volume.deviceGroup)
        defer { activeDevices.remove(volume.deviceGroup); gate.release(lease) }
        clearMessage()
        try Task.checkCancellation()
        // Normal OS unmount flushes the filesystem and lets busy users dissent.
        try await backend.unmount(volume, wholeDevice: action == .ejectDevice)
        if action == .ejectDevice {
            let refreshed = try backend.resolve(expected)
            try DiskActionPolicy.validate(expected, current: refreshed)
            guard refreshed.deviceGroup == volume.deviceGroup else { throw VolumeError.identityChanged }
            try await backend.eject(refreshed)
            notice = String(localized: "设备已推出，可以拔下连接线。")
        } else {
            notice = String(localized: "磁盘已卸载，设备上的其他卷未被推出。")
        }
    }
}
