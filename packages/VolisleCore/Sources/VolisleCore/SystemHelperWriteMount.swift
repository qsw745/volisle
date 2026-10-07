import Foundation
import CryptoKit
import Darwin
import MachO
import OSLog
import IOKit

/// Signed, build-time scope for a disposable image. Never supplied through IPC.
struct WriteFixturePolicy: Codable, Equatable, Sendable {
    let schema: Int
    let imagePath: String
    let ownerUID: UInt32
    let byteCount: UInt64
    let bootSHA256: String
    let imageSHA256: String
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperDiskFailure.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.ownerUID != 0, value.ownerUID != .max,
              value.byteCount == 67_108_864, value.imagePath.hasPrefix("/"),
              !value.imagePath.hasPrefix("/dev/"), !value.imagePath.contains("\0"),
              value.imagePath.utf8.count <= 2048,
              URL(filePath: value.imagePath).standardizedFileURL.path == value.imagePath,
              [value.bootSHA256, value.imageSHA256].allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw HelperDiskFailure.invalidRequest
        }
        return value
    }
    func allows(owner: UInt32, bytes: UInt64) -> Bool { owner == ownerUID && bytes == byteCount }
    static func installedBundle() throws -> Bundle {
        guard geteuid() == 0 else { throw HelperDiskFailure.unavailable }
        // SMAppService supplies a relative BundleProgram as argv[0]. Ask dyld
        // for the running image instead of treating argv[0] as its location.
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        guard length > 0, length <= 16384 else { throw HelperDiskFailure.unavailable }
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard _NSGetExecutablePath(&buffer, &length) == 0 else { throw HelperDiskFailure.unavailable }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path.hasPrefix("/") else { throw HelperDiskFailure.unavailable }
        let executable = URL(filePath: path).standardizedFileURL
        var app = executable
        for _ in 0..<4 { app.deleteLastPathComponent() }
        guard app.appendingPathComponent(HelperIdentity.executablePath).path == executable.path,
              let bundle = Bundle(url: app) else { throw HelperDiskFailure.unavailable }
        try HelperPackage.validate(bundle)
        Logger(subsystem: "top.qisw.volisle.helper", category: "write").notice("后台写入包身份已核验")
        return bundle
    }
    static func installed() throws -> Self {
        let file = try installedBundle().bundleURL.appendingPathComponent("Contents/Resources/WriteFixturePolicy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw HelperDiskFailure.unavailable }
        return try decode(Data(contentsOf: file))
    }
}

