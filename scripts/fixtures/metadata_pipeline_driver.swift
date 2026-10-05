// Detached 64 MiB fixtures only. This recorder is NOT shipped with FSKit.
import Foundation
import CryptoKit
import Darwin

private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func require(_ okay: Bool) throws { if !okay { throw POSIXError(.EIO) } }

private final class Driver {
    let image: Int32
    let log: Int32
    let pipeline = MetadataWritePipeline()
    var sequence = 0
    var previous = String(repeating: "0", count: 64)
    var writes = 0
    var target = 0
    var fault = "none"
    let blockSize: Int
    init(imagePath: String, logPath: String, blockSize: Int) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench")
        let url = URL(fileURLWithPath: imagePath)
        let journal = URL(fileURLWithPath: logPath)
        try require(url.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        try require(url.deletingLastPathComponent().lastPathComponent.hasPrefix("block-journal-"))
        try require(url.resolvingSymlinksInPath().path == url.path && journal.deletingLastPathComponent().path == url.deletingLastPathComponent().path)
        self.blockSize = blockSize
        image = Darwin.open(imagePath, O_RDWR | O_NOFOLLOW)
        guard image >= 0 else { throw POSIXError(.EIO) }
        var info = stat()
        try require(fstat(image, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == getuid() && info.st_size == 64*1024*1024)
        try require(flock(image, LOCK_EX | LOCK_NB) == 0)
        log = Darwin.open(logPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard log >= 0 else { Darwin.close(image); throw POSIXError(.EIO) }
        let content = try allBytes()
        try require(content[3..<11] == Data("NTFS    ".utf8))
        try append(["kind":"begin", "schema":1, "device":Int(info.st_dev), "inode":UInt64(info.st_ino),
                    "size":64*1024*1024, "originalSHA256":hash(content), "bootSHA256":hash(content.prefix(512))])
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(directory) }
        try require(fsync(directory) == 0)
    }
    deinit { Darwin.close(log); Darwin.close(image) }
    func allBytes() throws -> Data {
        var bytes = Data(count: 64*1024*1024)
        let count = bytes.withUnsafeMutableBytes { Darwin.pread(image, $0.baseAddress!, $0.count, 0) }
        try require(count == bytes.count)
        return bytes
    }
    func append(_ event: [String: Any]) throws {
        var payload = event
        payload["sequence"] = sequence; payload["previous"] = previous
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: options)
        let digest = hash(raw)
        var bytes = try JSONSerialization.data(withJSONObject: ["payload":payload, "sha256":digest], options: options)
        bytes.append(10)
        try require(lseek(log, 0, SEEK_END) <= 128*1024*1024 - bytes.count)
        try bytes.withUnsafeBytes { buffer in
            var at = 0
            while at < buffer.count {
                let count = Darwin.write(log, buffer.baseAddress!.advanced(by: at), buffer.count-at)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0); at += count
            }
        }
        try require(fsync(log) == 0)
        previous = digest; sequence += 1
    }
    func write(_ pointer: UnsafeRawPointer, count: Int64, offset: Int64) throws {
        try require(count >= 0)
        try pipeline.write(UnsafeRawBufferPointer(start:pointer,count:Int(count)), offset:offset, blockSize:blockSize, deviceSize:64*1024*1024,
            read: { at, block in try require(Darwin.pread(self.image,block.baseAddress!,block.count,off_t(at)) == block.count) },
            record: { intent in
                if self.fault == "journal" && self.writes+1 == self.target { throw POSIXError(.ENOSPC) }
                try self.append(["kind":"write", "offset":intent.offset, "before":intent.before.base64EncodedString(), "after":intent.after.base64EncodedString()])
            }, write: { at, block in
                self.writes += 1
                if self.fault == "fail" && self.writes == self.target { throw POSIXError(.EIO) }
                let partial = self.fault == "partial" && self.writes == self.target
                let count = partial ? max(1,block.count/2) : block.count
                try require(Darwin.pwrite(self.image,block.baseAddress!,count,off_t(at)) == count)
                if (self.fault == "crash" || partial) && self.writes == self.target { _ = fsync(self.image); _exit(86) }
            })
    }
    func commit() throws {
        try require(fsync(image) == 0)
        try append(["kind":"committed", "imageSHA256":hash(try allBytes())])
    }
}

@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 7)
        let driver = try Driver(imagePath:args[1],logPath:args[2],blockSize:Int(args[6])!)
        var io = nk_io(ctx:Unmanaged.passUnretained(driver).toOpaque(), pread: { ctx, buffer, count, offset in
            guard let ctx, let buffer, count >= 0 else { return -1 }
            let owner = Unmanaged<Driver>.fromOpaque(ctx).takeUnretainedValue()
            return Int64(Darwin.pread(owner.image,buffer,Int(count),off_t(offset)))
        }, pwrite: { ctx, buffer, count, offset in
            guard let ctx, let buffer else { return -1 }
            let owner = Unmanaged<Driver>.fromOpaque(ctx).takeUnretainedValue()
            do { try owner.write(buffer,count:count,offset:offset); return count }
            catch { errno = EIO; return -1 }
        }, size:64*1024*1024, readonly:0, sync: { ctx in
            guard let ctx else { return -1 }
            return fsync(Unmanaged<Driver>.fromOpaque(ctx).takeUnretainedValue().image)
        })
        guard let volume = nk_mount_io(&io,nil,0) else { throw POSIXError(.EIO) }
        let start = driver.writes
        driver.fault = args[4]; driver.target = start + Int(args[5])!
        let result = args[3] == "directory" ? nk_mkdir(volume,"/","new-node") : nk_create(volume,"/","new-node")
        if driver.fault == "fail" || driver.fault == "journal" {
            try require(result == -1 && nk_umount(volume) == -1)
            print("{\"failedAsExpected\":true}"); return
        }
        try require(result == 0)
        let count = driver.writes - start
        try require(nk_umount(volume) == 0)
        try driver.commit()
        if driver.fault == "committed-crash" { _exit(86) }
        print("{\"writes\":\(count)}")
    }
}
