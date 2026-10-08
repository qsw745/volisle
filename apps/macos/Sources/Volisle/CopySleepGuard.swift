import Foundation
import IOKit.pwr_mgt

/// While Volisle copies onto a disk, the Mac does not go to sleep for being
/// idle (Settings → General, on by default). Closing the lid or choosing Sleep
/// still sleeps: the copy pauses and continues once the disk is writable again.
/// The display still turns off as the system settings say.
@MainActor final class CopySleepGuard {
    static let key = "keepAwakeWhileCopying"
    private var assertion: IOPMAssertionID = 0
    private var copying = false
    private var observer: NSObjectProtocol?

    init() {
        UserDefaults.standard.register(defaults: [Self.key: true])
        // The Settings toggle takes effect at once, also in the middle of a copy.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    func update(copying: Bool) {
        guard copying != self.copying else { return }
        self.copying = copying
        apply()
    }

    private func apply() {
        let wanted = copying && UserDefaults.standard.bool(forKey: Self.key)
        if wanted && assertion == 0 {
            var id: IOPMAssertionID = 0
            let reason = String(localized: "盘屿正在拷贝文件到磁盘") as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !wanted && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
