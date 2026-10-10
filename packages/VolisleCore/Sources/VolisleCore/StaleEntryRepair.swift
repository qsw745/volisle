import CryptoKit
import Darwin
import Foundation
import Observation
import os

/// "Repair on This Mac" for one kind of damage only: folder entries that name
/// a file record by an older sequence number than it has now ("stale"). The
/// record was freed after the entry was written (and perhaps reused by another
/// file); the entry opens nothing. An index write lost to an unplug leaves
/// this, and "Check on This Mac" refuses the disk for it. The root helper
/// removes only those entries, saving what it overwrites first; everything
/// else is Windows' chkdsk's, and the user is told so before agreeing.
public struct StaleEntryExamination: Codable, Equatable, Sendable {
    public let markedForCheck: Bool
    /// Stale entries found (the helper stops listing at 8).
    public let staleEntries: Int
    /// MFT numbers of the folders holding them (no names cross XPC).
    public let folders: [UInt64]
    /// How many of the records they name now belong to another file or folder.
    public let reusedRecords: Int
    /// Every condition for removing them on the Mac holds.
    public let repairable: Bool
    public let checkedItems: Int64
    /// Why not, in CheckMarkerRefusal's fixed wording (numbers only).
    public let detail: String?
    /// A repair interrupted earlier left its undo record: the disk is put back
    /// as it was before that repair first.
    public let leftoverRestore: Bool

    public init(markedForCheck: Bool, staleEntries: Int, folders: [UInt64], reusedRecords: Int, repairable: Bool,
                checkedItems: Int64, detail: String? = nil, leftoverRestore: Bool = false) {
        self.markedForCheck = markedForCheck; self.staleEntries = staleEntries; self.folders = folders
        self.reusedRecords = reusedRecords; self.repairable = repairable; self.checkedItems = checkedItems
        self.detail = detail; self.leftoverRestore = leftoverRestore
    }
    func validate() throws {
        guard (0...8).contains(staleEntries), folders.count <= staleEntries, (0...staleEntries).contains(reusedRecords),
              !repairable || staleEntries > 0, checkedItems >= 0,
              detail.map({ CheckMarkerRefusal(.staleEntriesNotRepairable, detail: $0) != nil }) ?? true else {
            throw HelperServiceError.invalidReply
        }
    }
}

public struct StaleEntryRepairResult: Codable, Equatable, Sendable {
    /// Entries removed.
    public let removed: Int
    /// Files and folders checked afterwards.
    public let checkedItems: Int64
    /// Nothing was repaired this time: an earlier, interrupted repair was undone.
    public let restoredLeftover: Bool
    public init(removed: Int, checkedItems: Int64, restoredLeftover: Bool = false) {
        self.removed = removed; self.checkedItems = checkedItems; self.restoredLeftover = restoredLeftover
    }
}

/// What the helper reads from the volume to tell whether an undo record left
/// behind may still be put back.
public struct NTFSVolumeFacts: Equatable, Sendable {
    public let markedForCheck: Bool
    /// Where $LogFile's first bytes are.
    public let logOffset: Int64
    public let logLength: Int64
    public init(markedForCheck: Bool, logOffset: Int64, logLength: Int64) {
        self.markedForCheck = markedForCheck; self.logOffset = logOffset; self.logLength = logLength
    }
}

public extension PartitionMaintenanceEngine {
    func examineStaleEntries(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> StaleEntryExamination {
        throw HelperDiskFailure.unavailable
    }
    func repairStaleEntries(descriptor: Int32, blockSize: Int, byteCount: UInt64, undoFile: URL,
                            identity: PartitionUndoIdentity) throws -> StaleEntryRepairResult {
        throw HelperDiskFailure.unavailable
    }
    func volumeFacts(descriptor: Int32, blockSize: Int, byteCount: UInt64) throws -> NTFSVolumeFacts {
        throw HelperDiskFailure.unavailable
    }
}

/// Undo records an interruption left behind. A repair marks the volume "needs
/// check" before anything else and clears it with its very last write, so a
/// volume still marked (or that no longer even reads) was not finished, and
/// nothing mounts it for writing meanwhile — unless Windows did, which its
/// rewritten log head shows.
enum LeftoverUndo {
    enum Decision: Equatable {
        /// Put the volume back as it was before the interrupted change.
        case replay
        /// It no longer applies (finished, or mounted since): set the file aside.
        case obsolete
        /// Another volume's, or this one cannot be read now: leave the file.
        case keep
    }

