// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Observation

/// Everything the app keeps for the life of the process, wired together once.
/// One instance: Disk Arbitration and the power notifications hold parts of it unretained.
@MainActor final class StoreModel {
    static let shared = StoreModel()

    let disks = StoreDisks()
    let purchase = StorePurchase()
    let settings = StoreProSettings()
    let power: StorePower
    /// Launched at login into the menu bar: the main window SwiftUI opens at launch goes away.
    var suppressesMainWindow = false
    private var started = false
    private var menuBarWasShown = false

    private init() {
        power = StorePower(disks: disks, settings: settings)
    }

    func start() {
        guard !started else { return }
        started = true
        settings.apply(unlocked: purchase.unlocked)
        menuBarWasShown = settings.menuBarShown
        purchase.onChange = { [weak self] unlocked, revoked in self?.settings.apply(unlocked: unlocked, revoked: revoked) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        disks.onRefresh = { [weak self] in self?.power.update() }
        disks.onMounted = { [weak self] volume in
            guard let self, self.settings.unlocked, let serial = volume.serial,
                  self.settings.choice(serial: serial)?.revealsOnConnect == true else { return }
            self.disks.showInFinder(volume)
        }
        disks.start()
        purchase.start()
        power.start()
    }

    private func settingsChanged() {
        power.update()
        let shown = settings.menuBarShown
        defer { menuBarWasShown = shown }
        // The icon dragged out of the menu bar, or the purchase gone, with no window
        // open: nothing would be left to see or quit, so quit like any closed app.
        if menuBarWasShown && !shown && !NSApp.windows.contains(where: \.isAppWindow) {
            NSApp.terminate(nil)
        }
    }
}
