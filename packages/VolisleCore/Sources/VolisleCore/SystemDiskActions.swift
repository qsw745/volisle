import Foundation
import DiskArbitration

public enum DiskSystemError: Error, LocalizedError, Sendable {
    case busy, denied, failed(Int32), unavailable
    public var errorDescription: String? {
        switch self {
        case .busy: String(localized: "磁盘正在被使用。请关闭正在打开或复制的文件后重试。")
        case .denied: String(localized: "系统未允许此操作，请在 Finder 中推出设备。")
        case .failed: String(localized: "系统未能完成操作。请检查磁盘连接，或在 Finder 中重试。")
        case .unavailable: String(localized: "无法确认设备关系，请在 Finder 中操作。")
        }
    }
}

@MainActor public final class SystemDiskActions: DiskActionBackend {
    private let discovery: DiskDiscovery
    private let session: DASession?
    public init(discovery: DiskDiscovery) {
        self.discovery = discovery
        session = DASessionCreate(nil)
        if let session { DASessionSetDispatchQueue(session, .main) }
    }
    public func resolve(_ identity: VolumeIdentity) throws -> VolumeSnapshot {
        guard let current = discovery.revalidate(identity) else { throw VolumeError.disconnected }
        return current
    }
    private func disk(_ volume: VolumeSnapshot, whole: Bool) throws -> DADisk {
        let current = try resolve(volume.identity)
        try DiskActionPolicy.validate(volume.identity, current: current)
        guard let session, let disk = DADiskCreateFromBSDName(nil, session, current.bsdName) else {
            throw VolumeError.disconnected
        }
        // Bind the newly obtained DA object to the media instance revalidated
        // above. A reused BSD name at the same USB port is not the same disk.
        let heldIdentity = MediaIdentityReader.read(disk)
        guard let expectedRegistryID = current.identity.mediaRegistryID,
              heldIdentity.registryID == expectedRegistryID,
              heldIdentity.fingerprint == current.identity.mediaFingerprint else { throw VolumeError.identityChanged }
        let target: DADisk
        if whole {
            guard let wholeDisk = DADiskCopyWholeDisk(disk) else { throw DiskSystemError.unavailable }
            target = wholeDisk
        } else { target = disk }
        guard let description = DADiskCopyDescription(target) as NSDictionary?,
              description[kDADiskDescriptionDeviceInternalKey] as? Bool == false,
              let path = description[kDADiskDescriptionDevicePathKey] as? String,
              path == current.identity.devicePath else { throw DiskSystemError.unavailable }
        if let url = description[kDADiskDescriptionVolumePathKey] as? URL,
           url.path == "/" || url.path.hasPrefix("/System/") { throw VolumeError.protectedVolume }
        if whole {
            guard description[kDADiskDescriptionMediaWholeKey] as? Bool == true else { throw DiskSystemError.unavailable }
            // Do not derive the whole disk by trimming a BSD name. For virtual
            // containers that DA cannot associate reliably, fail closed.
            for peer in discovery.volumes where peer.deviceGroup == current.deviceGroup {
                let live = try resolve(peer.identity)
                try DiskActionPolicy.validate(peer.identity, current: live)
            }
        }
        return target
    }
    public func unmount(_ volume: VolumeSnapshot, wholeDevice: Bool) async throws {
        let target = try disk(volume, whole: wholeDevice)
        try await request(target) { target, context in
            DADiskUnmount(target, wholeDevice ? DADiskUnmountOptions(kDADiskUnmountOptionWhole) : DADiskUnmountOptions(kDADiskUnmountOptionDefault), diskActionCallback, context)
        }
    }
    public func eject(_ volume: VolumeSnapshot) async throws {
        let target = try disk(volume, whole: true)
        try await request(target) { target, context in
            DADiskEject(target, DADiskEjectOptions(kDADiskEjectOptionDefault), diskActionCallback, context)
        }
    }
    private func request(_ target: DADisk, submit: (DADisk, UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingDiskAction(continuation, owner: self, disk: target)
            submit(target, Unmanaged.passRetained(pending).toOpaque())
        }
    }
}

private final class PendingDiskAction {
    let continuation: CheckedContinuation<Void, Error>
    // Keep the DA session and exact disk alive until the OS completes.
    let owner: SystemDiskActions
    let disk: DADisk
    init(_ continuation: CheckedContinuation<Void, Error>, owner: SystemDiskActions, disk: DADisk) {
        self.continuation = continuation; self.owner = owner; self.disk = disk
    }
}
private let diskActionCallback: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    let pending = Unmanaged<PendingDiskAction>.fromOpaque(context).takeRetainedValue()
    guard let dissenter else { pending.continuation.resume(); return }
    let code = DADissenterGetStatus(dissenter)
    let error: DiskSystemError
    switch code {
    case DAReturn(kDAReturnBusy): error = .busy
    case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged): error = .denied
    default: error = .failed(code)
    }
    pending.continuation.resume(throwing: error)
}
