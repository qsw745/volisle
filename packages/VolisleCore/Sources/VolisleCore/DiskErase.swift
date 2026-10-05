import Foundation
import Observation

/// Erasing an external disk (or one partition) as NTFS in two steps: `diskutil`
/// writes a new partition map with one unformatted Windows data partition (GPT
/// Basic Data / MBR 0x07), then `newfs_fskit` has the Volisle extension's
/// `startFormat` write NTFS into it. `diskutil` itself only formats with the
/// file systems in /System/Library/Filesystems, not third-party FSKit modules.
/// A single partition keeps its type, so only Windows data partitions qualify.
/// Everything that decides *whether* a disk may be erased is pure and tested;
/// the executor re-reads the disk right before running and refuses on any change.

public enum PartitionScheme: String, Sendable, CaseIterable, Identifiable {
    case gpt = "GPT", mbr = "MBR"
    public var id: String { rawValue }
}

public enum EraseScope: Equatable, Sendable {
    case wholeDisk(PartitionScheme)
    case partition(String)
}

public struct ErasePartition: Equatable, Sendable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let name: String?
    public let content: String
    public let size: Int64
    public let mountPoint: String?
    public var isMacFormat: Bool { ["Apple_APFS", "Apple_HFS", "Apple_HFSX", "Apple_CoreStorage", "Apple_Boot"].contains(content) }
    /// Only partitions whose type already fits NTFS can be erased on their own
    /// (GPT Basic Data covers FAT and exFAT too); others need a whole-disk erase.
    public var isSelectable: Bool { DiskErasePlanner.dataContents.contains(content) }
}

public enum EraseRefusal: Equatable, Sendable {
    case internalDisk, notUSB, virtualDisk, systemDisk
    /// A Mac volume on this disk is mounted: eject it in Disk Utility first.
    case macVolumeMounted([String])
    public var message: String {
        switch self {
        case .internalDisk: String(localized: "不能抹掉内置磁盘。")
        case .notUSB: String(localized: "只能抹掉通过 USB 连接的外接磁盘。")
        case .virtualDisk: String(localized: "不能抹掉磁盘映像或虚拟磁盘。")
        case .systemDisk: String(localized: "这块磁盘上有 macOS 系统卷，不能抹掉。")
        case .macVolumeMounted(let names): String(localized: "这块磁盘上的 Mac 卷正在使用：\(names.joined(separator: String(localized: "、")))。请先在“磁盘工具”中推出这些卷。")
        }
    }
}

public struct EraseTarget: Equatable, Sendable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let model: String
    public let size: Int64
    public let blockSize: Int
    public let scheme: String
    public let partitions: [ErasePartition]
    /// Stable facts compared again right before erasing; a reconnected disk that
    /// reuses the BSD name does not match.
    public let fingerprint: String
    /// The same physical disk regardless of its partitions, to find it again
    /// after the partition map was rewritten.
    public let identity: String
    public let refusal: EraseRefusal?
    public var isEligible: Bool { refusal == nil }
    /// Mac-formatted content needs the user to type a name to confirm.
    public var hasMacContent: Bool { partitions.contains { $0.isMacFormat } }
}

public enum EraseNameError: Error, Equatable, Sendable, LocalizedError {
    case empty, tooLong, invalidCharacter
    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "请输入卷名。")
        case .tooLong: String(localized: "卷名最多 32 个字符。")
        case .invalidCharacter: String(localized: "卷名不能包含 \" * / : < > ? \\ | 等字符。")
        }
    }
}

public enum DiskErasePlanner {
    /// The extension's FSShortName, for `newfs_fskit -t`.
    public static let fileSystemType = "volisle"
    /// Partition types that hold NTFS. diskutil reports GPT Basic Data and
    /// MBR 0x07 by these names.
    public static let dataContents: Set<String> = ["Microsoft Basic Data", "Windows_NTFS"]
    private static let forbidden = CharacterSet(charactersIn: "\"*/:<>?\\|").union(.controlCharacters)