    static func decide(_ identity: PartitionUndoIdentity, serial: UInt64?, byteCount: UInt64,
                       logDigest: Data?, markedForCheck: Bool?) -> Decision {
        guard let serial, serial == identity.serial, byteCount == identity.byteCount else { return .keep }
        guard let logDigest else { return .keep }
        guard logDigest == identity.logDigest else { return .obsolete }
        // Unreadable (nil) is a half-written state nothing else could mount.
        return markedForCheck == false ? .obsolete : .replay
    }

    /// Reads `length` bytes at `offset` through a raw device (whole blocks only).
    static func read(_ descriptor: Int32, offset: Int64, length: Int, blockSize: Int) -> Data? {
        guard offset >= 0, length > 0, length <= 1 << 20, blockSize > 0 else { return nil }
        let bs = Int64(blockSize)
        let start = offset / bs * bs, end = (offset + Int64(length) + bs - 1) / bs * bs
        let span = Int(end - start)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: span, alignment: blockSize)
        defer { buffer.deallocate() }
        var done = 0
        while done < span {
            let n = pread(descriptor, buffer.baseAddress! + done, span - done, off_t(start) + off_t(done))
            if n <= 0 { return nil }
            done += n
        }
        let from = Int(offset - start)
        return Data(buffer[from..<from + length])
    }

