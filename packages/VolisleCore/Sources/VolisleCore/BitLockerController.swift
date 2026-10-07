import Foundation
import Observation

public enum BitLockerError: Error, Equatable, LocalizedError {
    case busy, invalidRecoveryKey, emptyPassword, lockFailed(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .busy: String(localized: "这块盘正在处理，请稍候。")
        case .invalidRecoveryKey: String(localized: "恢复密钥应为 48 位数字（8 组，每组 6 位），请核对是否有输错的数字。")
        case .emptyPassword: String(localized: "请输入密码。")
        case .lockFailed(let reason): String(localized: "无法锁定这块盘：\(reason)。请关闭正在使用盘内文件的应用后重试。")
        case .failed(let reason): reason
        }
    }
}

/// Locked BitLocker partitions and the ones unlocked in this session, and
/// whether each unlocked one is writable. macOS finds no file system in a BitLocker partition, so discovery
/// lists such Windows partitions as candidates and the root helper confirms
/// each once per connection. Disk Arbitration does not track the helper's
/// mount, so unlocked state comes from the live mount table.
@MainActor @Observable public final class BitLockerController {
    /// Candidate connection → whether the helper confirmed BitLocker.
    public private(set) var confirmed: [UUID: Bool] = [:]
    /// Partition → where it is mounted.
    public private(set) var unlocked: [String: URL] = [:]
    /// Unlocked partitions confirmed read-only by the kernel or the extension.
    public private(set) var readOnly: Set<String> = []
    /// An unconfirmed legacy mode or a mount left behind by a failed unlock.
    public private(set) var unverified: Set<String> = []
    /// Why a partition asked for writing came out read-only, until it is locked.
    public private(set) var readOnlyReasons: [String: HelperDiskFailure] = [:]
    public private(set) var working: Set<String> = []
    private var probing: Set<UUID> = []
    private let probe: @Sendable (String) async throws -> Bool
    private let unlockPartition: @Sendable (String, BitLockerSecretKind, String, Bool) async throws -> BitLockerUnlock
    private let runner: any EraseCommandRunner
    private let mounts: @Sendable () -> [(source: String, path: String, readOnly: Bool)]
    private let present: @Sendable (String) -> Bool
    private let mode: @Sendable (String) -> FSKitMountMode?
    private let ready: @Sendable (String) -> Bool
    private let kernelReportsReadOnly: Bool
    private var failedUnlockMounts: Set<String> = []
    private var modeRefresh: Task<Void, Never>?
    private var mountRefreshID: UInt64 = 0
    private var pendingModes: [(source: String, path: String, readOnly: Bool)] = []

    public init(probe: @escaping @Sendable (String) async throws -> Bool = { try await HelperBitLockerClient.isBitLocker(partition: $0) },
                unlock: @escaping @Sendable (String, BitLockerSecretKind, String, Bool) async throws -> BitLockerUnlock = {
                    try await HelperBitLockerClient.unlock(partition: $0, kind: $1, secret: $2, writable: $3) },
                runner: any EraseCommandRunner = ProcessEraseRunner(),
                mounts: @escaping @Sendable () -> [(source: String, path: String, readOnly: Bool)] = BitLockerController.systemMounts,
                present: @escaping @Sendable (String) -> Bool = BitLockerController.partitionPresent,
                mode: @escaping @Sendable (String) -> FSKitMountMode? = { FSKitMountMode.read(at: $0) },
                ready: @escaping @Sendable (String) -> Bool = { BitLockerMountPoint.isReady($0) },
                kernelReportsReadOnly: Bool = FSKitMountMode.kernelReportsReadOnly) {
        self.probe = probe; self.unlockPartition = unlock; self.runner = runner; self.mounts = mounts; self.present = present
        self.mode = mode; self.ready = ready; self.kernelReportsReadOnly = kernelReportsReadOnly
        refreshMounts()
    }

    public nonisolated static func systemMounts() -> [(source: String, path: String, readOnly: Bool)] {
        ((try? SystemMountRecord.current()) ?? []).filter { $0.type == "volisle" }
            .map { ($0.source, $0.path, $0.flags & UInt32(MNT_RDONLY) != 0) }
    }

