// SPDX-License-Identifier: GPL-2.0-only
// Derived from ntfskit b7153a8; Volisle modifications 2026-09-20. See ../UPSTREAM.md.
import Foundation
import FSKit
import os

/// NTFS volume backed by libntfs-3g through the nk_* C bridge.
/// libntfs-3g is not thread-safe → every engine call goes through one serial queue.
final class NTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {

    private let log = Logger(subsystem: "Volisle.NTFSModule", category: "volume")
    private let operationLock = NSRecursiveLock()
    private let engineQueue = DispatchQueue(label: "Volisle.engine")

    private let resource: FSBlockDeviceResource
    /// Set by the file system; reports a refused activation for its container.
    var activationRefused: ((Error) -> Void)?
    private let volumeSerial: [UInt8]
    /// Fixed mount intent, guarded for concurrent FSKit callbacks.
    /// A failed write mount is reported; it is not silently downgraded.
    private let roLock = NSLock()
    private var _readOnly: Bool
    private var readOnly: Bool {
        get { roLock.lock(); defer { roLock.unlock() }; return _readOnly }
        set { roLock.lock(); defer { roLock.unlock() }; _readOnly = newValue }
    }

    private var vol: OpaquePointer?              // nk_volume*
    /// BitLocker: the engine sees only the decrypted view; writable only with
    /// the same explicit intent as any daily write mount.
    private let bitLocker: Bool
    private var bitLockerKey: String?            // from the mount options
    private var bde: OpaquePointer?              // nk_bde*, guarded by engineQueue
    private var engineWritable = false          // guarded by engineQueue
    private var writeActivationFailed = false   // guarded by operationLock
    private var closeFailed = false             // guarded by engineQueue
    private let identityCache = ItemIdentityCache()
    /// Bumped on every namespace mutation so cached kernel dirents invalidate.
    private var dirGeneration: UInt64 = 1
    #if VOLISLE_EXPERIMENTAL_REPLACEMENT
    private struct LiveReplacement {
        let oldItem: NTFSItem
        let journal: ReplacementJournal
        var binding: ReplacementBinding { journal.state.binding }
    }
    private var replacements: [UInt64: LiveReplacement] = [:]
    #endif
    /// One live NTFSItem instance per path — FSKit tracks items by object
    /// identity; handing out fresh instances per lookup leaks phantom vnodes
    /// (files stay "open" forever and unlink is deferred indefinitely).
    /// FSKit doesn't promise upcalls arrive serialized — namespace-cache
    /// state is guarded together with the outer operation lock.
    private let stateLock = NSRecursiveLock()

    private func item(path: String, kind: FSItem.ItemType) throws -> NTFSItem {
        let reference = try reference(for: path)
        stateLock.lock(); defer { stateLock.unlock() }
        return identityCache.item(path: path, kind: kind, reference: reference)
    }

    private func reference(for path: String) throws -> UInt64 {
        try engineQueue.sync {
            var reference: UInt64 = 0
            let rc = path.withCString { nk_reference_path(vol, $0, &reference) }
            guard rc == 0 else { throw posix(errno == 0 ? EIO : errno) }
            return reference
        }
    }

    /// Every remaining path-based operation must fail closed if the name has
    /// been rebound. The outer operation lock prevents a local rename between
    /// this check and the engine call.
    private func requirePathIdentity(_ item: NTFSItem) throws {
        guard try reference(for: item.path) == item.fileReference else { throw posix(ESTALE) }
    }

    // Sector-aligned scratch state for the nk_io callbacks. The sandbox forbids
    // opening /dev, so all engine I/O goes through FSBlockDeviceResource.
    //
    // TWO device paths, switched automatically:
    // - The kernel buffer cache only becomes available after kernel mount.
    //   Activation opens a read-only engine with plain reads; the writable
    //   engine opens later, after a metadata read succeeds. No KOIO is used.
    // - Every cached region has one fixed (offset, length) pair, including
    //   partial edge writes. Variable-length overlapping buffers are unsafe.
    /// Device I/O mode; only touched from engineQueue (all device callbacks
    /// originate from engine calls serialized there).
    fileprivate enum IOMode { case probing, metadata }
    fileprivate var ioMode: IOMode = .probing
    /// Every engine device access. Writes exist only inside a journal session.
    private lazy var journal = JournaledIO(device: self)
    private var journalLock: Int32 = -1          // guarded by engineQueue
    private var checkpointTimer: DispatchSourceTimer?

    fileprivate var deviceBlockSize: Int {
        // Stable cache granularity, independent of each libntfs request size.
        // Capacity is still computed from the logical block size below.
        // 64 KiB: every flushed cache buffer is one device I/O, and 4 KiB
        // buffers limited USB writes to about 9 MiB/s.
        max(65536, Int(resource.blockSize), Int(resource.physicalBlockSize))
    }
    fileprivate var deviceSize: Int64 {
        // blockCount is in units of blockSize (NOT deviceBlockSize) — using
        // the wrong unit inflated the size 8x and pushed end-of-volume reads
        // (NTFS backup boot sector) past the device, which EIOs.
        Int64(exactly: resource.blockCount).flatMap { blocks in
            let result = blocks.multipliedReportingOverflow(by: Int64(resource.blockSize))
            return result.overflow ? nil : result.partialValue
        } ?? 0
    }

    /// Aligned whole-block reads through the current mode; pending journal
    /// blocks are served first so the engine always sees its own writes.
    fileprivate func devicePread(_ buf: UnsafeMutableRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let result = journal.pread(buf, count, offset)
        if result < 0 { log.error("devicePread(\(offset), \(count)) failed") }
        return result
    }

    private func readCacheBlock(into scratch: UnsafeMutableRawBufferPointer,
                                at start: Int64, length: Int) throws {
        if ioMode == .metadata {
            try resource.metadataRead(into: scratch, startingAt: off_t(start),
                                      length: length)
            return
        }
        do {
            try resource.metadataRead(into: scratch, startingAt: off_t(start),
                                      length: length)
            ioMode = .metadata
            log.info("device I/O upgraded to kernel buffer cache")
        } catch {
            let n = try resource.read(into: scratch, startingAt: off_t(start),
                                      length: length)
            guard n == length else { throw posix(EIO) }
        }
    }

    init(resource: FSBlockDeviceResource, volumeName: FSFileName,
         volumeID: FSVolume.Identifier, readOnly: Bool, serial: [UInt8], bitLocker: Bool = false) {
        self.resource = resource
        self.bitLocker = bitLocker
        self.volumeSerial = serial
        self._readOnly = readOnly
        super.init(volumeID: volumeID, volumeName: volumeName)
        wantReadOnlyMount = readOnly
    }


    // MARK: engine

