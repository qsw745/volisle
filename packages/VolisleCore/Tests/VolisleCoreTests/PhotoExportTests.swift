import Foundation
import Testing
@testable import VolisleCore

struct PhotoExportTests {
    private func resource(_ id: String, _ name: String, _ role: PhotoExportResource.Role) -> PhotoExportResource {
        .init(id: id, filename: name, role: role)
    }
    private var live: PhotoExportAsset {
        .init(id: "live-1", kind: .livePhoto, resources: [resource("still", "IMG_1234.HEIC", .photo), resource("motion", "IMG_1234.MOV", .pairedVideo)])
    }
    private func bench() throws -> (URL, PhotoExportCache, CopyJobStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-photo-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copies = CopyJobStore(directory: root.appendingPathComponent("copies"))
        return (root, PhotoExportCache(directory: root.appendingPathComponent("cache"), copyStore: copies), copies)
    }
    private func write(_ r: PhotoExportResource, to path: URL, progress: @Sendable (Double) -> Void) async throws {
        try Data(("original bytes " + r.id).utf8).write(to: path, options: .withoutOverwriting)
        progress(1)
    }
    private func contents(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path.replacingOccurrences(of: folder.path + "/", with: "")] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test func livePhotoIncludesBothOriginalResourcesAndCopiesTheirExactBytes() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "相册导出", writer: write)
        let files = try contents(batch.sourceDirectory)
        #expect(batch.assetCount == 1 && batch.resourceCount == 2)
        #expect(Set(files.values) == Set([Data("original bytes still".utf8), Data("original bytes motion".utf8)]))
        #expect(Set(files.keys.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }) == ["heic", "mov"])
        let disk = root.appendingPathComponent("disk"); try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let plan = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        _ = try ResumableCopier(plan: plan, root: disk).run(from: CopyProgress(), resuming: false, save: { _ in }, report: { _ in })
        #expect(try contents(disk.appendingPathComponent(batch.sourceDirectory.lastPathComponent)) == files)
    }

    @Test func missingLiveComponentCannotBecomeAStaticSuccessfulExport() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        for resources in [[resource("still", "a.heic", .photo)], [resource("motion", "a.mov", .pairedVideo)]] {
            do {
                _ = try await cache.prepare(assets: [.init(id: "broken", kind: .livePhoto, resources: resources)], folderName: "导出", writer: write)
                Issue.record("缺失实况配套资源不能成功")
            } catch PhotoExportError.missingOriginalResources { }
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path))?.isEmpty ?? true)
    }

    @Test func sameNamedAssetsAndUnsafeResourceNamesStayInsideTheirOwnFolders() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let assets = [live, PhotoExportAsset(id: "live-2", kind: .livePhoto, resources: [resource("still2", "IMG_1234.HEIC", .photo), resource("motion2", "IMG_1234.MOV", .pairedVideo)]),
                      .init(id: "other", kind: .photo, resources: [resource("bad1", "../CON.jpg", .photo), resource("bad2", "..\\con.JPG", .photo)])]
        let batch = try await cache.prepare(assets: assets, folderName: "../照片/导出", writer: write)
        let files = try contents(batch.sourceDirectory)
        #expect(files.count == 6)
        #expect(Set(files.keys.map { $0.lowercased() }).count == 6)
        #expect(batch.sourceDirectory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"))
        #expect(files.keys.allSatisfy { !$0.contains("..") && !$0.contains("\\") })
    }

    @Test func secondResourceFailureOrCancellationRemovesOnlyThatPreparation() async throws {
        enum DownloadFailure: Error { case unavailable }
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("user-original"); try Data("keep".utf8).write(to: marker)
        for cancel in [false, true] {
            do {
                _ = try await cache.prepare(assets: [live], folderName: "导出") { r, path, progress in
                    if r.role == .pairedVideo {
                        if cancel { throw CancellationError() }
                        throw DownloadFailure.unavailable
                    }
                    try Data("still".utf8).write(to: path); progress(1)
                }
                Issue.record("失败的批次不能交付给拷贝队列")
            } catch { }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).isEmpty)
        }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test func emptyResourceIsAnErrorRatherThanAnExportedPhoto() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: PhotoExportError.emptyResource) {
            _ = try await cache.prepare(assets: [live], folderName: "导出") { _, path, _ in try Data().write(to: path) }
        }
    }

    @Test func stagingSurvivesRelaunchAndRetiresOnlyAfterTheCopyPlanDoes() async throws {
        let (root, cache, store) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let pending = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        let plan = try await cache.bind(batch, to: pending)
        try store.save(plan)
        await cache.release(batch)
        let relaunched = PhotoExportCache(directory: root.appendingPathComponent("cache"), copyStore: store)
        try await relaunched.cleanup()
        #expect(try contents(batch.sourceDirectory).count == 2)
        store.remove(plan.id)
        try await relaunched.cleanup()
        #expect(!FileManager.default.fileExists(atPath: batch.sourceDirectory.path))
    }

    @Test func activeBatchCannotBeCleanedBetweenBindingAndQueuePersistence() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let plan = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        try await cache.bind(batch, to: plan)
        try await cache.cleanup()
        #expect(try contents(batch.sourceDirectory).count == 2)
    }

    @Test func cleanupDoesNotFollowSymlinksOrDeleteUnknownFolders() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("keep"); try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: external.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(UUID().uuidString), withDestinationURL: external)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("unknown"), withIntermediateDirectories: true)
        try await cache.cleanup(now: .distantFuture)
        #expect(try Data(contentsOf: external.appendingPathComponent("original")) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unknown").path))
    }

    @Test func corruptOrUndeletableRawCopyRecordsStillKeepTheCacheLease() async throws {
        let (root, cache, store) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let pending = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        let plan = try await cache.bind(batch, to: pending)
        try store.save(plan); await cache.release(batch)
        let record = root.appendingPathComponent("copies/" + plan.id.uuidString)
        try Data("broken JSON".utf8).write(to: record.appendingPathComponent("plan.json"))
        #expect(store.load().isEmpty)
        try await cache.cleanup()
        #expect(try contents(batch.sourceDirectory).count == 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.appendingPathComponent("copies").path)
        store.remove(plan.id)
        try await cache.cleanup()
        #expect(try contents(batch.sourceDirectory).count == 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("copies").path)
        store.remove(plan.id); try await cache.cleanup()
        #expect(!FileManager.default.fileExists(atPath: batch.sourceDirectory.path))
    }

    @Test func missingStagedLiveResourceDuringRecheckMustFailClosed() async throws {
        let (root, cache, _) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let pending = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        let plan = try await cache.bind(batch, to: pending)
        let disk = root.appendingPathComponent("disk"); try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let first = try ResumableCopier(plan: plan, root: disk).run(from: CopyProgress(), resuming: false, save: { _ in }, report: { _ in })
        let video = try #require(plan.items.first { $0.source.hasSuffix(".MOV") })
        try FileManager.default.removeItem(atPath: video.source)
        #expect(throws: (any Error).self) {
            _ = try ResumableCopier(plan: plan, root: disk).run(from: first, resuming: true, save: { _ in }, report: { _ in })
        }
    }

    @Test @MainActor func aLivePhotoCannotSkipItsFailedVideoAndReportSuccess() async throws {
        let (root, cache, store) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let pending = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        let plan = try await cache.bind(batch, to: pending)
        let at = try #require(plan.items.firstIndex { $0.source.hasSuffix(".MOV") })
        var progress = CopyProgress(); progress.next = at; progress.failedAt = at; progress.pause = .problem
        try store.save(plan); try store.save(progress, for: plan.id)
        let queue = CopyQueue(store: store, writableDisk: { _ in nil }, diskPresent: { _ in true })
        queue.load()
        await queue.skip(plan.id)
        #expect(queue.jobs.first?.progress.failedAt == at)
        #expect(queue.jobs.first?.progress.skipped.isEmpty == true)
        #expect(queue.jobs.first?.progress.finished == false)
        #expect(store.loadCleanups().isEmpty)
    }

    @Test func replacedQueueDirectoryIsNotEvidenceThatCopiesRetired() async throws {
        let (root, cache, store) = try bench(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await cache.prepare(assets: [live], folderName: "导出", writer: write)
        let pending = try CopyPlan.make(sources: [batch.sourceDirectory], diskKey: "VOL", volumeName: "测试盘", destination: "")
        let plan = try await cache.bind(batch, to: pending)
        try store.save(plan); await cache.release(batch)
        try FileManager.default.moveItem(at: store.directory, to: root.appendingPathComponent("old-records"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try await cache.cleanup(now: .distantFuture)
        #expect(try contents(batch.sourceDirectory).count == 2)
    }
}
