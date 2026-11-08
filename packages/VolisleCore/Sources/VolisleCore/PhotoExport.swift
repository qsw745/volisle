import Foundation
import Darwin

public struct PhotoExportResource: Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case photo, video, pairedVideo }
    public let id: String
    public let filename: String
    public let role: Role
    public init(id: String, filename: String, role: Role) { self.id = id; self.filename = filename; self.role = role }
}

public struct PhotoExportAsset: Sendable {
    public enum Kind: Sendable { case photo, livePhoto, video }
    public let id: String
    public let kind: Kind
    public let resources: [PhotoExportResource]
    public init(id: String, kind: Kind, resources: [PhotoExportResource]) { self.id = id; self.kind = kind; self.resources = resources }
}

/// Persisted with CopyPlan so a missing original or a skipped resource cannot
/// turn an incomplete Live Photo into a successful export after relaunch.
public struct PhotoExportInfo: Codable, Sendable, Equatable {
    public struct Group: Codable, Sendable, Equatable {
        public let live: Bool
        public let files: [String]
    }
    public let batchID: UUID
    public let sourceDirectory: String
    public let groups: [Group]
    public var assetCount: Int { groups.count }

    func validate(items: [CopyPlan.Item]) throws {
        let files = groups.flatMap(\.files)
        let actual = items.filter { $0.kind == .file }
        guard !groups.isEmpty, sourceDirectory.hasPrefix("/"),
              groups.allSatisfy({ !$0.files.isEmpty && (!$0.live || $0.files.count == 2) }),
              Set(files).count == files.count, Set(files) == Set(actual.map(\.relative)),
              actual.allSatisfy({ $0.size > 0 }), !items.contains(where: { $0.kind == .symlink }) else { throw CopyError.invalidPlan }
        let root = URL(fileURLWithPath: sourceDirectory).standardizedFileURL
        let prefix = root.lastPathComponent + "/"
        for item in items {
            guard item.relative == root.lastPathComponent || item.relative.hasPrefix(prefix) else { throw CopyError.invalidPlan }
            let suffix = item.relative == root.lastPathComponent ? "" : String(item.relative.dropFirst(prefix.count))
            let source = suffix.isEmpty ? root : root.appendingPathComponent(suffix)
            guard URL(fileURLWithPath: item.source).standardizedFileURL == source else { throw CopyError.invalidPlan }
        }
    }
}

public struct PhotoExportBatch: Sendable {
    public let id: UUID
    public let sourceDirectory: URL
    public let assetCount: Int
    public let resourceCount: Int
}

public struct PhotoExportProgress: Sendable {
    public let finishedResources: Int
    public let resourceCount: Int
    public let fraction: Double
}

public enum PhotoExportError: Error, Equatable, LocalizedError {
    case missingOriginalResources, emptyResource, invalidSelection, invalidCache
    public var errorDescription: String? {
        switch self {
        case .missingOriginalResources: String(localized: "所选项目的原片资源不完整，未开始导出。实况照片需要同时取得图片和配套视频。")
        case .emptyResource: String(localized: "未能取得完整的照片或视频原片，未开始拷贝。请检查网络和 Mac 的可用空间后重试。")
        case .invalidSelection: String(localized: "无法读取全部所选照片或视频，请重新选择，并检查照片访问权限。")
        case .invalidCache: String(localized: "相册导出的暂存文件无法核对，已停止处理。请重试；若仍出现，请导出诊断联系支持。")
        }
    }
}

