import Foundation
import Darwin
import os

/// One copy onto an NTFS disk that survives unplugging. The plan (what to copy,
/// in order) is written once; the progress is a small separate record. When the
/// disk comes back the destination is compared with the source rather than
/// trusted: reconnecting rolls the disk back about 20 seconds.
public struct CopyPlan: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case directory, file, symlink }
        /// Absolute path on the Mac.
        public let source: String
        /// Below the destination folder, "/"-separated, starting with the selected item's name.
        public let relative: String
        public let kind: Kind
        public let size: Int64
    }
    public let id: UUID
    /// The disk partition across reconnections (VolumeIdentity.resumeKey).
    public let diskKey: String
    public let volumeName: String
    /// The folder on the disk, relative to its root ("" is the root).
    public let destination: String
    public let items: [Item]
    public let totalBytes: Int64
    public let created: Date

    /// Each folder comes before its contents. Anything that cannot be read is
    /// reported now rather than silently left out of a copy that says "done".
    public static func make(sources: [URL], diskKey: String, volumeName: String, destination: String) throws -> CopyPlan {
        var items: [Item] = []
        var names = Set<String>()
        for source in sources {
            let base = source.standardizedFileURL
            let name = base.lastPathComponent
            // Two selected items with one name would overwrite each other on the disk.
            guard names.insert(name.lowercased()).inserted else { throw CopyError.duplicateName(name) }
            guard let kind = kind(of: base.path) else { throw CopyError.source(base.path, errno == 0 ? ENOENT : errno) }
            items.append(Item(source: base.path, relative: name, kind: kind, size: kind == .file ? size(of: base.path) : 0))
            guard kind == .directory else { continue }
            let failure = Failure()
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
                failure.record(url.path, ResumableCopier.code(error)); return false
            }) else { throw CopyError.source(base.path, EIO) }
            // Names by depth, not by cutting a prefix off: the walk may spell the
            // folder differently (/private/var for /var).
            var folders: [String] = []
            for case let url as URL in walker {
                let path = url.path
                folders.removeLast(max(0, folders.count - (walker.level - 1)))
                let relative = ([name] + folders + [url.lastPathComponent]).joined(separator: "/")
                guard let childKind = Self.kind(of: path) else {
                    if errno == ENOENT { continue }  // removed while listing
                    throw CopyError.source(path, errno)
                }
                if childKind == .directory, access(path, R_OK | X_OK) != 0 { throw CopyError.source(path, errno) }
                items.append(Item(source: path, relative: relative, kind: childKind, size: childKind == .file ? size(of: path) : 0))
                if childKind == .directory { folders.append(url.lastPathComponent) }
            }
            if let (path, code) = failure.first { throw CopyError.source(path, code) }
        }
        guard !items.isEmpty else { throw CopyError.nothingToCopy }
        var total: Int64 = 0
        for item in items {
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            guard !overflow else { throw CopyError.invalidPlan }
            total = sum
        }
        let plan = CopyPlan(id: UUID(), diskKey: diskKey, volumeName: volumeName, destination: destination,
                            items: items, totalBytes: total, created: Date())
        try plan.validate()
        return plan
    }

    /// Paths stay below the destination and never pass through a copied link,
    /// whatever the record on disk says; the sizes add up.
    func validate() throws {
        guard !diskKey.isEmpty, destination.isEmpty || Self.safe(destination) else { throw CopyError.invalidPlan }
        var links = Set<String>()
        var total: Int64 = 0
        for item in items {
            guard Self.safe(item.relative), item.source.hasPrefix("/"),
                  item.size >= 0, item.size <= 1 << 50 else { throw CopyError.invalidPlan }
            var parent = (item.relative as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if links.contains(parent) { throw CopyError.invalidPlan }
                parent = (parent as NSString).deletingLastPathComponent
            }
            if item.kind == .symlink { links.insert(item.relative) }
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            guard !overflow else { throw CopyError.invalidPlan }
            total = sum
        }
        guard total == totalBytes else { throw CopyError.invalidPlan }
    }

    /// A path that stays below the folder it is relative to.
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Below the disk root: the destination folder, then the item.
    func target(_ item: Item) -> String { destination.isEmpty ? item.relative : destination + "/" + item.relative }

    /// The skipped items with everything inside skipped folders (a folder's contents follow it).
    func leftOut(_ skipped: [Int]) -> Set<Int> {
        var all = Set<Int>()
        for index in skipped where index >= 0 && index < items.count {
            all.insert(index)
            guard items[index].kind == .directory else { continue }
            let prefix = items[index].relative + "/"
            var inside = index + 1
            while inside < items.count && items[inside].relative.hasPrefix(prefix) { all.insert(inside); inside += 1 }
        }
        return all
    }

    /// The items the user chose.
    public var topLevelCount: Int { items.reduce(0) { $0 + ($1.relative.contains("/") ? 0 : 1) } }

    private static func kind(of path: String) -> Item.Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: errno = ENOTSUP; return nil
        }
    }
    private static func size(of path: String) -> Int64 {
        var info = stat()
        return lstat(path, &info) == 0 ? Int64(info.st_size) : 0
    }
    /// The first error the folder walk met (its handler escapes).
    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var first: (String, Int32)?
        func record(_ path: String, _ code: Int32) { lock.lock(); if first == nil { first = (path, code) }; lock.unlock() }
    }
}

