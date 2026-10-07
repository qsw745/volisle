import Testing
@testable import VolisleCore

/// The self-check behind "Can't write to this disk?": the first unmet condition
/// is a problem with a way out, and the outcome says what happened last time.
struct DiskReadinessTests {
    private func inputs(_ change: (inout DiskReadiness.Inputs) -> Void = { _ in }) -> DiskReadiness.Inputs {
        var value = DiskReadiness.Inputs(helper: .connected, fullDiskAccess: true, extensionAvailable: true,
                                         extensionReason: "未启用", isNTFS: true, writable: false)
        change(&value)
        return value
    }
    private func item(_ id: String, _ inputs: DiskReadiness.Inputs) -> DiskReadiness.Item? {
        DiskReadiness.items(inputs).first { $0.id == id }
    }

    @Test func aReadyDiskOffersToTurnOnWriting() {
        let items = DiskReadiness.items(inputs())
        #expect(items.map(\.id) == ["helper", "access", "extension", "disk", "result"])
        #expect(items.dropLast().allSatisfy { $0.status == .ok })
        #expect(items.last?.status == .note && items.last?.action == .enableWriting)
        #expect(item("result", inputs { $0.writable = true })?.status == .ok)
    }

    @Test func eachMissingPieceSaysHowToFixIt() {
        #expect(item("helper", inputs { $0.helper = .requiresApproval })?.action == .approveHelper)
        #expect(item("helper", inputs { $0.helper = .notRegistered })?.action == .setUpHelper)
        #expect(item("helper", inputs { $0.helper = .failed; $0.helperError = "超时" })?.detail == "超时")
        #expect(item("access", inputs { $0.fullDiskAccess = false })?.action == .fullDiskAccess)
        #expect(item("access", inputs { $0.fullDiskAccess = nil })?.status == .note)
        let disabled = item("extension", inputs { $0.extensionAvailable = false })
        #expect(disabled?.status == .problem && disabled?.action == .fileSystemExtensions && disabled?.detail.hasPrefix("未启用") == true)
        #expect(item("disk", inputs { $0.designRefusal = "写保护" })?.detail == "写保护")
        // With something to fix above, writing is not offered yet.
        #expect(item("result", inputs { $0.fullDiskAccess = false })?.action == nil)
    }

    @Test func anotherDiskHoldingTheSlotIsNamed() {
        let slot = item("slot", inputs { $0.writeHolder = "旅行照片" })
        #expect(slot?.status == .problem && slot?.detail.contains("旅行照片") == true)
        #expect(item("slot", inputs()) == nil)
    }

    @Test func theLastRefusalLeadsToItsOwnRemedy() {
        let cases: [(HelperDiskFailure, DiskReadiness.Action?)] = [
            (.ntfsDirty, .checkOnMac), (.interruptedWriteUnverified, .exportDiagnostics), (.interruptedWriteRetry, .retry),
            (.interruptedWriteUnsupportedFormat, .exportDiagnostics),
            (.mountFailed, .retry), (.writeNotEnabled, .retry), (.windowsHibernated, nil), (.permissionDenied, .fullDiskAccess),
        ]
        for (failure, action) in cases {
            let result = item("result", inputs { $0.lastFailure = failure })
            #expect(result?.status == .problem && result?.action == action, "\(failure)")
            #expect(result?.detail.contains(failure.errorDescription ?? "-") == true)
        }
    }
}