    private func inspectBeforeWritableActivation() throws -> Int32 {
        try engineQueue.sync {
            guard !closeFailed, !writeActivationFailed else { throw posix(EIO) }
            // FSKit already holds the resource. Inspect using plain read I/O
            // before the kernel cache exists. No write or flush callback is
            // supplied; nk_inspect also forces a read-only forensic descriptor.
            if bitLocker {
                // nk_inspect reads the decrypted view through a read-only descriptor.
                let status = try journal.withVolume(writable: false) { nk_inspect(&$0) }
                log.notice("挂载前只读预检状态=\(status, privacy: .public)（BitLocker）")
                return status
            }
            let status = NTFSReadOnlyInspection.inspect(deviceSize: deviceSize) { offset, count in
                var data = Data(count: count)
                let actual = data.withUnsafeMutableBytes { self.devicePread($0.baseAddress!, Int64(count), offset) }
                guard actual == Int64(count) else { throw self.posix(EIO) }
                return data
            }
            log.notice("挂载前只读预检状态=\(status, privacy: .public)")
            return status
        }
    }

    private func openEngine(writable: Bool = false) throws {
        try engineQueue.sync {
            guard vol == nil else { return }
            guard !closeFailed else { throw self.posix(EIO) }
            var io = journal.makeIO(writable: writable)
            var errbuf = [CChar](repeating: 0, count: 256)
            if bitLocker {
                guard let key = bitLockerKey else { throw self.posix(EACCES) }
                guard let handle = nk_bde_open(&io, Int32(NK_BDE_KEY), key, &errbuf, 256) else {
                    let code = errno
                    log.error("BitLocker 解锁失败 errno=\(code, privacy: .public)")
                    throw self.posix(code == EACCES || code == ENOTSUP ? code : EIO)
                }
                bde = handle
                io = nk_bde_io(handle)
            }
            if let handle = nk_mount_io(&io, &errbuf, 256) {
                vol = handle
                engineWritable = writable
                return
            }
            if let b = bde { nk_bde_close(b); bde = nil }
            let reason = String(decoding: errbuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            log.error("nk_mount_io failed: \(reason, privacy: .private)")
            throw self.posix(EIO)
        }
    }

    /// Activation happens before the kernel buffer cache exists. Keep the
    /// engine forensic/read-only until the first post-mount mutation. Never
    /// mark a volume dirty without a working metadata flush path.
    private func requireWritableEngine() throws {
        guard !readOnly else { throw posix(EROFS) }
        guard !writeActivationFailed else { throw posix(EIO) }
        if engineQueue.sync(execute: { engineWritable }) {
            // Every mutation starts at an operation boundary. Bound the epoch
            // here too: a continuous copy can starve the timer of the lock.
            guard engineQueue.sync(execute: { checkpointJournal(force: false) }) == 0 else { throw posix(EIO) }
            return
        }
        try engineQueue.sync {
            let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: deviceBlockSize, alignment: deviceBlockSize)
            defer { scratch.deallocate() }
            // No plain-I/O fallback: failing before kernel mount is intentional.
            try resource.metadataRead(into: scratch, startingAt: 0, length: deviceBlockSize)
            ioMode = .metadata
        }
        guard closeEngine() == 0 else { writeActivationFailed = true; throw posix(EIO) }
        engineQueue.sync { ioMode = .metadata }
        do {
            try beginJournalSession()
            try openEngine(writable: true)
            engineQueue.sync { attachFreeSpaceMap() }
            startCheckpointTimer()
        } catch {
            engineQueue.sync { abandonJournalSession() }
            // A refused preflight consumed the read-only handle above. Keep
            // reads available, but never retry write activation this session.
            // The requested mutation still fails; this is not a successful
            // downgrade of a write request, and no dirty flag is cleared.
            writeActivationFailed = true
            do { try openEngine() }
            catch { log.error("写入被拒绝后无法恢复只读引擎；保留失败状态") }
            throw error
        }
    }

    @discardableResult
    private func closeEngine() -> Int32 {
        checkpointTimer?.cancel(); checkpointTimer = nil
        return engineQueue.sync {
            #if VOLISLE_EXPERIMENTAL_REPLACEMENT
            if !replacements.isEmpty { nk_abort_write_session(vol) }
            #endif
            var rc: Int32 = vol.map { nk_umount($0) } ?? (closeFailed ? -1 : 0)
            if engineWritable || journal.session != nil {
                if rc == 0 { rc = finishJournalSession() } else { abandonJournalSession() }
            }
            if rc != 0 { closeFailed = true }
            vol = nil
            if let b = bde { nk_bde_close(b); bde = nil }
            engineWritable = false
            // If FSKit reactivates a clean instance, the next engine open happens
            // pre-mount again — the buffer cache won't be attached, so start
            // back in probing mode.
            ioMode = .probing
            return rc
        }
    }

    private func id(for path: String) throws -> FSItem.Identifier {
        let reference = try reference(for: path)
        stateLock.lock(); defer { stateLock.unlock() }
        return identityCache.identifier(path: path, reference: reference)
    }

    /// Namespace mutation bookkeeping under one lock.
    private func mutateNamespace(_ body: () -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        dirGeneration += 1
        body()
    }

    // These helpers run under operationLock, outside engineQueue. The feature
    // is compiled only for one explicitly selected disposable fixture.
    private func isPrivateReplacementPath(_ path: String) -> Bool {
        #if VOLISLE_EXPERIMENTAL_REPLACEMENT
        return replacements.values.contains {
            let b = $0.binding
            return path.lowercased() == replacementPath(b.directory, b.backup).lowercased()
        }
        #else
        return false
        #endif
    }

    private func requirePhysicalTestPath(_ path: String) throws {
        #if VOLISLE_PHYSICAL_TEST
        guard PhysicalTestTarget.policy.allowsMutation(path: path, now: Date().timeIntervalSince1970) else {
            throw posix(EROFS)
        }
        #endif
    }

    private func requireMutableNamespace(_ path: String) throws {
        try requirePhysicalTestPath(path)
        #if VOLISLE_EXPERIMENTAL_REPLACEMENT
        let path = path.lowercased()
        for transaction in replacements.values {
            let b = transaction.binding
            for location in [b.sourcePath, replacementPath(b.directory, b.target), replacementPath(b.directory, b.backup)] {
                let pinned = location.lowercased()
                if pinned == path || pinned.hasPrefix(path + "/") { throw posix(EBUSY) }
            }
        }
        #endif
    }

    private func withReplacementWrite<T>(_ item: NTFSItem, maximumSize: UInt64? = nil,
                                          operation: () throws -> T) throws -> T {
        #if VOLISLE_EXPERIMENTAL_REPLACEMENT
        if let live = replacements.values.first(where: {
            $0.binding.oldReference == item.fileReference || $0.binding.newReference == item.fileReference
        }) {
            if let maximumSize, maximumSize > UInt64(Int64.max) { throw posix(EFBIG) }
            var result: T?
            let role: ReplacementRole = live.binding.oldReference == item.fileReference ? .old : .new
            try live.journal.write(role) {
                result = try operation()
                try replacementSync()
                return try replacementFingerprint(item.fileReference)
            }
            return result!
        }
        #endif
        return try operation()
    }

