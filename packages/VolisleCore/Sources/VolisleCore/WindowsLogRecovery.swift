import Foundation
import Observation
import os

/// A disk Windows let go of without Safe Removal: its NTFS log still says "in
/// use" and may hold changes Windows had confirmed but not yet written into
/// place. Windows replays them on its next mount; the root helper can do the
/// same on this Mac (NTFS-3G's ntfsrecover), then checks every record.
///
/// The disk alone cannot tell an unplug from Windows' fast startup or
/// hibernation with the disk attached: both leave the same log. Fast startup
/// keeps part of the changes only in that Windows' memory image, so replaying
/// here would lose them. The user's answer decides; the helper refuses anything
/// the disk itself shows to be something else.
public struct WindowsLogExamination: Codable, Equatable, Sendable {
    /// The "needs check" flag: Windows saw a problem, not just an unplug.
    public let markedForCheck: Bool
    /// chkdsk cut off, a log resize, an upgrade: only Windows may finish it.
    public let maintenancePending: Bool
    /// A hibernation file on this volume says Windows is hibernated.
    public let hibernated: Bool
    public let logReadable: Bool
    public let logClean: Bool
    /// The log's restart page version; Windows 8 and later write 2.0 while in use.
    public let logVersion: String
    /// The replay ran to the end in simulation, writing nothing.
    public let replaySimulated: Bool
    /// Changes Windows had confirmed that are not in place yet.
    public let pendingChanges: Int64
    /// ntfsrecover's last status lines (counts and block numbers, no names):
    /// shown as technical information when the replay cannot go ahead.
    public let detail: String?
    /// When the replay cannot run: whether the read-only check that giving the
    /// log up rests on ran and passed (every record reachable and in use,
    /// nothing in use marked free), how much it checked, and why it failed.
    public let discardChecked: Bool
    public let discardPassed: Bool
    public let checkedItems: Int64
    public let discardDetail: String?
    /// Space marked used that no file uses (Windows reserved it for changes it
    /// never wrote): harmless, only held until Windows checks the disk.
    public let heldBytes: Int64

    public init(markedForCheck: Bool, maintenancePending: Bool, hibernated: Bool, logReadable: Bool, logClean: Bool,
                logVersion: String, replaySimulated: Bool, pendingChanges: Int64, detail: String? = nil,
                discardChecked: Bool = false, discardPassed: Bool = false, checkedItems: Int64 = 0, discardDetail: String? = nil,
                heldBytes: Int64 = 0) {
        self.markedForCheck = markedForCheck; self.maintenancePending = maintenancePending; self.hibernated = hibernated
        self.logReadable = logReadable; self.logClean = logClean; self.logVersion = logVersion
        self.replaySimulated = replaySimulated; self.pendingChanges = pendingChanges; self.detail = detail
        self.discardChecked = discardChecked; self.discardPassed = discardPassed
        self.checkedItems = checkedItems; self.discardDetail = discardDetail; self.heldBytes = heldBytes
    }

    /// The disk shows something other than an unplug.
    private var diskRefusal: HelperDiskFailure? {
        if hibernated { return .windowsHibernated }
        if maintenancePending { return .windowsMaintenancePending }
        if markedForCheck { return .ntfsDirty }
        return nil
    }
    /// The log replays as Windows would.
    public var replayable: Bool { diskRefusal == nil && !logClean && logReadable && replaySimulated }
    /// The log does not replay, but the disk holds together without it.
    public var discardable: Bool { diskRefusal == nil && !logClean && !replayable && discardChecked && discardPassed }
    /// Why nothing may be done on the Mac, whatever the user answers; nil when
    /// one way fits an unplug (or the log is already complete).
    public var refusal: HelperDiskFailure? {
        if let diskRefusal { return diskRefusal }
        if logClean || replayable || discardable { return nil }
        return discardChecked ? .checkFoundProblems : .windowsLogUnreadable
    }
    /// Everything the disk shows fits "unplugged while Windows was running".
    public var fitsUnplug: Bool { replayable || discardable }

    func validate() throws {
        guard pendingChanges >= 0, pendingChanges < 100_000_000,
              logVersion.wholeMatch(of: /[0-9]{1,2}\.[0-9]{1,2}/) != nil,
              (detail?.count ?? 0) <= 300, (discardDetail?.count ?? 0) <= 200,
              checkedItems >= 0, heldBytes >= 0 else { throw HelperServiceError.invalidReply }
    }
}

/// What the replay did.
public struct WindowsLogRecoveryResult: Codable, Equatable, Sendable {
    /// Confirmed changes written into place.
    public let replayed: Int64
    /// Files and folders whose records were checked afterwards.
    public let checkedItems: Int64
    /// The log was given up instead of replayed.
    public let discarded: Bool
    /// Space left marked used that no file uses (see WindowsLogExamination.heldBytes).
    public let heldBytes: Int64
    public init(replayed: Int64, checkedItems: Int64, discarded: Bool = false, heldBytes: Int64 = 0) {
        self.replayed = replayed; self.checkedItems = checkedItems; self.discarded = discarded; self.heldBytes = heldBytes
    }
}

