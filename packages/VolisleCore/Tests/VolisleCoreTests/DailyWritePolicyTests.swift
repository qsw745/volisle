import Foundation
import Testing
@testable import VolisleCore

struct DailyWritePolicyTests {
    @Test func signedModeMustBeExplicitAndVersioned() throws {
        #expect(throws: (any Error).self) { _ = try DailyWritePolicy.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { _ = try DailyWritePolicy.decode(Data(#"{"schema":2,"mode":"external-usb-ntfs"}"#.utf8)) }
        #expect(throws: (any Error).self) { _ = try DailyWritePolicy.decode(Data(#"{"schema":1,"mode":"all-disks"}"#.utf8)) }
        _ = try DailyWritePolicy.decode(Data(#"{"schema":1,"mode":"external-usb-ntfs"}"#.utf8))
    }
}
