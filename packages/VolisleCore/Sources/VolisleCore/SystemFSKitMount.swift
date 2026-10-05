import Foundation
import CryptoKit
import DiskArbitration
import IOKit
import Darwin
import OSLog

/// Short-lived binding for a READ-ONLY system mount. It is neither a persistent
/// identity nor permission to write. The future privileged service must create
/// and validate its own binding; never trust a client-supplied device name alone.
public struct ReadOnlyDeviceBinding: Sendable {
    public let bsdName: String
    public let registryID: UInt64
    public let byteCount: UInt64
    public let bootSHA256: String
    fileprivate var imageURL: URL?
    public init(bsdName: String, registryID: UInt64, byteCount: UInt64, bootSHA256: String) throws {
        guard Self.validName(bsdName), registryID != 0, byteCount >= 512,
              byteCount <= UInt64(Int64.max), byteCount % 512 == 0,
              bootSHA256.utf8.count == 64,
              bootSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw VolumeError.unstableIdentity
        }
        self.bsdName = bsdName; self.registryID = registryID
        self.byteCount = byteCount; self.bootSHA256 = bootSHA256
    }
    /// Captures the current media instance. Callers still supply independently
    /// obtained size and boot evidence, e.g. from a new disposable image.
    public static func capture(bsdName: String, byteCount: UInt64, bootSHA256: String) throws -> Self {
        guard validName(bsdName) else { throw VolumeError.unstableIdentity }
        let metadata = try DeviceMetadata.read(bsdName)
        guard metadata.byteCount == byteCount else { throw VolumeError.identityChanged }
        let binding = try Self(bsdName: bsdName, registryID: metadata.registryID, byteCount: byteCount, bootSHA256: bootSHA256)
        _ = try binding.validatedMetadata()
        return binding
    }
    public static func captureDiskImage(_ image: URL, bsdName: String, byteCount: UInt64, bootSHA256: String) throws -> Self {
        guard validName(bsdName), image.isFileURL, image.host == nil || image.host == "" || image.host == "localhost",
              image.query == nil, image.fragment == nil else { throw VolumeError.unstableIdentity }
        let metadata = try DeviceMetadata.read(bsdName)
        var binding = try Self(bsdName: bsdName, registryID: metadata.registryID, byteCount: byteCount, bootSHA256: bootSHA256)
        binding.imageURL = image.standardizedFileURL
        _ = try binding.validatedMetadata()
        return binding
    }
    static func validName(_ name: String) -> Bool {
        name.utf8.count <= 32 && name.range(of: "\\Adisk[0-9]+(?:s[0-9]+)?\\z", options: .regularExpression) != nil
    }
    var devicePath: String { "/dev/" + bsdName }
    fileprivate func validatedMetadata() throws -> DeviceMetadata {
        let metadata = try DeviceMetadata.read(bsdName)
        guard metadata.registryID == registryID, metadata.byteCount == byteCount else { throw VolumeError.identityChanged }
        var verifiedImage = false
        if let imageURL {
            var info = Darwin.stat()
            guard imageURL.resolvingSymlinksInPath().path == imageURL.path,
                  lstat(imageURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1, info.st_size == byteCount,
                  metadata.writable == false,
                  try DiskImageMapping.matches(imageURL, device: devicePath) else { throw VolumeError.identityChanged }
            verifiedImage = true
        }
        guard ReadOnlyMediaPolicy.allows(internalDevice: metadata.internalDevice, virtual: metadata.virtual,
                                        verifiedReadOnlyImage: verifiedImage) else { throw VolumeError.protectedVolume }
        return metadata
    }
}

enum ReadOnlyMediaPolicy {
    static func allows(internalDevice: Bool?, virtual: Bool, verifiedReadOnlyImage: Bool) -> Bool {
        internalDevice == false || (internalDevice == nil && virtual && verifiedReadOnlyImage)
    }
}

enum DiskImageMapping {
    static func matches(_ image: URL, device: String) throws -> Bool {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return false }
        return images.filter { record in
            guard let path = record["image-path"] as? String,
                  URL(filePath: path).resolvingSymlinksInPath().path == image.path,
                  let entities = record["system-entities"] as? [[String: Any]] else { return false }
            return entities.compactMap { $0["dev-entry"] as? String } == [device]
        }.count == 1
    }
}

