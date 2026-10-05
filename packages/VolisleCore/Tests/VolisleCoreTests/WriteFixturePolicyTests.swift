import Foundation
import Testing
@testable import VolisleCore

struct WriteFixturePolicyTests {
    @Test func imageEnvelopeDoesNotRelaxPhysicalPartitionEnvelope() throws {
        let image = try HelperDiskRequest(version: 2, bsdName: "disk99", registryID: 10, byteCount: 67108864)
        #expect(try HelperDiskRequest.decode(JSONEncoder().encode(image)) == image)
        #expect(throws: (any Error).self) { _ = try HelperDiskRequest(bsdName: "disk99", registryID: 10, byteCount: 67108864) }
        #expect(throws: (any Error).self) { _ = try HelperDiskRequest(version: 2, bsdName: "disk99s1", registryID: 10, byteCount: 67108864) }
        #expect(throws: (any Error).self) { _ = try HelperDiskRequest(version: 2, bsdName: "disk99", registryID: 10, byteCount: 2000396321280) }
    }
    private let fixture = """
    {"schema":1,"imagePath":"/private/tmp/fixture.img","ownerUID":501,"byteCount":67108864,"bootSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","imageSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    """
    @Test func compiledScopeRejectsOtherOwnerAndUnboundedImages() throws {
        let policy = try WriteFixturePolicy.decode(Data(fixture.utf8))
        #expect(policy.allows(owner: 501, bytes: 67108864))
        #expect(!policy.allows(owner: 502, bytes: 67108864))
        #expect(!policy.allows(owner: 501, bytes: 2000396321280))
        for bad in [fixture.replacingOccurrences(of: "67108864", with: "2000396321280"),
                    fixture.replacingOccurrences(of: "/private/tmp/fixture.img", with: "/dev/disk7s1"),
                    fixture.replacingOccurrences(of: "/private/tmp/fixture.img", with: "/private/tmp/../fixture.img"),
                    fixture.replacingOccurrences(of: "\"ownerUID\":501", with: "\"ownerUID\":0")] {
            #expect(throws: (any Error).self) { _ = try WriteFixturePolicy.decode(Data(bad.utf8)) }
        }
    }
}
