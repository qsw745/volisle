// Separate developer test runner. This executable is not bundled or registered
// as the product's privileged service.
import Foundation
import VolisleCore

@main struct VolisleHelperProbe {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--check-package", let bundle = Bundle(path: args[2]) {
            do { try HelperPackage.validate(bundle); print("后台组件签名与包结构通过。"); exit(0) }
            catch { FileHandle.standardError.write(Data("安装包拒绝：\(error)\n".utf8)); exit(1) }
        }
        guard args.count >= 3, geteuid() != 0,
              args[2].hasPrefix("top.qisw.volisle.integration."),
              UUID(uuidString: String(args[2].dropFirst("top.qisw.volisle.integration.".count))) != nil else { exit(64) }
        let name = args[2]
        if args[1] == "--serve", args.count == 3 {
            let delegate = HelperListenerDelegate()
            let listener = NSXPCListener(machServiceName: name)
            listener.setConnectionCodeSigningRequirement(HelperIdentity.requirement(for: .application))
            listener.delegate = delegate
            listener.activate()
            withExtendedLifetime((delegate, listener)) { dispatchMain() }
        } else if args[1] == "--inspect", args.count == 7,
                  let registry = UInt64(args[4]), let bytes = UInt64(args[5]) {
            Task {
                do {
                    let request = try HelperDiskRequest(bsdName: args[3], registryID: registry, byteCount: bytes)
                    let report = try await HelperRPC.inspectDisk(request, over: NSXPCConnection(machServiceName: name))
                    guard args[6] == "success", report.effectiveUID == geteuid() else { exit(1) }
                    FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8)); exit(0)
                } catch let failure as HelperDiskFailure {
                    guard failure.rawValue == args[6] else { exit(1) }
                    print("只读检查按预期拒绝：\(failure.rawValue)"); exit(0)
                } catch { FileHandle.standardError.write(Data("检查通信失败：\(error)\n".utf8)); exit(1) }
            }
            dispatchMain()
        } else if args[1] == "--client", args.count == 4, ["accepted", "rejected"].contains(args[3]) {
            Task {
                do {
                    let status = try await HelperRPC.status(over: NSXPCConnection(machServiceName: name))
                    guard args[3] == "accepted", status.effectiveUID == geteuid(), !status.writeAccessAvailable else { exit(1) }
                    do { try status.validateSystemService(); exit(1) }
                    catch HelperServiceError.wrongPrivileges { }
                    print("通信通过；非 root 测试服务不会被视为系统服务。")
                    exit(0)
                } catch {
                    guard args[3] == "rejected" else {
                        FileHandle.standardError.write(Data("通信失败：\(error)\n".utf8)); exit(1)
                    }
                    print("连接按预期被拒绝。")
                    exit(0)
                }
            }
            dispatchMain()
        } else { exit(64) }
    }
}
