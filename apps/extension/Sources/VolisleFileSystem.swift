import Foundation
import FSKit

/// Development extension. No repair or format maintenance interfaces.
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
            return .usableButLimited(name: "BitLocker", containerID: FSContainerIdentifier(uuid: BitLockerMount.identifier(bytes)))
        }
        return .usable(name: "NTFS", containerID: FSContainerIdentifier(uuid: identifier(bytes)))
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
