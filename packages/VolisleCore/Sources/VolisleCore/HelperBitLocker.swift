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
    /// typed with spaces, dashes or nothing in between.
    public static func normalizedRecoveryKey(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == 48, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return stride(from: 0, to: 48, by: 6).map { start in
            String(digits.dropFirst(start).prefix(6))
        }.joined(separator: "-")
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
        for base in [root, "/var/run/volisle-bitlocker"] {
            let prefix = base + "/"
            guard path.hasPrefix(prefix) else { continue }
            let name = path.dropFirst(prefix.count)
            return UUID(uuidString: String(name)) != nil && name == name.lowercased()
        }
        return false
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
        guard mkdir(path, 0o700) == 0, chown(path, uid, gid_t.max) == 0 else { throw HelperDiskFailure.unavailable }
        // The key is in mount's arguments for the moment it runs; the FSKit
        // module never logs options.
        let options = (writable ? "nosuid,nodev,volisle-rw" : "rdonly,nosuid,nodev") + ",volisle-bde=" + key
        let arguments = ["asuser", String(uid), "/sbin/mount", "-F", "-k", "-t", "volisle", "-o", options, device, path]
        do {
            try await HelperLaunchctl.run(arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "SUDO_UID": String(uid)])
        } catch {
            rmdir(path)
            throw error
        }
        let required = UInt32(writable ? MNT_NOSUID | MNT_NODEV : MNT_RDONLY | MNT_NOSUID | MNT_NODEV)
        let records = try SystemMountRecord.current().filter { $0.source == device || $0.path == path }
        guard records.count == 1, records[0].source == device, records[0].path == path,
              records[0].type == "volisle", records[0].flags & required == required else {
            throw VolumeError.mountNotVerified
        }
        return (path, records[0].flags & UInt32(MNT_RDONLY) == 0)
    }

    /// Root-owned, and emptied of directories left by earlier, since unmounted volumes.
    private static func prepareRoot() throws {
        let root = BitLockerMountPoint.root
        if mkdir(root, 0o711) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        var info = Darwin.stat()
        guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
              info.st_mode & 0o777 == 0o711 else { throw HelperDiskFailure.unavailable }
        let mounted = Set(try SystemMountRecord.current().map(\.path))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + name
            guard BitLockerMountPoint.owns(path), !mounted.contains(path) else { continue }
            rmdir(path)  // only ever removes an empty directory
        }
    }
}

/// `launchctl asuser …`: mount inside the requesting user's login context.
enum HelperLaunchctl {
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
                let text = String(decoding: (try? errors.fileHandleForReading.read(upToCount: 16384)) ?? Data(), as: UTF8.self)
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
            do { try process.run() } catch { continuation.resume(throwing: error) }
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
