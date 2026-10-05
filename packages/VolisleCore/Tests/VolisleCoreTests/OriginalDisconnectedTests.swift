import Foundation
import IOKit
import Testing
@testable import VolisleCore

/// Uses the real IORegistry of the test machine; no device is touched.
@Suite struct OriginalDisconnectedTests {
    private func operation(registryID: UInt64) throws -> HelperMountOperation {
        HelperMountOperation(id: UUID(), disk: try HelperDiskRequest(bsdName: "disk999s1", registryID: registryID, byteCount: 4096),
                             ownerUID: 501, bootSession: "same-boot", phase: .needsRecovery, restoreRequired: true,
                             report: nil, failure: nil, purpose: .readWrite)
    }

    @Test func vanishedMediaIsReportedDisconnected() async throws {
        // An unplugged disk's registry ID no longer exists in the same boot.
        let gone = try operation(registryID: 0x7fff_ffff_fff0)
        #expect(try await SystemHelperWriteMountBackend().originalDisconnected(gone, currentBoot: "same-boot"))
    }

    @Test func presentMediaIsNotReportedDisconnected() async throws {
        var iterator: io_iterator_t = 0
        #expect(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS)
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        try #require(entry != 0)
        defer { IOObjectRelease(entry) }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        #expect(try await !SystemHelperWriteMountBackend().originalDisconnected(operation(registryID: id), currentBoot: "same-boot"))
    }
}
