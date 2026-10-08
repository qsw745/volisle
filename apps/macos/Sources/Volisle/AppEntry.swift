import Foundation
import SwiftUI
import VolisleCore

/// Fixed support commands use exactly the same signed package validation and
/// service controller as Settings. No sudo, shell, arbitrary path or disk writes.
@main struct AppEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first?.hasPrefix("--helper-") == true else { VolisleApp.main(); return }
        Task { @MainActor in
            do {
                try HelperPackage.validate()
                let commands: [String: HelperMountCommand.Action] = [
                    "--helper-cycle-start": .start, "--helper-write-start": .startWrite,
                    "--helper-cycle-resolve": .resolve, "--helper-write-resolve": .resolveWrite
                ]
                if arguments.count == 5, let action = commands[arguments[0]],
                   let registry = UInt64(arguments[2]), let bytes = UInt64(arguments[3]), let id = UUID(uuidString: arguments[4]) {
                    let disk = try HelperDiskRequest(version: [.startWrite, .resolveWrite].contains(action) ? 2 : 1, bsdName: arguments[1], registryID: registry, byteCount: bytes)
                    let result = try await HelperRPC.mountCycle(.init(action: action, id: id, disk: disk))
                    FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data("\n".utf8))
                } else if arguments.count == 2, ["--helper-cycle-status", "--helper-cycle-recover"].contains(arguments[0]),
                          let id = UUID(uuidString: arguments[1]) {
                    let action: HelperMountCommand.Action = arguments[0] == "--helper-cycle-status" ? .status : .recover
                    let result = try await HelperRPC.mountCycle(.init(action: action, id: id))
                    FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data("\n".utf8))
                } else if arguments == ["--helper-cycle-latest"] {
                    let result = try await HelperRPC.mountCycle(.init(action: .latest))
                    FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data("\n".utf8))
                } else if arguments.count == 4, arguments[0] == "--helper-inspect",
                   let registry = UInt64(arguments[2]), let bytes = UInt64(arguments[3]) {
                    let request = try HelperDiskRequest(bsdName: arguments[1], registryID: registry, byteCount: bytes)
                    let report = try await HelperRPC.inspectSystemDisk(request)
                    FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
                } else if arguments.count == 2, arguments[0] == "--helper-clear-check-marker" {
                    // Same request as "Check on This Mac"; the partition must be unmounted.
                    let items = try await HelperCheckMarkerClient.clear(partition: arguments[1])
                    FileHandle.standardOutput.write(Data("{\"checkedItems\":\(items)}\n".utf8))
                } else if arguments.count == 2, arguments[0] == "--helper-windows-log-examine" {
                    // Read-only; the partition must be unmounted first.
                    let found = try await HelperWindowsLogClient.examine(partition: arguments[1])
                    FileHandle.standardOutput.write(try JSONEncoder().encode(found) + Data("\n".utf8))
                } else if arguments.count == 2, arguments[0] == "--helper-bitlocker-probe" {
                    let found = try await HelperBitLockerClient.isBitLocker(partition: arguments[1])
                    FileHandle.standardOutput.write(Data("{\"bitLocker\":\(found)}\n".utf8))
                } else if [3, 4].contains(arguments.count), arguments[0] == "--helper-bitlocker-unlock", ["password", "recovery"].contains(arguments[2]),
                          arguments.count == 3 || arguments[3] == "rw" {
                    // The secret is one line on standard input, never an argument.
                    guard let line = readLine(strippingNewline: true), !line.isEmpty else { throw HelperServiceError.invalidRequest }
                    let recovery = arguments[2] == "recovery"
                    guard let secret = recovery ? BitLockerSecretKind.normalizedRecoveryKey(line) : line else { throw BitLockerError.invalidRecoveryKey }
                    let result = try await HelperBitLockerClient.unlock(partition: arguments[1], kind: recovery ? .recoveryKey : .password,
                                                                        secret: secret, writable: arguments.count == 4)
                    let reply: [String: Any] = ["mountPath": result.url.path, "writable": result.writable,
                                                "readOnlyReason": result.readOnlyReason?.rawValue ?? NSNull()]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: reply) + Data("\n".utf8))
                } else if arguments.count == 3, arguments[0] == "--helper-format" {
                    // Same checks as the erase sheet's last step; the helper re-verifies the device.
                    try await HelperFormatClient.format(partition: arguments[1], label: arguments[2])
                    FileHandle.standardOutput.write(Data("{\"formatted\":true}\n".utf8))
                } else if arguments.count == 1, ["--helper-status", "--helper-register", "--helper-unregister"].contains(arguments[0]) {
                    let controller = HelperServiceController()
                    switch arguments[0] {
                    case "--helper-register": await controller.register()
                    case "--helper-unregister": await controller.unregister()
                    default: await controller.refresh()
                    }
                    let report: [String: Any] = ["state": String(describing: controller.state),
                        "packageVerified": controller.packageVerified,
                        "message": controller.summary, "error": controller.lastError ?? "",
                        "writeAccessAvailable": controller.state == .connected && DailyWriteAvailability.enabled]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data("\n".utf8))
                    if controller.state == .failed || controller.state == .unavailable { exit(1) }
                } else { throw HelperServiceError.invalidRequest }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
            }
        }
        dispatchMain()
    }
}
