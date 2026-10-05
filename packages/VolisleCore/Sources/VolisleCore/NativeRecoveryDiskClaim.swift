// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin
import DiskArbitration
import IOKit

/// Scoped Disk Arbitration exclusion, serialized on its callback queue.
/// This does not open a raw device, authenticate a journal, or stop privileged
/// software that bypasses Disk Arbitration. A claim alone is not write authority.
/// The operation must keep the main callback queue responsive (no long raw I/O).
/// Abandoned native requests retain their context and reservation until reply.
/// Deadlines need a responsive main queue; they do not interrupt blocking OS IPC.
@MainActor final class NativeRecoveryDiskClaim {
    enum Failure: Error { case invalid, protectedMedia, changed, busy, unavailable, closed
        case claimDenied(DAReturn), mountedDescription, mountedRecord }
    private struct Identity: Equatable {
        let name: String
        let registryID: UInt64
        let size: UInt64
        let blockSize: Int
        let internalDevice: Bool?
        let deviceProtocol: String?
        let whole: Bool?
        let writable: Bool?
        let mediaFingerprint: String?
    }
    private enum Scope {
        case physical(UUID)
        #if DEBUG
        case fixture(URL, dev_t, ino_t, writable: Bool)
        #endif
    }
    private let session: DASession
    private let disk: DADisk
    private let wholeDisk: DADisk
    private let identity: Identity
    private let wholeIdentity: Identity
    private let scope: Scope
    private static var reservations = RecoveryClaimReservations()
    private var reserved = false
    private var pending: NativeRecoveryClaimPending?
    private let waitTimeout: Duration
    #if DEBUG
    fileprivate let callbackDelay: Duration
    static var fixtureReservationCount: Int { reservations.count }
    fileprivate(set) static var fixturePendingNativeReplies = 0
    #endif
    private var claimed: [DADisk] = []
    private var registered = false
    private var closed = false
    private var failed = false
    private var requiresRecoveryIdentity = false
    private(set) var deniedMountRequests = 0
    private(set) var deniedEjectRequests = 0
    private(set) var deniedReleaseRequests = 0
    let leaseID = UUID()

