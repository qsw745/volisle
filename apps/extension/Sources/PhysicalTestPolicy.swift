// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Explicitly bound, expiring laboratory permission. Never used by ordinary
/// builds. Namespace restrictions apply before activating a writable engine.
struct PhysicalTestPolicy {
    let bsdName: String
    let serial: [UInt8]
    let byteCount: UInt64
    let option: String
    let root: String
    let expiresAt: TimeInterval

    private func valid(at now: TimeInterval) -> Bool {
        now.isFinite && expiresAt.isFinite && now < expiresAt && expiresAt - now <= 7200 &&
        root.range(of: "^/Volisle-Test-[0-9]{8}-[0-9a-f]{32}$", options: .regularExpression) != nil
    }
    func allows(bsdName: String, serial: [UInt8], byteCount: UInt64,
                options: [String], writable: Bool, now: TimeInterval) -> Bool {
        let options = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        return valid(at: now) && writable && !self.bsdName.isEmpty && bsdName == self.bsdName &&
            self.serial.count == 8 && self.serial.contains(where: { $0 != 0 }) && serial == self.serial &&
            byteCount > 512 && byteCount == self.byteCount && !option.isEmpty && options.contains(option) &&
            !options.contains("ro") && !options.contains("rdonly")
    }
    func allowsMutation(path: String, now: TimeInterval) -> Bool {
        guard valid(at: now), path == root || path.hasPrefix(root + "/"),
              !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
