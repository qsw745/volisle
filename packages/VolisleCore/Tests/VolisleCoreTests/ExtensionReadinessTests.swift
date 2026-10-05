import Foundation
import Testing
@testable import VolisleCore

struct ExtensionReadinessTests {
    let expected = URL(filePath: "/fixture/Volisle.app/Contents/Extensions/VolisleFS.appex")
    @Test func installedEnabledOwnExtensionIsReadOnly() {
        let result = ExtensionReadiness.evaluate(expected: expected, modules: [.init(url: expected, enabled: true)])
        #expect(result.available && !result.finderReadWrite)
        #expect(!result.reason.isEmpty)
    }
    @Test func absentDisabledDuplicateOrOtherCopyIsNotReady() {
        let other = URL(filePath: "/other/VolisleFS.appex")
        for modules: [ExtensionReadiness.Module] in [[], [.init(url: expected, enabled: false)],
            [.init(url: other, enabled: true)], [.init(url: expected, enabled: true), .init(url: other, enabled: true)]] {
            let result = ExtensionReadiness.evaluate(expected: expected, modules: modules)
            #expect(!result.available && !result.finderReadWrite)
        }
    }
    @Test func translocatedCopyAsksToMoveIntoApplications() {
        let expected = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Volisle.app/Contents/Extensions/VolisleFS.appex")
        let result = ExtensionReadiness.evaluate(expected: expected, modules: [.init(url: expected, enabled: true)])
        #expect(!result.available && result.reason.contains("应用程序"))
    }
    @Test func appOnAWritableExternalVolumeIsNotMistakenForTheDiskImage() {
        let expected = URL(fileURLWithPath: "/Volumes/Data/Applications/Volisle.app/Contents/Extensions/VolisleFS.appex")
        let result = ExtensionReadiness.evaluate(expected: expected, modules: [.init(url: expected, enabled: true)])
        #expect(result.available)
    }
}
