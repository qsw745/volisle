import Foundation
import Testing
@testable import VolisleCore

struct RecoveryVolumeIdentityTests {
    private let media = "usb-v1:" + String(repeating: "a", count: 64)
    private let boot = String(repeating: "b", count: 64)
    @Test func stableKeyIsIndependentOfConnectionIdentifiers() throws {
        let first = try RecoveryVolumeIdentity.make(media: media, bootSHA256: boot, byteCount: 67108864, sectorSize: 512)
        let second = try RecoveryVolumeIdentity.make(media: media, bootSHA256: boot, byteCount: 67108864, sectorSize: 512)
        #expect(first == second && first.hasPrefix("recovery-volume/v1:"))
        #expect(!first.contains(media) && !first.contains(boot))
    }
    @Test func anyIdentityComponentChangeProducesDifferentKey() throws {
        let original = try RecoveryVolumeIdentity.make(media: media, bootSHA256: boot, byteCount: 67108864, sectorSize: 512)
        for candidate in [
            try RecoveryVolumeIdentity.make(media: "usb-v1:" + String(repeating:"c",count:64), bootSHA256: boot, byteCount: 67108864, sectorSize: 512),
            try RecoveryVolumeIdentity.make(media: media, bootSHA256: String(repeating:"c",count:64), byteCount: 67108864, sectorSize: 512),
            try RecoveryVolumeIdentity.make(media: media, bootSHA256: boot, byteCount: 33554432, sectorSize: 512),
            try RecoveryVolumeIdentity.make(media: media, bootSHA256: boot, byteCount: 67108864, sectorSize: 4096)
        ] { #expect(candidate != original) }
    }
    @Test func missingMalformedOrTransientMediaRejected() {
        for candidate: String? in [nil, "", "disk9", "native-connection/v1|boot|123", "usb-v1:abc", "usb-v1:" + String(repeating:"A",count:64)] {
            #expect(throws:(any Error).self) {
                _ = try RecoveryVolumeIdentity.make(media: candidate, bootSHA256: boot, byteCount: 67108864, sectorSize: 512)
            }
        }
    }
    @Test func malformedGeometryOrBootRejected() {
        for (hash,bytes,sector) in [("invalid",Int64(67108864),512), (boot,513,512), (boot,67108864,0), (boot,67108864,768), (boot,0,512)] {
            #expect(throws:(any Error).self) { _ = try RecoveryVolumeIdentity.make(media: media, bootSHA256: hash, byteCount: bytes, sectorSize: sector) }
        }
    }
    @Test func ambiguousOrMissingPhysicalMediaRejected() throws {
        try RecoveryVolumeIdentity.requireUnique(registryID: 12, matching: [12])
        for ids: [UInt64] in [[], [13], [12,13], [12,12]] {
            #expect(throws:(any Error).self) { try RecoveryVolumeIdentity.requireUnique(registryID: 12, matching: ids) }
        }
    }
}
