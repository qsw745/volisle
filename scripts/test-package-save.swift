// Package documents (RTFD, Pages, Keynote…) are folders. Apps save them with
// NSDocument's safe save: write a complete new copy into a replacement folder
// on the same volume, then swap it in. This drives that exact AppKit path on
// a mounted volume.  swiftc -O scripts/test-package-save.swift -o /tmp/pkgsave && /tmp/pkgsave <mounted folder>
import AppKit
import CryptoKit

final class PackageDocument: NSDocument {
    var files: [String: Data] = [:]
    override class var autosavesInPlace: Bool { false }
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var top: [String: FileWrapper] = [:], nested: [String: FileWrapper] = [:]
        for (path, data) in files {
            if path.hasPrefix("Data/") { nested[String(path.dropFirst(5))] = FileWrapper(regularFileWithContents: data) }
            else { top[path] = FileWrapper(regularFileWithContents: data) }
        }
        if !nested.isEmpty { top["Data"] = FileWrapper(directoryWithFileWrappers: nested) }
        return FileWrapper(directoryWithFileWrappers: top)
    }
    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {}
}

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Every file under the package, relative path → content hash.
func listing(_ url: URL) -> [String: String] {
    var result: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
    for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let relative = String(file.path.dropFirst(url.path.count + 1))
        result[relative] = digest((try? Data(contentsOf: file)) ?? Data())
    }
    return result
}

/// Leftovers of a safe save: temporary folders on the volume root.
func leftovers(_ root: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var found = names.filter { $0.contains("Document Being Saved") || $0.hasPrefix(".dat") }
    let temporary = root.appendingPathComponent(".TemporaryItems")
    if let walker = FileManager.default.enumerator(atPath: temporary.path) {
        for case let item as String in walker where !item.hasPrefix("folders.") || item.split(separator: "/").count > 1 { found.append(".TemporaryItems/" + item) }
    }
    return found
}

guard (2...3).contains(CommandLine.arguments.count) else { fail("usage: pkgsave <mounted folder> [--nearly-full]") }
if CommandLine.arguments.count == 3 {
    guard CommandLine.arguments[2] == "--nearly-full" else { fail("unknown option") }
    nearlyFull(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)); exit(0)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let folder = root.appendingPathComponent("文稿包测试-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
let url = folder.appendingPathComponent("报告.rtfd", isDirectory: true)
let document = PackageDocument()
var checks = 0

func save(_ operation: NSDocument.SaveOperationType, round: Int) {
    var files: [String: Data] = ["TXT.rtf": Data("{\\rtf1 第 \(round) 版 \(UUID())}".utf8)]
    files["image.png"] = Data((0..<(200_000 + round * 37_000)).map { UInt8(truncatingIfNeeded: $0 &* (round + 3)) })
    if round % 2 == 0 { files["Data/notes-\(round).bin"] = Data(repeating: UInt8(round), count: 64_000) }  // files come and go
    if round % 3 == 0 { files["Data/中文附件.txt"] = Data("附件 \(round)".utf8) }
    document.files = files
    do { try document.writeSafely(to: url, ofType: "com.apple.rtfd", for: operation) }
    catch { fail("第 \(round) 次保存失败：\(error.localizedDescription)") }
    document.fileURL = url
    let expected = files.mapValues(digest)
    let actual = listing(url)
    guard actual == expected else { fail("第 \(round) 次保存后内容不符：\(actual.keys.sorted()) vs \(expected.keys.sorted())") }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { fail("文稿包不是文件夹") }
    let stray = leftovers(root)
    guard stray.isEmpty else { fail("第 \(round) 次保存后残留临时文件：\(stray)") }
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    guard siblings == ["报告.rtfd"] else { fail("文稿旁多出文件：\(siblings)") }
    checks += 1
}

save(.saveAsOperation, round: 0)
for round in 1...30 { save(.saveOperation, round: round) }
// "Save a copy" style, then keep editing the original.
let copy = folder.appendingPathComponent("报告 副本.rtfd", isDirectory: true)
do { try document.writeSafely(to: copy, ofType: "com.apple.rtfd", for: .saveToOperation) } catch { fail("另存副本失败：\(error)") }
guard listing(copy) == listing(url) else { fail("副本内容不符") }
try FileManager.default.removeItem(at: copy)
for round in 31...35 { save(.saveOperation, round: round) }
// Plain FileManager replacement of a folder, used by many non-NSDocument apps.
let staged = root.appendingPathComponent(".staged-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
try Data("replaced".utf8).write(to: staged.appendingPathComponent("TXT.rtf"))
_ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
guard listing(url) == ["TXT.rtf": digest(Data("replaced".utf8))] else { fail("replaceItemAt 结果不符：\(listing(url))") }
guard !FileManager.default.fileExists(atPath: staged.path) else { fail("replaceItemAt 留下了暂存文件夹") }
checks += 1
try FileManager.default.removeItem(at: folder)
print("{\"saves\":\(checks),\"leftovers\":\(leftovers(root).count)}")

/// Safe save needs room for a whole second copy. On a nearly full volume it
/// must fail cleanly: the original stays intact and the temporary copy is gone.
func nearlyFull(_ root: URL) {
    let folder = root.appendingPathComponent("满盘保存-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let url = folder.appendingPathComponent("大文稿.rtfd", isDirectory: true)
    let filler = root.appendingPathComponent("filler.bin")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let document = PackageDocument()
        let big = Data((0..<40_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        document.files = ["TXT.rtf": Data("原始版本".utf8), "Data/movie.bin": big]
        try document.writeSafely(to: url, ofType: "com.apple.rtfd", for: .saveAsOperation)
        document.fileURL = url
        let original = listing(url)
        // Leave about 10 MB free: less than the 40 MB second copy needs.
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        let handle = try FileHandle(forWritingTo: { FileManager.default.createFile(atPath: filler.path, contents: nil); return filler }())
        let chunk = Data(repeating: 0xEE, count: 1 << 20)
        for _ in 0..<max(0, (free - 10_000_000) >> 20) { try handle.write(contentsOf: chunk) }
        try handle.close()
        document.files = ["TXT.rtf": Data("新版本".utf8), "Data/movie.bin": big + Data(repeating: 1, count: 1000)]
        var failed = false
        do { try document.writeSafely(to: url, ofType: "com.apple.rtfd", for: .saveOperation) }
        catch { failed = true; print("保存失败（预期）：\(error.localizedDescription)") }
        guard failed else { fail("空间不足时保存竟然成功") }
        guard listing(url) == original else { fail("保存失败后原文稿被改动：\(listing(url).keys.sorted())") }
        let stray = leftovers(root)
        guard stray.isEmpty else { fail("保存失败后残留临时文件：\(stray)") }
        try FileManager.default.removeItem(at: filler)
        try document.writeSafely(to: url, ofType: "com.apple.rtfd", for: .saveOperation)
        guard listing(url) == document.files.mapValues(digest) else { fail("腾出空间后保存内容不符") }
        try FileManager.default.removeItem(at: folder)
        print("{\"nearlyFull\":\"ok\",\"leftovers\":\(leftovers(root).count)}")
    } catch {
        try? FileManager.default.removeItem(at: filler)
        fail("满盘保存测试出错：\(error)")
    }
}
