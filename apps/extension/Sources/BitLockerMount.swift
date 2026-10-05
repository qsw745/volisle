// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// BitLocker volumes mount only when the mount carries the volume master key
/// the privileged helper derived from the user's password or recovery key (the
/// extension never sees either); writable only with `volisle-rw` as well.
enum BitLockerMount {
    static let optionPrefix = "volisle-bde="

    static func isBitLocker(_ boot: [UInt8]) -> Bool {
        boot.count >= 512 && Array(boot[3..<11]) == Array("-FVE-FS-".utf8)
    }

    /// The BitLocker volume GUID (header offset 160): stable across mounts.
    static func identifier(_ boot: [UInt8]) -> UUID {
        let b = Array(boot[160..<176])
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Exactly one well-formed key (64 lowercase hex digits), else nil.
    static func key(in options: [String]) -> String? {
        let keys = options.flatMap { $0.split(separator: ",") }
            .filter { $0.hasPrefix(optionPrefix) }
            .map { String($0.dropFirst(optionPrefix.count)) }
        guard keys.count == 1, let key = keys.first, key.utf8.count == 64,
              key.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return key
    }
}
