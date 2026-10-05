import Foundation
import Security
import ServiceManagement
import Testing
@testable import VolisleCore

struct HelperServiceTests {
    @Test func firstInstallationCanRegisterWithoutAnExistingSystemRecord() {
        #expect(HelperRegistrationPolicy.needsRegistration(.notFound))
        #expect(HelperRegistrationPolicy.needsRegistration(.notRegistered))
        #expect(!HelperRegistrationPolicy.needsRegistration(.enabled))
        #expect(!HelperRegistrationPolicy.needsRegistration(.requiresApproval))
    }

    @Test func unknownOrFutureServiceCannotAppearReady() throws {
        let status = HelperStatus(protocolVersion: 1, serviceIdentifier: "top.qisw.volisle.mount-helper",
                                  effectiveUID: 0, writeAccessAvailable: false)
        #expect(try HelperStatus.decode(JSONEncoder().encode(status)) == status)
        try status.validateSystemService()
        for data in [Data(), Data("{}".utf8), Data(repeating: 32, count: 4097),
                     Data(#"{"protocolVersion":2,"serviceIdentifier":"top.qisw.volisle.mount-helper","effectiveUID":0,"writeAccessAvailable":false}"#.utf8),
                     Data(#"{"protocolVersion":1,"serviceIdentifier":"other","effectiveUID":0,"writeAccessAvailable":false}"#.utf8),
                     Data(#"{"protocolVersion":1,"serviceIdentifier":"top.qisw.volisle.mount-helper","effectiveUID":0,"writeAccessAvailable":true}"#.utf8)] {
            #expect(throws: (any Error).self) { _ = try HelperStatus.decode(data) }
        }
    }
    @Test func userProcessCannotMasqueradeAsSystemService() throws {
        let status = HelperStatus(protocolVersion: 1, serviceIdentifier: "top.qisw.volisle.mount-helper",
                                  effectiveUID: 501, writeAccessAvailable: false)
        #expect(throws: HelperServiceError.wrongPrivileges) { try status.validateSystemService() }
    }
    @Test func unidentifiedOrRootClientIsRefused() {
        #expect(HelperIdentity.acceptsClient(uid: 501, auditSession: 100_001))
        #expect(!HelperIdentity.acceptsClient(uid: 0, auditSession: 100_001))
        #expect(!HelperIdentity.acceptsClient(uid: .max, auditSession: 100_001))
        #expect(!HelperIdentity.acceptsClient(uid: 501, auditSession: 0))
        #expect(!HelperIdentity.acceptsClient(uid: 501, auditSession: .max))
    }
    @Test func signingRequirementsAreValidAndSeparateClientFromHelper() {
        for peer in [HelperIdentity.Peer.application, .service] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(HelperIdentity.requirement(for: peer) as CFString, [], &requirement) == errSecSuccess)
            #expect(requirement != nil)
        }
        #expect(HelperIdentity.requirement(for: .application) != HelperIdentity.requirement(for: .service))
    }
}
