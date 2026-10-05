// Only new 64 MiB regular-file fixtures; never a mounted/physical device.
import Foundation
import CryptoKit
import Darwin

private func require(_ value: Bool) throws { if !value { throw BlockJournalError.failed } }
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func rejected(_ body: () throws -> Void) throws {
    do { try body() } catch { return }; throw BlockJournalError.failed
}
@main struct Main {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".workbench")
            .appendingPathComponent("block-journal-device-" + UUID().uuidString.lowercased())
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var checks: [String] = []
        for fault in ["none", "unlock", "rename", "symlink", "hardlink", "size", "boot", "parent", "read-rename", "write-error"] {
            // Transport requires image directly beneath .workbench/block-journal-*.
            let path = root.appendingPathComponent(fault + ".img").path
            let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try require(fd >= 0)
            defer { Darwin.close(fd) }
            try require(ftruncate(fd, 64*1024*1024) == 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
            let boot = Data(repeating: 7, count: 512)
            try require(boot.withUnsafeBytes { pwrite(fd, $0.baseAddress, 512, 0) } == 512)
            var info = stat(); try require(fstat(fd, &info) == 0)
            let binding = BlockJournalBinding(transactionID: UUID(), volumeIdentity: "\(info.st_dev):\(info.st_ino)",
                bootSHA256: hash(boot), deviceSize: Int64(info.st_size), blockSize: 4096)
            let transport = try DetachedRecoveryDevice(path: path, heldDescriptor: fd, binding: binding)
            let session = try transport.session()
            defer { session.close() }
            let moved = path + ".held"
            switch fault {
            case "unlock": try require(flock(fd, LOCK_UN) == 0)
            case "rename":
                try fm.moveItem(atPath: path, toPath: moved)
                try fm.copyItem(atPath: moved, toPath: path)
            case "symlink":
                try fm.moveItem(atPath: path, toPath: moved)
                try fm.createSymbolicLink(atPath: path, withDestinationPath: moved)
            case "hardlink": try require(link(path, moved) == 0)
            case "size": try require(ftruncate(fd, 64*1024*1024-512) == 0)
            case "boot":
                let wrong = Data(repeating: 8, count: 512)
                try require(wrong.withUnsafeBytes { pwrite(fd, $0.baseAddress, 512, 0) } == 512)
            case "parent":
                try fm.moveItem(at: root, to: root.appendingPathExtension("moved"))
                try fm.createDirectory(at: root, withIntermediateDirectories: false)
            case "read-rename":
                transport.beforeRead = {
                    try fm.moveItem(atPath: path, toPath: moved)
                    try fm.copyItem(atPath: moved, toPath: path)
                }
            case "write-error":
                transport.beforeWrite = { descriptor, offset, data in
                    try require(data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, data.count/2, off_t(offset)) } == data.count/2)
                    throw BlockJournalError.unavailable
                }
            default: break
            }
            if fault == "none" {
                try session.write(offset: 4096, bytes: Data(repeating: 9, count: 4096))
                try session.flush()
                try require(try session.read(offset: 4096, count: 4096) == Data(repeating: 9, count: 4096))
            } else {
                try rejected {
                    if fault == "read-rename" { _ = try session.read(offset: 4096, count: 4096) }
                    else { try session.write(offset: 4096, bytes: Data(repeating: 9, count: 4096)) }
                }
                try require(session.failed && transport.writes == (fault == "write-error" ? 1 : 0))
                try rejected { try session.flush() }
                var actual = Data(count: 4096)
                try require(actual.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, 4096) } == 4096)
                let expected = fault == "write-error" ? Data(repeating: 9, count: 2048) + Data(repeating: 0, count: 2048) : Data(repeating: 0, count: 4096)
                try require(actual == expected)
            }
            session.close(); session.close()
            checks.append(fault)
            if fault == "parent" {
                try fm.removeItem(at: root)
                try fm.moveItem(at: root.appendingPathExtension("moved"), to: root)
            }
        }
        let report: [String: Any] = ["passed": checks.count, "checks": checks, "physicalDevicesTouched": false]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: root.appendingPathComponent("result.json"))
        // Keep small evidence, delete only new successful fixture files.
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.lastPathComponent != "result.json" {
            try fm.removeItem(at: url)
        }
        print(String(decoding: bytes, as: UTF8.self))
        print(root.appendingPathComponent("result.json").path)
    }
}
