import Foundation
import Darwin
import Testing
@testable import VolisleCore

/// Copies that survive unplugging: interrupted, the disk "rolled back" (files
/// cut short, finished files gone or back to an older version), then resumed.
struct ResumableCopyTests {
    private final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-copy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ relative: String, _ data: Data) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    private static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    /// A source tree with a large file, small files, a nested folder and a link.
    private static func source() throws -> (Folder, [URL]) {
        let folder = try Folder()
        try folder.write("Photos/big.bin", random(13 << 20 | 12345))
        for i in 0..<20 { try folder.write("Photos/small \(i).txt", Data("small \(i)\n".utf8)) }
        try folder.write("Photos/2026/中文 名字.txt", Data("你好\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: folder.url.path + "/Photos/link", withDestinationPath: "small 1.txt")
        try folder.write("notes.txt", Data("notes\n".utf8))
        return (folder, [folder.url.appendingPathComponent("Photos"), folder.url.appendingPathComponent("notes.txt")])
    }

    private static func assertSameTree(_ source: URL, _ copy: URL) throws {
        let walker = FileManager.default.enumerator(atPath: source.path)!
        var seen = 0
        for case let relative as String in walker {
            let a = source.appendingPathComponent(relative), b = copy.appendingPathComponent(relative)
            let values = try a.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey])
            if values.isSymbolicLink == true {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.path) == FileManager.default.destinationOfSymbolicLink(atPath: a.path))
            } else if values.isDirectory == true {
                #expect((try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, "\(relative)")
            } else {
                #expect(try Data(contentsOf: a) == Data(contentsOf: b), "\(relative)")
                let date = try b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                #expect(date == values.contentModificationDate, "\(relative)")
            }
            seen += 1
        }
        #expect(seen > 20)
        let parts = FileManager.default.enumerator(atPath: copy.path)!.compactMap { $0 as? String }.filter { $0.contains("volisle-part") }
        #expect(parts.isEmpty, "\(parts)")
    }

    private static func run(_ plan: CopyPlan, into root: URL, from progress: CopyProgress = CopyProgress(), resuming: Bool = false) throws -> CopyProgress {
        try ResumableCopier(plan: plan, root: root).run(from: progress, resuming: resuming, save: { _ in }, report: { _ in })
    }

    private static func flags(_ path: String) throws -> UInt32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_flags
    }

    @Test("普通文件发布时解除点名前缀临时文件继承的隐藏属性", arguments: [false, true])
    func copiedFileDoesNotInheritPartHiddenFlag(resuming: Bool) throws {
        let source = try Folder(), disk = try Folder(), bytes = Data("video bytes".utf8)
        try source.write("movie.mp4", bytes)
        let target = disk.url.appendingPathComponent("movie.mp4")
        let part = ResumableCopier.partPath(for: target.path)
        try Data(bytes.prefix(3)).write(to: URL(filePath: part))
        #expect(chflags(part, UInt32(UF_HIDDEN | UF_NODUMP)) == 0)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.mp4")], diskKey: "V", volumeName: "qsw", destination: "")
        #expect(try Self.run(plan, into: disk.url, resuming: resuming).finished)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Self.flags(target.path) & UInt32(UF_HIDDEN) == 0)
        #expect(try Self.flags(target.path) & UInt32(UF_NODUMP) != 0, "只调整发布所需的隐藏属性")
        #expect(!FileManager.default.fileExists(atPath: part))
    }

    @Test("复查已经发布的完整文件也修正临时文件遗留的隐藏属性")
    func recheckedFileRepairsInheritedHiddenFlag() throws {
        let source = try Folder(), disk = try Folder(), bytes = Data("whole video".utf8)
        try source.write("movie.mp4", bytes); try disk.write("movie.mp4", bytes)
        let target = disk.url.appendingPathComponent("movie.mp4")
        #expect(chflags(target.path, UInt32(UF_HIDDEN)) == 0)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.mp4")], diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress(); saved.next = plan.items.count
        #expect(try Self.run(plan, into: disk.url, from: saved, resuming: true).finished)
        #expect(try Self.flags(target.path) & UInt32(UF_HIDDEN) == 0)
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test("主动隐藏的源文件和最终点名前缀仍保留隐藏意图", arguments: ["secret.mp4", ".secret.mp4"])
    func copiedFilePreservesIntendedHiddenState(name: String) throws {
        let source = try Folder(), disk = try Folder(), bytes = Data("private video".utf8)
        try source.write(name, bytes)
        let original = source.url.appendingPathComponent(name)
        if !name.hasPrefix(".") { #expect(chflags(original.path, UInt32(UF_HIDDEN)) == 0) }
        let plan = try CopyPlan.make(sources: [original], diskKey: "V", volumeName: "qsw", destination: "")
        #expect(try Self.run(plan, into: disk.url).finished)
        let target = disk.url.appendingPathComponent(name)
        #expect(try Self.flags(target.path) & UInt32(UF_HIDDEN) != 0)
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test("隐藏属性设置失败或没有生效时不发布最终文件或报告完成", arguments: [false, true])
    func hiddenFlagFailureStopsBeforePublishing(claimsSuccess: Bool) throws {
        let source = try Folder(), disk = try Folder(), bytes = Data("video bytes".utf8)
        try source.write("movie.mp4", bytes)
        let target = disk.url.appendingPathComponent("movie.mp4")
        let part = ResumableCopier.partPath(for: target.path)
        try Data().write(to: URL(filePath: part))
        #expect(chflags(part, UInt32(UF_HIDDEN)) == 0)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.mp4")], diskKey: "V", volumeName: "qsw", destination: "")
        let copier = ResumableCopier(plan: plan, root: disk.url, setFlags: { _, _ in
            if claimsSuccess { return 0 }
            errno = EPERM; return -1
        })
        var saved = CopyProgress()
        #expect(throws: CopyError.destination(part, claimsSuccess ? EIO : EPERM)) {
            _ = try copier.run(from: CopyProgress(), resuming: false, save: { saved = $0 }, report: { _ in })
        }
        #expect(!saved.finished && saved.next == 0 && saved.failedAt == 0)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Self.flags(part) & UInt32(UF_HIDDEN) != 0)
    }

    @Test("链接发布和复查保留链接自身的隐藏意图，不改变所指文件", arguments: [false, true])
    func copiedLinkVisibilityDoesNotChangeItsDestination(rechecking: Bool) throws {
        let source = try Folder(), disk = try Folder(), outside = try Folder()
        try outside.write("file.txt", Data("outside".utf8))
        let destination = outside.url.appendingPathComponent("file.txt")
        let original = source.url.appendingPathComponent("secret-link")
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: destination)
        #expect(lchflags(original.path, UInt32(UF_HIDDEN)) == 0)
        let target = disk.url.appendingPathComponent("secret-link")
        if rechecking { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination) }
        let plan = try CopyPlan.make(sources: [original], diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress()
        if rechecking { saved.next = plan.items.count }
        #expect(try Self.run(plan, into: disk.url, from: saved, resuming: rechecking).finished)
        #expect(try Self.flags(target.path) & UInt32(UF_HIDDEN) != 0)
        #expect(try Self.flags(destination.path) & UInt32(UF_HIDDEN) == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == destination.path)
    }

    @Test func planListsEachFolderBeforeItsContentsWithSafePaths() throws {
        let (folder, sources) = try Self.source()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "备份")
        #expect(plan.items.first?.relative == "Photos" && plan.items.first?.kind == .directory)
        for (index, item) in plan.items.enumerated() where item.relative.contains("/") {
            let parent = (item.relative as NSString).deletingLastPathComponent
            #expect(plan.items[..<index].contains { $0.relative == parent && $0.kind == .directory }, "\(item.relative)")
        }
        #expect(plan.items.contains { $0.relative == "Photos/link" && $0.kind == .symlink })
        #expect(plan.totalBytes == plan.items.reduce(0) { $0 + $1.size } && plan.totalBytes > 13 << 20 && plan.topLevelCount == 2)
        _ = folder
        func tampered(_ items: [CopyPlan.Item], total: Int64) -> CopyPlan {
            CopyPlan(id: UUID(), diskKey: "V", volumeName: "", destination: "", items: items, totalBytes: total, created: Date())
        }
        for bad in ["../escape", "/abs", "a//b", "a/./b", ""] {
            #expect(throws: CopyError.invalidPlan) { try tampered([.init(source: "/x", relative: bad, kind: .file, size: 1)], total: 1).validate() }
        }
        // Nothing may sit below a copied link, and the sizes must add up.
        let link = CopyPlan.Item(source: "/x", relative: "a", kind: .symlink, size: 0)
        let below = CopyPlan.Item(source: "/y", relative: "a/b", kind: .file, size: 1)
        #expect(throws: CopyError.invalidPlan) { try tampered([link, below], total: 1).validate() }
        #expect(throws: CopyError.invalidPlan) { try tampered([below], total: 7).validate() }
    }

    @Test func planningRefusesWhatWouldGoWrongLaterInsteadOfLeavingItOut() throws {
        let folder = try Folder()
        try folder.write("a/x.txt", Data("A".utf8)); try folder.write("b/X.txt", Data("B".utf8))
        #expect(throws: CopyError.duplicateName("X.txt")) {
            _ = try CopyPlan.make(sources: [folder.url.appendingPathComponent("a/x.txt"), folder.url.appendingPathComponent("b/X.txt")],
                                  diskKey: "V", volumeName: "", destination: "")
        }
        let locked = folder.url.appendingPathComponent("Locked/inner")
        try folder.write("Locked/inner/secret.txt", Data("S".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try CopyPlan.make(sources: [folder.url.appendingPathComponent("Locked")], diskKey: "V", volumeName: "", destination: "")
            Issue.record("an unreadable folder must not be left out of the copy")
        } catch CopyError.source(let path, let code) {
            #expect(path.hasSuffix("/Locked/inner") && code == EACCES, "\(path) \(code)")
        }
        #expect(throws: CopyError.self) {
            _ = try CopyPlan.make(sources: [folder.url.appendingPathComponent("missing")], diskKey: "V", volumeName: "", destination: "")
        }
    }

    @Test func aCopyRunsToTheEndAndKeepsDatesAndLinks() throws {
        let (source, sources) = try Self.source()
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "备份/2026")
        let progress = try Self.run(plan, into: disk.url)
        #expect(progress.finished && progress.next == plan.items.count)
        try Self.assertSameTree(source.url, disk.url.appendingPathComponent("备份/2026"))
    }

    @Test @MainActor func aPausedSingleFileKeepsItsProgressAfterRelaunch() async throws {
        let source = try Folder(), disk = try Folder(), records = try Folder()
        let data = Self.random(16 << 20)
        try source.write("movie.bin", data)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        let first = ResumableCopier(plan: plan, root: disk.url); first.reportInterval = 0
        var saved = CopyProgress(); saved.started = true
        #expect(throws: CopyError.stopped) {
            _ = try first.run(from: saved, resuming: false, save: { saved = $0 },
                              report: { if $0.copiedBytes > 6 << 20 { first.stop() } })
        }
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: disk.url.appendingPathComponent("movie.bin").path))
        let bytes = Int64(try Data(contentsOf: part).count)
        #expect(bytes > 0 && bytes < plan.totalBytes)
        saved.pause = .user
        let store = CopyJobStore(directory: records.url)
        try store.save(plan); try store.save(saved, for: plan.id)
        try store.saveWriteRequest(.init(id: UUID(), enabled: false, userPaused: true), for: plan.id)
        let session = UUID()
        let queue = CopyQueue(store: store, writableDisk: { _ in .init(root: disk.url, session: session) },
                              diskPresent: { _ in true })
        queue.load(); await queue.reconcile()
        #expect(queue.jobs.first?.progress.pause == .user && queue.jobs.first?.running == false)
        #expect(queue.jobs.first?.copiedBytes == bytes, "a paused single file retains the observed partial bytes")
        #expect(queue.jobs.first?.fraction == Double(bytes) / Double(plan.totalBytes))
        await queue.resume(plan.id)
        for _ in 0..<1000 where queue.jobs.first?.running == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.jobs.first?.progress.finished == true)
        #expect(try Data(contentsOf: disk.url.appendingPathComponent("movie.bin")) == data)
    }

    @Test func checkingAPartReportsItsReadProgressWithoutChangingCopiedBytes() throws {
        let source = try Folder(), disk = try Folder()
        let data = Self.random(20 << 20); try source.write("movie.bin", data)
        let target = disk.url.appendingPathComponent("movie.bin")
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: target.path))
        try Data(data.prefix(12 << 20)).write(to: part)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress(); saved.started = true; saved.observedBytes = 12 << 20
        let initial = saved, copier = ResumableCopier(plan: plan, root: disk.url); copier.reportInterval = 0
        var reports: [ResumableCopier.Status] = []
        let result = try copier.run(from: initial, resuming: true, save: { saved = $0 }, report: { status in
            guard status.checking else { return }
            reports.append(status)
            #expect(saved.observedBytes == 12 << 20, "checking does not replace the saved transfer estimate")
            var job = CopyQueue.Job(plan: plan, progress: saved); job.running = true; job.status = status
            #expect(job.copiedBytes == 12 << 20, "checking does not advance or reset the main copy bar")
        })
        #expect(result.finished)
        #expect(reports.contains { $0.checkedBytes > 0 && $0.checkedBytes < 12 << 20 }, "long checks show intermediate reads")
        #expect(reports.first?.checkedBytes == 0 && reports.last?.checkedBytes == 12 << 20)
        #expect(reports.allSatisfy { !$0.checkingWholeFile && $0.bytesToCheck == 12 << 20 })
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.checkedBytes <= $1.checkedBytes })
        #expect(try Data(contentsOf: target) == data)
    }

    @Test func checkingAnExistingFileAndAPartUsesSeparateTotals() throws {
        let source = try Folder(), disk = try Folder()
        let data = Self.random(20 << 20); try source.write("movie.bin", data)
        var old = data; old[9 << 20] ^= 0xff
        try disk.write("movie.bin", old)
        let target = disk.url.appendingPathComponent("movie.bin")
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: target.path))
        try Data(data.prefix(12 << 20)).write(to: part)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        var initial = CopyProgress(); initial.started = true; initial.observedBytes = 12 << 20
        let copier = ResumableCopier(plan: plan, root: disk.url); copier.reportInterval = 0
        var reports: [ResumableCopier.Status] = []
        #expect(try copier.run(from: initial, resuming: true, save: { _ in }, report: {
            if $0.checking { reports.append($0) }
        }).finished)
        let whole = reports.filter(\.checkingWholeFile), partial = reports.filter { !$0.checkingWholeFile }
        #expect(whole.count > 2 && partial.count > 2)
        #expect(whole.allSatisfy { $0.bytesToCheck == 20 << 20 && $0.checkedBytes <= 9 << 20 })
        #expect(whole.first?.checkedBytes == 0 && whole.last?.checkedBytes == 9 << 20)
        #expect(partial.allSatisfy { $0.bytesToCheck == 12 << 20 && $0.checkedBytes <= 12 << 20 })
        #expect(partial.first?.checkedBytes == 0 && partial.last?.checkedBytes == 12 << 20)
        #expect(try Data(contentsOf: target) == data, "a mismatching whole file still resumes the verified part")
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func stoppingMidCheckKeepsThePartAndTheSavedTransferEstimate() throws {
        let source = try Folder(), disk = try Folder()
        let data = Self.random(20 << 20); try source.write("movie.bin", data)
        let target = disk.url.appendingPathComponent("movie.bin")
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: target.path))
        let prefix = Data(data.prefix(12 << 20)); try prefix.write(to: part)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress(); saved.started = true; saved.observedBytes = 12 << 20
        let initial = saved, copier = ResumableCopier(plan: plan, root: disk.url); copier.reportInterval = 0
        #expect(throws: CopyError.stopped) {
            _ = try copier.run(from: initial, resuming: true, save: { saved = $0 }, report: {
                if $0.checking && $0.checkedBytes >= 4 << 20 { copier.stop() }
            })
        }
        #expect(saved.observedBytes == 12 << 20 && saved.next == 0)
        #expect(try Data(contentsOf: part) == prefix)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(Self.openPaths(below: disk.url).isEmpty)
        #expect(try Self.run(plan, into: disk.url, from: saved, resuming: true).finished)
        #expect(try Data(contentsOf: target) == data)
    }

    @Test func aRecheckedShorterPartCanLowerTheDisplayedProgress() throws {
        let source = try Folder(), disk = try Folder()
        let data = Self.random(16 << 20); try source.write("movie.bin", data)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress(); saved.started = true
        let first = ResumableCopier(plan: plan, root: disk.url); first.reportInterval = 0
        #expect(throws: CopyError.stopped) {
            _ = try first.run(from: saved, resuming: false, save: { saved = $0 },
                              report: { if $0.copiedBytes > 6 << 20 { first.stop() } })
        }
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: disk.url.appendingPathComponent("movie.bin").path))
        let oldBytes = Int64(try Data(contentsOf: part).count)
        let handle = try FileHandle(forUpdating: part); try handle.truncate(atOffset: UInt64(3 << 20)); try handle.close()
        let second = ResumableCopier(plan: plan, root: disk.url); second.reportInterval = 0
        let before = saved
        #expect(throws: CopyError.stopped) {
            _ = try second.run(from: before, resuming: true, save: { saved = $0 },
                               report: { if !$0.checking && $0.copiedBytes >= 7 << 20 { second.stop() } })
        }
        let actual = Int64(try Data(contentsOf: part).count)
        #expect(actual < oldBytes)
        let paused = CopyQueue.Job(plan: plan, progress: saved)
        #expect(paused.copiedBytes == actual, "a verified shorter prefix replaces the earlier display estimate")
        #expect(try Self.run(plan, into: disk.url, from: saved, resuming: true).finished)
        #expect(try Data(contentsOf: disk.url.appendingPathComponent("movie.bin")) == data)
    }

    @Test func aRolledBackCompletedFileShowsItsRecheckedPartialProgress() throws {
        let source = try Folder(), disk = try Folder()
        let data = Self.random(16 << 20); try source.write("movie.bin", data)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")],
                                     diskKey: "V", volumeName: "qsw", destination: "")
        var saved = try Self.run(plan, into: disk.url)
        #expect(saved.next == 1)
        saved.finished = false; saved.finishedAt = nil
        try disk.write("movie.bin", data.prefix(3 << 20))
        let initial = saved, copier = ResumableCopier(plan: plan, root: disk.url); copier.reportInterval = 0
        #expect(throws: CopyError.stopped) {
            _ = try copier.run(from: initial, resuming: true, save: { saved = $0 },
                               report: { if !$0.checking && $0.copiedBytes > 0 { copier.stop() } })
        }
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: disk.url.appendingPathComponent("movie.bin").path))
        let actual = Int64(try Data(contentsOf: part).count)
        #expect(saved.next == 1 && actual < plan.totalBytes)
        #expect(CopyQueue.Job(plan: plan, progress: saved).copiedBytes == actual,
                "old completed-item accounting cannot override newly verified transfer progress")
        #expect(try Self.run(plan, into: disk.url, from: saved, resuming: true).finished)
        #expect(try Data(contentsOf: disk.url.appendingPathComponent("movie.bin")) == data)
    }

    @Test func anInterruptedCopyResumesAfterTheDiskRolledBack() throws {
        let (source, sources) = try Self.source()
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "")
        // Stop partway through the large file, as when the cable is pulled.
        let first = ResumableCopier(plan: plan, root: disk.url)
        first.reportInterval = 0
        var saved = CopyProgress()
        #expect(throws: CopyError.stopped) {
            _ = try first.run(from: CopyProgress(), resuming: false, save: { saved = $0 }, report: { status in
                if status.copiedBytes > 6 << 20 { first.stop() }
            })
        }
        let big = disk.url.appendingPathComponent("Photos/big.bin")
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: big.path))
        #expect(!FileManager.default.fileExists(atPath: big.path), "a name only ever holds a whole file")
        let partial = try Data(contentsOf: part)
        #expect(partial.count > 6 << 20 && partial.count < 13 << 20)
        // The disk rolls back: the part is cut short and its last megabyte holds
        // stale bytes; a folder made before it is gone again.
        let handle = try FileHandle(forUpdating: part)
        try handle.truncate(atOffset: UInt64(3 << 20))
        try handle.seek(toOffset: UInt64(2 << 20)); try handle.write(contentsOf: Data(repeating: 0xEE, count: 1 << 20))
        try handle.close()
        try? FileManager.default.removeItem(at: disk.url.appendingPathComponent("Photos/2026"))
        let second = try Self.run(plan, into: disk.url, from: saved, resuming: true)
        #expect(second.finished)
        try Self.assertSameTree(source.url, disk.url)
    }

    @Test func replacingAFileKeepsTheOldOneWholeUntilTheCopyIs() throws {
        let source = try Folder(), disk = try Folder()
        let new = Self.random(9 << 20)
        try source.write("report.bin", new)
        let old = Data(repeating: 0x41, count: 5 << 20)
        try disk.write("report.bin", old)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("report.bin")], diskKey: "V", volumeName: "", destination: "")
        let copier = ResumableCopier(plan: plan, root: disk.url)
        copier.reportInterval = 0
        #expect(throws: CopyError.stopped) {
            _ = try copier.run(from: CopyProgress(), resuming: false, save: { _ in }, report: { if $0.copiedBytes > 2 << 20 { copier.stop() } })
        }
        #expect(try Data(contentsOf: disk.url.appendingPathComponent("report.bin")) == old)
        _ = try Self.run(plan, into: disk.url, resuming: true)
        #expect(try Data(contentsOf: disk.url.appendingPathComponent("report.bin")) == new)
    }

    @Test func filesFinishedJustBeforeTheInterruptionAreCheckedAgain() throws {
        let (source, sources) = try Self.source()
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "")
        var saved = CopyProgress()
        _ = try ResumableCopier(plan: plan, root: disk.url).run(from: CopyProgress(), resuming: false, save: { saved = $0 }, report: { _ in })
        // The disk rolled back after the end: one file is gone, one is back to an
        // older version of the same size, one has its old date again.
        saved.finished = false
        #expect(saved.recheckFrom == 0, "everything finished within the window")
        try FileManager.default.removeItem(at: disk.url.appendingPathComponent("Photos/small 3.txt"))
        try Data("small X\n".utf8).write(to: disk.url.appendingPathComponent("Photos/small 7.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: disk.url.path + "/notes.txt")
        _ = try Self.run(plan, into: disk.url, from: saved, resuming: true)
        try Self.assertSameTree(source.url, disk.url)
    }

    @Test func skippedItemsArePassedByEvenWhenRechecked() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        let folder = try #require(plan.items.firstIndex { $0.relative == "Photos/2026" })
        let file = try #require(plan.items.firstIndex { $0.relative == "notes.txt" })
        var progress = CopyProgress(); progress.skipped = [folder, file]
        #expect(try Self.run(plan, into: disk.url, from: progress).finished)
        #expect(!FileManager.default.fileExists(atPath: disk.url.path + "/Photos/2026"))
        #expect(!FileManager.default.fileExists(atPath: disk.url.path + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: disk.url.path + "/Photos/small 19.txt"))
    }

    @Test func aLinkOnTheDiskIsNeverFollowedOffIt() throws {
        let source = try Folder(), disk = try Folder(), outside = try Folder()
        try source.write("Photos/a.txt", Data("new".utf8))
        try outside.write("a.txt", Data("PRECIOUS".utf8))
        try FileManager.default.createSymbolicLink(atPath: disk.url.path + "/Photos", withDestinationPath: outside.url.path)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("Photos")], diskKey: "V", volumeName: "", destination: "")
        #expect(throws: CopyError.linkInPath(disk.url.path + "/Photos")) { _ = try Self.run(plan, into: disk.url) }
        #expect(try Data(contentsOf: outside.url.appendingPathComponent("a.txt")) == Data("PRECIOUS".utf8))
    }

    @Test func nothingIsWrittenWhereTheDiskWasOnceItIsGone() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let base = try Folder()
        let disk = base.url.appendingPathComponent("qsw")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "")
        let copier = ResumableCopier(plan: plan, root: disk)
        copier.reportInterval = 0
        var swapped = false
        do {
            _ = try copier.run(from: CopyProgress(), resuming: false, save: { _ in }, report: { status in
                guard !swapped, status.copiedBytes > 4 << 20 else { return }
                swapped = true
                // Unmounted mid-copy, with an empty folder left at its path.
                try? FileManager.default.moveItem(at: disk, to: base.url.appendingPathComponent("gone"))
                try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            })
            Issue.record("the copy should have stopped")
        } catch let error as CopyError {
            #expect(error.diskUnavailable, "\(error)")
        }
        #expect(swapped)
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.path).isEmpty)
    }

    @Test func aReplacedDiskRootCannotSupplyTheFileBeingFinished() throws {
        let source = try Folder(), base = try Folder()
        let data = Self.random(9 << 20)
        try source.write("movie.bin", data)
        let disk = base.url.appendingPathComponent("disk")
        let gone = base.url.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")], diskKey: "V", volumeName: "", destination: "")
        let copier = ResumableCopier(plan: plan, root: disk)
        copier.reportInterval = 0
        let target = disk.appendingPathComponent("movie.bin")
        let part = URL(fileURLWithPath: ResumableCopier.partPath(for: target.path))
        let unrelated = Data("a part belonging to a different root".utf8)
        var swapped = false, swapError: (any Error)?
        do {
            _ = try copier.run(from: CopyProgress(), resuming: false, save: { _ in }, report: { status in
                guard !swapped, status.copiedBytes >= 4 << 20 else { return }
                swapped = true
                do {
                    // The mount path now leads to another directory containing
                    // a same-named part; the open descriptor still writes to gone.
                    try FileManager.default.moveItem(at: disk, to: gone)
                    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
                    try unrelated.write(to: part)
                } catch { swapError = error }
            })
            Issue.record("a replaced root must stop the copy before metadata or rename")
        } catch let error as CopyError {
            #expect(error.diskUnavailable, "\(error)")
        }
        if let swapError { throw swapError }
        #expect(swapped)
        #expect(!FileManager.default.fileExists(atPath: target.path), "never rename another root's part into the final file")
        #expect((try? Data(contentsOf: part)) == unrelated, "the replacement root's part must stay untouched")
    }

    @Test func resumingCannotRemoveAPartLinkFromAReplacedDiskRoot() throws {
        let source = try Folder(), base = try Folder()
        let data = Data(repeating: 0x41, count: 4096)
        try source.write("movie.bin", data)
        let disk = base.url.appendingPathComponent("disk")
        let gone = base.url.appendingPathComponent("gone")
        let outside = base.url.appendingPathComponent("unrelated.bin")
        let unrelated = Data("keep the link and its target".utf8)
        try unrelated.write(to: outside)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
        let target = disk.appendingPathComponent("movie.bin")
        try Data(repeating: 0x42, count: data.count).write(to: target)
        let part = ResumableCopier.partPath(for: target.path)
        let plan = try CopyPlan.make(sources: [source.url.appendingPathComponent("movie.bin")], diskKey: "V", volumeName: "", destination: "")
        let copier = ResumableCopier(plan: plan, root: disk)
        copier.reportInterval = 0
        var swapped = false, swapError: (any Error)?
        do {
            _ = try copier.run(from: CopyProgress(), resuming: true, save: { _ in }, report: { status in
                guard !swapped, status.checking else { return }
                swapped = true
                do {
                    // The already-open whole file belongs to the original root;
                    // after its comparison fails, no part in the new root is ours.
                    try FileManager.default.moveItem(at: disk, to: gone)
                    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
                    try FileManager.default.createSymbolicLink(atPath: part, withDestinationPath: outside.path)
                } catch { swapError = error }
            })
            Issue.record("a replaced root must stop the resume")
        } catch let error as CopyError {
            #expect(error.diskUnavailable, "\(error)")
        }
        if let swapError { throw swapError }
        #expect(swapped)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: part)) == outside.path,
                "never remove another root's same-named part link")
        #expect(try Data(contentsOf: outside) == unrelated)
    }

    @Test func aFileIsNeverCopiedOntoItself() throws {
        let folder = try Folder()
        try folder.write("Photos/a.txt", Data("keep me".utf8))
        let plan = try CopyPlan.make(sources: [folder.url.appendingPathComponent("Photos")], diskKey: "V", volumeName: "", destination: "")
        #expect(throws: CopyError.sameFile(folder.url.path + "/Photos/a.txt")) { _ = try Self.run(plan, into: folder.url) }
        #expect(try Data(contentsOf: folder.url.appendingPathComponent("Photos/a.txt")) == Data("keep me".utf8))
    }

    @Test func aDamagedProgressRecordCannotCrashTheCopy() throws {
        let (source, sources) = try Self.source()
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        var broken = CopyProgress(); broken.next = 10_000; broken.recheckFrom = -5; broken.skipped = [-1, 1 << 40]
        let clean = broken.sanitized(itemCount: plan.items.count)
        #expect(clean.next == plan.items.count && clean.recheckFrom == 0 && clean.skipped.isEmpty)
        #expect(try Self.run(plan, into: disk.url, from: broken, resuming: true).finished)
        try Self.assertSameTree(source.url, disk.url)
    }

    @Test func recordsRoundTripAndBadOnesAreSkipped() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let records = try Folder()
        let store = CopyJobStore(directory: records.url)
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "qsw", destination: "")
        try store.save(plan)
        var progress = CopyProgress(); progress.next = 5; progress.recheckFrom = 2; progress.pause = .disk; progress.skipped = [3]
        try store.save(progress, for: plan.id)
        try FileManager.default.createDirectory(at: records.url.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: records.url.appendingPathComponent("junk"))
        let loaded = store.load()
        var expected = progress; expected.savedAt = loaded.first?.1.savedAt
        #expect(loaded.count == 1 && loaded[0].0 == plan && loaded[0].1 == expected && expected.savedAt != nil)
        var wild = progress; wild.next = 1 << 40
        try store.save(wild, for: plan.id)
        #expect(store.load()[0].1.next == plan.items.count)
        store.remove(plan.id)
        #expect(store.load().isEmpty)
    }

    @Test func onlyAGoneDiskCountsAsUnavailable() {
        for code in [EIO, ESTALE, ENXIO, EROFS] { #expect(CopyError.destination("/x", code).diskUnavailable) }
        for code in [ENOSPC, ENOENT, EILSEQ, EBUSY, ENOTSUP, ENAMETOOLONG] { #expect(!CopyError.destination("/x", code).diskUnavailable) }
        #expect(!CopyError.source("/x", EIO).diskUnavailable)
        let plan = CopyPlan(id: UUID(), diskKey: "V", volumeName: "", destination: "", items: [], totalBytes: 0, created: Date())
        #expect(throws: CopyError.destination("/nonexistent-volisle-disk", ENXIO)) {
            _ = try Self.run(plan, into: URL(fileURLWithPath: "/nonexistent-volisle-disk"))
        }
    }

    private static func openPaths(below folder: URL) -> [String] {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        return (0..<getdtablesize()).compactMap { fd -> String? in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
            let path = String(cString: buffer)
            return path.hasPrefix(prefix) ? path : nil
        }
    }

    @Test func stoppingWhileCheckingLeavesNoFileOpenOnTheDisk() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        var saved = CopyProgress()
        _ = try ResumableCopier(plan: plan, root: disk.url).run(from: CopyProgress(), resuming: false, save: { saved = $0 }, report: { _ in })
        saved.finished = false
        let copier = ResumableCopier(plan: plan, root: disk.url)
        copier.reportInterval = 0
        #expect(throws: CopyError.stopped) {
            _ = try copier.run(from: saved, resuming: true, save: { _ in }, report: { if $0.checking { copier.stop() } })
        }
        #expect(Self.openPaths(below: disk.url).isEmpty, "an open file keeps the disk from unmounting")
    }

    @Test func savesLostToAQuitDoNotThrowAwayThePart() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        let first = ResumableCopier(plan: plan, root: disk.url)
        first.reportInterval = 0
        var stale: CopyProgress?
        #expect(throws: CopyError.stopped) {
            // Only the first save reaches the record before the app quits.
            _ = try first.run(from: CopyProgress(), resuming: false, save: { if stale == nil { stale = $0 } },
                              report: { if $0.copiedBytes > 6 << 20 { first.stop() } })
        }
        let second = ResumableCopier(plan: plan, root: disk.url)
        second.reportInterval = 0
        var comparedPart = false
        _ = try second.run(from: try #require(stale), resuming: true, save: { _ in },
                           report: { if $0.checking && $0.current == "Photos/big.bin" { comparedPart = true } })
        #expect(comparedPart, "the part was compared and continued, not emptied")
        try Self.assertSameTree(tree.url, disk.url)
    }

    @Test func aSkippedFolderStaysOutWhenTheRecheckStartsInsideIt() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        let folder = try #require(plan.items.firstIndex { $0.relative == "Photos/2026" })
        var progress = CopyProgress()
        progress.next = plan.items.count; progress.recheckFrom = folder + 1; progress.skipped = [folder]
        #expect(try Self.run(plan, into: disk.url, from: progress, resuming: true).finished)
        #expect(!FileManager.default.fileExists(atPath: disk.url.path + "/Photos/2026"))
    }

    @Test func originalsGoneSinceTheCopyAreNotedInsteadOfStoppingTheRecheck() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        var saved = CopyProgress()
        _ = try ResumableCopier(plan: plan, root: disk.url).run(from: CopyProgress(), resuming: false, save: { saved = $0 }, report: { _ in })
        try FileManager.default.removeItem(at: tree.url.appendingPathComponent("Photos/small 4.txt"))
        saved.finished = false
        let done = try Self.run(plan, into: disk.url, from: saved, resuming: true)
        let index = try #require(plan.items.firstIndex { $0.relative == "Photos/small 4.txt" })
        #expect(done.finished && done.vanished == [index] && done.failedAt == nil)
        // Something never copied is still a problem when its original is gone.
        var fresh = CopyProgress(); fresh.next = index; fresh.recheckFrom = index
        try FileManager.default.removeItem(at: disk.url.appendingPathComponent("Photos/small 4.txt"))
        var failed: CopyProgress?
        #expect(throws: CopyError.self) {
            _ = try ResumableCopier(plan: plan, root: disk.url).run(from: fresh, resuming: true, save: { failed = $0 }, report: { _ in })
        }
        #expect(failed?.failedAt == index)
    }

    @Test func aLinkReplacesWhatHasItsNameInOneStep() throws {
        let (tree, sources) = try Self.source()
        defer { withExtendedLifetime(tree) {} }
        let disk = try Folder()
        try disk.write("Photos/link", Data("a file where the link goes".utf8))
        let plan = try CopyPlan.make(sources: sources, diskKey: "V", volumeName: "", destination: "")
        #expect(try Self.run(plan, into: disk.url).finished)
        try Self.assertSameTree(tree.url, disk.url)
    }

    @Test func partsAreRemovedOnlyBelowTheDiskAndOnlyPartsAtThat() throws {
        let disk = try Folder(), outside = try Folder()
        try disk.write("a/.x.bin.volisle-part", Data("part".utf8))
        try disk.write("a/x.bin", Data("the user's file".utf8))
        try outside.write(".y.bin.volisle-part", Data("outside".utf8))
        try FileManager.default.createSymbolicLink(atPath: disk.url.path + "/out", withDestinationPath: outside.url.path)
        ResumableCopier.removePart(of: "a/x.bin", root: disk.url.path)
        ResumableCopier.removePart(of: "out/y.bin", root: disk.url.path)
        ResumableCopier.removePart(of: "../escape", root: disk.url.path)
        #expect(!FileManager.default.fileExists(atPath: disk.url.path + "/a/.x.bin.volisle-part"))
        #expect(FileManager.default.fileExists(atPath: disk.url.path + "/a/x.bin"))
        #expect(FileManager.default.fileExists(atPath: outside.url.path + "/.y.bin.volisle-part"), "never through a link")
    }
}