    #if VOLISLE_EXPERIMENTAL_REPLACEMENT
    private func replacementPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    private func replacementSync() throws {
        try engineQueue.sync {
            guard nk_sync(vol) == 0 else { throw posix(EIO) }
            try resource.metadataFlush()
        }
    }

    private func replacementFingerprint(_ reference: UInt64) throws -> ReplacementFingerprint {
        try engineQueue.sync {
            var st = nk_stat()
            guard nk_stat_reference(vol, reference, &st) == 0 else { throw posix(EIO) }
            guard st.is_dir == 0, st.is_symlink == 0, st.size >= 0 else { throw posix(ENOTSUP) }
            return try ReplacementFingerprint.read(size: UInt64(st.size)) { offset, buffer in
                let count = nk_read_reference(vol, reference, Int64(offset), Int64(buffer.count), buffer.baseAddress)
                guard count >= 0 else { throw posix(errno == 0 ? EIO : errno) }
                return Int(count)
            }
        }
    }

    #endif

    private func replacementJournalStore() throws -> URL {
        // Resolve only the OS-provided sandbox base. Never accept a path from
        // disk names, mount options, or callers, nor relax journal path checks.
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        let store = base.appendingPathComponent("VolisleReplacementJournals", isDirectory: true)
        if mkdir(store.path, 0o700) != 0 && errno != EEXIST { throw posix(errno) }
        let fd = Darwin.open(store.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posix(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw posix(EPERM) }
        let parent = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw posix(errno) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw posix(errno) }
        return store
    }

    private func auditReplacementJournals() throws {
        let store = try replacementJournalStore()
        let serial = volumeSerial.map { String(format: "%02x", $0) }.joined()
        var boot = Data(count: 512)
        try engineQueue.sync {
            guard boot.withUnsafeMutableBytes({ devicePread($0.baseAddress!, 512, 0) }) == 512 else { throw posix(EIO) }
        }
        let audit = try ReplacementJournal.auditStore(at: store, serial: serial, bootHash: ReplacementJournal.hash(boot))
        log.notice("恢复记录只读复核：卷=\(serial, privacy: .public) 已完成=\(audit.completed) 未完成=\(audit.unresolved)；未执行磁盘修复或删除")
        // A Windows check may have cleared the NTFS dirty flag. The host
        // recovery record still prohibits new writes until it is resolved.
        if !readOnly && audit.blocksWriting { throw posix(EBUSY) }
    }

    #if VOLISLE_EXPERIMENTAL_REPLACEMENT
    private func replace(_ source: NTFSItem, old: NTFSItem, directory: NTFSItem, name: String) throws {
        // Final-reclaim synchronization is exposed by this SDK on macOS 27.
        guard #available(macOS 27.0, *) else { throw posix(ENOTSUP) }
        guard source.kind == .file, old.kind == .file,
              source.fileReference != old.fileReference,
              old.path == directory.childPath(name), replacements.count < 16 else { throw posix(ENOTSUP) }
        try requirePathIdentity(old)
        try requireMutableNamespace(source.path); try requireMutableNamespace(old.path)
        let before = try replacementFingerprint(old.fileReference)
        let after = try replacementFingerprint(source.fileReference)
        var boot = Data(count: 512)
        try engineQueue.sync {
            let count = boot.withUnsafeMutableBytes { devicePread($0.baseAddress!, 512, 0) }
            guard count == 512 else { throw posix(EIO) }
        }
        let binding = ReplacementBinding(serial: volumeSerial.map { String(format: "%02x", $0) }.joined(),
            bootHash: ReplacementJournal.hash(boot), directory: directory.path,
            source: (source.path as NSString).lastPathComponent, target: name,
            backup: ".volisle-replaced-" + UUID().uuidString.lowercased(),
            oldReference: old.fileReference, newReference: source.fileReference,
            sourceDirectory: (source.path as NSString).deletingLastPathComponent)
        let journal = try ReplacementJournal(at: replacementJournalStore().appendingPathComponent(UUID().uuidString, isDirectory: true), binding: binding,
            before: before, after: after, failClosed: { [weak self] in
                guard let self else { return }
                self.engineQueue.sync { nk_abort_write_session(self.vol) }
            })
        // Retain even failed transactions: no same-session retry/cleanup after
        // partial publication, and the volume cannot be marked clean at exit.
        replacements[old.fileReference] = LiveReplacement(oldItem: old, journal: journal)
        do {
            try journal.publish {
                try engineQueue.sync {
                    let rc = binding.directory.withCString { dp in
                        binding.source.withCString { sp in
                            binding.target.withCString { tp in
                                binding.backup.withCString { bp in
                                    binding.sourceParent.withCString { sd in nk_replace_between(vol, sd, sp, dp, tp, bp) }
                                }
                            }
                        }
                    }
                    guard rc == 0 else { throw posix(errno == 0 ? EIO : errno) }
                }
                try replacementSync()
            }
        } catch {
            mutateNamespace {}
            throw error
        }
        mutateNamespace {
            identityCache.move(old, to: replacementPath(binding.directory, binding.backup))
            identityCache.move(source, to: directory.childPath(name))
        }
        log.notice("覆盖实验已发布；旧字节=\(before.size) 新字节=\(after.size) 跨目录=\(binding.sourceParent != binding.directory)；恢复记录=\(journal.url.path, privacy: .private)")
    }

    private func reclaimReplacement(_ item: NTFSItem) throws {
        guard let live = replacements[item.fileReference], live.oldItem === item else { return }
        let b = live.binding
        try live.journal.oldItemReclaimed()
        try live.journal.cleanup(verify: {
            let old = try self.reference(for: self.replacementPath(b.directory, b.backup))
            let new = try self.reference(for: self.replacementPath(b.directory, b.target))
            var unused: UInt64 = 0
            let absent = self.engineQueue.sync {
                let rc = b.sourcePath.withCString { nk_reference_path(self.vol, $0, &unused) }
                return rc != 0 && errno == ENOENT
            }
            return ReplacementProof(oldReference: old, newReference: new,
                old: try self.replacementFingerprint(old), new: try self.replacementFingerprint(new), sourceAbsent: absent)
        }, removeAndSync: {
            try self.engineQueue.sync {
                let rc = self.replacementPath(b.directory, b.backup).withCString { nk_delete(self.vol, $0) }
                guard rc == 0 else { throw self.posix(EIO) }
            }
            try self.replacementSync()
        })
        live.journal.close()
        do { try ReplacementJournal.retireCompleted(at: live.journal.url) }
        catch {
            // Disk cleanup is already durable. Preserve the host record and
            // retry maintenance on the next activation, without faking an
            // NTFS failure or removing an unfinished transaction.
            log.error("已完成恢复记录暂未归档：\(String(describing: error), privacy: .public)")
        }
        replacements[item.fileReference] = nil
        mutateNamespace { identityCache.remove(item) }
        log.notice("覆盖实验旧对象最终回收并完成校验清理")
    }
    #endif

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    // MARK: FSVolume.Operations

