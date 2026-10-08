import Foundation
import Testing
@testable import VolisleCore

/// The extension's journal report (NTFSVolume.durabilityReport) as the app reads it.
struct WriteDurabilityTests {
    @Test func reportParsesAndCoversOnlyItsOwnSession() throws {
        let session = UUID()
        let mark = try #require(WriteDurability(text: "v1 \(session.uuidString) 7 4"))
        #expect(mark.writtenBelow == 7 && mark.durableBelow == 4 && !mark.covers(mark))
        #expect(try #require(WriteDurability(text: "v1 \(session.uuidString) 9 7")).covers(mark))
        #expect(try #require(WriteDurability(text: "v1 \(UUID().uuidString) 9 9")).covers(mark) == false)
        for text in ["", "stopped", "v2 \(session.uuidString) 7 4", "v1 \(session.uuidString) 7", "v1 x 7 4", "v1 \(session.uuidString) -1 4"] {
            #expect(WriteDurability(text: text) == nil, "\(text)")
        }
    }
    @Test func aFolderWithoutTheReportReadsNil() throws {
        // Any volume without a Volisle write session (here the test's own temporary folder).
        #expect(WriteDurability.read(root: FileManager.default.temporaryDirectory, flush: true) == nil)
    }
}
