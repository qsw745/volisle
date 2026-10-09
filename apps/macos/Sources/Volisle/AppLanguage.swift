import Foundation
import AppKit

/// The interface language: the system's, or one chosen in Settings. macOS reads
/// it at launch (AppleLanguages in Volisle's own defaults, never the global
/// domain), so a change shows once Volisle is opened again.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    var id: String { rawValue }
    private static let key = "AppleLanguages"

    /// The choice saved for Volisle alone.
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }
    /// What this run of Volisle was started with: touched at launch.
    static let atLaunch = current

    func apply() {
        if self == .system { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set([rawValue], forKey: Self.key) }
    }

    /// Quits (through the usual guard: nothing is quit while a disk is being
    /// erased or checked) and opens Volisle again once this process has ended.
    /// Read-write sessions carry on and are found again after the relaunch.
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits at most 20 s: a quit that was refused does not reopen it later.
        task.arguments = ["-c", "for i in $(seq 100); do kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$0\"; sleep 0.2; done",
                          Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try task.run() } catch { return }
        UpdateAppDelegate.closeSheetsAndTerminate()
    }
}
