import Foundation
import Darwin

enum Injected: Error { case fault }

// Test-only durable CAS provider. This is NOT a trusted helper/Keychain store.
final class Anchor {
    struct Record: Codable {
        let binding: BlockJournalBinding
        let sequence: Int
        let authentication: String
        var seal: BlockJournalSeal { .init(sequence: sequence, authentication: authentication) }
    }
    let directory: URL
    var fault: ((String, BlockJournalSeal) throws -> Void)?
    var trace: ((String) -> Void)?
    init(_ directory: URL) { self.directory = directory }
    func read() throws -> Record? {
        let file = directory.appendingPathComponent("anchor.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
    }
    func save(_ binding: BlockJournalBinding, _ previous: BlockJournalSeal?, _ next: BlockJournalSeal) throws -> BlockJournalSeal {
        trace?("anchor-start-\(next.sequence)")
        let old = try read()
        guard old?.seal == previous, old == nil || old?.binding == binding else { throw Injected.fault }
        try fault?("before", next)
        let bytes = try JSONEncoder().encode(Record(binding: binding, sequence: next.sequence, authentication: next.authentication))
        let temp = directory.appendingPathComponent("anchor.tmp")
        try bytes.write(to: temp)
        let fd = open(temp.path, O_RDWR); guard fd >= 0 else { throw Injected.fault }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0,
              rename(temp.path, directory.appendingPathComponent("anchor.json").path) == 0 else { throw Injected.fault }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { throw Injected.fault }; defer { Darwin.close(dir) }
        guard fsync(dir) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Injected.fault }
        trace?("anchor-durable-\(next.sequence)")
        try fault?("after", next)
        return next
    }
}

