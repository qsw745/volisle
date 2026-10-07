import Foundation
import Darwin
import OSLog

/// BitLocker. The root helper reads the encrypted partition, turns the user's
/// password or recovery key into the volume master key, and mounts the
/// partition through the FSKit module with that key: writable when asked and
/// the module's own checks pass, read-only otherwise. The FSKit module never
/// sees the user's secret; the helper itself never writes to the partition.
public enum BitLockerSecretKind: String, Codable, Sendable {
    case password, recoveryKey

    /// Windows shows recovery keys as eight groups of six digits; accept them
    /// typed with spaces, dashes or nothing in between, in full-width digits (a
    /// Chinese input method), or pasted with a label such as "Recovery key:".
    /// Every group of a real key is a multiple of 11, which catches most typos
    /// before the slow unlock attempt.
    public static func normalizedRecoveryKey(_ text: String) -> String? {
        let plain = text.precomposedStringWithCompatibilityMapping  // NFKC: full-width digits become ASCII
            .replacingOccurrences(of: "[\u{2010}-\u{2015}\u{2212}\u{FE58}\u{FE63}]", with: "-", options: .regularExpression)
        let pattern = /(?:^|[^0-9])(?<key>[0-9]{6}(?:[\s-]*[0-9]{6}){7})(?![0-9])/
        let matches = plain.matches(of: pattern)
        guard matches.count == 1 else { return nil }
        let digits = String(matches[0].output.key).filter { $0.isASCII && $0.isNumber }
        guard digits.count == 48 else { return nil }
        let groups = stride(from: 0, to: 48, by: 6).map { String(digits.dropFirst($0).prefix(6)) }
        guard groups.allSatisfy({ Int($0).map { $0 % 11 == 0 && $0 < 65536 * 11 } ?? false }) else { return nil }
        return groups.joined(separator: "-")
    }
}

/// `kind == nil` only asks whether the partition holds BitLocker.
public struct HelperBitLockerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let bsdName: String
    public let registryID: UInt64
    public let byteCount: UInt64
    public let kind: BitLockerSecretKind?
    public let secret: String?
    /// Unlock for writing (absent from older apps: read-only).
    public let writable: Bool?
    public init(bsdName: String, registryID: UInt64, byteCount: UInt64, kind: BitLockerSecretKind? = nil, secret: String? = nil,
                writable: Bool = false) throws {
        self.version = 1; self.bsdName = bsdName; self.registryID = registryID; self.byteCount = byteCount
        self.kind = kind; self.secret = secret; self.writable = writable ? true : nil
        try validate()
    }
    private func validate() throws {
        guard version == 1, bsdName.utf8.count <= 32,
              bsdName.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil,
              registryID > 0, byteCount >= 1_048_576, byteCount <= UInt64(Int64.max), byteCount % 512 == 0,
              (kind == nil) == (secret == nil), writable != false, writable == nil || kind != nil else { throw HelperServiceError.invalidRequest }
        guard let kind, let secret else { return }
        switch kind {
        case .password:
            // Windows allows up to 256 characters; 1024 UTF-8 bytes covers any of them.
            guard !secret.isEmpty, secret.utf8.count <= 1024, !secret.utf8.contains(0) else { throw HelperServiceError.invalidRequest }
        case .recoveryKey:
            guard BitLockerSecretKind.normalizedRecoveryKey(secret) == secret else { throw HelperServiceError.invalidRequest }
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 8192 else { throw HelperServiceError.invalidRequest }
        do { let request = try JSONDecoder().decode(Self.self, from: data); try request.validate(); return request }
        catch { throw HelperServiceError.invalidRequest }
    }
}

/// Where an unlocked volume is mounted, and whether it is writable. A volume
/// asked for writing that came out read-only says why, when that is known.
public struct BitLockerUnlock: Equatable, Sendable {
    public let url: URL
    public let writable: Bool
    public let readOnlyReason: HelperDiskFailure?
    public init(url: URL, writable: Bool, readOnlyReason: HelperDiskFailure? = nil) {
        self.url = url; self.writable = writable; self.readOnlyReason = writable ? nil : readOnlyReason
    }
}

