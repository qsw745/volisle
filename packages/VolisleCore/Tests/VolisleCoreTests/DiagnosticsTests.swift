import Testing
import Foundation
@testable import VolisleCore

@Test func populatedDiagnosticsExcludeSensitiveFieldsAndUntrustedStrings() throws {
    let secret = "PRIVATE-CANARY-不会导出"
    let snapshot = VolumeSnapshot(identity: .init(volumeUUID: secret, mediaUUID: secret, devicePath: secret,
                                                mediaRegistryID: 987654321, mediaFingerprint: secret),
        bsdName: secret, name: secret, fileSystem: secret, deviceName: secret,
        totalBytes: 123456789, availableBytes: 23456789, mountURL: URL(fileURLWithPath: "/Volumes/\(secret)"),
        mountState: .readWrite, isExternal: true, isProtected: false, safety: .risk(secret))
    let report = DiagnosticReport(volumes: [snapshot], diskServiceRunning: true,
                                  engine: .init(available: false, finderReadWrite: true, reason: secret))
    let data = try report.jsonData()
    let json = try #require(String(data: data, encoding: .utf8))
    for output in [report.text, json] {
        #expect(!output.contains(secret))
        #expect(!output.contains("/Volumes/"))
        #expect(!output.contains(snapshot.identity.connection.uuidString))
        #expect(!output.contains("123456789"))
        #expect(!output.contains("987654321"))
    }
    let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: data)
    #expect(decoded.fileSystemCounts == ["other": 1])
    #expect(decoded.mountStateCounts == ["readWrite": 1])
    #expect(!decoded.engineSupportsFinderReadWrite)
    #expect(decoded.safetyCheck == "not_performed")
}

@MainActor @Test func engineStatusUsesOwnAdapterAndStartsUnchecked() async {
    let status = EngineStatus(engine: UnavailableEngine())
    #expect(status.checkedAt == nil)
    #expect(!status.capability.available)
    await status.refresh()
    #expect(status.checkedAt != nil)
    #expect(!status.capability.finderReadWrite)
    #expect(status.title == "不可用")
}

@Test("诊断报告写入应用真实版本号，而不是固定的开发版本")
func diagnosticsReportsBundleVersion() {
    #expect(DiagnosticReport.bundleVersion(["CFBundleShortVersionString": "0.3.3", "CFBundleVersion": "19"]) == "0.3.3 (19)")
    #expect(DiagnosticReport.bundleVersion(["CFBundleShortVersionString": "0.4.0"]) == "0.4.0")
    #expect(DiagnosticReport.bundleVersion(nil) == "unknown")
}
