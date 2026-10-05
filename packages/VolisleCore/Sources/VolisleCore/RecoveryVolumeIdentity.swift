// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit

/// Reconnect identity is a matching constraint, never proof of write authority.
/// Caller must obtain media evidence from a current native claim, authenticate
/// the journal and validate the independently stored restored-view checkpoint.
enum RecoveryVolumeIdentity {
    enum Failure: Error { case unavailable, ambiguous }
    static func make(media: String?, bootSHA256: String, byteCount: Int64, sectorSize: Int) throws -> String {
        guard let media, validMedia(media), RecoveryReadOnlyDevice.validBootHash(bootSHA256),
              byteCount >= 512, sectorSize >= 512, sectorSize <= 65536,
              sectorSize.nonzeroBitCount == 1, byteCount % Int64(sectorSize) == 0 else { throw Failure.unavailable }
        return "recovery-volume/v1:" + digest(["volisle-recovery-volume-v1", media, bootSHA256, String(byteCount), String(sectorSize)])
    }
    static func requireUnique(registryID: UInt64, matching: [UInt64]) throws {
        guard registryID != 0, matching == [registryID] else { throw Failure.ambiguous }
    }
    private static func validMedia(_ value: String) -> Bool {
        var prefixes = ["usb-v1:"]
        #if DEBUG
        prefixes.append("fixture-file-v1:")
        #endif
        return prefixes.contains { value.hasPrefix($0) && RecoveryReadOnlyDevice.validBootHash(String(value.dropFirst($0.count))) }
    }
    private static func digest(_ fields: [String]) -> String {
        // Length-delimited fields avoid separator ambiguity and encoder dependence.
        let bytes = fields.reduce(into: Data()) { result, field in
            let data = Data(field.utf8)
            result.append(Data(String(data.count).utf8)); result.append(0x3a); result.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    #if DEBUG
    static func fixtureMedia(device: Int64, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64) -> String {
        "fixture-file-v1:" + digest([String(device), String(inode), String(birthSeconds), String(birthNanoseconds)])
    }
    #endif
}
