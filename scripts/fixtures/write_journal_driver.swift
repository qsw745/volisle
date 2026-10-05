// Disposable image fixtures only. Compiles the SAME journal sources as the
// FSKit extension; only the block device below is a test double.
import Foundation
import Darwin

private func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }

final class ImageDevice: JournalBlockDevice {
    let fd: Int32
    let journalBlockSize: Int
    let journalDeviceSize: Int64
    var flushIsDurable = true
    var writes = 0, flushes = 0
    var fault = "none", target = 0
    var written: [Int64] = []
    /// VOLATILE_LOSS=middle|scatter: a drive cache that loses power. Writes the
    /// last checkpoint flush "made durable" are partly undone at a crash.
    let loss = ProcessInfo.processInfo.environment["VOLATILE_LOSS"]
    private var undo: [(Int64, Data)] = []
    private var flushMarks: [Int] = []

    init(path: String, blockSize: Int) {
        fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { fail("image") }
        var info = stat(); fstat(fd, &info)
        journalBlockSize = blockSize; journalDeviceSize = Int64(info.st_size)
    }
    func journalRead(into block: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        guard Darwin.pread(fd, block.baseAddress, block.count, off_t(offset)) == block.count else { throw POSIXError(.EIO) }
    }
    func journalReadRun(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        guard Darwin.pread(fd, buffer.baseAddress, buffer.count, off_t(offset)) == buffer.count else { throw POSIXError(.EIO) }
    }
    func journalWrite(_ block: UnsafeRawBufferPointer, at offset: Int64) throws {
        writes += 1; written.append(offset)
        let hit = writes == target
        if hit && fault == "fail" { throw POSIXError(.EIO) }
        let count = hit && (fault == "partial" || fault == "short") ? block.count / 2 : block.count
        if loss != nil {
            var prior = Data(count: block.count)
            _ = prior.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, block.count, off_t(offset)) }
            undo.append((offset, prior))
        }
        guard Darwin.pwrite(fd, block.baseAddress, count, off_t(offset)) == count else { throw POSIXError(.EIO) }
        if hit && fault == "short" { throw POSIXError(.EIO) }
        if hit && (fault == "crash" || fault == "partial") { loseCache(); fsync(fd); _exit(86) }
    }
    private func loseCache() {
        guard let loss, let end = flushMarks.last else { return }
        let start = flushMarks.count >= 2 ? flushMarks[flushMarks.count - 2] : 0
        let window = Array(undo[start..<end])
        let lost: [(Int64, Data)]
        switch loss {
        case "middle": lost = Array(window[window.count / 4..<window.count * 3 / 4])
        case "scatter": lost = window.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        default: fail("loss")
        }
        for (offset, prior) in lost.reversed() {
            _ = prior.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, prior.count, off_t(offset)) }
        }
        FileHandle.standardError.write(Data("LOST \(lost.count) of \(window.count)\n".utf8))
    }
    func journalFlush() throws {
        flushes += 1
        if fault == "flush-fail" && flushes == target { throw POSIXError(.EIO) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        if loss != nil {
            flushMarks.append(undo.count)
            if flushMarks.count > 2 {
                let drop = flushMarks[flushMarks.count - 3]
                undo.removeFirst(drop); flushMarks = flushMarks.suffix(2).map { $0 - drop }
            }
        }
    }
}

/// Engine-level faults mirror the original 2026-09-24 numbering (Nth pwrite).
final class CountingIO {
    let inner: JournaledIO
    var pwrites = 0, fault = "none", target = 0
    init(_ inner: JournaledIO) { self.inner = inner }
    func makeIO() -> nk_io {
        nk_io(ctx: Unmanaged.passUnretained(self).toOpaque(), pread: { ctx, b, c, o in
            Unmanaged<CountingIO>.fromOpaque(ctx!).takeUnretainedValue().inner.pread(b!, c, o)
        }, pwrite: { ctx, b, c, o in
            let me = Unmanaged<CountingIO>.fromOpaque(ctx!).takeUnretainedValue()
            me.pwrites += 1
            if me.pwrites == me.target && me.fault == "engine-fail" { me.inner.session?.stop(); return -1 }
            let result = me.inner.pwrite(b!, c, o)
            if me.pwrites == me.target && me.fault == "engine-crash" { _exit(86) }
            return result
        }, size: inner.device.journalDeviceSize, readonly: 0, sync: { ctx in
            Unmanaged<CountingIO>.fromOpaque(ctx!).takeUnretainedValue().inner.sync()
        })
    }
}