/// The ordinary build supports only existing read-only transactions. A separate
/// signed policy opts in either an exact disposable image or a time-limited
/// USB partition and test directory. Ordinary packages contain neither.
struct SystemHelperWriteMountBackend: HelperWritableMountBackend {
    func originalDisconnected(_ operation: HelperMountOperation, currentBoot: String) async throws -> Bool {
        let records = try SystemMountRecord.current()
        let path = point(operation)
        guard !records.contains(where: { $0.path == path || ($0.type == "volisle" && $0.source == "/dev/" + operation.disk.bsdName) }) else { return false }
        if currentBoot != operation.bootSession { return true }
        // Enumerate every IOMedia and look for the recorded registry ID. A
        // registry-ID matching iterator with no result reports itself invalid
        // on macOS 27, which made every real unplug look "unavailable". A full
        // enumeration stays valid unless the registry changed meanwhile.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            throw HelperDiskFailure.unavailable
        }
        defer { IOObjectRelease(iterator) }
        var present = false, count = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            count += 1
            var id: UInt64 = 0
            guard count <= 4096, IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { throw HelperDiskFailure.unavailable }
            if id == operation.disk.registryID { present = true }
        }
        // A registry change during enumeration is not proof that the media vanished.
        guard IOIteratorIsValid(iterator) != 0 else { throw HelperDiskFailure.unavailable }
        return !present
    }
    static func verifyWritableState(_ record: HelperMountOperation) throws -> URL {
        try record.validate()
        guard record.isWrite, record.phase == .writeMounted,
              record.bootSession == (try SystemHelperMountService.currentBootSession()) else { throw HelperDiskFailure.busy }
        let disk = record.disk, metadata = try DeviceMetadata.read(record.disk.bsdName)
        guard metadata.registryID == disk.registryID, metadata.byteCount == disk.byteCount else { throw VolumeError.identityChanged }
        let path = "/private/var/run/volisle-write-mounts/" + record.id.uuidString.lowercased()
        let records = try SystemMountRecord.current().filter { $0.source == "/dev/" + disk.bsdName || $0.path == path }
        return try verifiedWritableMount(records, device: "/dev/" + disk.bsdName, path: path)
    }
    static func verifiedWritableMount(_ records: [SystemMountRecord], device: String, path: String,
                                      kernelReflectsFlags: Bool = mountRunsAsRoot) throws -> URL {
        guard records.count == 1, records[0].source == device,
              writeMountOutcome(records, path: path, kernelReflectsFlags: kernelReflectsFlags) == nil else {
            throw VolumeError.mountNotVerified
        }
        return URL(filePath: path)
    }
    private let readOnly = SystemHelperMountCycleBackend()
    private let root = "/private/var/run/volisle-write-mounts"
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func point(_ operation: HelperMountOperation) -> String { root + "/" + operation.id.uuidString.lowercased() }
    private struct Scope { let bootSHA256: String?; let option: String }
    private func validate(_ disk: HelperDiskRequest, owner: UInt32? = nil, initial: Bool = false, restoring: Bool = false) throws -> Scope {
        if disk.version == 1 {
            _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
            let bundle = try WriteFixturePolicy.installedBundle()
            let daily = try DailyWritePolicy.exists(in: bundle)
            if daily {
                guard let owner, owner != 0, owner != .max else { throw HelperDiskFailure.invalidRequest }
                let metadata = try DeviceMetadata.read(disk.bsdName)
                guard metadata.registryID == disk.registryID, metadata.byteCount == disk.byteCount,
                      !metadata.virtual, metadata.writable == true,
                      HelperDiskPolicy.allows(internalDevice: metadata.internalDevice, deviceProtocol: metadata.deviceProtocol, whole: metadata.whole) else {
                    throw VolumeError.protectedVolume
                }
                return Scope(bootSHA256: nil, option: "volisle-rw")
            }
            let policy = try PhysicalWritePolicy.installed()
            guard policy.allows(disk, owner: owner ?? policy.ownerUID, boot: try SystemHelperMountService.currentBootSession(),
                                now: Date().timeIntervalSince1970, restoring: restoring) else { throw VolumeError.identityChanged }
            let metadata = try DeviceMetadata.read(disk.bsdName)
            guard metadata.registryID == disk.registryID, metadata.byteCount == disk.byteCount,
                  !metadata.virtual, metadata.writable == true,
                  HelperDiskPolicy.allows(internalDevice: metadata.internalDevice, deviceProtocol: metadata.deviceProtocol, whole: metadata.whole) else {
                throw VolumeError.protectedVolume
            }
            return Scope(bootSHA256: policy.bootSHA256, option: policy.option)
        }
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        guard disk.version == 2 else { throw HelperDiskFailure.invalidRequest }
        let policy = try WriteFixturePolicy.installed()
        guard policy.allows(owner: owner ?? policy.ownerUID, bytes: disk.byteCount) else { throw HelperDiskFailure.invalidRequest }
        let metadata = try DeviceMetadata.read(disk.bsdName)
        guard metadata.registryID == disk.registryID, metadata.byteCount == disk.byteCount,
              metadata.virtual, metadata.writable == true,
              try DiskImageMapping.matches(URL(filePath: policy.imagePath), device: "/dev/" + disk.bsdName) else {
            throw VolumeError.identityChanged
        }
        let url = URL(filePath: policy.imagePath)
        guard url.resolvingSymlinksInPath().path == policy.imagePath else { throw VolumeError.identityChanged }
        let fd = open(policy.imagePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == policy.byteCount else { throw VolumeError.identityChanged }
        var bytes = [UInt8](repeating: 0, count: 512)
        guard bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == 512,
              hash(Data(bytes)) == policy.bootSHA256 else { throw VolumeError.identityChanged }
        if initial {
            var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            for offset in stride(from: 0, to: Int(policy.byteCount), by: buffer.count) {
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
                guard n == buffer.count else { throw POSIXError(.EIO) }
                digest.update(data: Data(buffer))
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == policy.imageSHA256 else { throw VolumeError.identityChanged }
        }
        return Scope(bootSHA256: policy.bootSHA256, option: "volisle-rw")
    }
    private func mounts(_ disk: HelperDiskRequest) throws -> [SystemMountRecord] {
        let records = try SystemMountRecord.current().filter { $0.source == "/dev/" + disk.bsdName }
        guard records.count <= 1 else { throw HelperDiskFailure.busy }
        return records
    }
    func prepare(_ disk: HelperDiskRequest) async throws -> Bool { try await readOnly.prepare(disk) }
    func prepareWrite(_ disk: HelperDiskRequest, id: UUID, uid: UInt32) async throws -> Bool {
        _ = try validate(disk, owner: uid, initial: true)
        let records = try mounts(disk)
        guard records.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 }) else { throw HelperDiskFailure.busy }
        let fd = open("/dev/" + disk.bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { close(fd) }
        else if errno != EBUSY || records.isEmpty { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return !records.isEmpty
    }
    func unmount(_ disk: HelperDiskRequest) async throws {
        if try DeviceMetadata.read(disk.bsdName).virtual {
            _ = try validate(disk)
            let records = try mounts(disk)
            guard records.count == 1, records[0].type == "ntfs", records[0].flags & UInt32(MNT_RDONLY) != 0 else { throw HelperDiskFailure.busy }
            try await NativeReadOnlyDisk(bsdName: disk.bsdName, registryID: disk.registryID).unmount()
            guard try mounts(disk).isEmpty else { throw HelperDiskFailure.busy }
        } else { try await readOnly.unmount(disk) }
    }
    func inspect(_ disk: HelperDiskRequest) async throws -> HelperDiskReport {
        guard try DeviceMetadata.read(disk.bsdName).virtual else { return try await readOnly.inspect(disk) }
        let policy = try validate(disk)
        guard let bootHash = policy.bootSHA256 else { throw HelperDiskFailure.invalidRequest }
        guard try mounts(disk).isEmpty else { throw HelperDiskFailure.busy }
        let fd = open("/dev/" + disk.bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat(), bytes = [UInt8](repeating: 0, count: 512)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFBLK,
              bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == 512,
              hash(Data(bytes)) == policy.bootSHA256 else { throw VolumeError.identityChanged }
        _ = try validate(disk)
        return .init(version: disk.version, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: disk.byteCount,
                     bootSHA256: bootHash, effectiveUID: geteuid(), writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
    private func rootDirectory() throws {
        if mkdir(root, 0o711) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        var info = stat()
        guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
              info.st_mode & 0o777 == 0o711 else { throw HelperDiskFailure.unavailable }
    }
    func activateWrite(_ operation: HelperMountOperation) async throws {
        let disk = operation.disk
        let scope = try validate(disk, owner: operation.ownerUID)
        guard let inspected = operation.report?.bootSHA256,
              scope.bootSHA256 == nil || inspected == scope.bootSHA256 else { throw VolumeError.identityChanged }
        // Re-read the raw boot sector immediately before mounting. The record
        // is persisted by the daemon, not provided as a trusted hash by UI.
        let fresh = try await inspect(disk)
        guard fresh.bootSHA256 == inspected else { throw VolumeError.identityChanged }
        guard operation.isWrite, operation.phase == .mountingWrite, try mounts(disk).isEmpty else { throw HelperDiskFailure.busy }
        try rootDirectory()
        let path = point(operation)
        guard mkdir(path, 0o700) == 0, chown(path, operation.ownerUID, gid_t.max) == 0 else { throw HelperDiskFailure.unavailable }
        _ = try validate(disk, owner: operation.ownerUID)
        // Real USB devices require root to obtain the FSKit block resource.
        // Keep the authenticated user's login context and owned mountpoint;
        // only disposable images drop device-opening privileges, except on
        // macOS 15 where every mount runs as the owner (see mountRunsAsRoot).
        let asOwner = Self.mountsAsOwner(operation)
        let loan = asOwner && disk.version == 1 ? try DeviceLoan.lend(disk.bsdName, to: operation.ownerUID) : nil
        do {
            let mount = {
                try await run(Self.mountArguments(for: operation, option: scope.option, asOwner: asOwner),
                              environment: Self.mountEnvironment(for: operation, asOwner: asOwner))
            }
            if let loan { try await loan.duringMount(mount) }
            else { try await mount() }
        } catch let failure as HelperDiskFailure { throw failure }
        catch { throw HelperDiskFailure.mountFailed }
        // A just-inserted disk can still be finishing macOS's own read-only
        // automount, which then lands beside this mount (two mounts, one device).
        if !operation.restoreRequired { try await settleNativeAutomount(disk, keeping: path) }
        _ = try validate(disk, owner: operation.ownerUID)
        if let failure = Self.writeMountOutcome(try mounts(disk), path: path) { throw failure }
    }
    static let automountSettleChecks = 24  // × 250 ms; the observed late automount took about 3 s
    private func settleNativeAutomount(_ disk: HelperDiskRequest, keeping path: String) async throws {
        for _ in 0..<Self.automountSettleChecks {
            // Spotlight or Finder briefly hold a fresh native mount: keep waiting.
            if Self.settleDone(after: try removeStrayNativeMounts(disk, keeping: path)) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    /// Only a removed copy ends the wait early. A busy one (Spotlight or Finder
    /// still on it) is retried; returning there failed the write mount while
    /// the native copy was seconds from letting go (seen on a quick replug).
    static func settleDone(after removal: StrayRemoval) -> Bool { removal == .removed }
    /// Native read-only copies of this device other than `path`. Never a
    /// writable mount, another device or Volisle's own mount.
    static func strayNativeMounts(_ records: [SystemMountRecord], device: String, keeping path: String?) -> [SystemMountRecord] {
        records.filter { $0.source == device && $0.path != path && $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 }
    }
    enum StrayRemoval { case none, removed, busy }
    /// Unmount by exact path, not via Disk Arbitration: with two mounts of one
    /// device, a DA unmount may pick Volisle's write mount instead.
    private func removeStrayNativeMounts(_ disk: HelperDiskRequest, keeping path: String?) throws -> StrayRemoval {
        let strays = Self.strayNativeMounts(try SystemMountRecord.current(), device: "/dev/" + disk.bsdName, keeping: path)
        guard !strays.isEmpty else { return .none }
        for stray in strays where Darwin.unmount(stray.path, 0) != 0 {
            let error = errno
            switch error {
            case ENOENT, EINVAL: continue  // already gone (unplugged or unmounted meanwhile)
            case EBUSY: return .busy
            default: throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
        return .removed
    }
    /// What the mount table says about a write mount just made at `path`.
    static func writeMountOutcome(_ records: [SystemMountRecord], path: String, kernelReflectsFlags: Bool = mountRunsAsRoot) -> HelperDiskFailure? {
        guard records.count == 1, records[0].path == path, records[0].type == "volisle" else { return .mountFailed }
        // The extension decides: it mounts read-only when it will not write.
        if records[0].flags & UInt32(MNT_RDONLY) != 0 { return .writeNotEnabled }
        // macOS 15 mounts an FSKit volume without the requested nosuid/nodev
        // (and without rdonly even when the module refuses writes).
        guard !kernelReflectsFlags || records[0].flags & UInt32(MNT_NOSUID | MNT_NODEV) == UInt32(MNT_NOSUID | MNT_NODEV) else { return .mountFailed }
        return nil
    }
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) async throws { try await readOnly.restore(disk, originallyMounted: originallyMounted) }
    func restoreWrite(_ operation: HelperMountOperation) async throws {
        guard operation.isWrite else { throw HelperDiskFailure.invalidRequest }
        let disk = operation.disk, path = point(operation)
        _ = try validate(disk, owner: operation.ownerUID, restoring: true)
        // A native copy that slipped in beside (or after) the write mount blocks
        // every check below. A single native mount that a previous attempt already
        // restored is the goal, not a stray: leave it so retries stay idempotent.
        let ofDevice = try SystemMountRecord.current().filter { $0.source == "/dev/" + disk.bsdName }
        let strays = Self.strayNativeMounts(ofDevice, device: "/dev/" + disk.bsdName, keeping: path)
        // The only mount left is macOS's own read-only one and that is where this
        // restore ends anyway: keep it (unmounting it failed while Spotlight held it).
        let nativeIsGoal = ofDevice.count == 1 && strays.count == 1 && Self.mountsNativeAfterRestore(operation)
        if !strays.isEmpty, !nativeIsGoal, ofDevice.count > 1 || !operation.restoreRequired {
            if try removeStrayNativeMounts(disk, keeping: path) == .busy { throw HelperDiskFailure.busy }
        }
        let records = try mounts(disk)
        let atPoint = try SystemMountRecord.current().filter { $0.path == path }
        if !atPoint.isEmpty {
            guard atPoint.count == 1, records.count == 1, atPoint[0].source == "/dev/" + disk.bsdName,
                  atPoint[0].type == "volisle" else { throw HelperDiskFailure.busy }
            do { try await NativeReadOnlyDisk(bsdName: disk.bsdName, registryID: disk.registryID).unmount() }
            catch let failure as HelperDiskFailure where failure != .busy && failure != .permissionDenied {
                // Files in use (busy) are never forced. Anything else: see whether
                // the volume could not flush because its session already stopped.
                guard Self.unmountStoppedWriteMount(path) else { throw failure }
                Logger(subsystem: "top.qisw.volisle.helper", category: "write")
                    .notice("写入会话已因设备错误停止，强制卸载读写挂载；恢复记录留待下次连接时回滚")
            }
        }
        guard try !SystemMountRecord.current().contains(where: { $0.path == path }) else { throw HelperDiskFailure.busy }
        var info = stat()
        if lstat(path, &info) == 0 {
            try rootDirectory()
            guard info.st_mode & S_IFMT == S_IFDIR, [UInt32(0), operation.ownerUID].contains(info.st_uid),
                  rmdir(path) == 0 else { throw HelperDiskFailure.unavailable }
        } else if errno != ENOENT { throw HelperDiskFailure.unavailable }
        let scope = try validate(disk, owner: operation.ownerUID, restoring: true)
        let remaining = try mounts(disk)
        let mountNative = Self.mountsNativeAfterRestore(operation)
        if remaining.isEmpty && mountNative {
            let report = try await inspect(disk)
            let expected = scope.bootSHA256 ?? operation.report?.bootSHA256
            guard expected == nil || report.bootSHA256 == expected else { throw VolumeError.identityChanged }
            do { try await NativeReadOnlyDisk(bsdName: disk.bsdName, registryID: disk.registryID).mount() }
            catch where !operation.restoreRequired {
                // Best effort for a disk that was not mounted before: it stays readable later by a replug.
                Logger(subsystem: "top.qisw.volisle.helper", category: "write").error("开启读写失败后补挂只读未成功：\(String(describing: error), privacy: .public)")
            }
        }
        let final = try mounts(disk)
        if operation.restoreRequired {
            guard final.count == 1, final[0].type == "ntfs", final[0].flags & UInt32(MNT_RDONLY) != 0 else { throw HelperDiskFailure.unavailable }
        } else if mountNative {
            guard final.isEmpty || (final.count == 1 && final[0].type == "ntfs" && final[0].flags & UInt32(MNT_RDONLY) != 0) else {
                throw HelperDiskFailure.busy
            }
        } else { guard final.isEmpty else { throw HelperDiskFailure.busy } }
    }
    /// A write mount whose session stopped on a device error (a USB link that
    /// dropped a read) cannot flush, so every normal unmount fails with EIO and
    /// only unplugging the disk used to end it. Its journal records stay for
    /// rollback at the next activation, so forcing loses nothing that was not
    /// already lost. Never for a busy volume. True once the mount is gone.
    static func unmountStoppedWriteMount(_ path: String) -> Bool {
        var value = [UInt8](repeating: 0, count: 16)
        let size = getxattr(path, "top.qisw.volisle.write-state", &value, value.count, 0, 0)
        if size <= 0 || String(decoding: value.prefix(size), as: UTF8.self) != "stopped" {
            // Extensions before 0.7 do not answer: a normal unmount failing with EIO tells the same.
            if Darwin.unmount(path, 0) == 0 { return true }
            guard errno == EIO else { return false }
        }
        return Darwin.unmount(path, MNT_FORCE) == 0
    }
    /// Whether restoring leaves the disk mounted read-only by macOS: always when
    /// it was mounted before, and also after a write start that failed on a
    /// just-inserted disk, which macOS was about to mount itself. Without this
    /// the disk ended up not mounted at all and missing from Finder.
    static func mountsNativeAfterRestore(_ operation: HelperMountOperation) -> Bool {
        operation.restoreRequired || operation.failure != nil
    }
    /// Run as root, mount(8) finds the invoking user's FSKit modules through
    /// SUDO_UID only from macOS 26. On macOS 15 it looks at root's own modules
    /// (none) and gives up before probing ("Unable to invoke task"). There the
    /// command runs as the owner, who is lent the device nodes meanwhile, and
    /// the kernel does not reflect the requested flags (nosuid, nodev, rdonly)
    /// on an FSKit mount: the module enforces read-only itself with EROFS.
    static let mountRunsAsRoot = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    /// Whether the mount command drops to the owner: always for a disposable
    /// image (no device privilege needed), and for every disk on macOS 15.
    static func mountsAsOwner(_ operation: HelperMountOperation, rootFindsModules: Bool = mountRunsAsRoot) -> Bool {
        operation.disk.version == 2 || !rootFindsModules
    }
    static func mountArguments(for operation: HelperMountOperation, option: String, asOwner: Bool) -> [String] {
        let context = ["asuser", String(operation.ownerUID)]
        let drop = asOwner ? ["/usr/bin/sudo", "-n", "-u", "#" + String(operation.ownerUID), "--"] : []
        let path = "/private/var/run/volisle-write-mounts/" + operation.id.uuidString.lowercased()
        return context + drop + ["/sbin/mount", "-F", "-k", "-t", "volisle", "-o", option + ",nosuid,nodev", "/dev/" + operation.disk.bsdName, path]
    }
    static func mountEnvironment(for operation: HelperMountOperation, asOwner: Bool) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        // Apple's mount uses SUDO_UID to discover the invoking user's FSKit
        // modules when euid is root. Take it only from the authenticated XPC
        // owner, never from the request or the daemon's inherited environment.
        if !asOwner { environment["SUDO_UID"] = String(operation.ownerUID) }
        return environment
    }
    /// The partition's block and raw device nodes, owned by the mount's owner
    /// for the duration of the mount command (fskitd opens the raw node with
    /// the caller's identity on macOS 15). Given back as soon as the command
    /// returns: the module already holds its descriptor by then.
    struct DeviceLoan {
        struct Attributes: Equatable, Sendable {
            var uid: uid_t; var gid: gid_t; var mode: mode_t
            let device: dev_t; let inode: ino_t
        }
        protocol Access: Sendable {
            func read(_ path: String) throws -> Attributes
            func changeOwner(_ path: String, uid: uid_t, gid: gid_t) throws
            func changeMode(_ path: String, mode: mode_t) throws
        }
        struct SystemAccess: Access {
            func read(_ path: String) throws -> Attributes {
                var info = stat()
                guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return Attributes(uid: info.st_uid, gid: info.st_gid, mode: info.st_mode,
                                  device: info.st_rdev, inode: info.st_ino)
            }
            func changeOwner(_ path: String, uid: uid_t, gid: gid_t) throws {
                guard chown(path, uid, gid) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            func changeMode(_ path: String, mode: mode_t) throws {
                guard chmod(path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        private struct Node { let path: String; let attributes: Attributes }
        private let nodes: [Node]
        private let access: any Access
        static func lend(_ bsdName: String, to owner: UInt32, using access: any Access = SystemAccess()) throws -> DeviceLoan {
            guard owner != 0, owner != .max else { throw HelperDiskFailure.invalidRequest }
            var nodes: [Node] = []
            do {
                for (path, kind) in [("/dev/" + bsdName, S_IFBLK), ("/dev/r" + bsdName, S_IFCHR)] {
                    let info = try access.read(path)
                    guard info.mode & S_IFMT == kind, info.uid == 0 else { throw HelperDiskFailure.unavailable }
                    nodes.append(Node(path: path, attributes: info))
                    try access.changeOwner(path, uid: uid_t(owner), gid: info.gid)
                    try access.changeMode(path, mode: 0o600)
                }
            } catch {
                Logger(subsystem: "top.qisw.volisle.helper", category: "write")
                    .error("设备节点权限借出失败：\(String(describing: error), privacy: .public)")
                try DeviceLoan(nodes: nodes, access: access).giveBack()
                throw HelperDiskFailure.unavailable
            }
            return DeviceLoan(nodes: nodes, access: access)
        }
        func giveBack() throws {
            var failed = false
            for node in nodes {
                do {
                    let current = try access.read(node.path), original = node.attributes
                    // A hot-unplug can reuse the BSD name for different media.
                    // Do not apply the previous device's permissions to it.
                    guard current.device == original.device, current.inode == original.inode,
                          current.mode & S_IFMT == original.mode & S_IFMT else { throw VolumeError.identityChanged }
                    try access.changeOwner(node.path, uid: original.uid, gid: original.gid)
                    try access.changeMode(node.path, mode: original.mode & 0o7777)
                    guard try access.read(node.path) == original else { throw HelperDiskFailure.unavailable }
                } catch {
                    failed = true
                    Logger(subsystem: "top.qisw.volisle.helper", category: "write")
                        .error("设备节点权限未还原：\(node.path, privacy: .public)，\(String(describing: error), privacy: .public)")
                }
            }
            guard !failed else { throw HelperDiskFailure.unavailable }
        }
        func duringMount(_ mount: () async throws -> Void) async throws {
            do { try await mount() }
            catch {
                do { try giveBack() }
                catch let restorationError {
                    Logger(subsystem: "top.qisw.volisle.helper", category: "write")
                        .error("挂载失败后设备权限亦未还原；挂载错误：\(String(describing: error), privacy: .public)")
                    throw restorationError
                }
                throw error
            }
            // Before automount settling, metadata checks, or writeMounted state.
            try giveBack()
        }
    }
    private func run(_ arguments: [String], environment: [String: String]) async throws {
        try await HelperLaunchctl.run(arguments, environment: environment)
    }
}
