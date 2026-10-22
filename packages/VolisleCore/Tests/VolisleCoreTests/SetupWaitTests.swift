import Foundation
import Testing
@testable import VolisleCore

struct SetupWaitTests {
    @Test func waitingEndsEvenIfThePermissionNeverArrives() {
        #expect(SetupWait.status(elapsed: nil, failed: false) == .idle)
        #expect(SetupWait.status(elapsed: 1, failed: false) == .waiting)
        #expect(SetupWait.status(elapsed: 120, failed: false) == .timedOut)
    }
    @Test func connectionFailureDoesNotKeepSpinning() {
        #expect(SetupWait.status(elapsed: 2, failed: true) == .failed)
    }
}