    /// Version-independent intent (Bool, no 26-only type) — the actual
    /// `requestedMountOptions` witness below is gated to macOS 26.4 where
    /// FSMountOptions exists. On 15.4–26.3 the kernel mount mode just follows
    /// the block device's own writability; the volume still works read-only.
    fileprivate var wantReadOnlyMount = false

    /// FSKit reads this after mount() replies; the kernel mount matches the
    /// explicit read-only intent. There is no silent write-mount fallback.
    /// Only on 26.4+
    /// (FSMountOptions is a V2.4 API).
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        wantReadOnlyMount ? [.readOnly] : []
    }

    /// POSIX open-unlink semantics (delete an open file, keep using it) —
    /// FSKit emulates it via rename + deferred delete. V2 API (macOS 26+);
    /// on 15.4 the kernel simply doesn't offer the emulation.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool { true }

    private var privateModesEnabled: Bool {
        #if VOLISLE_EXPERIMENTAL_PRIVATE_PERMISSIONS
        true
        #else
        false
        #endif
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        // Honest advertising: hard links (createLink) are ENOTSUP and our IDs
        // are per-mount path counters, not stable MFT references.
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = false
        caps.doesNotSupportImmutableFiles = true
        caps.doesNotSupportSettingFilePermissions = !privateModesEnabled
        caps.supports64BitObjectIDs = true
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "volisle")
        var total: Int64 = 0, free: Int64 = 0
        var cluster: Int32 = 0
        engineQueue.sync { _ = nk_statvfs(vol, &total, &free, &cluster) }
        let bs = cluster > 0 ? Int(cluster) : 4096
        stats.blockSize = bs
        stats.ioSize = 1 << 20
        let totalBytes = UInt64(max(0, total)), freeBytes = min(UInt64(max(0, free)), totalBytes)
        stats.totalBlocks = totalBytes / UInt64(bs)
        stats.availableBlocks = freeBytes / UInt64(bs)
        stats.freeBlocks = stats.availableBlocks
        // df and Finder read the used and byte counts; left at 0 they showed "0 used".
        stats.usedBlocks = stats.totalBlocks - stats.freeBlocks
        stats.totalBytes = totalBytes
        stats.availableBytes = freeBytes
        stats.freeBytes = freeBytes
        stats.usedBytes = totalBytes - freeBytes
        return stats
    }

    // MARK: PathConf

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: lifecycle

    func activate(options: FSTaskOptions) async throws -> FSItem {
        do { return try activateVolume(options: options) }
        catch {
            // A refused activation (e.g. unclean Windows log) must not keep the
            // device open: otherwise the disk cannot be ejected until this
            // extension process exits.
            operationLock.withLock { _ = closeEngine() }
            resource.revoke()
            activationRefused?(error)
            // FSKit keeps the refused container's device descriptor open in this
            // single-resource process (revoke does not close it), which blocks
            // eject. Nothing is mounted here; exit after the error is delivered.
            log.notice("激活被拒绝；稍后结束本实例以释放设备")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { exit(0) }
            throw error
        }
    }

    private func activateVolume(options: FSTaskOptions) throws -> FSItem {
        return try operationLock.withLock {
        if bitLocker {
            // Never log these options: they carry the key.
            guard let key = BitLockerMount.key(in: options.taskOptions) else {
                log.notice("BitLocker 卷没有随挂载提供密钥，拒绝激活")
                throw posix(EACCES)
            }
            bitLockerKey = key
            journal.bitLockerKey = key
            #if VOLISLE_DAILY_WRITES
            readOnly = !WriteMountPolicy.allowsBitLocker(options: options.taskOptions, writable: resource.isWritable,
                                                         byteCount: UInt64(max(0, deviceSize)))
            if !readOnly && !recoverInterruptedWrites() { readOnly = true }
            if !readOnly { try WriteMountPolicy.validateInspection(inspectBeforeWritableActivation()) }
            #else
            readOnly = true
            #endif
            wantReadOnlyMount = readOnly
            log.notice("BitLocker 卷激活只读=\(self.readOnly)")
            try openEngine()
            return try activatedRoot()
        }
        #if VOLISLE_DAILY_WRITES
        readOnly = !WriteMountPolicy.allowsDaily(options: options.taskOptions, writable: resource.isWritable,
            serial: volumeSerial, byteCount: UInt64(max(0, deviceSize)))
        if !readOnly && !recoverInterruptedWrites() { readOnly = true }
        if !readOnly { try WriteMountPolicy.validateInspection(inspectBeforeWritableActivation()) }
        wantReadOnlyMount = readOnly
        #endif
        #if VOLISLE_PHYSICAL_TEST
        readOnly = !PhysicalTestTarget.policy.allows(bsdName: resource.bsdName, serial: volumeSerial,
            byteCount: UInt64(max(0, deviceSize)), options: options.taskOptions,
            writable: resource.isWritable, now: Date().timeIntervalSince1970)
        if !readOnly && !recoverInterruptedWrites() { readOnly = true }
        if !readOnly { try WriteMountPolicy.validateInspection(inspectBeforeWritableActivation()) }
        wantReadOnlyMount = readOnly
        log.notice("实盘测试激活只读=\(self.readOnly)")
        #endif
        #if VOLISLE_EXPERIMENTAL_WRITES
        readOnly = try WriteMountPolicy.requiresReadOnly(options: options.taskOptions, writable: resource.isWritable,
            serial: volumeSerial, byteCount: UInt64(max(0, deviceSize)), allowedSerial: ExperimentalFixture.serial, allowedByteCount: ExperimentalFixture.byteCount,
            inspect: {
                guard self.recoverInterruptedWrites() else { throw self.posix(EROFS) }
                return try self.inspectBeforeWritableActivation()
            })
        wantReadOnlyMount = readOnly
        log.notice("实验激活参数=\(options.taskOptions.description, privacy: .public) 只读=\(self.readOnly)")
        #endif
        try openEngine()
        // An update from an experimental build must not bypass unresolved
        // evidence. All builds audit before the first writable engine opens.
        try auditReplacementJournals()
        return try activatedRoot()
    
        }
    }

    private func activatedRoot() throws -> FSItem {
        var label = [CChar](repeating: 0, count: 256)
        engineQueue.sync { _ = nk_label(vol, &label, 256) }
        let name = String(decoding: label.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if !name.isEmpty { self.name = FSFileName(string: name) }
        return try item(path: "/", kind: .directory)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        return try operationLock.withLock {

        // An unmount-time engine write failure must not be silent data loss,
        // and flushing the buffer cache at teardown is on us, not fskitd.
        let rc = closeEngine()
        guard rc == 0 else { throw posix(EIO) }
    
        }
    }
    func mount(options: FSTaskOptions) async throws {
        return try operationLock.withLock {
 try openEngine() 
        }
    }
    func unmount() async {
        return operationLock.withLock {
 closeEngine() 
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        return try operationLock.withLock {

        // FSKit can send a final sync after unmount has closed the engine.
        // Preserve an earlier failure, but don't sync a nil handle.
        let rc = engineQueue.sync { vol == nil ? (closeFailed ? Int32(-1) : Int32(0)) : checkpointJournal(force: true) }
        guard rc == 0 else { throw posix(EIO) }
    
        }
    }

    // MARK: attributes

    private func makeAttributes(path: String, st: nk_stat,
                                identifier: FSItem.Identifier) throws -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        if st.is_symlink != 0 {
            attrs.type = .symlink
            attrs.mode = 0o120755
        } else if st.is_dir != 0 {
            attrs.type = .directory
            attrs.mode = 0o040000 | st.mac_mode
        } else {
            attrs.type = .file
            attrs.mode = 0o100000 | st.mac_mode
        }
        attrs.size = UInt64(max(0, st.size))
        attrs.allocSize = UInt64(max(0, st.alloc_size))
        attrs.linkCount = isPrivateReplacementPath(path) ? 0 : 1
        attrs.fileID = identifier
        attrs.parentID = try path == "/" ? .parentOfRoot : id(for: (path as NSString).deletingLastPathComponent)
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.flags = Self.flags(st)
        // All I/O stays in the serialized callback bridge; no kernel-offloaded
        // mappings are advertised by this implementation.
        attrs.inhibitKernelOffloadedIO = true
        attrs.modifyTime = timespec(tv_sec: Int(st.mtime), tv_nsec: Int(st.mtime_nsec))
        attrs.accessTime = timespec(tv_sec: Int(st.atime), tv_nsec: Int(st.atime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(st.ctime), tv_nsec: Int(st.ctime_nsec))
        attrs.birthTime = timespec(tv_sec: Int(st.btime), tv_nsec: Int(st.btime_nsec))
        return attrs
    }

    /// NTFS HIDDEN → UF_HIDDEN, so Finder hides e.g. $RECYCLE.BIN like Windows.
    private static func flags(_ st: nk_stat) -> UInt32 {
        st.file_flags & 0x2 != 0 ? UInt32(UF_HIDDEN) : 0
    }

    func attributes(_ request: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        var st = nk_stat()
        try engineQueue.sync {
            guard nk_stat_reference(vol, item.fileReference, &st) == 0 else { throw posix(errno == 0 ? EIO : errno) }
        }
        return try makeAttributes(path: item.path, st: st, identifier: item.identifier)
    
        }
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        try requirePathIdentity(item)
        var current = nk_stat()
        let found = engineQueue.sync { item.path.withCString { nk_stat_path(vol, $0, &current) } }
        guard found == 0 else { throw posix(ENOENT) }
        let kind: FSItem.ItemType = current.is_dir != 0 ? .directory : (current.is_symlink != 0 ? .symlink : .file)
        let update = try AttributeUpdate(request, kind: kind, privateModes: privateModesEnabled,
                                         currentFlags: Self.flags(current))
        try requirePhysicalTestPath(item.path)
        try requireWritableEngine()
        try withReplacementWrite(item, maximumSize: request.isValid(.size) ? request.size : nil) {
            try applyAttributes(update, path: item.path)
        }
        var st = nk_stat()
        let rc = engineQueue.sync { item.path.withCString { nk_stat_path(vol, $0, &st) } }
        guard rc == 0 else { throw posix(EIO) }
        return try makeAttributes(path: item.path, st: st, identifier: item.identifier)
    
        }
    }

    private func applyAttributes(_ update: AttributeUpdate, path: String) throws {
        try update.apply(setMode: { mode in
            try self.engineQueue.sync {
                let rc = path.withCString { self.privateModesEnabled ? nk_set_mac_mode(self.vol, $0, mode) : nk_set_file_mode(self.vol, $0, mode) }
                guard rc == 0 else { throw self.posix(errno == 0 ? EIO : errno) }
            }
        }, truncate: { size in
            try self.engineQueue.sync {
                let rc = path.withCString { nk_truncate(self.vol, $0, size) }
                guard rc == 0 else { throw self.posix(errno == 0 ? EIO : errno) }
            }
        }, setTimes: { access, modify, birth in
            var a = access ?? nk_timestamp(), m = modify ?? nk_timestamp(), b = birth ?? nk_timestamp()
            try self.engineQueue.sync {
                let rc = withUnsafePointer(to: &a) { ap in
                    withUnsafePointer(to: &m) { mp in
                        withUnsafePointer(to: &b) { bp in
                            path.withCString { nk_set_times_precise(self.vol, $0,
                                access == nil ? nil : ap, modify == nil ? nil : mp, birth == nil ? nil : bp) }
                        }
                    }
                }
                guard rc == 0 else { throw self.posix(errno == 0 ? EIO : errno) }
            }
        })
    }

    // MARK: lookup / enumerate

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        return try operationLock.withLock {

        guard let dir = directory as? NTFSItem, let childName = name.string else { throw posix(EINVAL) }
        try requirePathIdentity(dir)
        let childPath = dir.childPath(childName)
        guard !isPrivateReplacementPath(childPath) else { throw posix(ENOENT) }
        var st = nk_stat()
        let rc = engineQueue.sync { childPath.withCString { nk_stat_path(vol, $0, &st) } }
        guard rc == 0 else { throw posix(ENOENT) }
        let kind: FSItem.ItemType = st.is_symlink != 0 ? .symlink
                                  : st.is_dir != 0 ? .directory : .file
        return (try item(path: childPath, kind: kind), name)
    
        }
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        return try operationLock.withLock {

        guard let dir = directory as? NTFSItem else { throw posix(EINVAL) }
        try requirePathIdentity(dir)

        // Sample the generation BEFORE listing: if a mutation lands during or
        // after the list, the verifier we hand back is already stale and the
        // next resume gets told to restart — never a fresh verifier on a
        // stale entry vector.
        let generation = stateLock.withLock { dirGeneration }
        if cookie.rawValue != 0 && verifier.rawValue != generation {
            throw FSError(.invalidDirectoryCookie)
        }

        let collector = DirCollector()
        let rc = engineQueue.sync {
            dir.path.withCString { path in
                nk_list(vol, path, dirCollectCallback, Unmanaged.passUnretained(collector).toOpaque())
            }
        }
        guard rc == 0 else { throw posix(EIO) }

        var entries: [(name: String, type: FSItem.ItemType, path: String)] = []
        if attributes == nil {
            let parentPath = dir.path == "/" ? "/"
                : (dir.path as NSString).deletingLastPathComponent
            entries.append((".", .directory, dir.path))
            entries.append(("..", .directory, parentPath))
        }
        for e in collector.items where !isPrivateReplacementPath(dir.childPath(e.name)) {
            entries.append((e.name, e.isDir ? .directory : (e.isLink ? .symlink : .file), dir.childPath(e.name)))
        }

        guard var index = Int(exactly: cookie.rawValue) else {
            throw FSError(.invalidDirectoryCookie)
        }
        while index < entries.count {
            let entry = entries[index]
            // FSKit drops entries packed without attributes when it asked for
            // them — fetch per entry (path-addressed engine, one stat each).
            var entryAttrs: FSItem.Attributes? = nil
            if attributes != nil {
                var st = nk_stat()
                let rc = engineQueue.sync { entry.path.withCString { nk_stat_path(vol, $0, &st) } }
                if rc == 0 {
                    entryAttrs = try makeAttributes(path: entry.path, st: st,
                                                identifier: id(for: entry.path))
                }
            }
            let ok = packer.packEntry(name: FSFileName(string: entry.name),
                                      itemType: entry.type,
                                      itemID: try id(for: entry.path),
                                      nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                      attributes: entryAttrs)
            if !ok { break }
            index += 1
        }
        return FSDirectoryVerifier(rawValue: generation)
    
        }
    }

    // MARK: create / remove / rename

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        return try operationLock.withLock {

        guard let dir = directory as? NTFSItem, let childName = name.string else { throw posix(EINVAL) }
        try requirePathIdentity(dir)
        try requireMutableNamespace(dir.childPath(childName))
        guard type == .file || type == .directory else { throw posix(ENOTSUP) }
        let update = try AttributeUpdate(newAttributes, kind: type, privateModes: privateModesEnabled)
        try requireWritableEngine()
        let rc = engineQueue.sync {
            dir.path.withCString { dp in
                childName.withCString { np in
                    if privateModesEnabled {
                        let mode: UInt32 = newAttributes.isValid(.mode) ? newAttributes.mode & 0o7777 : (type == .directory ? 0o755 : 0o644)
                        return nk_create_mode(vol, dp, np, mode, type == .directory ? 1 : 0)
                    }
                    return type == .directory ? nk_mkdir(vol, dp, np) : nk_create(vol, dp, np)
                }
            }
        }
        guard rc == 0 else { throw posix(EIO) }
        mutateNamespace {}
        let childPath = dir.childPath(childName)
        do {
            try applyAttributes(update, path: childPath)
        } catch {
            // Only the node created above belongs to this rollback. A failed
            // I/O session may reject cleanup; don't hide that or claim success.
            let cleanup = engineQueue.sync { childPath.withCString { nk_delete(vol, $0) } }
            if cleanup != 0 { log.error("新建属性写入失败且无法清理新节点；保留失败会话") }
            throw error
        }
        return (try item(path: childPath, kind: type), name)
    
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        try requirePathIdentity(item)
        try requireMutableNamespace(item.path)
        try requireWritableEngine()
        let rc = engineQueue.sync { item.path.withCString { nk_delete(vol, $0) } }
        log.info("removeItem \(item.path, privacy: .private) rc=\(rc)")
        guard rc == 0 else { throw posix(EIO) }
        mutateNamespace {
            identityCache.remove(item)
        }
    
        }
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem,
              let destDir = destinationDirectory as? NTFSItem,
              let newName = destinationName.string else { throw posix(EINVAL) }
        try requirePathIdentity(item)
        try requirePathIdentity(destDir)
        try requireMutableNamespace(item.path)
        try requireMutableNamespace(destDir.childPath(newName))
        try requireWritableEngine()

        // A directory must never move into itself or its own subtree — the
        // engine's link-then-delete would happily create a cycle.
        if destDir.path == item.path || destDir.path.hasPrefix(item.path + "/") {
            throw posix(EINVAL)
        }

        if let overItem {
            guard let old = overItem as? NTFSItem else { throw posix(EINVAL) }
            #if VOLISLE_EXPERIMENTAL_REPLACEMENT
            try replace(item, old: old, directory: destDir, name: newName)
            #else
            try replaceWithinOperation(item, old: old, directory: destDir, name: newName)
            #endif
            return destinationName
        }
        try requireMutableNamespace(item.path)
        try requireMutableNamespace(destDir.childPath(newName))
        let rc = engineQueue.sync {
            item.path.withCString { op in
                destDir.path.withCString { dp in
                    newName.withCString { np in nk_rename(vol, op, dp, np) }
                }
            }
        }
        guard rc == 0 else { throw posix(EIO) }

        // The kernel keeps using the SAME item object after rename (it may be
        // open) — rewrite its path in place and re-key the caches, including
        // every cached descendant and enumeration-only identifier.
        mutateNamespace {
            let newPath = destDir.childPath(newName)
            identityCache.move(item, to: newPath)
        }
        return destinationName
    
        }
    }

    #if !VOLISLE_EXPERIMENTAL_REPLACEMENT
    /// Application safe-save (rename over an existing name). Runs inside one
    /// FSKit operation, so the write journal makes it crash-atomic: an
    /// interruption rolls back to before it. Each step fails without loss;
    /// an engine failure locks the session for rollback at reconnection.
    private func replaceWithinOperation(_ item: NTFSItem, old: NTFSItem, directory: NTFSItem, name: String) throws {
        try requirePathIdentity(old)
        try requireMutableNamespace(old.path)
        guard old.path.lowercased() == directory.childPath(name).lowercased(), old.fileReference != item.fileReference else {
            throw posix(EINVAL)
        }
        var source = nk_stat(), target = nk_stat()
        try engineQueue.sync {
            guard item.path.withCString({ nk_stat_path(vol, $0, &source) }) == 0,
                  old.path.withCString({ nk_stat_path(vol, $0, &target) }) == 0 else { throw posix(ENOENT) }
        }
        if (source.is_dir != 0) != (target.is_dir != 0) { throw posix(target.is_dir != 0 ? EISDIR : ENOTDIR) }
        if target.is_dir != 0 {
            let collector = DirCollector()
            let listed = engineQueue.sync {
                old.path.withCString { nk_list(vol, $0, dirCollectCallback, Unmanaged.passUnretained(collector).toOpaque()) }
            }
            guard listed == 0 else { throw posix(EIO) }
            guard collector.items.isEmpty else { throw posix(ENOTEMPTY) }
        }
        let oldName = (old.path as NSString).lastPathComponent
        let backup = ".volisle-replaced-" + UUID().uuidString.lowercased()
        let backupPath = directory.childPath(backup)
        func rename(_ from: String, _ to: String) -> Int32 {
            from.withCString { f in directory.path.withCString { d in to.withCString { t in nk_rename(vol, f, d, t) } } }
        }
        try engineQueue.sync {
            guard rename(old.path, backup) == 0 else { throw posix(EIO) }
            guard rename(item.path, name) == 0 else {
                if rename(backupPath, oldName) != 0 { log.error("替换失败且无法还原原名；停止写入，下次连接时回滚") }
                throw posix(EIO)
            }
            // Keep the replaced file's Windows permissions, as Windows ReplaceFile does.
            let target = directory.childPath(name)
            guard source.is_dir != 0 || backupPath.withCString({ b in target.withCString { nk_copy_security(vol, b, $0) } }) == 0 else {
                log.error("替换后无法保留原 Windows 权限；停止写入，下次连接时回滚")
                throw posix(EIO)
            }
            guard backupPath.withCString({ nk_delete(vol, $0) }) == 0 else { throw posix(EIO) }
        }
        mutateNamespace {
            identityCache.remove(old)
            identityCache.move(item, to: directory.childPath(name))
        }
    }
    #endif

    func reclaimItem(_ item: FSItem) async throws {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { return }
        var failure: Error?
        let cleanup = {
            do {
                #if VOLISLE_EXPERIMENTAL_REPLACEMENT
                try self.reclaimReplacement(item)
                #endif
                self.evictIfCurrent(item)
            } catch {
                #if VOLISLE_EXPERIMENTAL_REPLACEMENT
                self.engineQueue.sync { nk_abort_write_session(self.vol) }
                #endif
                failure = error
            }
        }
        if #available(macOS 27.0, *) { _ = item.tryReclaim(cleanup) }
        else { cleanup() }
        if let failure { throw failure }
    
        }
    }

    private func evictIfCurrent(_ item: NTFSItem) {
        stateLock.lock(); defer { stateLock.unlock() }
        identityCache.reclaim(item)
    }

    // MARK: read / write

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        let n = try engineQueue.sync {
            let count = buffer.withUnsafeMutableBytes { raw -> Int64 in
                nk_read_reference(vol, item.fileReference, Int64(offset), Int64(min(length, raw.count)), raw.baseAddress)
            }
            guard count >= 0 else { throw posix(errno == 0 ? EIO : errno) }
            return count
        }
        guard n >= 0 else { throw posix(EIO) }
        return Int(n)
    
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        try requirePhysicalTestPath(item.path)
        try requireWritableEngine()
        guard offset >= 0, UInt64(contents.count) <= UInt64.max - UInt64(offset) else { throw posix(EINVAL) }
        let n = try withReplacementWrite(item, maximumSize: UInt64(offset) + UInt64(contents.count)) {
            try engineQueue.sync {
            let count = contents.withUnsafeBytes { raw -> Int64 in
                nk_write_reference(vol, item.fileReference, Int64(offset), Int64(raw.count), raw.baseAddress)
            }
            guard count >= 0 else { throw posix(errno == 0 ? EIO : errno) }
            return count
            }
        }
        guard n >= 0 else { throw posix(EIO) }
        return Int(n)
    
        }
    }

    // MARK: symlinks

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        return try operationLock.withLock {

        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        try requirePathIdentity(item)
        var buf = [CChar](repeating: 0, count: 4096)
        let rc = engineQueue.sync { item.path.withCString { nk_readlink(vol, $0, &buf, 4096) } }
        guard rc == 0 else { throw posix(EINVAL) }
        return FSFileName(string: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    
        }
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        return try operationLock.withLock {

        guard let dir = directory as? NTFSItem, let childName = name.string, let target = contents.string,
              !target.isEmpty, !target.utf8.contains(0) else { throw posix(EINVAL) }
        guard target.utf8.count <= Int(NK_SYMLINK_TARGET_MAX) else { throw posix(ENAMETOOLONG) }
        try requirePathIdentity(dir)
        try requireMutableNamespace(dir.childPath(childName))
        try requireWritableEngine()
        // Interix link: macOS and Linux read the target back verbatim;
        // Windows keeps it as a small system file. Links carry no mode.
        let error: Int32 = engineQueue.sync {
            let rc = dir.path.withCString { dp in
                childName.withCString { np in target.withCString { nk_create_symlink(vol, dp, np, $0) } }
            }
            return rc == 0 ? 0 : (errno == 0 ? EIO : errno)
        }
        guard error == 0 else { throw posix(error) }
        mutateNamespace {}
        return (try item(path: dir.childPath(childName), kind: .symlink), name)
    
        }
    }

    // MARK: not yet supported

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        return try operationLock.withLock {

        throw posix(ENOTSUP)
    
        }
    }
}

