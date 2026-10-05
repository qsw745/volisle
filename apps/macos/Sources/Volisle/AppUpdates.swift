import AppKit
import Observation
import Sparkle
import VolisleCore

/// Website distribution only. A missing production feed never starts Sparkle.
@MainActor @Observable final class AppUpdates: NSObject, SPUUpdaterDelegate {
    let maintenance = UpdateMaintenance()
    private(set) var available = false
    private(set) var canCheck = false
    private(set) var message = String(localized: "更新通道尚未开放")
    private(set) var pendingInstall = false
    private(set) var canRetryInstallation = false
    var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    var automaticDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticDownloads }
    }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var delayedInstall: (() -> Void)?
    private let cycle: MountCycleClient
    private let helper: HelperServiceController
    private var started = false
    private var preparing = false
    private static let restoreKey = "volisle.update.restoreHelper"

    init(cycle: MountCycleClient, helper: HelperServiceController) {
        self.cycle = cycle; self.helper = helper
        super.init()
    }
    func start() async {
        guard !started else { return }
        started = true
        // The receipt is also present in App Store sandbox receipts. Never
        // enable the website updater inside an App Store distribution.
        if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            message = String(localized: "此版本由 App Store 提供更新"); return
        }
        do { try await restoreHelperIfNeeded() }
        catch { message = String(localized: "更新后的后台组件需要恢复，请在设置中检查。"); return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              (try? UpdateChannel(feed: feed, publicKey: key)) != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.sendsSystemProfile = false
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        automaticDownloads = controller.updater.automaticallyDownloadsUpdates
        checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let allowed = change.newValue ?? false
            Task { @MainActor in self?.canCheck = allowed }
        }
        do { try controller.updater.start(); available = true; message = String(localized: "后台检查新版本，有更新时提醒") }
        catch { message = String(localized: "更新暂不可用：\(error.localizedDescription)") }
    }
    func check() {
        if let delayedInstall { Task { await prepareAndContinue(delayedInstall) }; return }
        guard available, canCheck else { return }
        message = String(localized: "正在检查更新…")
        controller?.checkForUpdates(nil)
    }
    func prepareForInstallation() async throws {
        try await maintenance.prepare(settle: {
            guard !self.cycle.isBusy, !self.helper.isBusy else { throw UpdateSafetyError.diskBusy }
            await self.helper.refresh()
            guard self.helper.state == .connected || self.helper.state == .notRegistered else { throw UpdateSafetyError.diskBusy }
            await self.cycle.refresh()
            if self.cycle.canRecover { await self.cycle.recover() }
            guard !self.cycle.blocksActions, !self.cycle.isBusy else { throw UpdateSafetyError.diskBusy }
        }, stopService: {
            if self.helper.state == .connected {
                UserDefaults.standard.set(true, forKey: Self.restoreKey)
                await self.helper.unregister()
            }
            guard self.helper.state == .notRegistered else { throw UpdateSafetyError.diskBusy }
        }, verify: {
            try self.helper.verifyStoppedForUpdate()
            try UpdateMaintenance.verifyNoMountedVolumes()
        })
    }
    private func restoreHelperIfNeeded() async throws {
        guard UserDefaults.standard.bool(forKey: Self.restoreKey) else { return }
        await helper.register()
        guard helper.state == .connected else { throw UpdateSafetyError.diskBusy }
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
    }
    func cancelPreparation() async {
        guard maintenance.blocking else { return }
        do { try await maintenance.cancel { try await self.restoreHelperIfNeeded() } }
        catch { message = String(localized: "后台组件尚未恢复，自动读写已暂停。请在设置中检查后重试。") }
    }
    private func prepareAndContinue(_ handler: @escaping () -> Void) async {
        guard !preparing else { return }
        preparing = true
        canRetryInstallation = false
        defer { preparing = false }
        do {
            message = String(localized: "正在安全结束磁盘读写…")
            try await prepareForInstallation()
            delayedInstall = nil
            message = String(localized: "磁盘已就绪，正在安装更新…")
            handler()
        } catch {
            message = error.localizedDescription
            canRetryInstallation = true
            await cancelPreparation()
            let alert = NSAlert()
            alert.messageText = String(localized: "暂时不能安装更新")
            alert.informativeText = String(localized: "请结束磁盘上的文件操作后，通过“检查更新”重试。当前版本会继续保留。") + "\n" + message
            alert.addButton(withTitle: String(localized: "知道了"))
            alert.runModal()
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = String(localized: "发现新版本 \(item.displayVersionString)")
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = true
        delayedInstall = installHandler
        Task { await prepareAndContinue(installHandler) }
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = true
        message = String(localized: "更新已下载，将在安全退出时安装")
        return false
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { pendingInstall = true }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        delayedInstall = nil; canRetryInstallation = false
        let ns = error as NSError
        message = ns.domain == SUSparkleErrorDomain && ns.code == Int(SUError.noUpdateError.rawValue) ? String(localized: "暂未发现可用更新") : String(localized: "更新未完成：\(error.localizedDescription)")
        Task { await cancelPreparation() }
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

/// Sparkle can resume a staged installer or install on ordinary quit. Guard the
/// termination path as well as the normal "Install and Relaunch" callback.
@MainActor final class UpdateAppDelegate: NSObject, NSApplicationDelegate {
    var updates: AppUpdates?
    private var waiting = false
    /// macOS refuses a quit request (logout, shutdown, scripts) while a window
    /// shows a sheet, e.g. the setup guide left open. Close sheets first, then
    /// quit through the normal path, so applicationShouldTerminate still decides.
    /// After launch: AppKit installs its default quit handler while launching.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }
    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        Self.closeSheetsAndTerminate()
    }
    /// Also behind the Quit menu item (⌘Q). SwiftUI sheets are not AppKit's
    /// attached sheets, so ask the views to close the informational ones (the
    /// setup guide, disk details) and terminate once they are gone. Sheets of
    /// running operations such as erasing stay and keep blocking, as before.
    static func closeSheetsAndTerminate() {
        guard NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) else { NSApp.terminate(nil); return }
        NotificationCenter.default.post(name: .volisleCloseSheetsForQuit, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let updates, updates.pendingInstall || updates.maintenance.blocking else { return .terminateNow }
        guard !waiting else { return .terminateLater }
        waiting = true
        Task {
            do {
                try await updates.prepareForInstallation()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                await updates.cancelPreparation()
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = String(localized: "更新已暂缓")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: String(localized: "知道了")); alert.runModal()
            }
            waiting = false
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let volisleCloseSheetsForQuit = Notification.Name("top.qisw.volisle.close-sheets-for-quit")
}
