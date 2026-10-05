import Foundation
import CoreFoundation
import Testing
@testable import VolisleCore

struct NativeMountPrerequisitesTests {
    @Test func onlyBooleanTrueCountsAsEntitlement() {
        #expect(NativeMountPrerequisites.entitlementState(value: kCFBooleanTrue) == .present)
        #expect(NativeMountPrerequisites.entitlementState(value: kCFBooleanFalse) == .absent)
        for value: Any? in [nil, NSNumber(value: 1), "true", ["true"], NSNull()] {
            #expect(NativeMountPrerequisites.entitlementState(value: value) == .absent)
        }
    }
    @Test func osAndUnknownSigningStatesFailClosed() {
        #expect(NativeMountPrerequisites(osMajor: 26, entitlement: .present).blocker == .unsupportedSystem)
        #expect(NativeMountPrerequisites(osMajor: 27, entitlement: .unknown).blocker == .signatureUnreadable)
        #expect(NativeMountPrerequisites(osMajor: 27, entitlement: .absent).blocker == .missingEntitlement)
    }
    @Test func entitlementDoesNotProveResourceAccessOrWriting() {
        let support = NativeMountPrerequisites(osMajor: 27, entitlement: .present)
        #expect(support.nativeAPIAvailable)
        #expect(support.blocker == .blockResourceUnavailable)
        #expect(!support.blockResourceCreationAvailable)
    }
    @Test func diagnosticsKeepSigningStatusWithoutExportingSigningDetails() throws {
        let report = DiagnosticReport(volumes: [], diskServiceRunning: false,
            engine: .init(available: true, finderReadWrite: false, reason: "fixture"),
            nativeMount: .init(osMajor: 27, entitlement: .absent))
        #expect(report.schemaVersion == 3)
        #expect(report.nativeMount?.blocker == .missingEntitlement)
        #expect(!report.engineSupportsFinderReadWrite)
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: report.jsonData())
        #expect(decoded.nativeMount == report.nativeMount)
    }
    @Test func oldDiagnosticReportsRemainReadable() throws {
        let report = DiagnosticReport(volumes: [], diskServiceRunning: false,
            engine: .init(available: false, finderReadWrite: false, reason: "fixture"))
        var object = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        object.removeValue(forKey: "nativeMount"); object["schemaVersion"] = 1
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.nativeMount == nil)
    }
}