    static func serial(_ descriptor: Int32, blockSize: Int) -> UInt64? {
        guard let boot = read(descriptor, offset: 0, length: 512, blockSize: blockSize),
              boot[boot.startIndex + 3..<boot.startIndex + 11] == Data("NTFS    ".utf8) else { return nil }
        return boot.subdata(in: boot.startIndex + 0x48..<boot.startIndex + 0x50).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    static func identity(engine: any PartitionMaintenanceEngine, descriptor: Int32, blockSize: Int,
                         byteCount: UInt64) throws -> PartitionUndoIdentity {
        let facts = try engine.volumeFacts(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)
        guard let serial = serial(descriptor, blockSize: blockSize),
              let head = read(descriptor, offset: facts.logOffset, length: Int(facts.logLength), blockSize: blockSize) else {
            throw HelperDiskFailure.checkReadFailed
        }
        return PartitionUndoIdentity(serial: serial, byteCount: byteCount, logOffset: facts.logOffset,
                                     logLength: facts.logLength, logDigest: Data(SHA256.hash(data: head)))
    }

    private static func decision(for identity: PartitionUndoIdentity, engine: any PartitionMaintenanceEngine,
                                 descriptor: Int32, blockSize: Int, byteCount: UInt64) -> Decision {
        let head = read(descriptor, offset: identity.logOffset, length: Int(identity.logLength), blockSize: blockSize)
        let marked = (try? engine.volumeFacts(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount))?.markedForCheck
        return decide(identity, serial: serial(descriptor, blockSize: blockSize), byteCount: byteCount,
                      logDigest: head.map { Data(SHA256.hash(data: $0)) }, markedForCheck: marked)
    }

    private static func files(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "undo" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Read-only: whether `settle` would put this volume back.
    static func pending(engine: any PartitionMaintenanceEngine, descriptor: Int32, blockSize: Int, byteCount: UInt64,
                        directory: URL) -> Bool {
        files(in: directory).contains { url in
            guard let leftover = PartitionUndoLog.leftover(at: url) else { return false }
            return decision(for: leftover.identity, engine: engine, descriptor: descriptor, blockSize: blockSize, byteCount: byteCount) == .replay
        }
    }

    /// Before changing a volume: puts back what an interrupted change left for
    /// it, and sets aside records that no longer apply. Returns whether the
    /// volume was put back. Throws when putting it back failed (the file stays).
    static func settle(engine: any PartitionMaintenanceEngine, descriptor: Int32, blockSize: Int, byteCount: UInt64,
                       directory: URL, log: Logger) throws -> Bool {
        var restored = false
        for url in files(in: directory) {
            guard let leftover = PartitionUndoLog.leftover(at: url) else { continue }
            switch decision(for: leftover.identity, engine: engine, descriptor: descriptor, blockSize: blockSize, byteCount: byteCount) {
            case .keep:
                continue
            case .obsolete:
                _ = rename(url.path, url.path + ".obsolete")
                log.notice("遗留撤销记录已不适用，已留存不回放：\(url.lastPathComponent, privacy: .public)")
            case .replay:
                guard PartitionUndoLog.write(leftover.entries, to: descriptor, limit: byteCount),
                      (try? engine.volumeFacts(descriptor: descriptor, blockSize: blockSize, byteCount: byteCount)) != nil else {
                    log.fault("遗留撤销记录回放失败，记录保留：\(url.lastPathComponent, privacy: .public)")
                    throw HelperDiskFailure.staleEntriesRestoreFailed
                }
                unlink(url.path)
                restored = true
                log.notice("已按遗留撤销记录还原 \(leftover.entries.count, privacy: .public) 处：\(url.lastPathComponent, privacy: .public)")
            }
        }
        return restored
    }
}

/// Root side, through the same verified raw partition as the other maintenance.
extension HelperPartitionFormatter {
    private static let staleLog = Logger(subsystem: "top.qisw.volisle", category: "stale-entries")

    static func examineStaleEntries(_ input: HelperDiskRequest) async throws -> StaleEntryExamination {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard request.version == 1 else { throw HelperServiceError.invalidRequest }
        let directory = undoDirectory
        let found: StaleEntryExamination = try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount,
                                                    writable: false) { engine, descriptor, blockSize in
            let leftover = LeftoverUndo.pending(engine: engine, descriptor: descriptor, blockSize: blockSize,
                                                byteCount: request.byteCount, directory: directory)
            // A half-done repair is put back before anything is judged.
            if leftover {
                return StaleEntryExamination(markedForCheck: true, staleEntries: 0, folders: [], reusedRecords: 0, repairable: false,
                                             checkedItems: 0, leftoverRestore: true)
            }
            return try engine.examineStaleEntries(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount)
        }
        staleLog.notice("""
            失效条目研判：设备=\(request.bsdName, privacy: .public) 条目=\(found.staleEntries, privacy: .public) \
            可修=\(found.repairable, privacy: .public) 遗留=\(found.leftoverRestore, privacy: .public) \
            原因=\(found.detail ?? "", privacy: .public)
            """)
        return found
    }

    static func repairStaleEntries(_ input: HelperDiskRequest) async throws -> StaleEntryRepairResult {
        let request = try HelperDiskRequest.decode(JSONEncoder().encode(input))
        guard request.version == 1 else { throw HelperServiceError.invalidRequest }
        guard geteuid() == 0 else { throw HelperServiceError.wrongPrivileges }
        for path in [undoDirectory.deletingLastPathComponent().path, undoDirectory.path] {
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        }
        let directory = undoDirectory
        let undo = directory.appending(path: "\(request.bsdName)-\(request.registryID)-\(Int(Date().timeIntervalSince1970))-repair.undo")
        let started = Date()
        let log = staleLog
        let result: StaleEntryRepairResult = try await withVerifiedPartition(request.bsdName, registryID: request.registryID, byteCount: request.byteCount) {
            engine, descriptor, blockSize in
            if try LeftoverUndo.settle(engine: engine, descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount,
                                       directory: directory, log: log) {
                return StaleEntryRepairResult(removed: 0, checkedItems: 0, restoredLeftover: true)
            }
            let identity = try LeftoverUndo.identity(engine: engine, descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount)
            return try engine.repairStaleEntries(descriptor: descriptor, blockSize: blockSize, byteCount: request.byteCount,
                                                 undoFile: undo, identity: identity)
        }
        staleLog.notice("""
            失效条目已处理：设备=\(request.bsdName, privacy: .public) 删除=\(result.removed, privacy: .public) \
            检查=\(result.checkedItems, privacy: .public) 还原遗留=\(result.restoredLeftover, privacy: .public) \
            用时=\(Int(Date().timeIntervalSince(started)), privacy: .public)s
            """)
        return result
    }
}

struct HelperStaleEntryReply: Codable, Sendable {
    var examination: StaleEntryExamination? = nil
    var result: StaleEntryRepairResult? = nil
    var failure: HelperDiskFailure? = nil
    var detail: String? = nil