struct HelperBitLockerReply: Codable, Sendable {
    let isBitLocker: Bool?
    let mountPath: String?
    let failure: HelperDiskFailure?
    var writable: Bool? = nil
    var readOnlyReason: HelperDiskFailure? = nil
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let answers = [value.isBitLocker != nil, value.mountPath != nil, value.failure != nil].filter { $0 }.count
        guard answers == 1, value.mountPath != nil || (value.writable == nil && value.readOnlyReason == nil),
              value.writable != true || value.readOnlyReason == nil else { throw HelperServiceError.invalidReply }
        if let failure = value.failure { throw failure }
        if let path = value.mountPath, !BitLockerMountPoint.owns(path) { throw HelperServiceError.invalidReply }
        return value
    }
}

/// Unlocked volumes live under one root-owned directory, one fresh directory
/// per mount, so the app can tell them apart from NTFS write mounts.
public enum BitLockerMountPoint {
    public static let root = "/private/var/run/volisle-bitlocker"
    public static func owns(_ path: String) -> Bool {
        canonicalPath(path) != nil
    }
    static func canonicalPath(_ path: String) -> String? {
        for base in [root, "/var/run/volisle-bitlocker"] {
            let prefix = base + "/"
            guard path.hasPrefix(prefix) else { continue }
            let name = path.dropFirst(prefix.count)
            guard UUID(uuidString: String(name)) != nil, name == name.lowercased() else { return nil }
            return root + "/" + name
        }
        return nil
    }
    public static func isReady(_ path: String) -> Bool {
        guard let path = canonicalPath(path), let pending = try? BitLockerPendingMount(parent: root,
                                                                                      name: URL(filePath: path).lastPathComponent) else { return false }
        return pending.isReady
    }
}

/// Outside the volume, under a trusted parent: survives an app/helper restart
/// and contains no key. Only a completely verified mount removes its marker.
struct BitLockerPendingMount: Sendable {
    let parent: String
    let name: String
    private let owner: uid_t
    init(parent: String, name: String, owner: uid_t = 0) throws {
        guard UUID(uuidString: name) != nil, name == name.lowercased() else { throw HelperDiskFailure.invalidRequest }
        self.parent = parent; self.name = name; self.owner = owner
    }
    var path: String { parent + "/" + name }
    var marker: String { parent + "/.pending-" + name }
    private var trustedParent: Bool {
        var info = stat()
        return lstat(parent, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == owner && info.st_mode & 0o7777 == 0o711
    }
    var isReady: Bool {
        guard trustedParent else { return false }
        var info = stat()
        return lstat(marker, &info) != 0 && errno == ENOENT
    }
    func begin() throws {
        guard trustedParent else { throw HelperDiskFailure.unavailable }
        let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HelperDiskFailure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else { throw HelperDiskFailure.unavailable }
    }
    func finish() throws {
        guard trustedParent else { throw HelperDiskFailure.unavailable }
        var info = stat()
        guard lstat(marker, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
              unlink(marker) == 0 else { throw HelperDiskFailure.unavailable }
    }
}

/// Reported by the mounted extension itself, never by an on-disk NTFS stream.
/// Older FSKit kernels do not reflect the module's read-only state in statfs.
public enum FSKitMountMode: String, Sendable {
    case readOnly = "read-only", readWrite = "read-write", stopped
    public static let attribute = "top.qisw.volisle.mount-mode"
    public static let kernelReportsReadOnly = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    public static func read(at path: String) -> Self? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let size = getxattr(path, attribute, &bytes, bytes.count, 0, 0)
        guard size > 0, size <= bytes.count else { return nil }
        return Self(rawValue: String(decoding: bytes.prefix(size), as: UTF8.self))
    }
}

/// Root side.
enum HelperBitLockerService {
    private static let logger = Logger(subsystem: "top.qisw.volisle", category: "bitlocker")

    static func probe(_ request: HelperBitLockerRequest) async throws -> Bool {
        let request = try HelperBitLockerRequest.decode(JSONEncoder().encode(request))
        guard request.kind == nil else { throw HelperServiceError.invalidRequest }
        return try await HelperPartitionFormatter.withVerifiedPartition(request.bsdName, registryID: request.registryID,
            byteCount: request.byteCount, writable: false) { engine, descriptor, blockSize in
            try engine.isBitLocker(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount)
        }
    }