// Extended attributes are named NTFS data streams. ACLs and compression
// metadata remain unsupported; an I/O failure is never translated to ENOATTR.
extension NTFSVolume: FSVolume.XattrOperations {
    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        try operationLock.withLock {
            guard let item = item as? NTFSItem else { throw posix(EINVAL) }
            try requirePathIdentity(item)
            let collector = XattrCollector()
            return try engineQueue.sync {
                let result = item.path.withCString {
                    nk_xattr_list(vol, $0, xattrCollectCallback, Unmanaged.passUnretained(collector).toOpaque())
                }
                guard result == 0 else { throw posix(errno == 0 ? EIO : errno) }
                return collector.names.map { FSFileName(string: $0) }
            }
        }
    }

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        try operationLock.withLock {
            guard let item = item as? NTFSItem, let name = name.string else { throw posix(EINVAL) }
            try requirePathIdentity(item)
            return try engineQueue.sync {
                try item.path.withCString { path in
                    try name.withCString { name in
                        let size = nk_xattr_get(vol, path, name, nil, 0)
                        guard size >= 0 else { throw posix(errno == 0 ? EIO : errno) }
                        guard size <= 4 * 1024 * 1024 else { throw posix(E2BIG) }
                        if size == 0 { return Data() }
                        var data = Data(count: Int(size))
                        let count = data.withUnsafeMutableBytes {
                            nk_xattr_get(vol, path, name, $0.baseAddress, Int64($0.count))
                        }
                        guard count >= 0 else { throw posix(errno == 0 ? EIO : errno) }
                        guard count == size else { throw posix(EIO) }
                        return data
                    }
                }
            }
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        try operationLock.withLock {
            guard let item = item as? NTFSItem, let name = name.string else { throw posix(EINVAL) }
            try requirePathIdentity(item)
            // Recovery fingerprints cover unnamed data, not named streams.
            try requireMutableNamespace(item.path)
            try requireWritableEngine()
            try engineQueue.sync {
                try item.path.withCString { path in
                    try name.withCString { name in
                        let result: Int32
                        if policy == .delete {
                            result = nk_xattr_remove(vol, path, name)
                        } else {
                            guard let value else { throw posix(EINVAL) }
                            let flag: Int32
                            switch policy {
                            case .mustCreate: flag = Int32(NK_XATTR_CREATE)
                            case .mustReplace: flag = Int32(NK_XATTR_REPLACE)
                            case .alwaysSet: flag = Int32(NK_XATTR_UPSERT)
                            default: throw posix(ENOTSUP)
                            }
                            guard value.count <= 4 * 1024 * 1024 else { throw posix(E2BIG) }
                            result = value.withUnsafeBytes {
                                nk_xattr_set(vol, path, name, $0.baseAddress, Int64($0.count), flag)
                            }
                        }
                        guard result == 0 else { throw posix(errno == 0 ? EIO : errno) }
                    }
                }
            }
        }
    }
}

