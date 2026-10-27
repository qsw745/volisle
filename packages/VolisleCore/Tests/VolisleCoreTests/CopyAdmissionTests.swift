import Foundation
import Testing
@testable import VolisleCore

struct CopyAdmissionTests {
    private final class Files {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func plan(_ name: String = "file.bin", destination: String = "") throws -> CopyPlan {
            let source = root.appendingPathComponent(name)
            try Data("source".utf8).write(to: source)
            return try CopyPlan.make(sources: [source], diskKey: "V", volumeName: "Disk", destination: destination).usingOwnedParts()
        }
    }

    @Test func separateJobsNeverShareAPartAndCancelOnlyRemovesItsOwn() throws {
        let files = try Files(), a = try files.plan(), b = try files.plan()
        let target = files.root.appendingPathComponent("final.bin")
        let ap = ResumableCopier.partPath(for: target.path, partID: a.partID)
        let bp = ResumableCopier.partPath(for: target.path, partID: b.partID)
        #expect(ap != bp)
        try Data("original".utf8).write(to: target)
        try Data("A".utf8).write(to: URL(fileURLWithPath: ap))
        try Data("B".utf8).write(to: URL(fileURLWithPath: bp))
        ResumableCopier.removePart(of: "final.bin", root: files.root.path, partID: a.partID)
        #expect(!FileManager.default.fileExists(atPath: ap))
        #expect(try Data(contentsOf: URL(fileURLWithPath: bp)) == Data("B".utf8))
        #expect(try Data(contentsOf: target) == Data("original".utf8))
    }

    @Test func oldPlansKeepTheirOldPartNamesAndForeignPartIDsAreRejected() throws {
        let files = try Files()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(files.plan())) as? [String: Any])
        json.removeValue(forKey: "partID")
        let legacy = try JSONDecoder().decode(CopyPlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.partID == nil)
        #expect(ResumableCopier.partPath(for: "/disk/file.bin", partID: legacy.partID) == "/disk/.file.bin.volisle-part")
        json["partID"] = UUID().uuidString
        let invalid = try JSONDecoder().decode(CopyPlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: CopyError.invalidPlan) { try invalid.validate() }
    }

    @Test func longOwnedPartNamesStayWithinTheFilesystemLimit() {
        let name = String(repeating: "🙂", count: 180) + ".bin"
        let id = UUID(), part = ResumableCopier.partPath(for: "/disk/" + name, partID: id)
        #expect((part as NSString).lastPathComponent.utf16.count <= 255)
        #expect(part != ResumableCopier.partPath(for: "/disk/" + name, partID: UUID()))
    }

    @Test func conflictRulesCoverCaseUnicodeAndParentDirectories() throws {
        let files = try Files()
        func overlap(_ a: CopyPlan, _ b: CopyPlan) -> Bool {
            CopyAdmission.overlap(CopyAdmission.claims(for: a), CopyAdmission.claims(for: b))
        }
        #expect(overlap(try files.plan(destination: "Backup"), try files.plan(destination: "backup")))
        #expect(overlap(try files.plan(destination: "é"), try files.plan(destination: "e\u{301}")))
        let directory = files.root.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: directory.appendingPathComponent("one.bin"))
        let album = try CopyPlan.make(sources: [directory], diskKey: "V", volumeName: "Disk", destination: "Backup").usingOwnedParts()
        #expect(overlap(album, try files.plan(destination: "Backup/Album/Sub")))
        #expect(!overlap(album, try files.plan(destination: "Backup/Album2")))
        #expect(!overlap(try files.plan("a.bin"), try files.plan("b.bin")))
        #expect(!overlap(try files.plan(".hidden"), try files.plan("hidden")))
        #expect(overlap(try files.plan("..."), try files.plan("...")))
    }

    @Test func aUserTargetCannotOverlapAnotherJobsPart() throws {
        let files = try Files(), a = try files.plan()
        let hiddenName = (ResumableCopier.partPath(for: "/file.bin", partID: a.partID) as NSString).lastPathComponent
        let b = try files.plan(hiddenName)
        #expect(CopyAdmission.overlap(CopyAdmission.claims(for: a), CopyAdmission.claims(for: b)))
    }
}