struct DeviceMetadata {
    let registryID: UInt64
    let byteCount: UInt64
    let blockSize: Int
    let internalDevice: Bool?
    let virtual: Bool
    let deviceProtocol: String?
    let whole: Bool?
    let writable: Bool?
    static func read(_ name: String) throws -> Self {
        guard let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, name),
              let description = DADiskCopyDescription(disk) as NSDictionary? else { throw VolumeError.disconnected }
        let entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { throw VolumeError.disconnected }
        defer { IOObjectRelease(entry) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS, registryID != 0,
              let size = description[kDADiskDescriptionMediaSizeKey] as? NSNumber, size.int64Value >= 512,
              let block = description[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber,
              block.intValue >= 512, block.intValue <= 65536, block.intValue.nonzeroBitCount == 1 else {
            throw VolumeError.unstableIdentity
        }
        return .init(registryID: registryID, byteCount: size.uint64Value, blockSize: block.intValue,
                     internalDevice: description[kDADiskDescriptionDeviceInternalKey] as? Bool,
                     virtual: description[kDADiskDescriptionDeviceProtocolKey] as? String == "Virtual Interface",
                     deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey] as? String,
                     whole: description[kDADiskDescriptionMediaWholeKey] as? Bool,
                     writable: description[kDADiskDescriptionMediaWritableKey] as? Bool)
    }
}

private final class HeldReadOnlyDevice {
    let descriptor: Int32
    let deviceNumber: dev_t
    let binding: ReadOnlyDeviceBinding
    init(_ binding: ReadOnlyDeviceBinding) throws {
        self.binding = binding
        _ = try binding.validatedMetadata()
        descriptor = Darwin.open(binding.devicePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var stat = Darwin.stat()
        guard fstat(descriptor, &stat) == 0, stat.st_mode & S_IFMT == S_IFBLK else {
            Darwin.close(descriptor)
            throw VolumeError.identityChanged
        }
        deviceNumber = stat.st_rdev
        // All stored properties are initialized; deinit closes on a thrown check.
        try revalidate()
    }
    deinit { Darwin.close(descriptor) }
    func revalidate() throws {
        let metadata = try binding.validatedMetadata()
        var pathStat = Darwin.stat()
        guard lstat(binding.devicePath, &pathStat) == 0, pathStat.st_mode & S_IFMT == S_IFBLK,
              pathStat.st_rdev == deviceNumber else { throw VolumeError.identityChanged }
        var boot = [UInt8](repeating: 0, count: metadata.blockSize)
        let count = boot.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == metadata.blockSize else { throw POSIXError(.EIO) }
        guard Array(boot[3..<11]) == Array("NTFS    ".utf8), boot[510] == 0x55, boot[511] == 0xaa else {
            throw VolumeError.unsupportedFileSystem
        }
        let hash = SHA256.hash(data: Data(boot.prefix(512))).map { String(format: "%02x", $0) }.joined()
        guard hash == binding.bootSHA256 else { throw VolumeError.identityChanged }
        // Re-check the media instance after reading the held descriptor.
        guard try DeviceMetadata.read(binding.bsdName).registryID == binding.registryID else { throw VolumeError.identityChanged }
    }
}

struct SystemMountRecord: Sendable {
    let source: String
    let path: String
    let type: String
    let flags: UInt32
    func verifies(_ binding: ReadOnlyDeviceBinding, at path: String) -> Bool {
        let required = UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV)
        return source == binding.devicePath && self.path == path && type == "volisle" && flags & required == required
    }
    static func current() throws -> [Self] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0, count < 100_000 else { throw VolumeError.mountNotVerified }
        var entries = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: Int(count) + 16)
        let actual = entries.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard actual >= 0, actual < entries.count else { throw VolumeError.mountNotVerified }
        return entries.prefix(Int(actual)).map { entry in
            .init(source: text(entry.f_mntfromname), path: text(entry.f_mntonname), type: text(entry.f_fstypename), flags: entry.f_flags)
        }
    }
    private static func text<T>(_ bytes: T) -> String {
        withUnsafeBytes(of: bytes) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

public enum SystemMountError: Error, LocalizedError, Sendable {
    case commandFailed(Int32), commandInterrupted
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status): String(localized: "系统挂载工具未完成操作（状态码 \(status)）。")
        case .commandInterrupted: String(localized: "系统挂载工具被中断，磁盘状态需要重新核验。")
        }
    }
}