private final class XattrCollector { var names: [String] = [] }
private let xattrCollectCallback: nk_name_cb = { context, name in
    guard let context, let name else { return 1 }
    Unmanaged<XattrCollector>.fromOpaque(context).takeUnretainedValue().names.append(String(cString: name))
    return 0
}

/// Box that collects directory entries out of the C callback.
final class DirCollector {
    var items: [(name: String, isDir: Bool, size: Int64, isLink: Bool)] = []
}

private let dirCollectCallback: nk_dirent_cb = { ctx, entryPtr in
    guard let ctx, let entryPtr else { return 0 }
    let collector = Unmanaged<DirCollector>.fromOpaque(ctx).takeUnretainedValue()
    let entry = entryPtr.pointee
    if let namePtr = entry.name {
        collector.items.append((String(cString: namePtr), entry.is_dir != 0, entry.size, entry.is_symlink != 0))
    }
    return 0
}

// MARK: write journal

extension NTFSVolume: JournalBlockDevice {
    var journalBlockSize: Int { deviceBlockSize }
    var journalDeviceSize: Int64 { deviceSize }
    /// Before a kernel mount only plain synchronous I/O exists; recovery done
    /// then is kept on record until a later metadata flush confirms it.
    var flushIsDurable: Bool { ioMode == .metadata }