/// How far a copy got. Saved often; everything before `next` is finished.
public struct CopyProgress: Codable, Sendable, Equatable {
    public enum Pause: String, Codable, Sendable {
        /// The disk went away or stopped being writable: resumes once it is writable again.
        case disk
        case user
        /// A problem the user has to look at (no space left, an unreadable source…).
        case problem
    }
    public var next = 0
    /// Ran at least once: part of the next file may already be on the disk.
    public var started = false
    /// Items finished within the last minute and a half before the latest save:
    /// the disk may have rolled them back, so a resume checks them again.
    public var recheckFrom = 0
    public var finished = false
    /// When it finished: an unplug in the next minute can still roll the last files back.
    public var finishedAt: Date?
    public var pause: Pause?
    public var pausedAt: Date?
    /// Why it paused, in words (also kept for a disk pause, for the log and the user).
    public var problem: String?
    /// Items the user chose to leave out (a folder with everything in it); a recheck passes them by too.
    public var skipped: [Int] = []
    /// The item the last run failed at: while rechecking it lies before `next`.
    public var failedAt: Int?
    /// Copied before, but their originals were gone when they were to be checked again.
    public var vanished: [Int] = []
    /// When the record was last written: a run cut off by quitting has no `pausedAt`.
    public var savedAt: Date?
    /// Last observed transfer count, for display while paused or rechecking.
    /// It is not a resume offset: the disk's actual matching bytes decide that.
    public var observedBytes: Int64?
    /// Device read/write errors (EIO) in a row at item `deviceErrorAt`: a disk
    /// failing at the same place again (bad sectors) gains nothing from
    /// reconnecting. Optional: records written by 0.8.0 have neither.
    public var deviceErrors: Int?
    public var deviceErrorAt: Int?
    public init() {}

    /// A damaged or edited record must not crash the app: indexes are clamped.
    func sanitized(itemCount: Int) -> CopyProgress {
        func indexes(_ list: [Int]) -> [Int] { Array(Set(list.filter { $0 >= 0 && $0 < itemCount })).sorted() }
        var value = self
        value.next = min(max(0, next), itemCount)
        value.recheckFrom = min(max(0, recheckFrom), value.next)
        value.skipped = indexes(skipped)
        value.vanished = indexes(vanished)
        if let failed = failedAt, failed < 0 || failed >= itemCount { value.failedAt = nil }
        return value
    }
}

