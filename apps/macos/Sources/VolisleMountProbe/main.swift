// Development-only integration runner; not embedded in the application bundle.
import Foundation
import CryptoKit
import Darwin
#if DEBUG
@testable import VolisleCore
#else
import VolisleCore
#endif

@main struct VolisleMountProbe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("系统挂载执行层验收失败：\(error)\n".utf8)); exit(1) }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func run() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--write-image-binding" {
            let session = try FSKitWriteMountSession(image: URL(filePath: CommandLine.arguments[3]), bsdName: CommandLine.arguments[2],
                extensionURL: URL(filePath: NSHomeDirectory() + "/Applications/Volisle Test.app/Contents/Extensions/VolisleFS.appex"),
                identifier: "top.qisw.volisle.filesystem")
            let volume = try await session.snapshot()
            let disk = try HelperDiskRequest(version: 2, bsdName: volume.bsdName, registryID: volume.identity.mediaRegistryID!, byteCount: 67_108_864)
            FileHandle.standardOutput.write(try JSONEncoder().encode(disk))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--write-transaction" {
            try await WriteProbe.run(Array(CommandLine.arguments.dropFirst(2))); return
        }
        guard CommandLine.arguments.count == 4, getuid() != 0 else { throw VolumeError.protectedVolume }
        let bsdName = CommandLine.arguments[1]
        let image = URL(filePath: CommandLine.arguments[2]).standardizedFileURL
        let expectedPayloadHash = CommandLine.arguments[3]
        guard image.lastPathComponent == "fixture.img",
              image.deletingLastPathComponent().lastPathComponent.hasPrefix("fskit-readonly-"),
              image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".workbench",
              image.resolvingSymlinksInPath().path == image.path else { throw VolumeError.unstableIdentity }
        let fd = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(fd) }
        var metadata = Darwin.stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_size == 67_108_864 else {
            throw VolumeError.unstableIdentity
        }
        var boot = [UInt8](repeating: 0, count: 512)
        guard boot.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 512, 0) }) == 512 else { throw POSIXError(.EIO) }
        // Independently verify the BSD device belongs to this ordinary image;
        // an arbitrary physical disk argument never reaches the mount session.
        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { throw VolumeError.unstableIdentity }
        let matches = images.filter { record in
            guard let path = record["image-path"] as? String,
                  URL(filePath: path).resolvingSymlinksInPath() == image,
                  let entities = record["system-entities"] as? [[String: Any]] else { return false }
            return entities.compactMap { $0["dev-entry"] as? String } == ["/dev/" + bsdName]
        }
        guard matches.count == 1 else { throw VolumeError.identityChanged }
        let binding = try ReadOnlyDeviceBinding.captureDiskImage(image, bsdName: bsdName, byteCount: 67_108_864, bootSHA256: hash(Data(boot)))
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Volisle Test.app")
        let extensionURL = installed.appendingPathComponent("Contents/Extensions/VolisleFS.appex")
        // Exercise actual held-device validation before the successful mount,
        // including a failed initializer which must release its descriptor.
        let wrongBoot = try ReadOnlyDeviceBinding.captureDiskImage(image, bsdName: bsdName, byteCount: 67_108_864,
                                                                   bootSHA256: String(repeating: "0", count: 64))
        let wrongMedia = try ReadOnlyDeviceBinding(bsdName: bsdName, registryID: binding.registryID + 1,
                                                   byteCount: 67_108_864, bootSHA256: binding.bootSHA256)
        for invalid in [wrongBoot, wrongMedia] {
            do {
                let unexpected = try FSKitReadOnlyMountSession(binding: invalid, extensionURL: extensionURL,
                                                               identifier: "top.qisw.volisle.filesystem")
                try await unexpected.close()
                throw VolumeError.mountNotVerified
            } catch VolumeError.identityChanged { }
        }
        var result: [String: Bool] = ["incorrect_resource_binding_rejected": true]
        #if DEBUG
        // Exercise the same DA primitives used by the system helper, against
        // this independently bound disposable image only.
        let native = try await NativeReadOnlyDisk(bsdName: bsdName, registryID: binding.registryID)
        do {
            FileHandle.standardError.write(Data("stage=native-readonly-mount\n".utf8))
            try await native.mount()
            let records = try SystemMountRecord.current().filter { $0.source == "/dev/" + bsdName }
            guard records.count == 1, records[0].type == "ntfs",
                  records[0].flags & UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV) == UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV) else {
                throw VolumeError.mountNotVerified
            }
            let payload = try Data(contentsOf: URL(filePath: records[0].path).appendingPathComponent("Volisle-中文读取.txt"))
            guard hash(payload) == expectedPayloadHash else { throw VolumeError.mountNotVerified }
            result["native_readonly_restore_verified"] = true
            FileHandle.standardError.write(Data("stage=native-normal-unmount\n".utf8))
            try await native.unmount()
            guard try !SystemMountRecord.current().contains(where: { $0.source == "/dev/" + bsdName }) else {
                throw VolumeError.mountNotVerified
            }
            result["native_normally_unmounted"] = true
            let bootFD = open("/dev/" + bsdName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard bootFD >= 0 else { throw POSIXError(.EACCES) }
            var deviceBoot = [UInt8](repeating: 0, count: 512)
            let readCount = deviceBoot.withUnsafeMutableBytes { pread(bootFD, $0.baseAddress, $0.count, 0) }
            Darwin.close(bootFD)
            guard readCount == 512, hash(Data(deviceBoot)) == binding.bootSHA256 else { throw VolumeError.identityChanged }
            try await native.mount()
            let restored = try SystemMountRecord.current().filter { $0.source == "/dev/" + bsdName }
            guard restored.count == 1, restored[0].type == "ntfs", restored[0].flags & UInt32(MNT_RDONLY) != 0,
                  hash(try Data(contentsOf: URL(filePath: restored[0].path).appendingPathComponent("Volisle-中文读取.txt"))) == expectedPayloadHash else {
                throw VolumeError.mountNotVerified
            }
            try await native.unmount()
            guard try !SystemMountRecord.current().contains(where: { $0.source == "/dev/" + bsdName }) else { throw VolumeError.mountNotVerified }
            result["native_unmount_inspect_restore_cycle_verified"] = true
        } catch {
            try? await native.unmount()
            throw error
        }
        #endif
        let session = try FSKitReadOnlyMountSession(binding: binding,
            extensionURL: extensionURL, identifier: "top.qisw.volisle.filesystem")
        var failure: (any Error)?
        do {
            FileHandle.standardError.write(Data("stage=fskit-readonly-mount\n".utf8))
            let mounted = try await session.mountReadOnly()
            result["mount_verified"] = true
            let payload = try Data(contentsOf: mounted.appendingPathComponent("Volisle-中文读取.txt"))
            guard hash(payload) == expectedPayloadHash else { throw VolumeError.mountNotVerified }
            result["read_verified"] = true
            let forbidden = mounted.appendingPathComponent("Volisle-forbidden-probe-file")
            let writeFD = open(forbidden.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if writeFD >= 0 { Darwin.close(writeFD); throw VolumeError.mountNotVerified }
            guard errno == EROFS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result["write_denied"] = true
        } catch { failure = error }
        do {
            try await session.close()
            result["normally_unmounted"] = true
            result["mountpoint_removed"] = await session.mountURL == nil
        } catch {
            FileHandle.standardError.write(Data("正常卸载/清理失败：\(error)\n".utf8))
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(encoded + Data("\n".utf8))
    }
}