public extension PartitionMaintenanceEngine {
    func examineWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> WindowsLogExamination {
        throw HelperDiskFailure.unavailable
    }
    func recoverWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
        throw HelperDiskFailure.unavailable
    }
    func discardWindowsLog(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL) throws -> WindowsLogRecoveryResult {
        throw HelperDiskFailure.unavailable
    }
}

/// Root side, through the same verified raw partition as formatting.
extension HelperPartitionFormatter {
    private static let windowsLog = Logger(subsystem: "top.qisw.volisle", category: "windows-log")
    /// Before-images of everything the replay writes, kept until the result is
    /// verified (and only then removed). Root only, like the mount records.
    static let undoDirectory = URL(filePath: "/private/var/db/volisle/windows-log-undo")

    static func examineWindowsLog(_ input: HelperDiskRequest) async throws -> WindowsLogExamination {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard request.version == 1 else { throw HelperServiceError.invalidRequest }
        let result = try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount,
                                                     writable: false) { engine, descriptor, blockSize in
            try engine.examineWindowsLog(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount)
        }
        windowsLog.notice("""
            Windows 日志研判：设备=\(request.bsdName, privacy: .public) 版本=\(result.logVersion, privacy: .public) \
            干净=\(result.logClean, privacy: .public) 可读=\(result.logReadable, privacy: .public) \
            模拟=\(result.replaySimulated, privacy: .public) 待补写=\(result.pendingChanges, privacy: .public) \
            需要检查=\(result.markedForCheck, privacy: .public) 休眠=\(result.hibernated, privacy: .public) \
            维护=\(result.maintenancePending, privacy: .public) 输出=\(result.detail ?? "", privacy: .public)
            """)
        return result
    }

    static func recoverWindowsLog(_ input: HelperDiskRequest, discard: Bool = false) async throws -> WindowsLogRecoveryResult {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard request.version == 1 else { throw HelperServiceError.invalidRequest }
        guard geteuid() == 0 else { throw HelperServiceError.wrongPrivileges }
        for path in [undoDirectory.deletingLastPathComponent().path, undoDirectory.path] {
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let undo = undoDirectory.appending(path: "\(request.bsdName)-\(request.registryID)-\(stamp).undo")
        let started = Date()
        let result = try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount) {
            engine, descriptor, blockSize in
            discard
                ? try engine.discardWindowsLog(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount, undoFile: undo)
                : try engine.recoverWindowsLog(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount, undoFile: undo)
        }
        windowsLog.notice("""
            Windows 日志已\(discard ? "放弃" : "补写", privacy: .public)：设备=\(request.bsdName, privacy: .public) 补写=\(result.replayed, privacy: .public) \
            检查=\(result.checkedItems, privacy: .public) 用时=\(Int(Date().timeIntervalSince(started)), privacy: .public)s
            """)
        return result
    }
}

struct HelperWindowsLogReply: Codable, Sendable {
    var examination: WindowsLogExamination? = nil
    var result: WindowsLogRecoveryResult? = nil
    var failure: HelperDiskFailure? = nil
    var detail: String? = nil

    static func decodeExamination(_ data: Data) throws -> WindowsLogExamination {
        let value = try decode(data)
        guard let examination = value.examination, value.result == nil else { throw HelperServiceError.invalidReply }
        try examination.validate()
        return examination
    }
    static func decodeResult(_ data: Data) throws -> WindowsLogRecoveryResult {
        let value = try decode(data)
        guard let result = value.result, value.examination == nil,
              result.replayed >= 0, result.checkedItems >= 0 else { throw HelperServiceError.invalidReply }
        return result
    }
    private static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HelperServiceError.invalidReply }
        let value = try JSONDecoder().decode(Self.self, from: data)
        if let failure = value.failure {
            guard value.examination == nil, value.result == nil else { throw HelperServiceError.invalidReply }
            throw CheckMarkerRefusal(failure, detail: value.detail) ?? failure
        }
        return value
    }
}

/// App side: identifies the partition independently, then asks the helper.
public enum HelperWindowsLogClient {
    /// The examination replays in simulation; the recovery also reads every record.
    static let timeout: TimeInterval = 1800