public enum CopyError: Error, Equatable, LocalizedError {
    case invalidPlan
    case nothingToCopy
    case duplicateName(String)
    case sourceOnDisk
    case source(String, Int32)
    case destination(String, Int32)
    /// A folder on the way to the destination is a link: writing would follow it off the disk.
    case linkInPath(String)
    /// The target is the source file itself (copied onto its own place).
    case sameFile(String)
    case stopped
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: String(localized: "拷贝记录无效。")
        case .nothingToCopy: String(localized: "没有可拷贝的项目。")
        case .duplicateName(let name): String(localized: "选中的项目里有两个都叫“\(name)”，拷到同一个文件夹会互相覆盖。请分开拷贝。")
        case .sourceOnDisk: String(localized: "要拷贝的项目就在这块盘上。盘内拷贝请直接在 Finder 中进行。")
        case .source(let path, let code): String(localized: "无法读取“\((path as NSString).lastPathComponent)”：\(String(cString: strerror(code)))")
        case .destination(let path, let code): String(localized: "无法写入“\((path as NSString).lastPathComponent)”：\(String(cString: strerror(code)))")
        case .linkInPath(let path): String(localized: "盘上的“\((path as NSString).lastPathComponent)”是一个链接，盘屿不会顺着链接写入。请换一个目标文件夹。")
        case .sameFile(let path): String(localized: "“\((path as NSString).lastPathComponent)”就是要拷贝的源文件本身，不能拷到它自己的位置。")
        case .stopped: String(localized: "拷贝已停止。")
        }
    }
    /// Only failures that mean the disk is gone or no longer writable; anything
    /// else is a problem with one file that retrying will not fix.
    public var diskUnavailable: Bool {
        guard case .destination(_, let code) = self else { return false }
        return [EIO, ENXIO, ENODEV, ENOTCONN, ESTALE, EROFS, EBADF].contains(code)
    }
    var isDestination: Bool {
        if case .destination = self { return true }
        return false
    }
    /// The disk answered with an I/O error: it was there, but could not read or
    /// write that place (bad sectors, a loose cable, a weak supply).
    var isDeviceError: Bool {
        if case .destination(_, let code) = self { return code == EIO }
        return false
    }
}

/// Plans and progress in Application Support/Volisle/copies/<id>/.
public struct CopyJobStore: Sendable {
    /// Only the main-actor queue writes this intent. A late worker progress
    /// save must never undo a user's pause or planned return to read-only.
    struct WriteRequest: Codable, Sendable {
        let id: UUID
        var session: UUID?
        var enabled: Bool
        var userPaused: Bool? = nil
    }
    /// Part files of cancelled copies, left on a disk that was not writable then:
    /// paths below its root, removed once it is writable again.
    public struct Cleanup: Codable, Sendable, Equatable {
        public let diskKey: String
        public var targets: [String]
    }
    let directory: URL
    private static let log = Logger(subsystem: "top.qisw.volisle", category: "copy")
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volisle/copies", isDirectory: true)
    }
    public func save(_ plan: CopyPlan) throws {
        let folder = directory.appendingPathComponent(plan.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(plan).write(to: folder.appendingPathComponent("plan.json"), options: .atomic)
    }
    public func save(_ progress: CopyProgress, for id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("progress.json")
        var stamped = progress
        stamped.savedAt = Date()
        try JSONEncoder().encode(stamped).write(to: file, options: .atomic)
    }
    func saveWriteRequest(_ request: WriteRequest, for id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("write-request.json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
    }
    func loadWriteRequest(_ id: UUID) -> WriteRequest? {
        let file = directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("write-request.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(WriteRequest.self, from: $0) }
    }
    public func saveCleanups(_ cleanups: [Cleanup]) {
        let file = directory.appendingPathComponent("cleanup.json")
        do {
            if cleanups.isEmpty { try? FileManager.default.removeItem(at: file); return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(cleanups).write(to: file, options: .atomic)
        } catch { Self.log.error("待清理记录未能保存：\(error.localizedDescription, privacy: .public)") }
    }
    public func loadCleanups() -> [Cleanup] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("cleanup.json")),
              let list = try? JSONDecoder().decode([Cleanup].self, from: data) else { return [] }
        return list.compactMap { cleanup in
            var safe = cleanup
            safe.targets = cleanup.targets.filter(CopyPlan.safe)
            return cleanup.diskKey.isEmpty || safe.targets.isEmpty ? nil : safe
        }
    }
    /// For callers that cannot stop on a failed save: the copy goes on, and a resume rechecks more.
    public func trySave(_ progress: CopyProgress, for id: UUID) {
        do { try save(progress, for: id) } catch { Self.log.error("拷贝进度未能保存：\(error.localizedDescription, privacy: .public)") }
    }
    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString, isDirectory: true))
    }
    /// Unreadable records are skipped: they can only describe a copy that cannot resume.
    public func load() -> [(CopyPlan, CopyProgress)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (CopyPlan, CopyProgress)? in
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("plan.json")),
                  let plan = try? JSONDecoder().decode(CopyPlan.self, from: data),
                  plan.id.uuidString == name, (try? plan.validate()) != nil else { return nil }
            let progress = (try? Data(contentsOf: folder.appendingPathComponent("progress.json")))
                .flatMap { try? JSONDecoder().decode(CopyProgress.self, from: $0) } ?? CopyProgress()
            return (plan, progress.sanitized(itemCount: plan.items.count))
        }.sorted { $0.0.created < $1.0.created }
    }
}

