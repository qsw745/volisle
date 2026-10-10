import Foundation
import Observation

/// The Mac-side answer to a disk that is read-only only because NTFS marks it
/// "needs check" (for people without a Windows PC). The root helper walks the
/// whole volume read-only and clears that one flag only if nothing fails; it is
/// not chkdsk, and the confirmation says so.
public enum CheckMarkerError: Error, Equatable, LocalizedError {
    case unsupported, unmountFailed(String), failed(String)
    /// The check found only what "Repair on This Mac" may be able to remove:
    /// stale folder entries. Nothing was changed. Carries the technical detail.
    case staleEntries(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "只能检查外接磁盘上的 NTFS 分区。")
        case .unmountFailed(let reason): String(localized: "无法卸载这块盘，没有做任何修改：\(reason)。请关闭正在使用盘内文件的应用后重试。")
        case .failed(let reason): reason
        case .staleEntries(let detail):
            String(localized: "检查发现这块盘的文件夹里有已经打不开的条目（失效的目录条目），没有做任何修改。盘里的文件仍可以只读打开和拷出。") + "\n" + String(localized: "技术信息：\(detail)")
        }
    }
}

@MainActor @Observable public final class CheckMarkerClearer {
    public private(set) var isWorking = false
    private let runner: any EraseCommandRunner
    private let clear: @Sendable (String) async throws -> Int64
    private let retryDelay: Duration
    private let isMounted: @Sendable (String) -> Bool
    private static let diskutil = "/usr/sbin/diskutil"

    public init(runner: any EraseCommandRunner = ProcessEraseRunner(), retryDelay: Duration = .seconds(2),
                isMounted: @escaping @Sendable (String) -> Bool = CheckMarkerClearer.systemMounted,
                clear: @escaping @Sendable (String) async throws -> Int64 = { try await HelperCheckMarkerClient.clear(partition: $0) }) {
        self.runner = runner; self.retryDelay = retryDelay; self.isMounted = isMounted; self.clear = clear
    }

    /// Only the partition name comes from the UI; the helper independently
    /// checks it is an external USB NTFS partition of the same identity.
    public static func applies(toPartition bsdName: String) -> Bool {
        bsdName.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil
    }

    public static func applies(to volume: VolumeSnapshot) -> Bool {
        volume.isExternal && !volume.isProtected && volume.isNTFS && applies(toPartition: volume.bsdName)
    }

    /// Read from the live mount table, not from a possibly stale disk list.
    public nonisolated static func systemMounted(_ bsdName: String) -> Bool {
        (try? SystemMountRecord.current().contains { $0.source == "/dev/" + bsdName }) ?? true
    }

    /// Unmounts, checks and clears, then mounts the partition again whatever
    /// the outcome. Returns the files and folders checked (0: it was not marked).
    public func run(partition bsd: String) async throws(CheckMarkerError) -> Int64 {
        guard Self.applies(toPartition: bsd) else { throw .unsupported }
        guard !isWorking else { throw .failed(String(localized: "已有检查正在进行。")) }
        isWorking = true
        defer { isWorking = false }
        if isMounted(bsd), let reason = await unmount(bsd) { throw .unmountFailed(reason) }
        let result: Result<Int64, any Error>
        do { result = .success(try await clear(bsd)) } catch { result = .failure(error) }
        _ = await runner.run(Self.diskutil, ["mount", bsd])
        switch result {
        case .success(let items): return items
        case .failure(let refusal as CheckMarkerRefusal) where refusal.isStaleEntry: throw .staleEntries(refusal.detail)
        case .failure(let error): throw .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Spotlight or another reader may briefly hold the volume: retry a few times.
    private func unmount(_ bsd: String) async -> String? {
        var output = ""
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: retryDelay) }
            let result = await runner.run(Self.diskutil, ["unmount", bsd])
            if result.status == 0 { return nil }
            output = result.output
        }
        return output.split(separator: "\n").last.map(String.init) ?? String(localized: "未知错误")
    }
}