    /// Holds the device for the whole unlock, so nothing else can start on it
    /// between reading the key and mounting. Asked for writing, a volume the
    /// extension refuses to write (needs a check, hibernated Windows, unclean
    /// log) is mounted read-only instead, with that reason.
    static func unlock(_ input: HelperBitLockerRequest, uid: UInt32) async throws -> (path: String, writable: Bool, reason: HelperDiskFailure?) {
        let request = try HelperBitLockerRequest.decode(JSONEncoder().encode(input))
        guard let kind = request.kind, let secret = request.secret, uid != 0, uid != .max else { throw HelperServiceError.invalidRequest }
        let lease = try DeviceOperationGate.shared.acquire(request.bsdName)
        defer { DeviceOperationGate.shared.release(lease) }
        let key = try await HelperPartitionFormatter.openVerifiedPartition(request.bsdName, registryID: request.registryID,
            byteCount: request.byteCount, writable: false) { engine, descriptor, blockSize in
            try engine.bitLockerKey(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount, kind: kind, secret: secret)
        }
        guard request.writable == true else {
            let path = try await mount(request, key: key, uid: uid, writable: false).path
            logger.notice("BitLocker 卷已只读挂载：设备=\(request.bsdName, privacy: .public)")
            return (path, false, nil)
        }
        do {
            let mounted = try await mount(request, key: key, uid: uid, writable: true)
            logger.notice("BitLocker 卷已挂载：设备=\(request.bsdName, privacy: .public) 可写=\(mounted.writable, privacy: .public)")
            // Read-only without a refusal: the extension kept it so (e.g. an
            // interrupted write it could not safely roll back).
            return (mounted.path, mounted.writable, mounted.writable ? nil : .writeNotEnabled)
        } catch let refusal as HelperDiskFailure where [.ntfsDirty, .windowsHibernated, .windowsLogUnclean].contains(refusal) {
            logger.notice("BitLocker 卷拒绝写入（\(refusal.rawValue, privacy: .public)），改为只读挂载")
            // The refusing extension instance exits shortly after to release the device.
            var lastError: any Error = refusal
            for attempt in 0..<4 {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                do { return (try await mount(request, key: key, uid: uid, writable: false).path, false, refusal) }
                catch { lastError = error }
            }
            throw lastError
        }
    }

    private static func mount(_ request: HelperBitLockerRequest, key: String, uid: UInt32,
                              writable: Bool) async throws -> (path: String, writable: Bool) {
        let metadata = try DeviceMetadata.read(request.bsdName)
        guard metadata.registryID == request.registryID, metadata.byteCount == request.byteCount else { throw VolumeError.identityChanged }
        let device = "/dev/" + request.bsdName
        guard try !SystemMountRecord.current().contains(where: { $0.source == device }) else { throw VolumeError.busy }
        try prepareRoot()
        let path = BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()
        let pending = try BitLockerPendingMount(parent: BitLockerMountPoint.root, name: URL(filePath: path).lastPathComponent)
        try pending.begin()
        // The key is in mount's arguments for the moment it runs; the FSKit
        // module never logs options.
        let command = mountCommand(request, key: key, uid: uid, path: path, writable: writable)
        do {
            guard mkdir(path, 0o700) == 0, chown(path, uid, gid_t.max) == 0 else { throw HelperDiskFailure.unavailable }
            let loan = command.asOwner ? try SystemHelperWriteMountBackend.DeviceLoan.lend(request.bsdName, to: uid) : nil
            let mount = { try await HelperLaunchctl.run(command.arguments, environment: command.environment) }
            if let loan { try await loan.duringMount(mount) }
            else { try await mount() }
            let fresh = try DeviceMetadata.read(request.bsdName)
            guard fresh.registryID == request.registryID, fresh.byteCount == request.byteCount else { throw VolumeError.identityChanged }
            let records = try SystemMountRecord.current().filter { $0.source == device || $0.path == path }
            let actualWritable = try mountWritable(records, device: device, path: path, requestedWritable: writable,
                                                    mode: FSKitMountMode.read(at: path))
            try pending.finish()
            return (path, actualWritable)
        } catch {
            discardFailedMount(device: device, pending: pending)
            throw error
        }
    }