    public static func examine(partition bsdName: String) async throws -> WindowsLogExamination {
        try HelperWindowsLogReply.decodeExamination(await call(bsdName) { proxy, data, reply in proxy.examineWindowsLog(data, reply: reply) })
    }
    public static func recover(partition bsdName: String) async throws -> WindowsLogRecoveryResult {
        try HelperWindowsLogReply.decodeResult(await call(bsdName) { proxy, data, reply in proxy.recoverWindowsLog(data, reply: reply) })
    }
    public static func discard(partition bsdName: String) async throws -> WindowsLogRecoveryResult {
        try HelperWindowsLogReply.decodeResult(await call(bsdName) { proxy, data, reply in proxy.discardWindowsLog(data, reply: reply) })
    }
    private static func call(_ bsdName: String,
                             _ body: @escaping @Sendable (any VolisleHelperProtocol, Data, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        let metadata = try DeviceMetadata.read(bsdName)
        let request = try HelperDiskRequest(bsdName: bsdName, registryID: metadata.registryID, byteCount: metadata.byteCount)
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        return try await HelperRPC.request(over: connection, timeout: timeout) { proxy, reply in body(proxy, data, reply) }
    }
}

/// How the disk left Windows, as the user remembers it.
public enum WindowsUnplugAnswer: String, CaseIterable, Sendable {
    /// Windows was running and the disk was pulled without Safe Removal.
    case whileRunning
    /// Shut down, restarted or put to sleep first: with fast startup (on by
    /// default) Windows may still hold part of the changes.
    case afterShutdown
    case unsure
}

/// The App's side of the flow: unmount, examine, (user answers), recover,
/// mount again whatever happened. Like "Check on This Mac".
@MainActor @Observable public final class WindowsLogRecoverer {
    public enum Phase: Equatable { case idle, examining, recovering }
    public private(set) var phase: Phase = .idle
    public var isWorking: Bool { phase != .idle }
    private let runner: any EraseCommandRunner
    private let isMounted: @Sendable (String) -> Bool
    private let examineCall: @Sendable (String) async throws -> WindowsLogExamination
    private let recoverCall: @Sendable (String) async throws -> WindowsLogRecoveryResult
    private let discardCall: @Sendable (String) async throws -> WindowsLogRecoveryResult
    private let retryDelay: Duration
    private static let diskutil = "/usr/sbin/diskutil"

    public init(runner: any EraseCommandRunner = ProcessEraseRunner(), retryDelay: Duration = .seconds(2),
                isMounted: @escaping @Sendable (String) -> Bool = CheckMarkerClearer.systemMounted,
                examine: @escaping @Sendable (String) async throws -> WindowsLogExamination = { try await HelperWindowsLogClient.examine(partition: $0) },
                recover: @escaping @Sendable (String) async throws -> WindowsLogRecoveryResult = { try await HelperWindowsLogClient.recover(partition: $0) },
                discard: @escaping @Sendable (String) async throws -> WindowsLogRecoveryResult = { try await HelperWindowsLogClient.discard(partition: $0) }) {
        self.runner = runner; self.retryDelay = retryDelay; self.isMounted = isMounted
        self.examineCall = examine; self.recoverCall = recover; self.discardCall = discard
    }

    /// Read-only. The disk is mounted again afterwards.
    public func examine(partition bsd: String) async throws(CheckMarkerError) -> WindowsLogExamination {
        try await unmounted(bsd, phase: .examining) { try await self.examineCall(bsd) }
    }

    /// Only with the answer "while running": anything else is refused here
    /// before the helper is asked, and the helper examines the disk again itself.
    public func recover(partition bsd: String, answer: WindowsUnplugAnswer) async throws(CheckMarkerError) -> WindowsLogRecoveryResult {
        guard answer == .whileRunning else {
            throw .failed(String(localized: "只有在 Windows 开着机时直接拔下的盘，才能在 Mac 上补写。请把盘接回那台 Windows 开机，用“安全删除硬件”弹出后再插回。"))
        }
        return try await unmounted(bsd, phase: .recovering) { try await self.recoverCall(bsd) }
    }

    /// When the log does not replay: gives it up, only after the same answer
    /// and the user's explicit agreement that Windows' unfinished changes go.
    public func discard(partition bsd: String, answer: WindowsUnplugAnswer, accepted: Bool) async throws(CheckMarkerError) -> WindowsLogRecoveryResult {
        guard answer == .whileRunning else {
            throw .failed(String(localized: "只有在 Windows 开着机时直接拔下的盘，才能在 Mac 上补写。请把盘接回那台 Windows 开机，用“安全删除硬件”弹出后再插回。"))
        }
        guard accepted else { throw .failed(String(localized: "需要先确认放弃 Windows 没写完的改动。")) }
        return try await unmounted(bsd, phase: .recovering) { try await self.discardCall(bsd) }
    }

    private func unmounted<T: Sendable>(_ bsd: String, phase: Phase, _ body: @escaping @Sendable () async throws -> T) async throws(CheckMarkerError) -> T {
        guard CheckMarkerClearer.applies(toPartition: bsd) else { throw .unsupported }
        guard !isWorking else { throw .failed(String(localized: "已有操作正在进行。")) }
        self.phase = phase
        defer { self.phase = .idle }
        if isMounted(bsd), let reason = await unmount(bsd) { throw .unmountFailed(reason) }
        let result: Result<T, any Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        // No answer in time: the helper may still be writing. Mounting now would
        // put the file system on top of it; leave the disk unmounted.
        if case .failure(let error) = result, error as? HelperServiceError == .timedOut {
            throw .failed(String(localized: "后台组件还在处理这块盘，请不要拔下它。等几分钟后在盘屿里点“刷新”；仍然没有挂上时，拔下后重新插入。"))
        }
        _ = await runner.run(Self.diskutil, ["mount", bsd])
        switch result {
        case .success(let value): return value
        case .failure(let error): throw .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

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
