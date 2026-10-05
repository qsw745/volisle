import Foundation
import Testing
import Darwin
@testable import VolisleCore

struct HelperDiskTests {
    @Test func busyDeviceIsNotReportedAsDisconnectedOrPermissionDenied() {
        #expect(HelperDiskFailure.from(POSIXError(.EBUSY)) == .busy)
        #expect(HelperDiskFailure.from(POSIXError(.EACCES)) == .permissionDenied)
        #expect(HelperDiskFailure.from(POSIXError(.EPERM)) == .permissionDenied)
        #expect(HelperDiskFailure.from(POSIXError(.EIO)) == .unavailable)
    }
    private let good = Data(#"{"version":1,"bsdName":"disk7s1","registryID":12345,"byteCount":2000396321280}"#.utf8)
    @Test func onlyBoundPartitionRequestsReachDeviceAccess() throws {
        let request = try HelperDiskRequest.decode(good)
        #expect(request.bsdName == "disk7s1")
        for data in [Data(), Data(repeating: 32, count: 4097),
                     Data(#"{"version":2,"bsdName":"disk7s1","registryID":12345,"byteCount":2000396321280}"#.utf8),
                     Data(#"{"version":1,"bsdName":"disk7","registryID":12345,"byteCount":2000396321280}"#.utf8),
                     Data(#"{"version":1,"bsdName":"../disk7s1","registryID":12345,"byteCount":2000396321280}"#.utf8),
                     Data(#"{"version":1,"bsdName":"disk7s1","registryID":0,"byteCount":2000396321280}"#.utf8),
                     Data(#"{"version":1,"bsdName":"disk7s1","registryID":12345,"byteCount":513}"#.utf8)] {
            #expect(throws: (any Error).self) { _ = try HelperDiskRequest.decode(data) }
        }
    }
    @Test func externalUSBPartitionPolicyRejectsInternalVirtualWholeAndUnknownMedia() {
        #expect(HelperDiskPolicy.allows(internalDevice: false, deviceProtocol: "USB", whole: false))
        #expect(!HelperDiskPolicy.allows(internalDevice: true, deviceProtocol: "USB", whole: false))
        #expect(!HelperDiskPolicy.allows(internalDevice: nil, deviceProtocol: "USB", whole: false))
        #expect(!HelperDiskPolicy.allows(internalDevice: false, deviceProtocol: "Virtual Interface", whole: false))
        #expect(!HelperDiskPolicy.allows(internalDevice: false, deviceProtocol: "USB", whole: true))
        #expect(!HelperDiskPolicy.allows(internalDevice: false, deviceProtocol: "USB", whole: nil))
    }
    @Test func replyCannotSubstituteDiskOrClaimWriteSafety() throws {
        let request = try HelperDiskRequest.decode(good)
        let report = HelperDiskReport(version: 1, bsdName: "disk7s1", registryID: 12345,
            byteCount: 2000396321280, bootSHA256: String(repeating: "a", count: 64),
            effectiveUID: 0, writeAccessAvailable: false, fileSystemHealthChecked: false)
        #expect(try HelperDiskReport.decode(JSONEncoder().encode(report), matching: request) == report)
        let other = try HelperDiskRequest(version: 1, bsdName: "disk8s1", registryID: 12345, byteCount: 2000396321280)
        #expect(throws: (any Error).self) { _ = try HelperDiskReport.decode(JSONEncoder().encode(report), matching: other) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for field in ["writeAccessAvailable", "fileSystemHealthChecked"] {
            var invalid = json; invalid[field] = true
            #expect(throws: (any Error).self) { _ = try HelperDiskReport.decode(JSONSerialization.data(withJSONObject: invalid), matching: request) }
        }
        json["bootSHA256"] = "bad"
        #expect(throws: (any Error).self) { _ = try HelperDiskReport.decode(JSONSerialization.data(withJSONObject: json), matching: request) }
    }
    @Test func malformedBootNeverProducesAnIdentity() throws {
        var boot = Data(repeating: 0, count: 512)
        #expect(throws: (any Error).self) { _ = try HelperDiskPolicy.bootHash(boot) }
        boot.replaceSubrange(3..<11, with: "NTFS    ".utf8)
        #expect(throws: (any Error).self) { _ = try HelperDiskPolicy.bootHash(boot) }
        boot[510] = 0x55; boot[511] = 0xaa
        #expect(try HelperDiskPolicy.bootHash(boot).count == 64)
        #expect(throws: (any Error).self) { _ = try HelperDiskPolicy.bootHash(boot.dropLast()) }
    }
}