    /// False only once the partition is gone from the I/O registry (unplugged).
    public nonisolated static func partitionPresent(_ bsdName: String) -> Bool {
        do { _ = try DeviceMetadata.read(bsdName); return true }
        catch VolumeError.disconnected { return false }
        catch { return true }
    }

    public func isBitLocker(_ volume: VolumeSnapshot) -> Bool {
        volume.isUnrecognizedWindows && (confirmed[volume.identity.connection] == true || unlocked[volume.bsdName] != nil)
    }
    public func mountURL(for volume: VolumeSnapshot) -> URL? { isBitLocker(volume) ? unlocked[volume.bsdName] : nil }
    public func isWritable(_ volume: VolumeSnapshot) -> Bool {
        mountURL(for: volume) != nil && !readOnly.contains(volume.bsdName) && !unverified.contains(volume.bsdName)
    }
    public func readOnlyReason(for volume: VolumeSnapshot) -> HelperDiskFailure? {
        mountURL(for: volume) != nil && readOnly.contains(volume.bsdName) ? readOnlyReasons[volume.bsdName] : nil
    }
    public func isWorking(_ volume: VolumeSnapshot) -> Bool { working.contains(volume.bsdName) }

    /// Asks the helper about candidates not asked yet on this connection. A
    /// failed question (helper not ready) is asked again on the next call.
    public func check(_ volumes: [VolumeSnapshot]) async {
        refreshMounts()
        for volume in volumes where volume.isUnrecognizedWindows && volume.isExternal && !volume.isProtected {
            let id = volume.identity.connection
            guard confirmed[id] == nil, !probing.contains(id), unlocked[volume.bsdName] == nil,
                  CheckMarkerClearer.applies(toPartition: volume.bsdName) else { continue }
            probing.insert(id)
            let answer = try? await probe(volume.bsdName)
            probing.remove(id)
            if let answer { confirmed[id] = answer }
        }
    }