/// Mirrors NTFSVolume.attachFreeSpaceMap.
func attachFreeSpace(_ volume: OpaquePointer, _ session: WriteJournalSession, _ device: ImageDevice) {
    var clusterSize: Int64 = 0, clusters: Int64 = 0, count = 0
    var runs = [nk_extent](repeating: nk_extent(), count: 256)
    guard nk_bitmap_layout(volume, &clusterSize, &clusters, &runs, runs.count, &count) == 0,
          let map = FreeSpaceMap(clusterSize: clusterSize, clusters: clusters,
                                 runs: runs.prefix(count).map { ($0.offset, $0.length) }, deviceSize: device.journalDeviceSize) else { fail("bitmap") }
    session.freeSpace = map
}

/// Each MiB distinct; the Python checks compute the same bytes.
func pattern(_ index: Int) -> Data {
    var data = Data(count: 1048576)
    data.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for j in 0..<1048576 { bytes[j] = UInt8(truncatingIfNeeded: (j &* 31) ^ (index &* 131) ^ (j >> 12)) }
    }
    return data
}

/// BDE_KEY (a BitLocker volume master key): mirrors NTFSVolume.openEngine for an
/// encrypted volume — the engine runs on the decrypted view of the journaled
/// device, and every before-image is kept (attachFreeSpaceMap is skipped).
let bitLockerKey = ProcessInfo.processInfo.environment["BDE_KEY"]
nonisolated(unsafe) var bitLockerHandle: OpaquePointer?  // kept open for the process lifetime

func engineIO(_ io: inout nk_io) -> nk_io {
    guard let key = bitLockerKey else { return io }
    guard let handle = nk_bde_open(&io, Int32(NK_BDE_KEY), key, nil, 0) else { fail("bde") }
    bitLockerHandle = handle
    return nk_bde_io(handle)
}

func checkpoint(_ volume: OpaquePointer, _ io: JournaledIO) throws {
    guard nk_sync(volume) == 0 else { throw POSIXError(.EIO) }
    try io.session!.checkpoint()
}