    func journalRead(into block: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        try readCacheBlock(into: block, at: offset, length: block.count)
    }

    func journalReadRun(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws {
        guard try resource.read(into: buffer, startingAt: off_t(offset), length: buffer.count) == buffer.count else {
            throw posix(EIO)
        }
    }

    /// Mounted: into the buffer cache, written by the checkpoint's flush.
    /// The journal record for the block is already durable at this point.
    func journalWrite(_ block: UnsafeRawBufferPointer, at offset: Int64) throws {
        if ioMode == .metadata {
            try resource.delayedMetadataWrite(from: block, startingAt: off_t(offset), length: block.count)
            return
        }
        guard resource.isWritable else { throw posix(EROFS) }
        guard try resource.write(from: block, startingAt: off_t(offset), length: block.count) == block.count else {
            throw posix(EIO)
        }
    }

    func journalFlush() throws {
        if ioMode == .metadata { try resource.metadataFlush() }
    }

    private var journalSerial: String { volumeSerial.map { String(format: "%02x", $0) }.joined() }

    private func writeJournalStore() throws -> WriteJournalStore {
        // Only the OS-provided sandbox base, never a path from the disk or options.
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        return try WriteJournalStore(directory: base.appendingPathComponent("VolisleWriteJournal", isDirectory: true))
    }

    /// Activation, before the writable inspection: roll an interrupted session
    /// back to its last checkpoint. Returns false when writes must stay off.
    func recoverInterruptedWrites() -> Bool {
        engineQueue.sync {
            let outcome: WriteJournalCoordinator.Outcome
            do { outcome = WriteJournalCoordinator.recover(store: try writeJournalStore(), serial: journalSerial, io: journal) }
            catch { outcome = .refused(.unavailable) }
            switch outcome {
            case .none: return true
            case .superseded:
                log.notice("这块盘中断后在其他系统上用过：旧的恢复记录已作废并归档，按磁盘当前状态检查")
                return true
            case .recovered:
                log.notice("上次写入中断已回滚到最后一致点并释放本机脏标记")
                return true
            case .refused(let reason):
                log.error("上次写入中断无法安全恢复（\(String(describing: reason), privacy: .public)）；保持只读，记录保留")
                return false
            }
        }
    }

    private func beginJournalSession() throws {
        try engineQueue.sync {
            guard journal.session == nil else { throw posix(EBUSY) }
            do {
                (_, journalLock) = try WriteJournalCoordinator.begin(store: try writeJournalStore(),
                                                                       serial: journalSerial, io: journal)
                log.notice("写入日志会话开始：卷=\(self.journalSerial, privacy: .public)")
            } catch {
                log.error("写入日志无法开始（\(String(describing: error), privacy: .public)）；拒绝写入")
                throw posix(EROFS)
            }
        }
    }

    /// Engine queue. Records stay for recovery at the next connection.
    private func abandonJournalSession() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        if journal.session != nil { log.error("写入日志会话停止：记录保留，下次连接时恢复") }
        journal.session?.stop()
        journal.session = nil
        if journalLock >= 0 { Darwin.close(journalLock); journalLock = -1 }
    }

