import Foundation
import ServiceManagement
import Testing
@testable import VolisleCore

@MainActor struct HelperRegistrationRaceTests {
    @Test func registrationWaitsForInFlightStatusCheckInsteadOfBeingLost() async {
        var status = SMAppService.Status.enabled
        var pending: CheckedContinuation<HelperStatus, Never>?
        var shouldSuspend = true
        let reply = HelperStatus(protocolVersion: 1, serviceIdentifier: HelperIdentity.service,
                                 effectiveUID: 0, writeAccessAvailable: false, fullDiskAccess: true)
        let controller = HelperServiceController(environment: .init(
            validate: {}, status: { status }, register: { status = .enabled }, systemStatus: {
                if shouldSuspend {
                    shouldSuspend = false
                    return await withCheckedContinuation { pending = $0 }
                }
                return reply
            }))
        let checking = Task { await controller.refresh() }
        while pending == nil { await Task.yield() }
        status = .notRegistered // replacement removed the old service record
        var registrationReturned = false
        let restoring = Task { await controller.register(); registrationReturned = true }
        for _ in 0..<20 { await Task.yield() }
        #expect(!registrationReturned)
        pending?.resume(returning: reply)
        await checking.value
        await restoring.value
        #expect(status == .enabled)
        #expect(controller.state == .connected)
        #expect(controller.fullDiskAccess == true)
    }
    @Test func approvalIsReportedWithoutRegisteringAgain() async {
        var registrations = 0
        let controller = HelperServiceController(environment: .init(
            validate: {}, status: { .requiresApproval }, register: { registrations += 1 },
            systemStatus: { throw HelperServiceError.wrongPrivileges }))
        await controller.register()
        #expect(controller.state == .requiresApproval)
        #expect(registrations == 0)
        #expect(!controller.isBusy)
    }

    @Test func rejectedPackageCannotRegister() async {
        var registrations = 0
        let controller = HelperServiceController(environment: .init(
            validate: { throw HelperServiceError.untrustedPackage }, status: { .notRegistered },
            register: { registrations += 1 }, systemStatus: { throw HelperServiceError.wrongPrivileges }))
        await controller.register()
        #expect(!controller.packageVerified)
        #expect(controller.state != .connected)
        #expect(registrations == 0)
    }

}
