import Foundation
import CryptoKit
import DiskArbitration
import IOKit

/// Stored preferences exclude transient device names, USB ports and raw serials.
public struct PersistentVolumeKey: Hashable, Codable, Sendable {
    public let volumeUUID: String
    public let media: String
}

enum MediaFingerprint {
    static func usb(serial: String, vendor: UInt64, product: UInt64,
                    offset: UInt64, size: UInt64) -> String? {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard serial.count >= 4, serial.count <= 256,
              !["unknown", "none", "null", "default", "123456789", "1234567890"].contains(serial.lowercased()),
              Set(serial).count > 1, serial.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              vendor > 0, vendor <= 65535, product > 0, product <= 65535,
              size >= 512, offset % 512 == 0, size % 512 == 0,
              offset <= UInt64.max - size else { return nil }
        let fields = ["volisle-usb-partition-v1", serial, String(vendor), String(product), String(offset), String(size)]
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return "usb-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only IOKit metadata is read; no raw device or file content is opened.
enum MediaIdentityReader {
    static func read(_ disk: DADisk) -> (registryID: UInt64?, fingerprint: String?) {
        var entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { return (nil, nil) }
        var registryID: UInt64 = 0
        let idOK = IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS && registryID != 0
        let geometry = properties(entry)
        let offset = unsigned(geometry?["Base"]), size = unsigned(geometry?["Size"])
        var fingerprint: String?
        for _ in 0..<16 {
            let values = properties(entry)
            if let offset, let size, let values,
               let serial = (values["kUSBSerialNumberString"] ?? values["USB Serial Number"]) as? String,
               let vendor = unsigned(values["idVendor"]), let product = unsigned(values["idProduct"]) {
                fingerprint = MediaFingerprint.usb(serial: serial, vendor: vendor, product: product, offset: offset, size: size)
                // Do not fall back to an upstream hub's serial when the device's
                // own serial is invalid or missing from a matching USB node.
                break
            }
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0 { break }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = result == KERN_SUCCESS ? parent : 0
            if entry == 0 { break }
        }
        if entry != 0 { IOObjectRelease(entry) }
        return (idOK ? registryID : nil, fingerprint)
    }
    private static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var result: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &result, nil, 0) == KERN_SUCCESS else { return nil }
        return result?.takeRetainedValue() as? [String: Any]
    }
    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.uint64Value
    }
}