    /// Engine queue, after a successful nk_umount.
    private func finishJournalSession() -> Int32 {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        guard journal.session != nil, journalLock >= 0 else { return -1 }
        defer { journalLock = -1 }
        do {
            try WriteJournalCoordinator.finish(store: try writeJournalStore(), io: journal, lock: journalLock)
            log.notice("写入日志会话正常结束：记录已清除")
            return 0
        } catch {
            log.error("写入日志结束失败；记录保留，下次连接时恢复")
            return -1
        }
    }

    /// Engine queue, writable engine open. Without the map every block keeps
    /// its before-image, which is only slower.
    private func attachFreeSpaceMap() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        // BitLocker: the bitmap on the device is ciphertext, so the journal could
        // not tell free blocks apart. Keep every before-image instead.
        guard !bitLocker, let vol, let session = journal.session else { return }
        var clusterSize: Int64 = 0, clusters: Int64 = 0, count = 0
        var runs = [nk_extent](repeating: nk_extent(), count: 256)
        guard nk_bitmap_layout(vol, &clusterSize, &clusters, &runs, runs.count, &count) == 0,
              let map = FreeSpaceMap(clusterSize: clusterSize, clusters: clusters,
                                     runs: runs.prefix(count).map { ($0.offset, $0.length) }, deviceSize: deviceSize) else {
            log.error("无法读取簇位图位置；写入照常备份全部原内容")
            return
        }
        session.freeSpace = map
    }

    /// Engine queue, at an operation boundary (callers hold operationLock).
    fileprivate func checkpointJournal(force: Bool) -> Int32 {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        guard let vol else { return closeFailed ? -1 : 0 }
        guard engineWritable, let session = journal.session else { return nk_sync(vol) }
        guard !session.failed else { return -1 }
        // Even when idle: a retained epoch left past its window would make an
        // unplug minutes later undo writes long since on the disk.
        session.pruneRetained()
        let now = Date()
        guard force || session.checkpointDue ||
              (session.hasUncheckpointedWrites &&
               (now.timeIntervalSince(session.lastWrite) >= 1 || now.timeIntervalSince(session.epochStarted) >= 5)) else { return 0 }
        guard nk_sync(vol) == 0 else { session.stop(); return -1 }
        do {
            let epoch = session.epoch
            try session.checkpoint()
            if session.epoch != epoch { log.info("检查点完成：周期=\(epoch, privacy: .public)") }
            return 0
        }
        catch { log.error("检查点失败；停止写入，下次连接时恢复"); return -1 }
    }

    private func startCheckpointTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.operationLock.withLock { _ = self.engineQueue.sync { self.checkpointJournal(force: false) } }
        }
        checkpointTimer = timer
        timer.resume()
    }
}
