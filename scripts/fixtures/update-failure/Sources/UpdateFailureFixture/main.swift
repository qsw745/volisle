import AppKit
import Sparkle

@MainActor func record(_ event: String) {
    let url = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureLog") as! String)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data((event + "\n").utf8))
    try! handle.close()
}

@MainActor final class Driver: NSObject, SPUUserDriver {
    var rejected = false
    func fail(_ error: Error) {
        let value = error as NSError
        record("rejected:\(value.domain):\(value.code)")
        rejected = true
        NSApplication.shared.terminate(nil)
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(.init(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("found:" + appcastItem.versionString); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { fail(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); fail(error) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); fail(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("UNEXPECTED:ready-to-install"); reply(.dismiss)
        NSApplication.shared.terminate(nil)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { record("UNEXPECTED:installing") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { record("UNEXPECTED:installed"); acknowledgement() }
    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let driver = Driver()
    var updater: SPUUpdater?
    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launched:" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String))
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do { try updater!.start(); updater!.checkForUpdates() } catch { driver.fail(error) }
    }
}
let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