    /// The helper checks the partition again; asked for writing, it mounts the
    /// volume writable when the extension's checks pass, read-only otherwise.
    public func unlock(_ volume: VolumeSnapshot, recoveryKey: Bool, secret: String,
                       writable: Bool = true) async throws(BitLockerError) -> BitLockerUnlock {
        guard isBitLocker(volume), !working.contains(volume.bsdName) else { throw .busy }
        let kind: BitLockerSecretKind = recoveryKey ? .recoveryKey : .password
        let value: String
        if recoveryKey {
            guard let key = BitLockerSecretKind.normalizedRecoveryKey(secret) else { throw .invalidRecoveryKey }
            value = key
        } else {
            guard !secret.isEmpty else { throw .emptyPassword }
            value = secret
        }
        working.insert(volume.bsdName)
        defer { working.remove(volume.bsdName) }
        let previousMount = unlocked[volume.bsdName]?.path
        do {
            let result = try await unlockPartition(volume.bsdName, kind, value, writable)
            readOnlyReasons[volume.bsdName] = result.readOnlyReason
            refreshMounts()
            unlocked[volume.bsdName] = result.url
            if !result.writable { readOnly.insert(volume.bsdName) }
            return result
        } catch {
            refreshMounts()
            if let path = unlocked[volume.bsdName]?.path, path != previousMount {
                failedUnlockMounts.insert(path)
                unverified.insert(volume.bsdName)
            }
            throw .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Unmounts the unlocked volume; the partition is locked again.
    public func lock(_ volume: VolumeSnapshot) async throws(BitLockerError) {
        refreshMounts()
        guard let url = unlocked[volume.bsdName] else { return }
        guard !working.contains(volume.bsdName) else { throw .busy }
        working.insert(volume.bsdName)
        defer { working.remove(volume.bsdName) }
        // Disk Arbitration does not know this mount ("diskutil unmount" fails);
        // it belongs to the user, so a plain unmount works.
        let result = await runner.run("/sbin/umount", [url.path])
        refreshMounts()
        if unlocked[volume.bsdName] == nil { readOnlyReasons[volume.bsdName] = nil }
        guard unlocked[volume.bsdName] == nil else {
            throw .lockFailed(result.output.split(separator: "\n").last.map(String.init) ?? String(localized: "未知错误"))
        }
    }

    /// A disk unplugged while unlocked leaves its mount behind: it never went
    /// through Disk Arbitration, so nothing removes it, and it holds the old
    /// device node. Force-unmount such mounts so the partition can be unlocked
    /// again once the disk is back (an interrupted write is rolled back then).
    public func removeDisconnected() async {
        refreshMounts()
        for (bsd, url) in unlocked where !working.contains(bsd) && !present(bsd) {
            _ = await runner.run("/sbin/umount", ["-f", url.path])
            readOnlyReasons[bsd] = nil
        }
        refreshMounts()
    }

    /// Call when any volume mounts or unmounts (e.g. ejected in Finder).
    public func refreshMounts() {
        mountRefreshID &+= 1
        var found: [String: URL] = [:]
        var foundReadOnly: Set<String> = []
        var foundUnverified: Set<String> = []
        var pending: [(source: String, path: String, readOnly: Bool)] = []
        for entry in mounts() where BitLockerMountPoint.owns(entry.path) && entry.source.hasPrefix("/dev/disk") {
            let bsd = String(entry.source.dropFirst(5))
            found[bsd] = URL(filePath: entry.path, directoryHint: .isDirectory)
            if failedUnlockMounts.contains(entry.path) {
                foundUnverified.insert(bsd)
                continue
            }
            if kernelReportsReadOnly {
                if entry.readOnly { foundReadOnly.insert(bsd) }
            }
            // The helper's persistent completion marker must be checked on
            // every kernel. Legacy systems also need the extension's mode.
            foundUnverified.insert(bsd)
            pending.append(entry)
        }
        if found != unlocked { unlocked = found }
        if foundReadOnly != readOnly { readOnly = foundReadOnly }
        if foundUnverified != unverified { unverified = foundUnverified }
        failedUnlockMounts.formIntersection(found.values.map(\.path))
        let reasons = readOnlyReasons.filter { found[$0.key] != nil || working.contains($0.key) }
        if reasons != readOnlyReasons { readOnlyReasons = reasons }
        pendingModes = pending
        refreshModes()
    }
    private func refreshModes() {
        // A synchronous FSKit call cannot be cancelled. Keep one query in
        // flight; changes invalidate its result and queue only the latest set.
        guard modeRefresh == nil, !pendingModes.isEmpty else { return }
        let refreshID = mountRefreshID, readMode = mode, isReady = ready, entries = pendingModes
        let kernelReportsReadOnly = kernelReportsReadOnly
        modeRefresh = Task { [weak self] in
            let modes = await Task.detached(priority: .utility) {
                entries.map { entry -> (ready: Bool, mode: FSKitMountMode?) in
                    guard isReady(entry.path) else { return (false, nil) }
                    let mode = readMode(entry.path)
                    return (isReady(entry.path), mode)
                }
            }.value
            guard let self else { return }
            self.modeRefresh = nil
            guard self.mountRefreshID == refreshID else { self.refreshModes(); return }
            let live = self.mounts()
            for (entry, actual) in zip(entries, modes) {
                let bsd = String(entry.source.dropFirst(5))
                guard self.unlocked[bsd]?.path == entry.path, !self.failedUnlockMounts.contains(entry.path),
                      self.present(bsd), live.contains(where: {
                          $0.source == entry.source && $0.path == entry.path && $0.readOnly == entry.readOnly
                      }) else { continue }
                guard actual.ready else { continue }
                if kernelReportsReadOnly {
                    guard actual.mode != .stopped,
                          actual.mode == nil || (actual.mode == .readOnly) == entry.readOnly else { continue }
                    self.unverified.remove(bsd); continue
                }
                switch actual.mode {
                case .readOnly:
                    self.readOnly.insert(bsd); self.unverified.remove(bsd)
                case .readWrite where !entry.readOnly:
                    self.readOnly.remove(bsd); self.unverified.remove(bsd)
                default: break // Missing, stopped or contradictory stays unverified.
                }
            }
        }
    }
}
