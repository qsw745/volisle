import Foundation
import FSKit
import os

/// No repair or format. The store build answers the system's pre-mount check (below).
final class VolisleFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private func boot(_ resource: FSBlockDeviceResource) throws -> [UInt8] {
        let size = Int(resource.blockSize)
        guard size >= 512, size <= 65536, size.nonzeroBitCount == 1, resource.blockCount > 0 else { throw posix(EINVAL) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: size)
        defer { buffer.deallocate() }
        guard try resource.read(into: buffer, startingAt: 0, length: size) == size else { throw posix(EIO) }
        let bytes = Array(buffer.prefix(512))
        if BitLockerMount.isBitLocker(bytes) { return bytes }
        guard Array(bytes[3..<11]) == Array("NTFS    ".utf8), bytes[510] == 0x55, bytes[511] == 0xaa else { throw posix(ENOTSUP) }
        return bytes
    }
    private func identifier(_ bytes: [UInt8]) -> UUID {
        // Keep every serial bit; deterministic, not a newly assigned disk identity.
        let b = Array(bytes[0x48..<0x50])
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 0x56, 0x4f, 0x4c, 0x49, 0x53, 0x4c, 0x45, 0))
    }
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let block = resource as? FSBlockDeviceResource, let bytes = try? boot(block) else { return .notRecognized }
        // Usable only with a key in the mount options.
        if BitLockerMount.isBitLocker(bytes) {
            #if VOLISLE_STORE
            // Nothing can pass a key to a system mount; leave the volume to the system.
            return .notRecognized
            #else
            return .usableButLimited(name: "BitLocker", containerID: FSContainerIdentifier(uuid: BitLockerMount.identifier(bytes)))
            #endif
        }
        #if VOLISLE_STORE
        // After a failed activation the system does not go on to its own
        // read-only driver: a claimed volume the engine cannot open stays
        // unmounted. Leave such a volume to the system here instead.
        guard let label = engineLabel(block) else {
            Logger(subsystem: "Volisle.NTFSModule", category: "probe").notice("引擎打不开这块盘，交还系统处理")
            return .notRecognized
        }
        // The system names the mount point after this.
        return .usable(name: StoreMountPolicy.mountName(label: label), containerID: FSContainerIdentifier(uuid: identifier(bytes)))
        #else
        return .usable(name: "NTFS", containerID: FSContainerIdentifier(uuid: identifier(bytes)))
        #endif
    }
    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let block = resource as? FSBlockDeviceResource else { throw posix(ENOTSUP) }
        let bytes = try boot(block)
        // loadResource may receive no mount options. Start read-only; evaluate
        // explicit fixture write intent at activation, before opening the engine.
        containerStatus = .ready
        if BitLockerMount.isBitLocker(bytes) {
            // No NTFS serial before decryption: the BitLocker volume GUID names its
            // write journal instead. Starts read-only; activation decides. The
            // name comes from the decrypted label.
            let identifier = BitLockerMount.identifier(bytes)
            let guid = withUnsafeBytes(of: identifier.uuid) { Array($0.prefix(8)) }
            let volume = NTFSVolume(resource: block, volumeName: FSFileName(string: "BitLocker"), volumeID: FSVolume.Identifier(uuid: identifier),
                                    readOnly: true, serial: guid, bitLocker: true)
            volume.activationRefused = { [weak self] error in self?.containerStatus = .notReady(status: error) }
            return volume
        }
        let volume = NTFSVolume(resource: block, volumeName: FSFileName(string: "NTFS"), volumeID: FSVolume.Identifier(uuid: identifier(bytes)), readOnly: true, serial: Array(bytes[0x48..<0x50]))
        // A refused activation leaves no usable container; tell FSKit so it
        // releases the device instead of keeping it loaded for a retry.
        volume.activationRefused = { [weak self] error in self?.containerStatus = .notReady(status: error) }
        return volume
    }
    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
    private func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}

#if VOLISLE_STORE
/// What the engine reports while it opens a volume describes the volume's
/// structure and is the only account of a failure there. Capture it then only;
/// the bridge also drops any message built from a string. The engine's log
/// handler is process-wide, so openings in one process take turns.
enum StoreEngineLog {
    private static let turn = NSLock()
    static func whileOpening<T>(_ body: () throws -> T) rethrows -> T {
        turn.lock()
        defer { turn.unlock() }
        nk_log_capture { message in
            guard let message else { return }
            Logger(subsystem: "Volisle.NTFSModule", category: "engine").error("\(String(cString: message), privacy: .public)")
        }
        defer { nk_log_capture(nil) }
        return try body()
    }
}

extension VolisleFileSystem {
    /// Whole logical blocks, as the device resource requires before a mount.
    /// The label of a volume the engine can open, else nil.
    fileprivate func engineLabel(_ resource: FSBlockDeviceResource) -> String? {
        let blockSize = Int64(resource.blockSize)
        guard blockSize > 0, let blocks = Int64(exactly: resource.blockCount) else { return nil }
        let (size, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow else { return nil }
        return StoreEngineLog.whileOpening {
            NTFSReadOnlyInspection.openableLabel(deviceSize: size) { offset, count in
                let start = offset / blockSize * blockSize
                let end = min((offset + Int64(count) + blockSize - 1) / blockSize * blockSize, size)
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(end - start), alignment: Int(blockSize))
                defer { buffer.deallocate() }
                guard try resource.read(into: buffer, startingAt: off_t(start), length: buffer.count) == buffer.count else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                return Data(bytes: buffer.baseAddress!.advanced(by: Int(offset - start)), count: count)
            }
        }
    }
}

/// The system checks a volume before it mounts it and, when the check fails,
/// tries a repair, reports "can't repair this disk" and mounts read-only.
/// This module repairs nothing. Whether a volume is safe to write is decided
/// at activation from its own inspection, so the check passes without touching
/// the disk and a volume that needs Windows is mounted read-only there.
extension VolisleFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Also what First Aid in Disk Utility runs: say that nothing was verified.
        Logger(subsystem: "Volisle.NTFSModule", category: "check").notice("检查请求参数=\(options.taskOptions.description, privacy: .public)；未检查磁盘")
        task.logMessage(String(localized: "盘屿不在 Mac 上检查或修复 NTFS 磁盘，这里没有检查文件系统。需要检查时请在 Windows 上运行磁盘检查。"))
        let progress = Progress(totalUnitCount: 1)
        // After the progress is handed back, as FSKit expects of a task.
        DispatchQueue.global(qos: .userInitiated).async {
            progress.completedUnitCount = 1
            task.didComplete(error: nil)
        }
        return progress
    }
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
    }
}
#endif
