import Darwin
import Foundation
import Testing
@testable import VolisleCore

struct RecoveryReadOnlyDeviceTests {
    @Test(arguments: [UInt32(0), 1, 511, 513, 131072])
    func invalidSectorSizesAreRefused(_ block: UInt32) {
        #expect(throws: (any Error).self) { try RecoveryDiskGeometry(blockSize: block, blockCount: 10) }
    }
    @Test(arguments: [UInt64(0), UInt64.max, UInt64(Int64.max) / 512 + 1])
    func invalidOrOverflowingCapacityIsRefused(_ count: UInt64) {
        #expect(throws: (any Error).self) { try RecoveryDiskGeometry(blockSize: 512, blockCount: count) }
    }
    @Test func geometryAndAlignedReadBoundaries() throws {
        let geometry = try RecoveryDiskGeometry(blockSize: 4096, blockCount: 1024)
        #expect(geometry.byteCount == 4_194_304 && geometry.blockSize == 4096)
        try geometry.validateRead(offset: 0, count: 1_048_576)
        try geometry.validateRead(offset: 4_190_208, count: 4096)
        try geometry.validateRead(offset: 4_194_304, count: 0)
        for (offset, count) in [(Int64(-1), 4096), (1, 4096), (0, 512), (0, -1),
                                (0, 1_052_672), (4_194_304, 4096), (Int64.max, 4096)] {
            #expect(throws: (any Error).self) { try geometry.validateRead(offset: offset, count: count) }
        }
    }
    @Test func nonDeviceDescriptorsCannotSupplyDiskGeometry() throws {
        #expect(throws: (any Error).self) { try RecoveryDiskGeometry.read(descriptor: -1) }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { if fd >= 0 { Darwin.close(fd) } }
        try #require(fd >= 0)
        #expect(throws: (any Error).self) { try RecoveryDiskGeometry.read(descriptor: fd) }
    }
    @Test @MainActor func invalidBootDigestCannotOpenPhysicalDevice() async {
        await #expect(throws: (any Error).self) {
            try await NativeRecoveryDiskClaim.withPhysicalReadOnlyDevice(bsdName: "disk0s1", registryID: 1,
                byteCount: 8192, bootSession: UUID().uuidString, bootSHA256: "bad") { _ in
                Issue.record("Invalid digest reached a physical device")
            }
        }
    }
}