    /// Mount can have succeeded before permission restoration or mode validation
    /// fails. Only release this exact mount normally; never force files in use.
    private static func discardFailedMount(device: String, pending: BitLockerPendingMount) {
        let path = pending.path
        do {
            let records = try SystemMountRecord.current().filter { BitLockerMountPoint.canonicalPath($0.path) == path }
            if !records.isEmpty {
                guard records.count == 1, records[0].source == device, records[0].type == "volisle" else {
                    throw VolumeError.mountNotVerified
                }
                guard Darwin.unmount(path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard try !SystemMountRecord.current().contains(where: { BitLockerMountPoint.canonicalPath($0.path) == path }) else { throw VolumeError.busy }
            rmdir(path)
            try pending.finish()
        } catch {
            logger.error("BitLocker 解锁失败后的挂载未释放：\(path, privacy: .public)，\(String(describing: error), privacy: .public)")
        }
    }

    static func mountCommand(_ request: HelperBitLockerRequest, key: String, uid: UInt32, path: String,
                             writable: Bool, rootFindsModules: Bool = SystemHelperWriteMountBackend.mountRunsAsRoot)
        -> (arguments: [String], environment: [String: String], asOwner: Bool) {
        let options = (writable ? "nosuid,nodev,volisle-rw" : "rdonly,nosuid,nodev") + ",volisle-bde=" + key
        let asOwner = !rootFindsModules
        let drop = asOwner ? ["/usr/bin/sudo", "-n", "-u", "#" + String(uid), "--"] : []
        let arguments = ["asuser", String(uid)] + drop + ["/sbin/mount", "-F", "-k", "-t", "volisle", "-o", options, "/dev/" + request.bsdName, path]
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        if !asOwner { environment["SUDO_UID"] = String(uid) }
        return (arguments, environment, asOwner)
    }

    static func mountWritable(_ records: [SystemMountRecord], device: String, path: String, requestedWritable: Bool,
                              mode: FSKitMountMode?, kernelReflectsSafetyFlags: Bool = SystemHelperWriteMountBackend.mountRunsAsRoot,
                              kernelReportsReadOnly: Bool = FSKitMountMode.kernelReportsReadOnly) throws -> Bool {
        let required = UInt32(MNT_NOSUID | MNT_NODEV)
        guard records.count == 1, records[0].source == device, records[0].path == path,
              records[0].type == "volisle",
              !kernelReflectsSafetyFlags || records[0].flags & required == required else {
            throw VolumeError.mountNotVerified
        }
        let kernelReadOnly = records[0].flags & UInt32(MNT_RDONLY) != 0
        guard mode != .stopped else { throw VolumeError.mountNotVerified }
        let readOnly: Bool
        if kernelReportsReadOnly {
            // Old installed extensions have no mode attribute; these kernels
            // still reliably reflect their requestedMountOptions witness.
            if let mode, (mode == .readOnly) != kernelReadOnly { throw VolumeError.mountNotVerified }
            readOnly = kernelReadOnly
        } else {
            // A successful mount on a writable device says nothing about the
            // module's actual mode before 26.4. Never infer it from the request.
            guard let mode, mode != .readWrite || !kernelReadOnly else { throw VolumeError.mountNotVerified }
            readOnly = mode == .readOnly
        }
        guard requestedWritable || readOnly else { throw VolumeError.mountNotVerified }
        return !readOnly
    }

    /// Root-owned, and emptied of directories left by earlier, since unmounted volumes.
    private static func prepareRoot() throws {
        let root = BitLockerMountPoint.root
        if mkdir(root, 0o711) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        var info = Darwin.stat()
        guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
              info.st_mode & 0o777 == 0o711 else { throw HelperDiskFailure.unavailable }
        let mounted = Set(try SystemMountRecord.current().map { BitLockerMountPoint.canonicalPath($0.path) ?? $0.path })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            if name.hasPrefix(".pending-") {
                let identifier = String(name.dropFirst(".pending-".count))
                guard let pending = try? BitLockerPendingMount(parent: root, name: identifier), !mounted.contains(pending.path) else { continue }
                var entry = Darwin.stat()
                guard lstat(pending.marker, &entry) == 0,
                      time(nil) - entry.st_birthtimespec.tv_sec > Int(HelperLaunchctl.timeout) + 60 else { continue }
                try pending.finish()
                continue
            }
            let path = root + "/" + name
            guard BitLockerMountPoint.owns(path), !mounted.contains(path) else { continue }
            // A recent one may be another partition's mount point whose mount is
            // still running (unlocking two at once).
            var entry = Darwin.stat()
            guard lstat(path, &entry) == 0, time(nil) - entry.st_birthtimespec.tv_sec > Int(HelperLaunchctl.timeout) + 60 else { continue }
            rmdir(path)  // only ever removes an empty directory
        }
    }
}

/// `launchctl asuser …`: mount inside the requesting user's login context.
enum HelperLaunchctl {
    /// A mount that never returns (a disk that stopped answering, a stuck file
    /// system module) must not hold the helper's only operation slot for ever:
    /// it is stopped and the operation restores as after any failed mount.
    static let timeout: TimeInterval = 300