/// Copies one plan into a writable disk root, on the caller's thread.
/// A file is written to a hidden part file beside it and renamed over its name
/// when complete, so its name only ever holds the old file or a whole copy.
/// Unchecked Sendable: only the stop flag is shared, behind a lock; everything
/// else is used by the one thread that runs the copy.
public final class ResumableCopier: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var copiedBytes: Int64 = 0
        public var current: String?
        /// Comparing what is already on the disk with the source.
        public var checking = false
        /// Live comparison progress, for display only; never a resume offset.
        public var checkedBytes: Int64 = 0
        public var bytesToCheck: Int64 = 0
        /// An existing final file is checked before trying a partial copy.
        public var checkingWholeFile = false
    }
    static let chunk = 4 << 20
    /// Items finished this long before a save are taken as safe on the disk.
    static let recheckWindow: TimeInterval = 90
    private static let log = Logger(subsystem: "top.qisw.volisle", category: "copy")

    let plan: CopyPlan
    let root: URL
    private let lock = NSLock()
    private var stopRequested = false
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Seconds between status reports (tests report every chunk).
    var reportInterval: TimeInterval = 0.25
    /// Folders checked in this run to be real folders on the disk (not links).
    private var checked = Set<String>()
    private var buffers: ([UInt8], [UInt8]) = ([], [])
    /// The root when the run began: if the disk goes away, its path may lead
    /// somewhere else (nowhere, or an empty folder on the Mac).
    private var rootID: (device: dev_t, inode: ino_t) = (0, 0)
    private let setFlags: @Sendable (Int32, UInt32) -> Int32

    public convenience init(plan: CopyPlan, root: URL) {
        self.init(plan: plan, root: root, setFlags: { fchflags($0, $1) })
    }
    init(plan: CopyPlan, root: URL, setFlags: @escaping @Sendable (Int32, UInt32) -> Int32) {
        self.plan = plan; self.root = root; self.setFlags = setFlags
    }

    /// Asks a running copy to stop between two chunks; it throws `CopyError.stopped`.
    public func stop() { lock.lock(); stopRequested = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    /// The hidden file a copy of `target` is written to before it takes its name.
    public static func partPath(for target: String) -> String {
        let folder = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let part = "." + name + ".volisle-part"
        if part.utf16.count <= 255 { return folder + "/" + part }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return folder + "/.volisle-part-" + String(hash, radix: 16)
    }

    /// Removes the part left for `target` (a path below the disk root `root`):
    /// only a part, never through a link or on another file system.
    public static func removePart(of target: String, root: String) {
        var rootInfo = stat()
        guard CopyPlan.safe(target), stat(root, &rootInfo) == 0 else { return }
        var current = root
        for component in (target as NSString).deletingLastPathComponent.split(separator: "/") {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_dev == rootInfo.st_dev else { return }
        }
        let part = partPath(for: root + "/" + target)
        var info = stat()
        guard lstat(part, &info) == 0, info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK else { return }
        unlink(part)
    }

    /// Copies from `start` on. `resuming`: an earlier run may have left part of
    /// the next file (and, rolled back, of the ones just before it) on the disk.
    /// `save` gets the progress after every item, `report` the status a few
    /// times a second. Throws CopyError.
    public func run(from start: CopyProgress, resuming: Bool, save: (CopyProgress) -> Void, report: (Status) -> Void) throws -> CopyProgress {
        var progress = start.sanitized(itemCount: plan.items.count)
        progress.pause = nil; progress.problem = nil; progress.pausedAt = nil; progress.failedAt = nil
        var rootInfo = stat()
        // No root: the disk is gone, which is not a problem with any item.
        guard stat(root.path, &rootInfo) == 0 else { throw CopyError.destination(root.path, ENXIO) }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw CopyError.destination(root.path, ENOTDIR) }
        rootID = (rootInfo.st_dev, rootInfo.st_ino)
        checked = [root.path]
        buffers = ([UInt8](repeating: 0, count: Self.chunk), [UInt8](repeating: 0, count: Self.chunk))
        let base = plan.destination.isEmpty ? root.path : root.path + "/" + plan.destination
        let resumeAt = progress.next
        let first = progress.recheckFrom
        let skipped = plan.leftOut(progress.skipped)
        var status = Status()
        status.copiedBytes = plan.items[..<first].reduce(0) { $0 + $1.size }
        var recent: [(index: Int, at: TimeInterval)] = []
        var oldest = 0
        var lastReport = clock()
        func tick(_ status: Status, _ force: Bool) {
            if !status.checking { progress.observedBytes = status.copiedBytes }
            let now = clock()
            if force || now - lastReport >= reportInterval { lastReport = now; report(status) }
        }
        for index in first..<plan.items.count {
            if shouldStop { throw CopyError.stopped }
            let item = plan.items[index]
            if skipped.contains(index) {
                status.copiedBytes += item.size
            } else {
                status.current = item.relative
                // Resuming, anything from `next` on may have a part from a run whose
                // last saves were lost (quit, crash): compared, never truncated.
                let mode: Mode = index < resumeAt ? .recheck : resuming ? .resume : .fresh
                do {
                    try copy(item, to: base + "/" + item.relative, mode: mode, status: &status, tick: tick)
                } catch CopyError.source(_, let code) where code == ENOENT && mode == .recheck {
                    // Copied before; its original is gone since, so there is nothing to check it against.
                    if !progress.vanished.contains(index) { progress.vanished.append(index) }
                    status.copiedBytes += item.size
                } catch {
                    if (error as? CopyError) != .stopped { progress.failedAt = index }
                    save(progress)
                    throw error
                }
            }
            let now = clock()
            recent.append((index, now))
            while oldest < recent.count && now - recent[oldest].at > Self.recheckWindow { oldest += 1 }
            progress.next = max(progress.next, index + 1)
            progress.recheckFrom = oldest < recent.count ? recent[oldest].index : progress.next
            save(progress)
            tick(status, true)
        }
        // The last files stay "to recheck": unplugged right after finishing, the
        // disk rolls them back, and the copy then resumes from there.
        progress.finished = true
        save(progress)
        return progress
    }

    enum Mode { case fresh, resume, recheck }

    private func copy(_ item: CopyPlan.Item, to target: String, mode: Mode, status: inout Status, tick: (Status, Bool) -> Void) throws {
        do {
            switch item.kind {
            case .directory: try directory(target)
            case .symlink: try link(item, target)
            case .file: try file(item, to: target, mode: mode, status: &status, tick: tick)
            }
        } catch let error as CopyError {
            // A path that stopped leading to the disk (ENOENT once it is unmounted)
            // means the disk went away, not that this item has a problem.
            if case .destination(let path, _) = error, !error.diskUnavailable, !onDisk() { throw CopyError.destination(path, ENXIO) }
            throw error
        }
    }

    /// The root still is the disk this run began on. Checked before creating
    /// anything, so nothing lands on the Mac in place of a vanished disk.
    private func onDisk() -> Bool {
        var info = stat()
        return stat(root.path, &info) == 0 && info.st_dev == rootID.device && info.st_ino == rootID.inode
    }

    /// `path` (below the root) as a real folder: every part checked with lstat,
    /// created if missing, and never a link that would lead off the disk.
    private func directory(_ path: String) throws {
        if checked.contains(path) { return }
        let rootPath = root.path
        guard path.hasPrefix(rootPath + "/") else { throw CopyError.invalidPlan }
        var current = rootPath
        for part in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            current += "/" + part
            if checked.contains(current) { continue }
            var info = stat()
            if lstat(current, &info) != 0 {
                guard errno == ENOENT else { throw CopyError.destination(current, errno) }
                guard onDisk() else { throw CopyError.destination(current, ENXIO) }
                if mkdir(current, 0o755) != 0 && errno != EEXIST { throw CopyError.destination(current, errno) }
                guard lstat(current, &info) == 0 else { throw CopyError.destination(current, errno) }
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                // Another file system mounted inside the disk is not the disk.
                guard info.st_dev == rootID.device else { throw CopyError.destination(current, EXDEV) }
                checked.insert(current)
            case S_IFLNK: throw CopyError.linkInPath(current)
            default: throw CopyError.destination(current, ENOTDIR)
            }
        }
    }

    private func link(_ item: CopyPlan.Item, _ path: String) throws {
        var sourceInfo = stat()
        guard lstat(item.source, &sourceInfo) == 0 else { throw CopyError.source(item.source, errno) }
        let destination: String
        do { destination = try FileManager.default.destinationOfSymbolicLink(atPath: item.source) }
        catch { throw CopyError.source(item.source, Self.code(error)) }
        try directory((path as NSString).deletingLastPathComponent)
        var info = stat()
        if lstat(path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFLNK, (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == destination {
                try finishVisibility(path, publishedAs: path, sourceInfo: sourceInfo)
                return
            }
            guard info.st_mode & S_IFMT != S_IFDIR else { throw CopyError.destination(path, EISDIR) }
        }
        // Like a file, the new link takes the name in one step.
        let part = Self.partPath(for: path)
        if lstat(part, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFDIR else { throw CopyError.destination(part, EISDIR) }
            guard onDisk() else { throw CopyError.destination(part, ENXIO) }
            guard unlink(part) == 0 else { throw CopyError.destination(part, errno) }
        }
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        guard symlink(destination, part) == 0 else { throw CopyError.destination(part, errno) }
        try finishVisibility(part, publishedAs: path, sourceInfo: sourceInfo)
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        guard rename(part, path) == 0 else {
            let code = errno
            unlink(part)
            throw CopyError.destination(path, code)
        }
    }

    private func file(_ item: CopyPlan.Item, to path: String, mode: Mode, status: inout Status, tick: (Status, Bool) -> Void) throws {
        let source = open(item.source, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw CopyError.source(item.source, errno) }
        defer { close(source) }
        var sourceInfo = stat()
        guard fstat(source, &sourceInfo) == 0 else { throw CopyError.source(item.source, errno) }
        let size = Int64(sourceInfo.st_size)
        let before = status.copiedBytes
        try directory((path as NSString).deletingLastPathComponent)

        var targetInfo = stat()
        let exists = lstat(path, &targetInfo) == 0
        // Writing there would empty the very file being copied.
        if exists && targetInfo.st_dev == sourceInfo.st_dev && targetInfo.st_ino == sourceInfo.st_ino { throw CopyError.sameFile(path) }
        if exists && targetInfo.st_mode & S_IFMT == S_IFDIR { throw CopyError.destination(path, EISDIR) }
        let part = Self.partPath(for: path)

        // Finished before (or renamed just before a pause) and still whole: only the dates and attributes again.
        if mode != .fresh, exists, targetInfo.st_mode & S_IFMT == S_IFREG, Int64(targetInfo.st_size) == size {
            let whole = open(path, O_RDONLY | O_CLOEXEC)
            guard whole >= 0 else { throw CopyError.destination(path, errno) }
            // Closed however the comparison ends: an open file would keep the disk from unmounting.
            defer { close(whole) }
            status.checkingWholeFile = true
            let same = try matching(source, whole, path: path, item: item, length: size, status: &status, tick: tick) == size
            if same {
                try finishMetadata(item, path, sourceInfo)
                try finishVisibility(path, publishedAs: path, sourceInfo: sourceInfo)
                guard onDisk() else { throw CopyError.destination(part, ENXIO) }
                unlink(part)
                status.copiedBytes = before + size
                return
            }
        }

        var partInfo = stat()
        let partExists = lstat(part, &partInfo) == 0
        if partExists && partInfo.st_mode & S_IFMT == S_IFDIR { throw CopyError.destination(part, EISDIR) }
        if partExists && partInfo.st_mode & S_IFMT != S_IFREG {
            guard onDisk() else { throw CopyError.destination(part, ENXIO) }
            guard unlink(part) == 0 else { throw CopyError.destination(part, errno) }
        }
        let keep = mode != .fresh && partExists && partInfo.st_mode & S_IFMT == S_IFREG
        guard onDisk() else { throw CopyError.destination(part, ENXIO) }
        let target = keep ? open(part, O_RDWR | O_CLOEXEC | O_NOFOLLOW) : open(part, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard target >= 0 else { throw CopyError.destination(part, errno) }
        var closed = false
        defer { if !closed { close(target) } }

        var offset: Int64 = 0
        if keep {
            var info = stat()
            guard fstat(target, &info) == 0 else { throw CopyError.destination(part, errno) }
            status.checkingWholeFile = false
            offset = try matching(source, target, path: part, item: item, length: min(Int64(info.st_size), size), status: &status, tick: tick)
            if Int64(info.st_size) != offset && ftruncate(target, offset) != 0 { throw CopyError.destination(part, errno) }
            if offset > 0 { Self.log.notice("续传：从 \(offset, privacy: .public) 字节接着拷") }
        }
        status.copiedBytes = before + offset
        tick(status, true)
        while offset < size {
            if shouldStop { throw CopyError.stopped }
            guard onDisk() else { throw CopyError.destination(part, ENXIO) }
            let wanted = Int(min(Int64(Self.chunk), size - offset))
            let read = buffers.0.withUnsafeMutableBytes { pread(source, $0.baseAddress, wanted, off_t(offset)) }
            guard read > 0 else { throw CopyError.source(item.source, read < 0 ? errno : EIO) }
            var written = 0
            while written < read {
                let n = buffers.0.withUnsafeBytes { pwrite(target, $0.baseAddress! + written, read - written, off_t(offset) + off_t(written)) }
                guard n > 0 else { throw CopyError.destination(part, n < 0 ? errno : EIO) }
                written += n
            }
            offset += Int64(read)
            status.copiedBytes += Int64(read)
            tick(status, false)
        }
        closed = true
        guard close(target) == 0 else { throw CopyError.destination(part, errno) }
        try finishMetadata(item, part, sourceInfo)
        try finishVisibility(part, publishedAs: path, sourceInfo: sourceInfo)
        // Takes the name in one step: the old file stays whole until the copy is.
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        guard rename(part, path) == 0 else { throw CopyError.destination(path, errno) }
        status.copiedBytes = before + size
    }

    /// Tags, the download source and other extended attributes, then the dates.
    private func finishMetadata(_ item: CopyPlan.Item, _ path: String, _ sourceInfo: stat) throws {
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        if copyfile(item.source, path, nil, copyfile_flags_t(COPYFILE_XATTR)) != 0 {
            Self.log.notice("扩展属性未能全部复制：\(String(cString: strerror(errno)), privacy: .public)")
        }
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        var times = [sourceInfo.st_atimespec, sourceInfo.st_mtimespec]
        guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw CopyError.destination(path, errno) }
    }

    /// NTFS creates dot-prefixed parts with HIDDEN and preserves it at rename.
    /// Derive visibility from the source and final name, changing only UF_HIDDEN.
    /// A link descriptor refers to the link itself, never to its destination.
    private func finishVisibility(_ path: String, publishedAs finalPath: String, sourceInfo: stat) throws {
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        let kind = sourceInfo.st_mode & S_IFMT
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        guard descriptor >= 0 else { throw CopyError.destination(path, errno) }
        defer { close(descriptor) }
        var current = stat()
        guard fstat(descriptor, &current) == 0 else { throw CopyError.destination(path, errno) }
        guard current.st_mode & S_IFMT == kind, current.st_dev == rootID.device else { throw CopyError.destination(path, ESTALE) }
        let hidden = sourceInfo.st_flags & UInt32(UF_HIDDEN) != 0 || (finalPath as NSString).lastPathComponent.hasPrefix(".")
        let flags = current.st_flags & ~UInt32(UF_HIDDEN) | (hidden ? UInt32(UF_HIDDEN) : 0)
        guard flags != current.st_flags else { return }
        guard onDisk() else { throw CopyError.destination(path, ENXIO) }
        guard setFlags(descriptor, flags) == 0 else { throw CopyError.destination(path, errno) }
        guard fstat(descriptor, &current) == 0 else { throw CopyError.destination(path, errno) }
        guard current.st_flags & UInt32(UF_HIDDEN) == flags & UInt32(UF_HIDDEN) else { throw CopyError.destination(path, EIO) }
    }

    /// How much of `target` already equals the source, from the start.
    private func matching(_ source: Int32, _ target: Int32, path: String, item: CopyPlan.Item, length: Int64,
                          status: inout Status, tick: (Status, Bool) -> Void) throws -> Int64 {
        status.checking = true
        status.checkedBytes = 0; status.bytesToCheck = length
        tick(status, true)
        defer {
            // No report here: the caller must apply the verified offset first,
            // before a non-checking report can update the transfer estimate.
            status.checking = false; status.checkingWholeFile = false
            status.checkedBytes = 0; status.bytesToCheck = 0
        }
        var offset: Int64 = 0
        while offset < length {
            if shouldStop { throw CopyError.stopped }
            let wanted = Int(min(Int64(Self.chunk), length - offset))
            let a = try Self.readFully(source, into: &buffers.0, wanted, at: offset) { CopyError.source(item.source, $0) }
            let b = try Self.readFully(target, into: &buffers.1, wanted, at: offset) { CopyError.destination(path, $0) }
            let same = min(a, b)
            var equal = same
            buffers.0.withUnsafeBytes { x in buffers.1.withUnsafeBytes { y in
                guard same > 0, memcmp(x.baseAddress!, y.baseAddress!, same) != 0 else { return }
                equal = 0
                while equal < same && x[equal] == y[equal] { equal += 1 }
            } }
            offset += Int64(equal)
            status.checkedBytes = offset
            tick(status, offset == length || equal < wanted)
            if equal < wanted { break }
        }
        return offset
    }

    /// Short reads (network sources) are continued; stops at the end of the file.
    private static func readFully(_ fd: Int32, into buffer: inout [UInt8], _ count: Int, at offset: Int64,
                                  error: (Int32) -> CopyError) throws -> Int {
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 { if errno == EINTR { continue }; throw error(errno) }
            if n == 0 { break }
            done += n
        }
        return done
    }

    static func code(_ error: any Error) -> Int32 {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain { return Int32(posix.code) }
        return ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : EIO
    }
}
