// Read-only FSKit discovery. Does not enable extensions or mount resources.
import Foundation
import FSKit

let identifier = "top.qisw.volisle.filesystem"
DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write(Data("FSKit 状态查询超时\n".utf8))
    exit(124)
}
FSClient.shared.fetchInstalledExtensions { modules, error in
    if let error {
        let error = error as NSError
        let data = try! JSONSerialization.data(withJSONObject: [
            "success": false, "domain": error.domain, "code": error.code
        ], options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(1)
    }
    let matches = (modules ?? []).filter { $0.bundleIdentifier == identifier }
    let data = try! JSONSerialization.data(withJSONObject: [
        "success": true,
        "bundle_id": identifier,
        "modules": matches.map { ["path": $0.url.path, "enabled": $0.isEnabled] as [String: Any] }
    ], options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(0)
}
dispatchMain()