    /// mount's own words without the BitLocker volume key it was given.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: "volisle-bde=[0-9A-Fa-f]+", with: "volisle-bde=…", options: .regularExpression)
    }

    static func run(_ arguments: [String], environment: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/launchctl"); process.arguments = arguments
            process.currentDirectoryURL = URL(filePath: "/")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { p in
                // Bounded: mount's diagnostics are a few lines.
                let text = redacted(String(decoding: (try? errors.fileHandleForReading.read(upToCount: 16384)) ?? Data(), as: UTF8.self))
                FileHandle.standardError.write(Data(text.utf8))
                if p.terminationStatus != 0 || p.terminationReason != .exit {
                    // mount's own words (no file names): which step of the system mount failed.
                    let lines = text.split(separator: "\n").suffix(3).joined(separator: " | ")
                    Logger(subsystem: "top.qisw.volisle.helper", category: "mount")
                        .error("mount 失败：状态=\(p.terminationStatus, privacy: .public) 输出=\(lines, privacy: .public)")
                }
                if p.terminationReason != .exit { continuation.resume(throwing: SystemMountError.commandInterrupted) }
                else if p.terminationStatus != 0 {
                    continuation.resume(throwing: HelperDiskFailure.mountRefusal(text) ?? SystemMountError.commandFailed(p.terminationStatus))
                }
                else { continuation.resume() }
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                Logger(subsystem: "top.qisw.volisle.helper", category: "mount").error("mount 超过 \(Int(timeout), privacy: .public) 秒未返回，已终止")
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

/// App side: identifies the partition independently, then asks the helper.
public enum HelperBitLockerClient {
    static let timeout: TimeInterval = 120

    public static func isBitLocker(partition bsdName: String) async throws -> Bool {
        let reply = try await send(try request(bsdName, kind: nil, secret: nil))
        guard let value = reply.isBitLocker else { throw HelperServiceError.invalidReply }
        return value
    }

    /// Returns where the volume is mounted and whether it came out writable.
    public static func unlock(partition bsdName: String, kind: BitLockerSecretKind, secret: String,
                              writable: Bool) async throws -> BitLockerUnlock {
        let reply = try await send(try request(bsdName, kind: kind, secret: secret, writable: writable))
        guard let path = reply.mountPath else { throw HelperServiceError.invalidReply }
        return BitLockerUnlock(url: URL(filePath: path, directoryHint: .isDirectory), writable: reply.writable == true,
                               readOnlyReason: reply.readOnlyReason)
    }

    private static func request(_ bsdName: String, kind: BitLockerSecretKind?, secret: String?,
                                writable: Bool = false) throws -> HelperBitLockerRequest {
        let metadata = try DeviceMetadata.read(bsdName)
        return try HelperBitLockerRequest(bsdName: bsdName, registryID: metadata.registryID, byteCount: metadata.byteCount,
                                          kind: kind, secret: secret, writable: writable)
    }

    private static func send(_ request: HelperBitLockerRequest) async throws -> HelperBitLockerReply {
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        let reply = try await HelperRPC.request(over: connection, timeout: timeout) { proxy, reply in
            proxy.bitLocker(data, reply: reply)
        }
        return try HelperBitLockerReply.decode(reply)
    }
}
