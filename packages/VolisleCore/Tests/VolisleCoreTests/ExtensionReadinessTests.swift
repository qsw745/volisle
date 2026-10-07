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
    /// Seen on macOS 15.6.1 (and 27.2 for the first line).
    @Test func pluginKitRegistrationsAreReadWithOrWithoutElectionMark() {
        let id = "top.qisw.volisle.filesystem"
        let output = """
        +    top.qisw.volisle.filesystem(0.8.2)\tF575F5B3-8E34-42E7-8A3A-CC8D3FB9BD4E\t2026-10-07 05:09:56 +0000\t/Applications/Volisle.app/Contents/Extensions/VolisleFS.appex
             top.qisw.volisle.filesystem((null))\t42C9A654-40CC-47ED-9AA0-B27EF0D2BC93\t2026-10-07 06:42:34 +0000\t~/Downloads/Volisle.app/Contents/Extensions/VolisleFS.appex
             com.apple.fskit.msdos((null))\tD42CAE74-FD98-5047-9939-1282985CD6C5\t2026-10-07 06:29:55 +0000\t/System/Library/ExtensionKit/Extensions/com.apple.fskit.msdos.appex
         (3 plug-ins)
        """
        #expect(ExtensionReadiness.registeredPaths(pluginKit: output, identifier: id).map(\.path) == [
            "/Applications/Volisle.app/Contents/Extensions/VolisleFS.appex",
            "~/Downloads/Volisle.app/Contents/Extensions/VolisleFS.appex"])
        #expect(ExtensionReadiness.registeredPaths(pluginKit: "", identifier: id).isEmpty)
        #expect(ExtensionReadiness.registeredPaths(pluginKit: output, identifier: "top.qisw.volisle").isEmpty)
    }
    /// mount(8) on macOS 15.6.1 for a device that does not exist.
    @Test func mountProbeTellsOnOffAndUnknown() {
        let id = "top.qisw.volisle.filesystem"
        let on = "mount: Probing resource: The operation couldn’t be completed. No such file or directory\nmount: Unable to invoke task\n"
        let off = "Module top.qisw.volisle.filesystem is disabled!\nmount: Unable to invoke task\n"
        let unknown = "mount: Unable to invoke task\n"
        #expect(ExtensionReadiness.enabled(mountProbe: on, identifier: id) == true)
        #expect(ExtensionReadiness.enabled(mountProbe: off, identifier: id) == false)
        #expect(ExtensionReadiness.enabled(mountProbe: unknown, identifier: id) == nil)
        #expect(ExtensionReadiness.enabled(mountProbe: "Module com.other.fs is disabled!\n", identifier: id) == nil)
    }
    @Test func appOnAWritableExternalVolumeIsNotMistakenForTheDiskImage() {
        let expected = URL(fileURLWithPath: "/Volumes/Data/Applications/Volisle.app/Contents/Extensions/VolisleFS.appex")
        let result = ExtensionReadiness.evaluate(expected: expected, modules: [.init(url: expected, enabled: true)])
        #expect(result.available)
    }
}