@main struct Main {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count >= 4 else { fail("usage") }
        let device = ImageDevice(path: a[2], blockSize: Int(ProcessInfo.processInfo.environment["BLOCK"] ?? "4096")!)
        let store = try WriteJournalStore(directory: URL(fileURLWithPath: a[3]))
        let io = JournaledIO(device: device)
        io.bitLockerKey = bitLockerKey
        let serial = "0123456789abcdef"
        switch a[1] {
        case "recover":
            if a.count == 6 { device.fault = a[4]; device.target = Int(a[5])! }
            let outcome = WriteJournalCoordinator.recover(store: store, serial: serial, io: io)
            let text: String
            switch outcome {
            case .none: text = "none"
            case .recovered: text = "recovered"
            case .superseded: text = "superseded"
            case .refused(let error): text = "refused-\(error)"
            }
            print("{\"outcome\":\"\(text)\",\"writes\":\(device.writes)}")
        case "op":
            // op <image> <dir> <kind> <fault> <n>
            let kind = a[4], fault = a[5], n = Int(a[6])!
            let (session, lock) = try WriteJournalCoordinator.begin(store: store, serial: serial, io: io)
            if let seconds = ProcessInfo.processInfo.environment["RETENTION"] { session.retention = TimeInterval(seconds)! }
            let counting = CountingIO(io)
            var counted = counting.makeIO()
            var nkio = engineIO(&counted)
            guard let volume = nk_mount_io(&nkio, nil, 0) else { fail("mount") }
            if ProcessInfo.processInfo.environment["KEEP_ALL_BEFORE"] == nil && bitLockerKey == nil { attachFreeSpace(volume, session, device) }
            try checkpoint(volume, io)                     // checkpoint A
            if fault == "checkpoint-crash" || fault.hasPrefix("journal-") {
                var hits = 0
                session.boundary = { name in
                    hits += 1
                    if fault == "journal-fail" && name == "group-before-record" && hits >= n { throw POSIXError(.ENOSPC) }
                    if fault == "journal-crash" && name == "group-recorded" { _exit(86) }
                    if fault == "checkpoint-crash" && name == "checkpoint-before-record" { _exit(86) }
                }
            } else if fault.hasPrefix("engine-") {
                counting.fault = fault; counting.target = counting.pwrites + n
            } else {
                device.fault = fault; device.target = (fault == "flush-fail" ? device.flushes : device.writes) + n
            }
            let before = device.writes, pwritesBefore = counting.pwrites
            var result: Int32 = 0
            switch kind {
            case "file": result = nk_create(volume, "/", "new-node")
            case "next": result = nk_create(volume, "/", "next-session")
            case "directory": result = nk_mkdir(volume, "/", "new-node")
            case "write":
                let data = Data(repeating: 0x5a, count: 3 * 1024 * 1024 + 123)
                result = data.withUnsafeBytes { nk_write(volume, "/sentinel", 4096, Int64($0.count), $0.baseAddress) } == Int64(data.count) ? 0 : -1
            case "many":
                for index in 0..<40 where result == 0 { result = nk_create(volume, "/", "many-\(index)") }
            case "big":
                // One epoch larger than the hard cap must stop, never grow.
                let mebibytes = Int(ProcessInfo.processInfo.environment["BIG_MIB"] ?? "300")!
                result = nk_create(volume, "/", "big")
                // PATTERNED: each MiB distinct, so a recovered prefix can be checked block by block.
                let patterned = ProcessInfo.processInfo.environment["PATTERNED"] != nil
                for index in 0..<mebibytes where result == 0 {
                    let chunk = patterned ? pattern(index) : Data(repeating: 0xa5, count: 1024 * 1024)
                    let wrote = chunk.withUnsafeBytes { nk_write(volume, "/big", Int64(index) * 1048576, 1048576, $0.baseAddress) }
                    if wrote != 1048576 { result = -1 }
                    // Mirrors NTFSVolume.requireWritableEngine: boundary checkpoint when due.
                    if result == 0, ProcessInfo.processInfo.environment["OP_CHECKPOINTS"] != nil, io.session!.checkpointDue {
                        do { try checkpoint(volume, io) } catch { result = -1 }
                    }
                }
            case "reuse":
                // A file older than the retention window is deleted inside it and
                // its clusters reused: rolling back to the window start must find
                // the old file intact (its clusters needed before-images).
                let size = Int(ProcessInfo.processInfo.environment["BIG_MIB"] ?? "160")!
                device.target = .max
                func fill(_ path: String, _ salt: Int) -> Int32 {
                    guard nk_create(volume, "/", String(path.dropFirst())) == 0 else { return -1 }
                    for index in 0..<size {
                        let chunk = pattern(index + salt)
                        guard chunk.withUnsafeBytes({ nk_write(volume, path, Int64(index) * 1048576, 1048576, $0.baseAddress) }) == 1048576 else { return -1 }
                        if io.session!.checkpointDue { do { try checkpoint(volume, io) } catch { return -1 } }
                    }
                    return 0
                }
                result = fill("/old", 0)
                if result == 0 { do { try checkpoint(volume, io) } catch { result = -1 } }
                Thread.sleep(forTimeInterval: session.retention + 0.5)
                if result == 0 { result = nk_delete(volume, "/old") }
                if result == 0 { do { try checkpoint(volume, io) } catch { result = -1 } }  // prunes /old's epochs
                session.retention = 3600  // keep the deletion inside the window however slow the machine is
                device.target = device.writes + n   // the crash counts from here
                if result == 0 { result = fill("/new", 7) }
            default: fail("kind")
            }
            if result == 0 { do { try checkpoint(volume, io) } catch { result = -1 } }  // checkpoint B
            if result == 0 { FileHandle.standardError.write(Data("COMMITTED\n".utf8)) }
            if result != 0 {
                _ = nk_umount(volume)
                print("{\"failed\":true,\"deviceWrites\":\(device.writes - before),\"engineWrites\":\(counting.pwrites - pwritesBefore)}")
                return
            }
            // A failed clean unmount keeps every record for the next connection.
            guard nk_umount(volume) == 0,
                  (try? WriteJournalCoordinator.finish(store: store, io: io, lock: lock)) != nil else {
                print("{\"failed\":true,\"deviceWrites\":\(device.writes - before),\"engineWrites\":\(counting.pwrites - pwritesBefore)}")
                return
            }
            if fault == "after-finish-crash" { _exit(86) }
            print("{\"failed\":false,\"deviceWrites\":\(device.writes - before),\"engineWrites\":\(counting.pwrites - pwritesBefore),\"skipped\":\(session.skippedBytes)}")
        case "facts":
            // facts <image> <dir>: the volume as recovery reads it (flags only).
            do { let facts = try WriteJournalCoordinator.volumeFacts(io); print("{\"flags\":\(facts.flags)}") }
            catch { print("{\"error\":\"\(error)\",\"errno\":\(errno)}") }
        case "session-crash":
            // Crash while mounted after checkpoint A, with no operation.
            _ = try WriteJournalCoordinator.begin(store: store, serial: serial, io: io)
            var raw = io.makeIO(writable: true)
            var nkio = engineIO(&raw)
            guard let volume = nk_mount_io(&nkio, nil, 0) else { fail("mount") }
            try checkpoint(volume, io)
            _exit(86)
        default: fail("mode")
        }
    }
}
