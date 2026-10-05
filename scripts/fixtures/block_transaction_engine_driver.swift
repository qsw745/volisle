// Detached 64 MiB test files only; never installed in the application.
import Foundation
import CryptoKit
import Darwin

private enum Injected: Error { case fault }
private func require(_ value: Bool) throws { if !value { throw Injected.fault } }
private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

private func deviceDigest(_ fd: Int32, size: Int64) throws -> String {
    var hash = SHA256(), offset: Int64 = 0
    while offset < size {
        let count = Int(min(1024*1024, size-offset))
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        try require(n == count); hash.update(data: data); offset += Int64(count)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
private func validateBaseline(_ fd: Int32, size: Int64, baseline: String) throws {
    try require(deviceDigest(fd, size: size) == baseline)
}
private func inspectClean(size: Int64, read: NTFSReadOnlyInspection.Read) throws {
    try require(NTFSReadOnlyInspection.inspect(deviceSize: size, read: read) == NK_CHECK_CLEAN)
}
private func inspectClean(_ fd: Int32, size: Int64) throws {
    try inspectClean(size: size) { offset, count in
        var bytes = Data(count: count)
        let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        try require(n == count); return bytes
    }
}

private func validateDeviceBaseline(_ device: BlockJournalDeviceSession, size: Int64, baseline: String) throws {
    try inspectClean(size: size) { try device.read(offset: $0, count: $1) }
    var hash = SHA256(), offset: Int64 = 0
    while offset < size {
        let count = Int(min(1024*1024, size-offset))
        hash.update(data: try device.read(offset: offset, count: count)); offset += Int64(count)
    }
    try require(hash.finalize().map { String(format: "%02x", $0) }.joined() == baseline)
    try device.verify()
}

private final class EngineDriver {
    let fd: Int32
    let path: String
    let binding: BlockJournalBinding
    let authority: BlockJournalAuthority
    let key: Data
    let logs: URL
    let pipeline = MetadataWritePipeline()
    var transaction: BlockJournalTransaction?
    var writes = 0
    var target = 0
    var fault = "none"
    init(_ path: String, blockSize: Int, inspect: Bool, recovering: Bool = false, recoveryBaseline: String? = nil, completingCommit: Bool = false, replayRecovery: Bool = false, retiringID: UUID? = nil, managingEpoch: Bool = false, managed: Bool = false, maintenanceCrash: String? = nil, usingStoredBaseline: Bool = false, seedUnsafeBaseline: Bool = false) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench")
        try require(url.deletingLastPathComponent().deletingLastPathComponent().path == root.path && url.deletingLastPathComponent().lastPathComponent.hasPrefix("block-journal-"))
        try require(url.resolvingSymlinksInPath().path == url.path)
        fd = open(path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw Injected.fault }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size == 64*1024*1024 && info.st_nlink == 1 && info.st_uid == getuid())
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        var boot = Data(count: 512)
        let descriptor = fd
        let count = boot.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 512, 0) }
        try require(count == 512 && boot[3..<11] == Data("NTFS    ".utf8))
        let currentIdentity = "\(info.st_dev):\(info.st_ino)", currentSize = Int64(info.st_size), currentBoot = sha(boot)
        // Reject an unsafe original view before creating journal state.
        if !inspect && !seedUnsafeBaseline { try inspectClean(descriptor, size: currentSize) }
        let dir = url.deletingPathExtension().appendingPathExtension("state")
        logs = dir.appendingPathComponent("logs")
        if !inspect { try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let authorityDirectory = dir.appendingPathComponent("authority")
        if !inspect { try FileManager.default.createDirectory(at: authorityDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        authority = try BlockJournalAuthority.fixture(directory: authorityDirectory, capacity: managed ? 1 : 256, recovering: recovering, pool: BlockJournalStore.pool(directory: logs))
        if authority.hasInterruptedPublication {
            var heldDevices: [BlockJournalDeviceSession] = []
            defer { heldDevices.forEach { $0.close() } }
            func heldDevice(_ binding: BlockJournalBinding) throws -> BlockJournalDeviceSession {
                let device = try DetachedRecoveryDevice(path: path, heldDescriptor: descriptor, binding: binding).session()
                heldDevices.append(device); return device
            }
            try authority.finishInterruptedPublication(logDirectory: logs, validateRecovery: { binding, checkpoint in
                try require((recoveryBaseline ?? (usingStoredBaseline ? binding.recoveryBaselineSHA256 : nil)) == checkpoint && binding.volumeIdentity == currentIdentity &&
                    binding.deviceSize == currentSize && binding.bootSHA256 == currentBoot && binding.blockSize == blockSize)
                let device = try heldDevice(binding)
                try device.flush()
                try validateDeviceBaseline(device, size: currentSize, baseline: checkpoint)
            }, validateCommit: { binding, checkpoint in
                try require(completingCommit && recoveryBaseline == checkpoint && binding.volumeIdentity == currentIdentity &&
                    binding.deviceSize == currentSize && binding.bootSHA256 == currentBoot && binding.blockSize == blockSize)
                let device = try heldDevice(binding)
                try device.flush()
                try validateDeviceBaseline(device, size: currentSize, baseline: checkpoint)
            })
        }
        key = try authority.key()
        let records = try authority.bindings()
        let heldAuthority = authority
        let completed = try records.filter { try heldAuthority.recoveryCompletion($0) != nil }
        let unresolved = try authority.unresolvedBindings()
        let committed = try records.filter { try heldAuthority.commitCompletion($0)?.checkpoint == recoveryBaseline && recoveryBaseline != nil }
        let selected = retiringID != nil ? records.first { $0.transactionID == retiringID } : (completingCommit ? (unresolved.first ?? committed.first) : (replayRecovery ? completed.first : (unresolved.first ?? completed.first ?? records.first)))
        if inspect {
            var observed = BlockJournalBinding(transactionID: selected?.transactionID ?? UUID(), volumeIdentity: currentIdentity,
                bootSHA256: currentBoot, deviceSize: currentSize, blockSize: blockSize)
            observed.authorityEpoch = selected?.authorityEpoch
            observed.recoveryBaselineSHA256 = selected?.recoveryBaselineSHA256
            binding = observed
            if !managingEpoch { try require(selected == binding) }
        } else if managed {
            if let maintenanceCrash { authority.storageBoundary = { if $0 == maintenanceCrash { _exit(86) } } }
            let prepared = try authority.prepareTransaction(volumeIdentity: currentIdentity, bootSHA256: currentBoot,
                deviceSize: currentSize, blockSize: blockSize, recoveryBaselineSHA256: deviceDigest(descriptor, size: currentSize), stopWrites: {})
            binding = prepared.binding; transaction = prepared.transaction
            authority.storageBoundary = nil
        } else {
            binding = try authority.newBinding(volumeIdentity: currentIdentity, bootSHA256: currentBoot,
                deviceSize: currentSize, blockSize: blockSize, recoveryBaselineSHA256: deviceDigest(descriptor, size: currentSize))
            try authority.requireNewTransaction(binding)
            transaction = try BlockJournalTransaction(directory: logs, binding: binding, key: key,
                expectedPool: BlockJournalStore.pool(directory: logs),
                saveAnchor: { [weak self] binding, previous, next in
                    guard let self else { throw Injected.fault }
                    let atTarget = self.writes + 1 == self.target
                    if self.fault == "anchor-before" && atTarget { throw Injected.fault }
                    let receipt = try self.authority.save(binding, previous: previous, next: next)
                    if self.fault == "anchor-after" && atTarget { throw Injected.fault }
                    return receipt
                }, stopWrites: {})
        }
    }
    deinit { transaction?.close(); Darwin.close(fd) }
    func write(_ pointer: UnsafeRawPointer, _ count: Int64, _ offset: Int64) throws {
        var intent: MetadataWritePipeline.Intent?
        do {
            try pipeline.write(UnsafeRawBufferPointer(start: pointer, count: Int(count)), offset: offset, blockSize: binding.blockSize, deviceSize: binding.deviceSize,
                read: { at, block in try require(pread(self.fd, block.baseAddress, block.count, off_t(at)) == block.count) },
                record: { intent = $0 }, write: { at, block in
                    guard let entry = intent else { throw Injected.fault }; intent = nil
                    try require(entry.offset == at && entry.after == Data(block))
                    try self.transaction!.write(offset: at, before: entry.before, after: entry.after) { offset, data in
                        self.writes += 1
                        if self.fault == "fail" && self.writes == self.target { throw Injected.fault }
                        let partial = self.fault == "partial" && self.writes == self.target
                        let length = partial ? data.count / 2 : data.count
                        let written = data.withUnsafeBytes { pwrite(self.fd, $0.baseAddress, length, off_t(offset)) }
                        try require(written == length)
                        if (self.fault == "crash" || partial) && self.writes == self.target { _ = fsync(self.fd); _exit(86) }
                    }
                })
        } catch { transaction?.abort(); throw error }
    }
    func inspect(reconcile: Bool = false) throws {
        let seal = try authority.read(binding)!
        let snapshot: BlockJournalSnapshot
        if reconcile {
            snapshot = try BlockJournalStore.reconcile(directory: logs, binding: binding, key: key, expectedSeal: seal, expectedPool: BlockJournalStore.pool(directory: logs)) {
                try self.authority.save(self.binding, previous: $0, next: $1)
            }
        } else {
            snapshot = try BlockJournalStore.inspect(directory: logs, binding: binding, key: key, expectedSeal: seal, expectedPool: BlockJournalStore.pool(directory: logs))
        }
        let result: [String: Any] = ["writes": snapshot.writes.map { ["offset": $0.offset, "before": $0.before.base64EncodedString(), "after": $0.after.base64EncodedString()] }, "committed": snapshot.checkpoint != nil]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    func advanceEpoch(crashAt: Int) throws {
        let records = try authority.bindings()
        if records.isEmpty { print("{\"empty\":true}"); return }
        let stages = [1001: "written", 1002: "file-durable", 1003: "renamed", 1004: "directory-durable"]
        authority.storageBoundary = { if $0 == stages[crashAt] { _exit(86) } }
        try authority.advanceEpoch(logDirectory: logs)
        print("{\"empty\":true}")
    }
    func retire(crashAt: Int) throws {
        let stages = [1: "retirement-before-unlink", 2: "retirement-unlinked",
                      3: "retirement-before-directory-sync", 4: "retirement-directory-durable"]
        authority.storageBoundary = { if $0 == stages[crashAt] { _exit(86) } }
        let removed = try authority.retireLog(binding, logDirectory: logs)
        print("{\"removed\":\(removed)}")
    }
    func finishCommit(baseline: String, crashAt: Int) throws {
        if let prior = try authority.commitCompletion(binding) {
            try require(prior.checkpoint == baseline)
            print("{\"alreadyCompleted\":true}"); return
        }
        let stages = [1001: "written", 1002: "file-durable", 1003: "renamed", 1004: "directory-durable"]
        authority.storageBoundary = { if $0 == stages[crashAt] { _exit(86) } }
        let device = try DetachedRecoveryDevice(path: path, heldDescriptor: fd, binding: binding).session()
        defer { device.close() }
        _ = try authority.completeCommit(binding, logDirectory: logs, checkpoint: baseline) { _ in
            try device.flush()
            try validateDeviceBaseline(device, size: self.binding.deviceSize, baseline: baseline)
        }
        print("{\"completed\":true}")
    }
    func restore(baseline: String, crashAt: Int, stored: Bool = false, deviceFault: String? = nil) throws {
        try require(baseline.utf8.count == 64 && baseline.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        if let completed = try authority.recoveryCompletion(binding) {
            try require(completed.checkpoint == baseline)
            // Historical completion only; no claim about the device after a later session.
            print("{\"restoredBlocks\":0,\"alreadyCompleted\":true}"); return
        }
        var restored = 0, calls = 0
        let publicationStages = [1001: "written", 1002: "file-durable", 1003: "renamed", 1004: "directory-durable"]
        authority.storageBoundary = { if $0 == publicationStages[crashAt] { _exit(86) } }
        func makeDevice() throws -> BlockJournalDeviceSession {
            let transport = try DetachedRecoveryDevice(path: path, heldDescriptor: fd, binding: binding)
            transport.beforeWrite = { descriptor, offset, bytes in
                calls += 1
                let partial = crashAt < 0 && calls == -crashAt
                let length = partial ? bytes.count/2 : bytes.count
                let n = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, length, off_t(offset)) }
                try require(n == length)
                if partial || (crashAt > 0 && calls == crashAt) { _ = fsync(descriptor); _exit(86) }
                return true
            }
            if let deviceFault {
                var injected = false
                transport.beforeRead = { [weak transport] in
                    guard !injected else { return }; injected = true
                    switch deviceFault {
                    case "unlock": try require(flock(self.fd, LOCK_UN) == 0)
                    case "rename":
                        try FileManager.default.moveItem(atPath: self.path, toPath: self.path + ".detached")
                        try FileManager.default.copyItem(atPath: self.path + ".detached", toPath: self.path)
                    case "close": transport?.close()
                    default: throw Injected.fault
                    }
                }
            }
            return try transport.session()
        }
        let validate: (BlockJournalRollback.Read, String) throws -> Void = { read, expectedBaseline in
            try inspectClean(size: self.binding.deviceSize, read: read)
            // Fixture policy: full streaming SHA-256 plus independent NTFS health.
            var hash = SHA256(), offset: Int64 = 0
            while offset < self.binding.deviceSize {
                let count = Int(min(1024*1024, self.binding.deviceSize-offset))
                hash.update(data: try read(offset, count)); offset += Int64(count)
            }
            try require(hash.finalize().map { String(format: "%02x", $0) }.joined() == expectedBaseline)
        }
        if stored {
            let result = try BlockJournalDeviceRecovery.restore(authority: authority, binding: binding, logDirectory: logs,
                openDevice: { _ in try makeDevice() }, validateRestoredView: validate)
            restored = result.restoredBlocks
        } else {
            let device = try makeDevice()
            defer { device.close() }
            _ = try authority.recover(binding, logDirectory: logs, checkpoint: baseline) { snapshot in
                let result = try BlockJournalRollback().restore(snapshot: snapshot, expectedBinding: self.binding,
                    read: { try device.read(offset: $0, count: $1) },
                    write: { try device.write(offset: $0, bytes: $1) }, flush: { try device.flush() },
                    validateRestoredView: { try validate($0, baseline) })
                try device.verify()
                restored = result.restoredBlocks
            }
        }
        print("{\"restoredBlocks\":\(restored)}")
    }
}

@main struct Main {
    static func main() throws {
        let a = CommandLine.arguments
        precondition(a.count == 6)
        let inspecting = a[2] == "inspect" || a[2] == "reconcile" || a[2] == "restore" || a[2] == "restore-stored" || a[2] == "restore-device-fault" || a[2] == "restore-old" || a[2] == "finalize" || a[2] == "retire" || a[2] == "epoch" || a[2] == "old-request"
        if inspecting {
            do {
                let d = try EngineDriver(a[1], blockSize: Int(a[5])!, inspect: true, recovering: ["reconcile", "restore", "restore-stored", "restore-device-fault", "restore-old", "finalize", "epoch"].contains(a[2]),
                    recoveryBaseline: ["restore", "restore-old", "finalize"].contains(a[2]) ? a[3] : nil,
                    completingCommit: a[2] == "finalize", replayRecovery: a[2] == "restore-old", retiringID: a[2] == "retire" ? UUID(uuidString: a[3]) : nil, managingEpoch: ["epoch", "old-request"].contains(a[2]), usingStoredBaseline: ["restore-stored", "restore-device-fault"].contains(a[2]))
                if a[2] == "epoch" { try d.advanceEpoch(crashAt: Int(a[4])!) }
                else if a[2] == "old-request" {
                    guard let data = Data(base64Encoded: a[3]) else { throw Injected.fault }
                    let old = try JSONDecoder().decode(BlockJournalBinding.self, from: data)
                    _ = try d.authority.read(old); print("{\"incorrectlyAccepted\":true}")
                }
                else if a[2] == "retire" { try require(UUID(uuidString: a[3]) != nil); try d.retire(crashAt: Int(a[4])!) }
                else if a[2] == "finalize" { try d.finishCommit(baseline: a[3], crashAt: Int(a[4])!) }
                else if a[2] == "restore-stored" || a[2] == "restore-device-fault" {
                    guard let baseline = d.binding.recoveryBaselineSHA256 else { throw Injected.fault }
                    try d.restore(baseline: baseline, crashAt: Int(a[4])!, stored: true,
                                  deviceFault: a[2] == "restore-device-fault" ? a[3] : nil)
                }
                else if a[2] == "restore" || a[2] == "restore-old" { try d.restore(baseline: a[3], crashAt: Int(a[4])!) }
                else { try d.inspect(reconcile: a[2] == "reconcile") }
            } catch { print("{\"rejected\":true}"); exit(3) }
            return
        }
        let managed = a[2].hasPrefix("auto-")
        let stages = [1:"retirement-before-unlink",2:"retirement-unlinked",3:"retirement-before-directory-sync",4:"retirement-directory-durable",
                      5:"written",6:"file-durable",7:"renamed",8:"directory-durable"]
        let d: EngineDriver
        do {
            d = try EngineDriver(a[1], blockSize: Int(a[5])!, inspect: false, recovering: managed,
                managed: managed, maintenanceCrash: a[3] == "maintenance" ? stages[Int(a[4])!] : nil, seedUnsafeBaseline: a[2] == "seed-unsafe-baseline")
        } catch {
            if managed { print("{\"rejected\":true}"); exit(3) }
            throw error
        }
        if a[2] == "seed-unsafe-baseline" {
            // Negative test only: create a trusted but unhealthy original view.
            // This driver accepts only fresh disposable regular files.
            d.transaction!.close(); print("{\"seededUnsafeBaseline\":true}"); return
        }
        var io = nk_io(ctx: Unmanaged.passUnretained(d).toOpaque(), pread: { ctx, bytes, count, offset in
            guard let ctx, let bytes else { return -1 }
            return Int64(pread(Unmanaged<EngineDriver>.fromOpaque(ctx).takeUnretainedValue().fd, bytes, Int(count), off_t(offset)))
        }, pwrite: { ctx, bytes, count, offset in
            guard let ctx, let bytes else { return -1 }
            do { try Unmanaged<EngineDriver>.fromOpaque(ctx).takeUnretainedValue().write(bytes, count, offset); return count }
            catch { errno = EIO; return -1 }
        }, size: 64*1024*1024, readonly: 0, sync: { ctx in
            guard let ctx else { return -1 }
            return fsync(Unmanaged<EngineDriver>.fromOpaque(ctx).takeUnretainedValue().fd)
        })
        guard let v = nk_mount_io(&io, nil, 0) else { throw Injected.fault }
        let start = d.writes
        d.fault = a[3]; d.target = start + Int(a[4])!
        d.authority.storageBoundary = { [weak d] stage in
            guard let d else { return }
            if d.writes + 1 == d.target && ((d.fault == "authority-written" && stage == "written") ||
                                          (d.fault == "authority-durable" && stage == "file-durable")) { _exit(86) }
        }
        let name = a[2].hasSuffix("file-2") ? "new-node-2" : (a[2].hasSuffix("file-3") ? "new-node-3" : "new-node")
        let result = a[2] == "directory" ? nk_mkdir(v, "/", name) : nk_create(v, "/", name)
        if ["fail", "anchor-before", "anchor-after"].contains(d.fault) {
            try require(result == -1 && nk_umount(v) == -1 && d.transaction!.state == .failed)
            print("{\"failedAsExpected\":true}"); return
        }
        try require(result == 0)
        let count = d.writes - start
        // The test transaction spans clean mount to clean unmount. A real
        // continuously mounted per-operation checkpoint is a separate problem.
        // Drain/close under the same transaction before deriving the fixture's
        // independent final digest; all unmount writes remain journalled.
        try require(nk_umount(v) == 0)
        try inspectClean(d.fd, size: d.binding.deviceSize)
        let checkpoint = try deviceDigest(d.fd, size: d.binding.deviceSize)
        _ = try d.transaction!.commit(checkpoint: checkpoint, prepare: {}, flushDevice: { try require(fsync(d.fd) == 0 && fcntl(d.fd, F_FULLFSYNC) == 0) })
        if d.fault == "committed-crash" { _exit(86) }
        print("{\"writes\":\(count)}")
    }
}