/// A real system transport, deliberately limited to read-only mounts. It cannot
/// enable write capability or serve as a privileged IPC endpoint. Each instance
/// owns one held device and one newly created internal temporary mountpoint.
public actor FSKitReadOnlyMountSession {
    private let binding: ReadOnlyDeviceBinding
    private let readiness: ReadOnlyFSKitEngine
    private var held: HeldReadOnlyDevice?
    private var operating = false
    private var attempted = false
    private var closed = false
    public private(set) var mountURL: URL?
    public init(binding: ReadOnlyDeviceBinding, extensionURL: URL, identifier: String) throws {
        self.binding = binding
        readiness = ReadOnlyFSKitEngine(expectedExtension: extensionURL, identifier: identifier)
        held = try HeldReadOnlyDevice(binding)
    }
    public func mountReadOnly() async throws -> URL {
        guard !operating, !attempted, !closed, let held else { throw VolumeError.busy }
        operating = true
        defer { operating = false }
        guard await readiness.capability().available else { throw VolumeError.engineUnavailable }
        try Task.checkCancellation()
        try held.revalidate()
        guard try !SystemMountRecord.current().contains(where: { $0.source == binding.devicePath }) else { throw VolumeError.busy }
        var template = Array("/private/tmp/volisle-system-mount-XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let url = URL(filePath: path, directoryHint: .isDirectory)
        mountURL = url
        attempted = true
        // Fixed executable, argument vector and options; no shell, arbitrary
        // commands, incoming mount path, write mode or force option.
        try await Self.run(.mount(binding.devicePath, path))
        try held.revalidate()
        let matches = try SystemMountRecord.current().filter { $0.path == path }
        guard matches.count == 1, matches[0].verifies(binding, at: path) else { throw VolumeError.mountNotVerified }
        return url
    }
    /// Only normally unmounts this session's own verified source and path.
    /// Await command completion even if the initiating task is cancelled.
    public func close() async throws {
        guard !operating else { throw VolumeError.busy }
        guard !closed else { return }
        operating = true
        defer { operating = false }
        if let url = mountURL {
            let matches = try SystemMountRecord.current().filter { $0.path == url.path }
            if !matches.isEmpty {
                guard matches.count == 1, matches[0].verifies(binding, at: url.path), let held else {
                    throw VolumeError.mountNotVerified
                }
                try held.revalidate()
                try await Self.run(.unmount(url.path))
            }
            guard try !SystemMountRecord.current().contains(where: { $0.path == url.path }) else { throw VolumeError.mountNotVerified }
            // Never recursively delete a mount directory or user data.
            guard rmdir(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        mountURL = nil; held = nil; closed = true
    }
    private enum Command: Sendable { case mount(String, String), unmount(String) }
    private static func run(_ command: Command) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let process = Process()
            switch command {
            case .mount(let device, let path):
                process.executableURL = URL(filePath: "/sbin/mount")
                process.arguments = ["-F", "-k", "-t", "volisle", "-o", "rdonly,nosuid,nodev", device, path]
            case .unmount(let path):
                process.executableURL = URL(filePath: "/sbin/umount")
                process.arguments = [path]
            }
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
            process.currentDirectoryURL = URL(filePath: "/")
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            process.terminationHandler = { process in
                if process.terminationReason != .exit { continuation.resume(throwing: SystemMountError.commandInterrupted) }
                else if process.terminationStatus != 0 { continuation.resume(throwing: SystemMountError.commandFailed(process.terminationStatus)) }
                else { continuation.resume() }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}


/// First service-side device operation: bounded read-only identity inspection.
/// No unmount, filesystem repair, mounting or write syscall is performed.
enum HelperDiskInspector {
    private static let logger = Logger(subsystem: "top.qisw.volisle", category: "disk-inspection")
    private static let lock = NSLock()
    static func inspect(_ input: HelperDiskRequest) throws -> HelperDiskReport {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard lock.try() else { throw VolumeError.busy }
        defer { lock.unlock() }
        func metadata() throws -> DeviceMetadata {
            let current = try DeviceMetadata.read(request.bsdName)
            guard current.registryID == request.registryID, current.byteCount == request.byteCount else {
                throw VolumeError.identityChanged
            }
            guard HelperDiskPolicy.allows(internalDevice: current.internalDevice,
                                          deviceProtocol: current.deviceProtocol, whole: current.whole) else {
                throw VolumeError.protectedVolume
            }
            return current
        }
        let before = try metadata()
        let path = "/dev/" + request.bsdName
        func checkMounts() throws {
            let mounts = try SystemMountRecord.current().filter { $0.source == path }
            guard mounts.count <= 1,
                  mounts.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 }) else {
                throw VolumeError.busy
            }
        }
        try checkMounts()
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            logger.error("Read-only device open failed: errno=\(code, privacy: .public)")
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var held = Darwin.stat()
        guard fstat(descriptor, &held) == 0, held.st_mode & S_IFMT == S_IFBLK else { throw VolumeError.identityChanged }
        _ = try metadata()
        var bytes = [UInt8](repeating: 0, count: before.blockSize)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == before.blockSize else {
            let code = count < 0 ? errno : EIO
            logger.error("Read-only boot read failed: errno=\(code, privacy: .public), count=\(count, privacy: .public)")
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let bootHash = try HelperDiskPolicy.bootHash(Data(bytes.prefix(512)))
        var currentPath = Darwin.stat()
        guard lstat(path, &currentPath) == 0, currentPath.st_mode & S_IFMT == S_IFBLK,
              currentPath.st_rdev == held.st_rdev else { throw VolumeError.identityChanged }
        _ = try metadata()
        try checkMounts()
        return HelperDiskReport(version: 1, bsdName: request.bsdName, registryID: request.registryID,
                                byteCount: request.byteCount, bootSHA256: bootHash, effectiveUID: geteuid(),
                                writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
}

/// Public macOS file access prompts are triggered by access from the GUI app.
/// Merely completing this request is NOT an authorization success signal.
enum RemovableVolumeAccess {
    static func capture(_ volume: VolumeSnapshot) throws -> HelperDiskRequest {
        guard volume.isExternal, !volume.isProtected else { throw VolumeError.protectedVolume }
        guard volume.isNTFS else { throw VolumeError.unsupportedFileSystem }
        let metadata = try DeviceMetadata.read(volume.bsdName)
        guard metadata.registryID == volume.identity.mediaRegistryID else { throw VolumeError.identityChanged }
        return try HelperDiskRequest(bsdName: volume.bsdName, registryID: metadata.registryID, byteCount: metadata.byteCount)
    }
    static func requestFromApplication(_ request: HelperDiskRequest) throws {
        guard geteuid() != 0 else { throw HelperServiceError.wrongPrivileges }
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(request))
        func validate() throws {
            let metadata = try DeviceMetadata.read(request.bsdName)
            guard metadata.registryID == request.registryID, metadata.byteCount == request.byteCount else {
                throw VolumeError.identityChanged
            }
            guard HelperDiskPolicy.allows(internalDevice: metadata.internalDevice,
                                          deviceProtocol: metadata.deviceProtocol, whole: metadata.whole) else {
                throw VolumeError.protectedVolume
            }
        }
        try validate()
        // No read/write calls. Opening read-only may trigger the system consent
        // dialog even when Unix device permissions prevent this user opening it.
        let fd = Darwin.open("/dev/" + request.bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { Darwin.close(fd) }
        else if errno != EACCES && errno != EPERM {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try validate()
        // Only the following independent root helper read determines access.
    }
}

/// Root's first mount transaction: normal native unmount, bounded inspection,
/// then native read-only restore. The writable FSKit adapter is not enabled.
struct SystemHelperMountCycleBackend: HelperMountCycleBackend {
    private func validate(_ disk: HelperDiskRequest) throws -> [SystemMountRecord] {
        _ = try HelperDiskRequest.decode(JSONEncoder().encode(disk))
        let info = try DeviceMetadata.read(disk.bsdName)
        guard info.registryID == disk.registryID, info.byteCount == disk.byteCount else { throw VolumeError.identityChanged }
        guard HelperDiskPolicy.allows(internalDevice: info.internalDevice, deviceProtocol: info.deviceProtocol,
                                      whole: info.whole) else { throw VolumeError.protectedVolume }
        let mounts = try SystemMountRecord.current().filter { $0.source == "/dev/" + disk.bsdName }
        guard mounts.count <= 1, mounts.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 &&
            $0.path.hasPrefix("/Volumes/") }) else { throw HelperDiskFailure.busy }
        return mounts
    }
    func verifyRestoredState(_ record: HelperMountOperation) throws -> MountCycleVerifiedState {
        guard record.phase == .finished else { throw HelperDiskFailure.busy }
        // No old operation can remain running across a boot; never infer that
        // a reused BSD name/registry ID is the old device after a reboot.
        guard try record.bootSession == SystemHelperMountService.currentBootSession() else { return .disconnected }
        let original = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(record.disk.registryID))
        guard original != 0 else { return .disconnected }
        defer { IOObjectRelease(original) }
        let current: [SystemMountRecord]
        if record.isWrite, try DeviceMetadata.read(record.disk.bsdName).virtual {
            let metadata = try DeviceMetadata.read(record.disk.bsdName)
            guard metadata.registryID == record.disk.registryID, metadata.byteCount == record.disk.byteCount,
                  metadata.byteCount == 67_108_864 else { throw VolumeError.identityChanged }
            current = try SystemMountRecord.current().filter { $0.source == "/dev/" + record.disk.bsdName }
            guard current.count <= 1, current.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 && $0.path.hasPrefix("/Volumes/") }) else {
                throw HelperDiskFailure.busy
            }
        } else { current = try validate(record.disk) }
        guard current.isEmpty != record.restoreRequired else { throw HelperDiskFailure.busy }
        return current.isEmpty ? .unmounted : .readOnly
    }
    func prepare(_ disk: HelperDiskRequest) async throws -> Bool {
        let mounted = try !validate(disk).isEmpty
        // On this OS mounted FSKit devices return EBUSY. EPERM/EACCES are not
        // accepted: fail before unmounting when no disk access was granted.
        let fd = Darwin.open("/dev/" + disk.bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { Darwin.close(fd) }
        else if errno != EBUSY || !mounted { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try !validate(disk).isEmpty == mounted else { throw HelperDiskFailure.busy }
        return mounted
    }
    func unmount(_ disk: HelperDiskRequest) async throws {
        guard try !validate(disk).isEmpty else { return }
        let target = try await NativeReadOnlyDisk(bsdName: disk.bsdName, registryID: disk.registryID)
        try await target.unmount()
        guard try validate(disk).isEmpty else { throw HelperDiskFailure.busy }
    }
    func inspect(_ disk: HelperDiskRequest) async throws -> HelperDiskReport {
        guard try validate(disk).isEmpty else { throw HelperDiskFailure.busy }
        return try HelperDiskInspector.inspect(disk)
    }
    func restore(_ disk: HelperDiskRequest, originallyMounted: Bool) async throws {
        let before = try validate(disk)
        if !originallyMounted {
            guard before.isEmpty else { throw HelperDiskFailure.busy }
            return
        }
        if !before.isEmpty { return } // Already native read-only; do not unmount it.
        // Before re-mounting an unmounted target, independently confirm NTFS.
        // This also fails closed if permissions were revoked during the cycle.
        _ = try HelperDiskInspector.inspect(disk)
        let target = try await NativeReadOnlyDisk(bsdName: disk.bsdName, registryID: disk.registryID)
        try await target.mount()
        guard try !validate(disk).isEmpty else { throw HelperDiskFailure.unavailable }
    }
}

/// Real transactional write transport for one explicitly bound disposable image.
/// Physical devices and ordinary application startup cannot create this adapter.
/// The extension remains authoritative: activation must pass its read-only NTFS
/// preflight and compiled fixture binding before the OS can report writable.
public actor FSKitWriteMountSession: TransactionalFileSystemAdapter, VolumeResolver {
    private let image: URL
    private let bsdName: String
    private let registryID: UInt64
    private let bootHash: String
    private let identity: VolumeIdentity
    private let readiness: ReadOnlyFSKitEngine
    private var operating = false
    private var started = false
    private var originalMounted = false
    private var mountPoint: URL?
    private var settled = false

    public init(image: URL, bsdName: String, extensionURL: URL, identifier: String) throws {
        guard image.isFileURL, image.host == nil || image.host == "" || image.host == "localhost",
              image.query == nil, image.fragment == nil, ReadOnlyDeviceBinding.validName(bsdName),
              geteuid() != 0 else { throw VolumeError.protectedVolume }
        let image = image.standardizedFileURL
        let metadata = try DeviceMetadata.read(bsdName)
        let boot = try Self.validateImage(image, bsdName: bsdName, registryID: metadata.registryID)
        self.image = image; self.bsdName = bsdName; registryID = metadata.registryID
        bootHash = Self.hash(boot)
        identity = VolumeIdentity(volumeUUID: Data(boot[72..<80]).map { String(format: "%02x", $0) }.joined(),
                                  mediaUUID: nil, devicePath: "/dev/" + bsdName, mediaRegistryID: metadata.registryID)
        readiness = ReadOnlyFSKitEngine(expectedExtension: extensionURL, identifier: identifier)
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func validateImage(_ image: URL, bsdName: String, registryID: UInt64) throws -> Data {
        let metadata = try DeviceMetadata.read(bsdName)
        guard metadata.registryID == registryID, metadata.virtual, metadata.writable == true,
              metadata.byteCount == 67_108_864,
              try DiskImageMapping.matches(image, device: "/dev/" + bsdName),
              image.resolvingSymlinksInPath() == image else { throw VolumeError.identityChanged }
        let fd = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VolumeError.identityChanged }
        defer { Darwin.close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size == 67_108_864 else { throw VolumeError.identityChanged }
        var bytes = [UInt8](repeating: 0, count: 512)
        guard bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == 512 else { throw POSIXError(.EIO) }
        _ = try HelperDiskPolicy.bootHash(Data(bytes))
        guard bytes[72..<80].contains(where: { $0 != 0 }) else { throw VolumeError.unstableIdentity }
        return Data(bytes)
    }
    private func validate() throws {
        guard try Self.hash(Self.validateImage(image, bsdName: bsdName, registryID: registryID)) == bootHash else {
            throw VolumeError.identityChanged
        }
    }
    private func mounts() throws -> [SystemMountRecord] {
        try validate()
        let records = try SystemMountRecord.current().filter { $0.source == "/dev/" + bsdName }
        guard records.count <= 1 else { throw VolumeError.busy }
        return records
    }
    public func snapshot() throws -> VolumeSnapshot {
        let record = try mounts().first
        let state: MountState = record.map { $0.flags & UInt32(MNT_RDONLY) == 0 ? .readWrite : .readOnly } ?? .unmounted
        return .init(identity: identity, bsdName: bsdName, name: "写入事务测试镜像", fileSystem: "ntfs", deviceName: "一次性镜像",
                     totalBytes: 67_108_864, availableBytes: nil, mountURL: record.map { URL(filePath: $0.path) },
                     mountState: state, isExternal: true, isProtected: false)
    }
    public func resolve(_ expected: VolumeIdentity) throws -> VolumeSnapshot {
        guard expected == identity else { throw VolumeError.identityChanged }
        return try snapshot()
    }
    public func capability() async -> EngineCapability {
        let ready = await readiness.capability()
        guard ready.available else { return ready }
        do { try validate() } catch {
            return .init(available: false, finderReadWrite: false, reason: error.localizedDescription)
        }
        return .init(available: true, finderReadWrite: true, reason: "仅供已绑定的一次性镜像事务验收。")
    }
    public func inspect(_ volume: VolumeSnapshot) throws -> SafetyStatus { throw VolumeError.safetyUnknown }
    public func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL { try await enableReadWriteTransaction(volume) }
    public func enableReadWriteTransaction(_ volume: VolumeSnapshot) async throws -> URL {
        guard !operating, !started, volume.identity == identity, volume.bsdName == bsdName else { throw VolumeError.busy }
        operating = true
        defer { operating = false }
        guard await readiness.capability().available else { throw VolumeError.engineUnavailable }
        let existing = try mounts()
        guard existing.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 }) else { throw VolumeError.busy }
        try Task.checkCancellation()
        originalMounted = !existing.isEmpty; started = true
        if originalMounted {
            let native = try await NativeReadOnlyDisk(bsdName: bsdName, registryID: registryID)
            try await native.unmount()
        }
        guard try mounts().isEmpty else { throw VolumeError.busy }
        // Verify the device itself, not only the image's path. No write handle
        // is opened here: FSKit owns the actual resource and repeats preflight.
        let fd = open("/dev/" + bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bytes = [UInt8](repeating: 0, count: 512)
        var info = Darwin.stat()
        let validFD = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFBLK
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        Darwin.close(fd)
        guard validFD, count == 512, Self.hash(Data(bytes)) == bootHash else { throw VolumeError.identityChanged }
        try validate()
        var template = Array("/private/tmp/volisle-write-transaction-XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { throw POSIXError(.EIO) }
        mountPoint = URL(filePath: path)
        try await Self.run(mount: true, device: "/dev/" + bsdName, path: path)
        let records = try mounts()
        guard records.count == 1, records[0].path == path, records[0].type == "volisle",
              records[0].flags & UInt32(MNT_RDONLY) == 0,
              records[0].flags & UInt32(MNT_NOSUID | MNT_NODEV) == UInt32(MNT_NOSUID | MNT_NODEV) else {
            throw VolumeError.mountNotVerified
        }
        return URL(filePath: path)
    }
    public func unmount(_ volume: VolumeSnapshot) async throws {
        guard case .settled = await recoverFailedMount(volume) else { throw VolumeError.mountNotVerified }
    }
    public func recoverFailedMount(_ volume: VolumeSnapshot) async -> MountRecoveryDisposition {
        guard volume.identity == identity, !operating else { return .unresolved }
        guard !settled else { return .settled }
        operating = true
        defer { operating = false }
        do {
            let records = try mounts()
            if let point = mountPoint {
                let atPoint = try SystemMountRecord.current().filter { $0.path == point.path }
                if let record = atPoint.first {
                    guard atPoint.count == 1, record.source == "/dev/" + bsdName,
                          record.type == "volisle", records.count == 1 else { return .unresolved }
                    try await Self.run(mount: false, device: "", path: point.path)
                }
                guard try !SystemMountRecord.current().contains(where: { $0.path == point.path }) else { return .unresolved }
                guard rmdir(point.path) == 0 else { return .unresolved }
                mountPoint = nil
            }
            if try started && originalMounted && mounts().isEmpty {
                let native = try await NativeReadOnlyDisk(bsdName: bsdName, registryID: registryID)
                try await native.mount()
            }
            let final = try mounts()
            if started && originalMounted {
                guard final.count == 1, final[0].type == "ntfs", final[0].flags & UInt32(MNT_RDONLY) != 0 else { return .unresolved }
            } else {
                guard final.isEmpty || (!started && final.allSatisfy({ $0.type == "ntfs" && $0.flags & UInt32(MNT_RDONLY) != 0 })) else { return .unresolved }
            }
            settled = true; return .settled
        } catch { return .unresolved }
    }
    private static func run(mount: Bool, device: String, path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let process = Process()
            process.executableURL = URL(filePath: mount ? "/sbin/mount" : "/sbin/umount")
            process.arguments = mount ? ["-F", "-k", "-t", "volisle", "-o", "volisle-rw,nosuid,nodev", device, path] : [path]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
            process.currentDirectoryURL = URL(filePath: "/")
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            process.terminationHandler = { result in
                if result.terminationReason != .exit { continuation.resume(throwing: SystemMountError.commandInterrupted) }
                else if result.terminationStatus != 0 { continuation.resume(throwing: SystemMountError.commandFailed(result.terminationStatus)) }
                else { continuation.resume() }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
