import Foundation
import DiskArbitration
import IOKit

/// Each DA request retains the exact media object and its session until the OS
/// callback. No shell or device-name-only command, force flag, or writable mount.
@MainActor final class NativeReadOnlyDisk {
    private let session: DASession
    private let disk: DADisk
    init(bsdName: String, registryID: UInt64) throws {
        guard ReadOnlyDeviceBinding.validName(bsdName), registryID != 0,
              let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, bsdName) else {
            throw VolumeError.disconnected
        }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { throw VolumeError.disconnected }
        defer { IOObjectRelease(media) }
        var actual: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &actual) == KERN_SUCCESS, actual == registryID else {
            throw VolumeError.identityChanged
        }
        self.session = session; self.disk = disk
        DASessionSetDispatchQueue(session, .main)
    }
    func unmount() async throws {
        try await request { disk, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), nativeReadOnlyCallback, context)
        }
    }
    func mount() async throws {
        try await request { disk, context in
            let options = ["rdonly" as CFString, "nosuid" as CFString, "nodev" as CFString]
            var arguments: [Unmanaged<CFString>?] = options.map { .some(.passUnretained($0)) } + [nil]
            withExtendedLifetime(options) {
                arguments.withUnsafeMutableBufferPointer {
                    DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault),
                                            nativeReadOnlyCallback, context, $0.baseAddress)
                }
            }
        }
    }
    private func request(_ submit: (DADisk, UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            submit(disk, Unmanaged.passRetained(NativeReadOnlyPending(continuation: continuation, owner: self)).toOpaque())
        }
    }
}
private final class NativeReadOnlyPending {
    let continuation: CheckedContinuation<Void, any Error>
    let owner: NativeReadOnlyDisk
    init(continuation: CheckedContinuation<Void, any Error>, owner: NativeReadOnlyDisk) {
        self.continuation = continuation; self.owner = owner
    }
}
private let nativeReadOnlyCallback: DADiskMountCallback = { _, dissenter, context in
    guard let context else { return }
    let pending = Unmanaged<NativeReadOnlyPending>.fromOpaque(context).takeRetainedValue()
    guard let dissenter else { pending.continuation.resume(); return }
    switch DADissenterGetStatus(dissenter) {
    case DAReturn(kDAReturnBusy): pending.continuation.resume(throwing: HelperDiskFailure.busy)
    case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged):
        pending.continuation.resume(throwing: HelperDiskFailure.permissionDenied)
    default: pending.continuation.resume(throwing: HelperDiskFailure.unavailable)
    }
}