    static func decodeExamination(_ data: Data) throws -> StaleEntryExamination {
        let value = try decode(data)
        guard let examination = value.examination, value.result == nil else { throw HelperServiceError.invalidReply }
        try examination.validate()
        return examination
    }
    static func decodeResult(_ data: Data) throws -> StaleEntryRepairResult {
        let value = try decode(data)
        guard let result = value.result, value.examination == nil, (0...8).contains(result.removed), result.checkedItems >= 0,
              !(result.restoredLeftover && result.removed > 0) else { throw HelperServiceError.invalidReply }
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
public enum HelperStaleEntryClient {
    /// Both read every file record; the repair reads them twice.
    static let timeout: TimeInterval = 3600

    public static func examine(partition bsdName: String) async throws -> StaleEntryExamination {
        try HelperStaleEntryReply.decodeExamination(await call(bsdName) { proxy, data, reply in proxy.examineStaleEntries(data, reply: reply) })
    }
    public static func repair(partition bsdName: String) async throws -> StaleEntryRepairResult {
        try HelperStaleEntryReply.decodeResult(await call(bsdName) { proxy, data, reply in proxy.repairStaleEntries(data, reply: reply) })
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

/// The App's side of the flow: unmount, examine, (user agrees), repair, mount
/// again whatever happened. Like "Recover on This Mac".
@MainActor @Observable public final class StaleEntryRepairer {
    public enum Phase: Equatable { case idle, examining, repairing }
    public private(set) var phase: Phase = .idle
    public var isWorking: Bool { phase != .idle }
    private let runner: any EraseCommandRunner
    private let isMounted: @Sendable (String) -> Bool
    private let examineCall: @Sendable (String) async throws -> StaleEntryExamination
    private let repairCall: @Sendable (String) async throws -> StaleEntryRepairResult
    private let retryDelay: Duration
    private static let diskutil = "/usr/sbin/diskutil"

    public init(runner: any EraseCommandRunner = ProcessEraseRunner(), retryDelay: Duration = .seconds(2),
                isMounted: @escaping @Sendable (String) -> Bool = CheckMarkerClearer.systemMounted,
                examine: @escaping @Sendable (String) async throws -> StaleEntryExamination = { try await HelperStaleEntryClient.examine(partition: $0) },
                repair: @escaping @Sendable (String) async throws -> StaleEntryRepairResult = { try await HelperStaleEntryClient.repair(partition: $0) }) {
        self.runner = runner; self.retryDelay = retryDelay; self.isMounted = isMounted
        self.examineCall = examine; self.repairCall = repair
    }

    /// Read-only. The disk is mounted again afterwards.
    public func examine(partition bsd: String) async throws(CheckMarkerError) -> StaleEntryExamination {
        try await unmounted(bsd, phase: .examining) { try await self.examineCall(bsd) }
    }

    /// Only with the user's explicit agreement; the helper examines the disk
    /// again itself and refuses anything but stale entries it may remove.
    public func repair(partition bsd: String, accepted: Bool) async throws(CheckMarkerError) -> StaleEntryRepairResult {
        guard accepted else { throw .failed(String(localized: "需要先确认删除这些失效条目。")) }
        return try await unmounted(bsd, phase: .repairing) { try await self.repairCall(bsd) }
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
