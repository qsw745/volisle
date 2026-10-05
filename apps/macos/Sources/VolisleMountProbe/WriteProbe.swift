import Foundation
import CryptoKit
import Darwin
import VolisleCore

enum WriteProbe {
    static func run(_ args: [String]) async throws {
        guard args.count == 3, getuid() != 0 else { throw VolumeError.protectedVolume }
        let image = URL(filePath: args[1]).standardizedFileURL
        guard image.lastPathComponent == "fixture.img",
              image.deletingLastPathComponent().lastPathComponent.hasPrefix("fskit-readonly-"),
              image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".workbench" else {
            throw VolumeError.protectedVolume
        }
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Volisle Test.app")
        let session = try FSKitWriteMountSession(image: image, bsdName: args[0],
            extensionURL: app.appendingPathComponent("Contents/Extensions/VolisleFS.appex"),
            identifier: "top.qisw.volisle.filesystem")
        let volume = try await session.snapshot()
        guard volume.mountState == .readOnly else { throw VolumeError.mountNotVerified }
        let capability = await session.capability()
        FileHandle.standardError.write(Data("write-capability=\(capability.finderReadWrite) \(capability.reason)\n".utf8))
        let coordinator = MountCoordinator(engine: session, resolver: session, gate: DeviceOperationGate())
        var evidence: [String: Bool] = [:]
        let name = "Volisle-事务写入-" + UUID().uuidString + ".txt"
        let data = Data("盘屿：只读 → 可写 → 只读\n".utf8)
        var failure: (any Error)?
        do {
            FileHandle.standardError.write(Data("stage=enable-transaction\n".utf8))
            let url = try await coordinator.enableReadWrite(expected: volume.identity)
            evidence["coordinator_verified_writable"] = true
            FileHandle.standardError.write(Data("stage=read-seed\n".utf8))
            let seed = try Data(contentsOf: url.appendingPathComponent("Volisle-中文读取.txt"))
            let seedHash = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
            guard seedHash == args[2] else { throw VolumeError.identityChanged }
            let file = url.appendingPathComponent(name)
            FileHandle.standardError.write(Data("stage=create\n".utf8))
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o666)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd); close(fd)
            FileHandle.standardError.write(Data("stage=write count=\(count) sync=\(synced)\n".utf8))
            guard count == data.count, synced == 0, try Data(contentsOf: file) == data else { throw POSIXError(.EIO) }
            evidence["write_fsync_read_verified"] = true
        } catch { failure = error }
        FileHandle.standardError.write(Data("stage=restore\n".utf8))
        let disposition = await session.recoverFailedMount(volume)
        guard disposition == .settled else { throw VolumeError.mountNotVerified }
        let restored = try await session.snapshot()
        guard restored.mountState == .readOnly, let root = restored.mountURL else { throw VolumeError.mountNotVerified }
        evidence["native_readonly_restored"] = true
        if let failure { throw failure }
        FileHandle.standardError.write(Data("stage=native-readback\n".utf8))
        guard try Data(contentsOf: root.appendingPathComponent(name)) == data else { throw POSIXError(.EIO) }
        evidence["independent_native_readback_verified"] = true
        let fd = open(root.appendingPathComponent("must-not-write").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 { close(fd); throw VolumeError.mountNotVerified }
        guard errno == EROFS else { throw POSIXError(.EIO) }
        evidence["restored_write_denied"] = true
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
    }
}