    static func validBSDName(_ value: String) -> Bool {
        value.utf8.count <= 32 && value.range(of: "\\Adisk[0-9]+(?:s[0-9]+)?\\z", options: .regularExpression) != nil
    }
    static func isFamily(_ name: String, wholeName: String) -> Bool {
        guard validBSDName(name), wholeName.range(of: "\\Adisk[0-9]+\\z", options: .regularExpression) != nil else { return false }
        return name == wholeName || name.hasPrefix(wholeName + "s")
    }
    static func allowsPhysical(internalDevice: Bool?, deviceProtocol: String?, whole: Bool?) -> Bool {
        internalDevice == false && deviceProtocol == "USB" && whole == false
    }
    static func withPhysicalClaim<T>(bsdName: String, registryID: UInt64, byteCount: UInt64, bootSession: String,
                                    operation: (NativeRecoveryDiskClaim) async throws -> T) async throws -> T {
        guard validBSDName(bsdName), registryID != 0, byteCount >= 512, byteCount <= Int64.max,
              byteCount % 512 == 0, let boot = UUID(uuidString: bootSession) else { throw Failure.invalid }
        guard try UUID(uuidString: SystemHelperMountService.currentBootSession()) == boot else { throw Failure.changed }
        let claim = try Self(bsdName: bsdName, scope: .physical(boot))
        guard claim.identity.registryID == registryID, claim.identity.size == byteCount else { throw Failure.changed }
        return try await claim.run(operation)
    }
    /// Read-only transport admission. No write authority is inferred from a claim.
    static func withPhysicalReadOnlyDevice<T: Sendable>(bsdName: String, registryID: UInt64,
        byteCount: UInt64, bootSession: String, bootSHA256: String,
        operation: @escaping @Sendable (RecoveryReadOnlyDevice) throws -> T) async throws -> T {
        guard RecoveryReadOnlyDevice.validBootHash(bootSHA256) else { throw Failure.invalid }
        return try await withPhysicalClaim(bsdName: bsdName, registryID: registryID,
            byteCount: byteCount, bootSession: bootSession) { claim in
            try await claim.readOnlyDevice(bootSHA256: bootSHA256, operation: operation)
        }
    }
    private func readOnlyDevice<T: Sendable>(bootSHA256: String,
        operation: @escaping @Sendable (RecoveryReadOnlyDevice) throws -> T) async throws -> T {
        let target = try transportTarget()
        return try await RecoveryClaimWorker.run(verify: { try self.verify() }) { checkpoint in
            try RecoveryReadOnlyDevice.withDevice(target: target, bootSHA256: bootSHA256,
                checkpoint: checkpoint, operation: operation)
        }
    }
    private func transportTarget() throws -> NativeRecoveryClaimTarget {
        let boot = try SystemHelperMountService.currentBootSession()
        guard let id = UUID(uuidString: boot) else { throw Failure.changed }
        var persistentMedia = identity.mediaFingerprint
        #if DEBUG
        if case let .fixture(url, _, _, _) = scope {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Failure.changed }
            persistentMedia = RecoveryVolumeIdentity.fixtureMedia(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        }
        #endif
        return .init(bsdName: identity.name, byteCount: identity.size, blockSize: identity.blockSize, persistentMedia: persistentMedia,
            connectionIdentity: "native-connection/v1|" + id.uuidString.lowercased() + "|" + String(identity.registryID))
    }
    static func withPhysicalRecoveryConnection<T: Sendable>(bsdName: String, registryID: UInt64,
        byteCount: UInt64, bootSession: String, bootSHA256: String,
        operation: @escaping @Sendable (NativeRecoveryConnection) throws -> T) async throws -> T {
        guard RecoveryReadOnlyDevice.validBootHash(bootSHA256) else { throw Failure.invalid }
        return try await withPhysicalClaim(bsdName: bsdName, registryID: registryID, byteCount: byteCount, bootSession: bootSession) { claim in
            try await claim.recoveryConnection(bootSHA256: bootSHA256, operation: operation)
        }
    }
    private func recoveryConnection<T: Sendable>(bootSHA256: String,
        operation: @escaping @Sendable (NativeRecoveryConnection) throws -> T) async throws -> T {
        requiresRecoveryIdentity = true
        try verify()
        let target = try transportTarget(), lease = leaseID
        return try await RecoveryClaimWorker.run(verify: { try self.verify() }) { checkpoint in
            try operation(NativeRecoveryConnection(target: target, checkpoint: checkpoint, bootSHA256: bootSHA256, leaseID: lease))
        }
    }
    #if DEBUG
    /// Only a newly created 64 MiB virtual image in this dedicated test directory.
    static func withWritableFixtureConnection<T: Sendable>(image: URL, bsdName: String, bootSHA256: String,
        operation: @escaping @Sendable (NativeRecoveryConnection) throws -> T) async throws -> T {
        guard RecoveryReadOnlyDevice.validBootHash(bootSHA256), image.isFileURL,
              image.path == image.standardizedFileURL.path, image.resolvingSymlinksInPath().path == image.path,
              image.deletingLastPathComponent().lastPathComponent.hasPrefix("native-write-"),
              image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".workbench" else { throw Failure.invalid }
        var info = stat()
        guard lstat(image.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 64*1024*1024 else { throw Failure.invalid }
        let claim = try Self(bsdName: bsdName, scope: .fixture(image, info.st_dev, info.st_ino, writable: true))
        return try await claim.run { owner in try await owner.recoveryConnection(bootSHA256: bootSHA256, operation: operation) }
    }
    #endif
    /// Holds the native claim until synchronous recovery has fully unwound.
    /// The checkpoint must fence each transport observation, not just the job.
    /// This entry does not itself authorize writes or authenticate a journal.
    static func withPhysicalWorker<T: Sendable>(bsdName: String, registryID: UInt64,
        byteCount: UInt64, bootSession: String,
        operation: @escaping @Sendable (RecoveryWorkerCheckpoint) throws -> T) async throws -> T {
        try await withPhysicalClaim(bsdName: bsdName, registryID: registryID,
            byteCount: byteCount, bootSession: bootSession) { claim in
            try await RecoveryClaimWorker.run(verify: { try claim.verify() }, operation: operation)
        }
    }
    #if DEBUG
    static func withReadOnlyFixtureDevice<T: Sendable>(image: URL, bsdName: String, bootSHA256: String,
        operation: @escaping @Sendable (RecoveryReadOnlyDevice) throws -> T) async throws -> T {
        guard RecoveryReadOnlyDevice.validBootHash(bootSHA256) else { throw Failure.invalid }
        return try await withReadOnlyFixtureClaim(image: image, bsdName: bsdName) { claim in
            try await claim.readOnlyDevice(bootSHA256: bootSHA256, operation: operation)
        }
    }
    #endif
    #if DEBUG
    static func withReadOnlyFixtureWorker<T: Sendable>(image: URL, bsdName: String,
        operation: @escaping @Sendable (RecoveryWorkerCheckpoint) throws -> T) async throws -> T {
        try await withReadOnlyFixtureClaim(image: image, bsdName: bsdName) { claim in
            try await RecoveryClaimWorker.run(verify: { try claim.verify() }, operation: operation)
        }
    }
    #endif
    #if DEBUG
    /// Test-only: exact, read-only, unpartitioned 64 MiB image under .workbench.
    /// Omitted from release builds and never exposed through the helper's XPC API.
    static func withReadOnlyFixtureClaim<T>(image: URL, bsdName: String,
                                           waitTimeout: Duration = .seconds(15), callbackDelay: Duration = .zero,
                                           operation: (NativeRecoveryDiskClaim) async throws -> T) async throws -> T {
        guard waitTimeout > .zero, waitTimeout <= .seconds(60), callbackDelay >= .zero, callbackDelay <= .seconds(5),
              image.isFileURL, image.path == image.standardizedFileURL.path,
              image.resolvingSymlinksInPath().path == image.path,
              image.deletingLastPathComponent().lastPathComponent.hasPrefix("native-claim-"),
              image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".workbench" else { throw Failure.invalid }
        var info = stat()
        guard lstat(image.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 64*1024*1024 else { throw Failure.invalid }
        let claim = try Self(bsdName: bsdName, scope: .fixture(image, info.st_dev, info.st_ino, writable: false),
                             waitTimeout: waitTimeout, callbackDelay: callbackDelay)
        return try await claim.run(operation)
    }
    #endif

    private init(bsdName: String, scope: Scope, waitTimeout: Duration = .seconds(15), callbackDelay: Duration = .zero) throws {
        self.waitTimeout = waitTimeout
        #if DEBUG
        self.callbackDelay = callbackDelay
        #endif
        guard Self.validBSDName(bsdName), let session = DASessionCreate(nil),
              let disk = DADiskCreateFromBSDName(nil, session, bsdName),
              let whole = DADiskCopyWholeDisk(disk) else { throw Failure.invalid }
        self.session = session; self.disk = disk; wholeDisk = whole; self.scope = scope
        identity = try Self.snapshot(disk); wholeIdentity = try Self.snapshot(whole)
        guard wholeIdentity.whole == true, Self.isFamily(identity.name, wholeName: wholeIdentity.name) else { throw Failure.changed }
        try validateMedia()
    }
    private func run<T>(_ operation: (NativeRecoveryDiskClaim) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try Self.reservations.reserve(media: wholeIdentity.registryID, token: leaseID)
        reserved = true
        defer { close() }
        register()
        do {
            try validateMedia()
            // Claim whole media first; another mounted partition prevents recovery.
            try await acquire(wholeDisk)
            if identity.registryID != wholeIdentity.registryID { try await acquire(disk) }
            try verify()
            try Task.checkCancellation()
            let result = try await operation(self)
            try Task.checkCancellation()
            try verify()
            return result
        } catch { failed = true; throw error }
    }
    func verify() throws {
        do {
            guard !closed, !failed, registered,
                  claimed.count == (identity.registryID == wholeIdentity.registryID ? 1 : 2),
                  claimed.allSatisfy({ DADiskIsClaimed($0) }) else { throw Failure.closed }
            try validateMedia()
        } catch { failed = true; throw error }
    }
    private func validateMedia() throws {
        guard !closed, !failed,
              let current = DADiskCreateFromBSDName(nil, session, identity.name),
              let currentWhole = DADiskCopyWholeDisk(current),
              try Self.snapshot(current) == identity, try Self.snapshot(currentWhole) == wholeIdentity else { throw Failure.changed }
        for id in [identity.registryID, wholeIdentity.registryID] {
            guard let match = IORegistryEntryIDMatching(id) else { throw Failure.unavailable }
            let live = IOServiceGetMatchingService(kIOMainPortDefault, match)
            guard live != 0 else { throw Failure.changed }; IOObjectRelease(live)
        }
        switch scope {
        case let .physical(boot):
            guard try UUID(uuidString: SystemHelperMountService.currentBootSession()) == boot else { throw Failure.changed }
            guard Self.allowsPhysical(internalDevice: identity.internalDevice, deviceProtocol: identity.deviceProtocol, whole: identity.whole),
                  identity.writable == true, wholeIdentity.internalDevice == false,
                  wholeIdentity.deviceProtocol == "USB" else { throw Failure.protectedMedia }
            if requiresRecoveryIdentity { try verifyUniqueRecoveryMedia() }
        #if DEBUG
        case let .fixture(url, dev, ino, writable):
            var info = stat()
            guard url.resolvingSymlinksInPath().path == url.path, lstat(url.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_dev == dev, info.st_ino == ino,
                  info.st_size == 64*1024*1024, info.st_nlink == 1, info.st_uid == getuid(),
                  identity.deviceProtocol == "Virtual Interface", identity.writable == writable,
                  identity.size == 64*1024*1024, identity.registryID == wholeIdentity.registryID,
                  try DiskImageMapping.matches(url, device: "/dev/" + identity.name) else { throw Failure.protectedMedia }
        #endif
        }
        for target in [current, currentWhole] {
            guard let description = DADiskCopyDescription(target) as NSDictionary?,
                  description[kDADiskDescriptionVolumePathKey] == nil else { throw Failure.mountedDescription }
        }
        for mount in try SystemMountRecord.current() where mount.source.hasPrefix("/dev/") {
            var name = String(mount.source.dropFirst(5))
            if name.hasPrefix("rdisk") { name.removeFirst() }
            guard !Self.isFamily(name, wholeName: wholeIdentity.name) else { throw Failure.mountedRecord }
        }
    }
    private static func snapshot(_ disk: DADisk) throws -> Identity {
        guard let name = DADiskGetBSDName(disk), let description = DADiskCopyDescription(disk) as NSDictionary? else { throw Failure.changed }
        let bsd = String(cString: name), media = DADiskCopyIOMedia(disk)
        guard validBSDName(bsd), media != 0 else { throw Failure.changed }
        defer { IOObjectRelease(media) }
        var registry: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &registry) == KERN_SUCCESS, registry > 0,
              let size = description[kDADiskDescriptionMediaSizeKey] as? NSNumber, size.int64Value >= 512,
              let block = description[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber,
              block.intValue >= 512, block.intValue <= 65536, block.intValue.nonzeroBitCount == 1,
              size.uint64Value % UInt64(block.intValue) == 0 else { throw Failure.changed }
        let evidence = MediaIdentityReader.read(disk)
        guard evidence.registryID == registry else { throw Failure.changed }
        return .init(name: bsd, registryID: registry, size: size.uint64Value, blockSize: block.intValue,
            internalDevice: description[kDADiskDescriptionDeviceInternalKey] as? Bool,
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey] as? String,
            whole: description[kDADiskDescriptionMediaWholeKey] as? Bool,
            writable: description[kDADiskDescriptionMediaWritableKey] as? Bool, mediaFingerprint: evidence.fingerprint)
    }
    /// Recheck all currently attached media; duplicate serial/partition evidence
    /// is not resolved by picking the first disk or trusting an old BSD name.
    private func verifyUniqueRecoveryMedia() throws {
        guard let fingerprint = identity.mediaFingerprint,
              let match = IOServiceMatching("IOMedia") else { throw RecoveryVolumeIdentity.Failure.unavailable }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { throw Failure.unavailable }
        defer { IOObjectRelease(iterator) }
        var matching: [UInt64] = [], count = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            count += 1
            guard count <= 4096, let disk = DADiskCreateFromIOMedia(nil, session, entry) else { throw Failure.unavailable }
            let evidence = MediaIdentityReader.read(disk)
            guard let registry = evidence.registryID else { throw Failure.changed }
            if evidence.fingerprint == fingerprint { matching.append(registry) }
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw Failure.changed }
        try RecoveryVolumeIdentity.requireUnique(registryID: identity.registryID, matching: matching)
    }
    private func register() {
        DASessionSetDispatchQueue(session, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, nativeRecoveryMountApproval, context)
        DARegisterDiskEjectApprovalCallback(session, nil, nativeRecoveryEjectApproval, context)
        DARegisterDiskDisappearedCallback(session, nil, nativeRecoveryDisappeared, context)
        registered = true
    }
    private func acquire(_ target: DADisk) async throws {
        guard !closed, !failed, pending == nil else { throw Failure.closed }
        let request = NativeRecoveryClaimPending(owner: self, target: target)
        pending = request
        do {
            let status = try await request.wait.start(timeout: waitTimeout) {
                request.submitted = true
                #if DEBUG
                Self.fixturePendingNativeReplies += 1
                #endif
                // Retained until the real callback, even if the caller times out.
                DADiskClaim(target, DADiskClaimOptions(kDADiskClaimOptionDefault), nativeRecoveryRelease,
                    Unmanaged.passUnretained(self).toOpaque(), nativeRecoveryClaimed, Unmanaged.passRetained(request).toOpaque())
            }
            guard status == 0 else { throw Failure.claimDenied(status) }
            guard !closed, !failed else { throw Failure.changed }
            try validateMedia()
        } catch {
            if !request.submitted, pending === request { pending = nil }
            throw error
        }
    }
    fileprivate func claimAbandoned() { failed = true }
    fileprivate func claimReplied(_ request: NativeRecoveryClaimPending, status: Int32, active: Bool) {
        guard pending === request else { return }
        pending = nil
        #if DEBUG
        Self.fixturePendingNativeReplies -= 1
        #endif
        if status == 0 {
            if active && !closed && !failed { claimed.append(request.target) }
            else { DADiskUnclaim(request.target) }
        }
        if closed { finishClose() }
    }
    private func close() {
        guard !closed else { return }; closed = true
        for disk in claimed.reversed() { DADiskUnclaim(disk) }; claimed.removeAll()
        // Release any grant already made by DA before its callback reaches us.
        // A later grant is released again by claimReplied, never used for I/O.
        if let pending { DADiskUnclaim(pending.target) }
        else { finishClose() }
    }
    private func finishClose() {
        guard closed, pending == nil else { return }
        if registered {
            let context = Unmanaged.passUnretained(self).toOpaque()
            DAUnregisterCallback(session, unsafeBitCast(nativeRecoveryMountApproval, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(nativeRecoveryEjectApproval, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(nativeRecoveryDisappeared, to: UnsafeMutableRawPointer.self), context)
            DASessionSetDispatchQueue(session, nil); registered = false
        }
        if reserved {
            Self.reservations.release(media: wholeIdentity.registryID, token: leaseID)
            reserved = false
        }
    }
    fileprivate func concerns(name: String?, whole: String?) -> Bool {
        guard !closed else { return false }
        return name.map { Self.isFamily($0, wholeName: wholeIdentity.name) } == true || whole == wholeIdentity.name
    }
    fileprivate func mountApproval(name: String?, whole: String?) -> Bool {
        guard concerns(name: name, whole: whole) else { return false }; deniedMountRequests += 1; return true
    }
    fileprivate func ejectApproval(name: String?, whole: String?) -> Bool {
        guard concerns(name: name, whole: whole) else { return false }; deniedEjectRequests += 1; return true
    }
    fileprivate func releaseApproval() -> Bool {
        guard !closed else { return false }; deniedReleaseRequests += 1; return true
    }
    fileprivate func disappeared(name: String?, whole: String?) {
        if concerns(name: name, whole: whole) { failed = true }
    }
}
@MainActor private final class NativeRecoveryClaimPending {
    let owner: NativeRecoveryDiskClaim
    let target: DADisk
    var submitted = false
    lazy var wait = RecoveryClaimWait(onAbandon: { [unowned self] in owner.claimAbandoned() },
        onReply: { [unowned self] status, active in owner.claimReplied(self, status: status, active: active) })
    init(owner: NativeRecoveryDiskClaim, target: DADisk) { self.owner = owner; self.target = target }
    func receive(_ status: Int32) {
        #if DEBUG
        if owner.callbackDelay > .zero {
            Task { @MainActor [self] in
                try? await Task.sleep(for: owner.callbackDelay)
                wait.complete(status)
            }
            return
        }
        #endif
        wait.complete(status)
    }
}
// Copy primitive callback values before entering actor isolation. No CF objects
// cross executors, no @unchecked Sendable conformance, no detached task hop.
private func nativeRecoveryNames(_ disk: DADisk) -> (String?, String?) {
    let name = DADiskGetBSDName(disk).map { String(cString: $0) }
    let whole = DADiskCopyWholeDisk(disk).flatMap { DADiskGetBSDName($0).map { String(cString: $0) } }
    return (name, whole)
}
private func nativeRecoveryDissent(_ denied: Bool) -> Unmanaged<DADissenter>? {
    guard denied else { return nil }
    return .passRetained(DADissenterCreate(nil, DAReturn(kDAReturnBusy), "Volisle recovery owns this device" as CFString))
}
private let nativeRecoveryClaimed: DADiskClaimCallback = { _, dissent, context in
    guard let context else { return }
    let pending = Unmanaged<NativeRecoveryClaimPending>.fromOpaque(context).takeRetainedValue()
    let status = dissent.map { DADissenterGetStatus($0) } ?? 0
    MainActor.assumeIsolated { pending.receive(status) }
}
private let nativeRecoveryMountApproval: DADiskMountApprovalCallback = { disk, context in
    guard let context else { return nil }
    let owner = Unmanaged<NativeRecoveryDiskClaim>.fromOpaque(context).takeUnretainedValue()
    let (name, whole) = nativeRecoveryNames(disk)
    return nativeRecoveryDissent(MainActor.assumeIsolated { owner.mountApproval(name: name, whole: whole) })
}
private let nativeRecoveryEjectApproval: DADiskEjectApprovalCallback = { disk, context in
    guard let context else { return nil }
    let owner = Unmanaged<NativeRecoveryDiskClaim>.fromOpaque(context).takeUnretainedValue()
    let (name, whole) = nativeRecoveryNames(disk)
    return nativeRecoveryDissent(MainActor.assumeIsolated { owner.ejectApproval(name: name, whole: whole) })
}
private let nativeRecoveryRelease: DADiskClaimReleaseCallback = { _, context in
    guard let context else { return nil }
    let owner = Unmanaged<NativeRecoveryDiskClaim>.fromOpaque(context).takeUnretainedValue()
    return nativeRecoveryDissent(MainActor.assumeIsolated { owner.releaseApproval() })
}
private let nativeRecoveryDisappeared: DADiskDisappearedCallback = { disk, context in
    guard let context else { return }
    let owner = Unmanaged<NativeRecoveryDiskClaim>.fromOpaque(context).takeUnretainedValue()
    let (name, whole) = nativeRecoveryNames(disk)
    MainActor.assumeIsolated { owner.disappeared(name: name, whole: whole) }
}

/// Only a live claim in this file can create a transport target. This is a
/// connection-scoped admission value, not a persistent volume identity.
struct NativeRecoveryClaimTarget: Sendable {
    let bsdName: String
    let byteCount: UInt64
    let blockSize: Int
    let connectionIdentity: String
    let persistentMedia: String?
    fileprivate init(bsdName: String, byteCount: UInt64, blockSize: Int, persistentMedia: String?, connectionIdentity: String) {
        self.bsdName = bsdName; self.byteCount = byteCount; self.blockSize = blockSize; self.connectionIdentity = connectionIdentity
        self.persistentMedia = persistentMedia
    }
}