    /// Windows' NTFS label rule: 1–32 UTF-16 units, none of the reserved characters.
    public static func validate(name: String) throws(EraseNameError) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw .empty }
        guard name.utf16.count <= 32 else { throw .tooLong }
        guard name.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { throw .invalidCharacter }
    }

    /// New partition map with one unformatted, unmounted NTFS-type partition.
    public static func layoutArguments(target: EraseTarget, scheme: PartitionScheme) -> [String] {
        ["partitionDisk", target.bsdName, "1", scheme.rawValue, "%Windows_NTFS%", "%noformat%", "100%"]
    }

    /// The partition to write NTFS into after the layout step, or nil when the
    /// layout is not exactly what was asked for.
    public static func dataPartition(of target: EraseTarget, scope: EraseScope) -> String? {
        let data = target.partitions.filter { dataContents.contains($0.content) }
        switch scope {
        case .wholeDisk: return data.count == 1 ? data[0].bsdName : nil
        case .partition(let bsd): return data.contains { $0.bsdName == bsd } ? bsd : nil
        }
    }

    /// The name the user must type before erasing Mac content, else nil.
    public static func confirmationName(target: EraseTarget, scope: EraseScope) -> String? {
        let affected: [ErasePartition]
        switch scope {
        case .wholeDisk: affected = target.partitions
        case .partition(let bsd): affected = target.partitions.filter { $0.bsdName == bsd }
        }
        guard affected.contains(where: \.isMacFormat) else { return nil }
        return affected.first { $0.isMacFormat && ($0.name?.isEmpty == false) }?.name ?? target.model
    }

    /// Builds targets from `diskutil list -plist` (all disks) and `diskutil info -plist <disk>`.
    public static func catalog(list: [String: Any], info: (String) -> [String: Any]?) -> [EraseTarget] {
        let entries = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        // APFS containers are separate synthesized disks; map their mounted
        // volumes back to the physical partition that stores them.
        var containerMounts: [String: [String]] = [:]
        for entry in entries {
            guard let stores = entry["APFSPhysicalStores"] as? [[String: Any]] else { continue }
            let mounted = (entry["APFSVolumes"] as? [[String: Any]] ?? []).compactMap { volume -> String? in
                guard let mount = volume["MountPoint"] as? String, !mount.isEmpty else { return nil }
                return (volume["VolumeName"] as? String) ?? mount
            }
            for store in stores { if let id = store["DeviceIdentifier"] as? String { containerMounts[id, default: []] += mounted } }
        }
        var systemStores = Set<String>()
        for entry in entries {
            guard let stores = entry["APFSPhysicalStores"] as? [[String: Any]] else { continue }
            let isSystem = (entry["APFSVolumes"] as? [[String: Any]] ?? []).contains {
                let mount = $0["MountPoint"] as? String ?? ""
                return mount == "/" || mount.hasPrefix("/System/Volumes/")
            }
            if isSystem { for store in stores { if let id = store["DeviceIdentifier"] as? String { systemStores.insert(id) } } }
        }
        return entries.compactMap { entry -> EraseTarget? in
            guard let bsd = entry["DeviceIdentifier"] as? String, entry["APFSPhysicalStores"] == nil,
                  let details = info(bsd), details["WholeDisk"] as? Bool == true else { return nil }
            let partitions = (entry["Partitions"] as? [[String: Any]] ?? []).compactMap { p -> ErasePartition? in
                guard let id = p["DeviceIdentifier"] as? String else { return nil }
                return ErasePartition(bsdName: id, name: p["VolumeName"] as? String, content: p["Content"] as? String ?? "",
                                      size: (p["Size"] as? NSNumber)?.int64Value ?? 0, mountPoint: p["MountPoint"] as? String)
            }
            let ids = Set(partitions.map(\.bsdName))
            let macMounted = ids.sorted().flatMap { containerMounts[$0] ?? [] } +
                partitions.filter { $0.isMacFormat && $0.mountPoint != nil }.compactMap { $0.name ?? $0.mountPoint }
            let refusal: EraseRefusal? =
                details["Internal"] as? Bool != false ? .internalDisk :
                !ids.isDisjoint(with: systemStores) || partitions.contains { $0.mountPoint == "/" } ? .systemDisk :
                details["VirtualOrPhysical"] as? String != "Physical" ? .virtualDisk :
                details["BusProtocol"] as? String != "USB" ? .notUSB :
                macMounted.isEmpty ? nil : .macVolumeMounted(macMounted)
            let size = (details["Size"] as? NSNumber)?.int64Value ?? (entry["Size"] as? NSNumber)?.int64Value ?? 0
            let model = (details["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "外接设备")
            let layout = partitions.map { "\($0.bsdName):\($0.size)" }.joined(separator: ",")
            let identity = [bsd, model, details["IORegistryEntryName"] as? String ?? "", String(size)].joined(separator: "|")
            return EraseTarget(bsdName: bsd, model: model, size: size, blockSize: (details["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512,
                               scheme: entry["Content"] as? String ?? "", partitions: partitions,
                               fingerprint: identity + "|" + layout, identity: identity, refusal: refusal)
        }.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }
}

/// Runs a tool and returns its exit status and combined output.
public protocol EraseCommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)
}

public struct ProcessEraseRunner: EraseCommandRunner {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe
                do { try process.run() } catch { continuation.resume(returning: (-1, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

public enum EraseError: Error, Equatable, LocalizedError {
    case changed, refused(EraseRefusal), invalidName(EraseNameError), confirmationMismatch, failed(String)
    /// Erasing started but NTFS was not written: the partition may be unusable
    /// now, and erasing again is the way out.
    case formatFailed(String)
    public var errorDescription: String? {
        switch self {
        case .changed: String(localized: "磁盘已断开或发生变化，没有抹掉任何内容。请重新选择。")
        case .refused(let refusal): refusal.message
        case .invalidName(let error): error.errorDescription
        case .confirmationMismatch: String(localized: "输入的名称不一致，没有抹掉任何内容。")
        case .failed(let output): String(localized: "抹掉失败：\(output)")
        case .formatFailed(let reason): String(localized: "写入 NTFS 失败：\(reason)。这个分区可能已无法使用，请再抹掉一次。")
        }
    }
}

@MainActor @Observable public final class DiskEraser {
    public private(set) var targets: [EraseTarget] = []
    public private(set) var isWorking = false
    private let runner: any EraseCommandRunner
    private static let diskutil = "/usr/sbin/diskutil"

    private let unmountRetryDelay: Duration
    /// Writes NTFS into an unmounted partition. Needs root: the helper does it.
    public typealias PartitionFormatter = @Sendable (_ partition: String, _ label: String) async throws -> Void
    private let formatPartition: PartitionFormatter

    public init(runner: any EraseCommandRunner = ProcessEraseRunner(), unmountRetryDelay: Duration = .seconds(2),
                formatPartition: @escaping PartitionFormatter = { try await HelperFormatClient.format(partition: $0, label: $1) }) {
        self.runner = runner
        self.unmountRetryDelay = unmountRetryDelay
        self.formatPartition = formatPartition
    }

    public func refresh() async {
        targets = await loadCatalog()
    }

    private func loadCatalog() async -> [EraseTarget] {
        let listed = await runner.run(Self.diskutil, ["list", "-plist"])
        guard listed.status == 0, let list = Self.plist(listed.output) else { return [] }
        var infos: [String: [String: Any]] = [:]
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let bsd = entry["DeviceIdentifier"] as? String, entry["APFSPhysicalStores"] == nil else { continue }
            let result = await runner.run(Self.diskutil, ["info", "-plist", bsd])
            if result.status == 0, let info = Self.plist(result.output) { infos[bsd] = info }
        }
        return DiskErasePlanner.catalog(list: list, info: { infos[$0] })
    }

    /// Re-reads the disk, re-checks every rule and the typed confirmation, then
    /// erases. `prepare` ends Volisle's own write sessions on the device first.
    public func erase(_ target: EraseTarget, scope: EraseScope, name: String, typedConfirmation: String,
                      prepare: () async throws -> Void) async throws(EraseError) {
        guard !isWorking else { throw .failed(String(localized: "已有抹掉操作正在进行。")) }
        isWorking = true
        defer { isWorking = false }
        do { try DiskErasePlanner.validate(name: name) } catch { throw .invalidName(error) }
        let fresh = await loadCatalog()
        guard let current = fresh.first(where: { $0.bsdName == target.bsdName }), current.fingerprint == target.fingerprint else {
            targets = fresh; throw .changed
        }
        if let refusal = current.refusal { targets = fresh; throw .refused(refusal) }
        if case .partition(let bsd) = scope, current.partitions.first(where: { $0.bsdName == bsd })?.isSelectable != true { throw .changed }
        if let required = DiskErasePlanner.confirmationName(target: current, scope: scope), typedConfirmation != required {
            throw .confirmationMismatch
        }
        do { try await prepare() } catch { throw .failed(error.localizedDescription) }
        let partition: String
        switch scope {
        case .partition(let bsd):
            // Keeps its partition type; only an existing mount has to end first.
            if current.partitions.first(where: { $0.bsdName == bsd })?.mountPoint != nil, let reason = await unmount(bsd) {
                throw .failed(reason)
            }
            partition = bsd
        case .wholeDisk(let scheme):
            let layout = await runner.run(Self.diskutil, DiskErasePlanner.layoutArguments(target: current, scheme: scheme))
            guard layout.status == 0 else { targets = await loadCatalog(); throw .failed(Self.lastLine(layout.output)) }
            let laidOut = await loadCatalog()
            targets = laidOut
            // Write NTFS only into the partition just created on this same disk.
            guard let after = laidOut.first(where: { $0.bsdName == current.bsdName && $0.identity == current.identity }),
                  let found = DiskErasePlanner.dataPartition(of: after, scope: scope) else {
                throw .formatFailed(String(localized: "找不到刚建立的分区"))
            }
            if after.partitions.first(where: { $0.bsdName == found })?.mountPoint != nil, let reason = await unmount(found) {
                throw .formatFailed(reason)
            }
            partition = found
        }
        do { try await formatPartition(partition, name) } catch {
            targets = await loadCatalog()
            throw .formatFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        // Mounting hands the new volume to Volisle's usual read-write setup;
        // the disk is already formatted if this fails, so it is not an error.
        _ = await runner.run(Self.diskutil, ["mount", partition])
        targets = await loadCatalog()
    }

    /// Spotlight or another reader may briefly hold a volume: retry a few times.
    private func unmount(_ partition: String) async -> String? {
        var output = ""
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: unmountRetryDelay) }
            let result = await runner.run(Self.diskutil, ["unmount", partition])
            if result.status == 0 { return nil }
            output = result.output
        }
        return Self.lastLine(output)
    }

    private static func lastLine(_ output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? String(localized: "未知错误")
    }

    private static func plist(_ text: String) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)) as? [String: Any]
    }
}