/// Only owns UUID directories carrying our marker. Prepared originals remain
/// leased until the queue's RAW record directory is known to be gone; malformed
/// JSON, failed deletion and a replaced queue directory never release a lease.
public actor PhotoExportCache {
    public static let shared = PhotoExportCache()
    public typealias Writer = @Sendable (PhotoExportResource, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    private struct Identity: Codable, Equatable {
        let device: Int32, inode: UInt64
    }
    private struct Record: Codable {
        var schema = 1
        let id: UUID
        let created: Date
        let info: PhotoExportInfo
        var planID: UUID?
        var copyStoreIdentity: Identity?
    }
    private let directory: URL
    private let copyStore: CopyJobStore
    private var active = Set<UUID>()
    public init(directory: URL? = nil, copyStore: CopyJobStore = CopyJobStore()) {
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volisle/photo-exports", isDirectory: true)).standardizedFileURL
        self.copyStore = copyStore
    }

    public func prepare(assets: [PhotoExportAsset], folderName: String, writer: Writer,
                        progress: @escaping @Sendable (PhotoExportProgress) -> Void = { _ in }) async throws -> PhotoExportBatch {
        guard !assets.isEmpty, Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ !$0.id.isEmpty && !$0.resources.isEmpty }),
              Set(assets.flatMap(\.resources).map(\.id)).count == assets.flatMap(\.resources).count else { throw PhotoExportError.invalidSelection }
        for asset in assets {
            let roles = asset.resources.map(\.role)
            switch asset.kind {
            case .livePhoto: guard roles.count == 2 && Set(roles) == [.photo, .pairedVideo] else { throw PhotoExportError.missingOriginalResources }
            case .photo: guard roles.allSatisfy({ $0 == .photo }) else { throw PhotoExportError.missingOriginalResources }
            case .video: guard roles == [.video] else { throw PhotoExportError.missingOriginalResources }
            }
        }
        try Task.checkCancellation()
        try makeDirectory(directory)
        let id = UUID(), home = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try makeDirectory(home)
        active.insert(id)
        let source = home.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(Self.filename(folderName), isDirectory: true)
        var groups: [PhotoExportInfo.Group] = [], transfers: [(PhotoExportResource, URL)] = []
        do {
            try makeDirectory(source)
            for (index, asset) in assets.enumerated() {
                let name = Self.filename((asset.resources.first!.filename as NSString).deletingPathExtension)
                let folder = source.appendingPathComponent(String(format: "%04d - %@", index + 1, name), isDirectory: true)
                try makeDirectory(folder)
                var used = Set<String>(), files: [String] = []
                for resource in asset.resources {
                    let original = Self.filename(resource.filename)
                    var name = original, suffix = 1
                    while !used.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                        suffix += 1
                        let url = URL(fileURLWithPath: original), ext = url.pathExtension
                        name = url.deletingPathExtension().lastPathComponent + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
                    }
                    transfers.append((resource, folder.appendingPathComponent(name)))
                    files.append([source.lastPathComponent, folder.lastPathComponent, name].joined(separator: "/"))
                }
                groups.append(.init(live: asset.kind == .livePhoto, files: files))
            }
            let info = PhotoExportInfo(batchID: id, sourceDirectory: source.path, groups: groups)
            try save(Record(id: id, created: Date(), info: info), home: home)
            for (index, transfer) in transfers.enumerated() {
                try Task.checkCancellation()
                let partial = transfer.1.appendingPathExtension("partial")
                let total = transfers.count
                try await writer(transfer.0, partial) { fraction in
                    let part = fraction.isFinite ? min(1, max(0, fraction)) : 0
                    progress(.init(finishedResources: index, resourceCount: total, fraction: (Double(index) + part) / Double(total)))
                }
                try Task.checkCancellation()
                let values = try partial.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { throw PhotoExportError.emptyResource }
                try FileManager.default.moveItem(at: partial, to: transfer.1)
                progress(.init(finishedResources: index + 1, resourceCount: total, fraction: Double(index + 1) / Double(total)))
            }
            return .init(id: id, sourceDirectory: source, assetCount: assets.count, resourceCount: transfers.count)
        } catch {
            active.remove(id)
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    @discardableResult public func bind(_ batch: PhotoExportBatch, to plan: CopyPlan) throws -> CopyPlan {
        let home = try owned(batch.id)
        var record = try read(home)
        guard active.contains(batch.id), record.planID == nil, record.info.sourceDirectory == batch.sourceDirectory.path else { throw PhotoExportError.invalidCache }
        var result = plan
        result.photoExport = record.info
        try result.validate()
        try makeDirectory(copyStore.directory)
        record.planID = result.id
        record.copyStoreIdentity = try identity(copyStore.directory)
        try save(record, home: home)
        return result
    }

    /// After binding, callers only release; cleanup determines retirement from
    /// the durable queue. A cancellation racing enqueue must not delete sources.
    public func release(_ batch: PhotoExportBatch) { active.remove(batch.id) }

    public func discard(_ batch: PhotoExportBatch) throws {
        let home = try owned(batch.id), record = try read(home)
        guard record.planID == nil else { throw PhotoExportError.invalidCache }
        active.remove(batch.id)
        try FileManager.default.removeItem(at: home)
    }

    public func cleanup(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        _ = try identity(directory)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard let id = UUID(uuidString: name), !active.contains(id), let home = try? owned(id),
                  let record = try? read(home), record.id == id else { continue }
            if let planID = record.planID {
                guard let expected = record.copyStoreIdentity, let actual = try? identity(copyStore.directory), expected == actual else { continue }
                var value = stat()
                guard lstat(copyStore.directory.appendingPathComponent(planID.uuidString).path, &value) != 0, errno == ENOENT else { continue }
            } else if now.timeIntervalSince(record.created) < 86400 { continue }
            try FileManager.default.removeItem(at: home)
        }
    }

    private func identity(_ url: URL) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw PhotoExportError.invalidCache }
        return .init(device: value.st_dev, inode: value.st_ino)
    }
    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try identity(url)
    }
    private func owned(_ id: UUID) throws -> URL {
        _ = try identity(directory)
        let home = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        _ = try identity(home)
        return home
    }
    private func read(_ home: URL) throws -> Record {
        let file = home.appendingPathComponent("record.json")
        guard (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw PhotoExportError.invalidCache }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.schema == 1, record.id.uuidString == home.lastPathComponent else { throw PhotoExportError.invalidCache }
        return record
    }
    private func save(_ record: Record, home: URL) throws {
        try JSONEncoder().encode(record).write(to: home.appendingPathComponent("record.json"), options: .atomic)
    }
    private static func filename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var name = value.components(separatedBy: forbidden).joined(separator: "_").replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "Original" }
        let stem = (name as NSString).deletingPathExtension.uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(stem) || (1...9).contains(where: { stem == "COM\($0)" || stem == "LPT\($0)" }) { name = "_" + name }
        while name.utf16.count > 180 { name.removeLast() }
        return name
    }
}
