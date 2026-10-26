// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

/// Mac App Store build. The file system extension does the work and the system
/// mounts the disks; this app explains what happened to each disk and holds the
/// preferences. No helper, no updater, no disk access of its own.
@main struct StoreApp: App {
    @NSApplicationDelegateAdaptor(StoreAppDelegate.self) private var delegate
    private let model = StoreModel.shared

    var body: some Scene {
        // Read here so the scene follows the purchase and the switch.
        let menuBarShown = model.settings.menuBarShown
        Window(StoreLink.displayName, id: StoreAppDelegate.mainWindow) {
            StoreMainWindow(model: model)
        }
        .defaultSize(width: 820, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("刷新磁盘") { model.disks.checkExtension(); model.disks.refresh() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Link("盘屿帮助", destination: StoreLink.help)
                Link("提交反馈…", destination: StoreLink.feedback)
            }
        }
        // Tall enough for every section without scrolling, in all three languages.
        Settings {
            StoreSettingsView(disks: model.disks, settings: model.settings, purchase: model.purchase)
                .frame(width: 480, height: 620)
        }
        MenuBarExtra(isInserted: Binding(get: { menuBarShown }, set: { model.settings.showsMenuBar = $0 })) {
            StoreMenuBarView(disks: model.disks, power: model.power)
        } label: {
            StoreMenuBarLabel(disks: model.disks)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Starts the model even when no window opens (launched at login into the menu
/// bar), and keeps the app running in the menu bar once its windows are closed.
@MainActor final class StoreAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindow = "main"
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Before SwiftUI opens the main window. The purchase is the last one known (StorePurchase caches it).
        let model = StoreModel.shared
        model.suppressesMainWindow = launchedAtLogin && model.purchase.unlocked && model.settings.showsMenuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = StoreModel.shared
        model.start()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // After the window is gone: with only the menu bar left, leave the Dock too.
            // A minimized window still needs the Dock.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if model.settings.menuBarShown && !NSApp.windows.contains(where: \.isAppWindow) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !StoreModel.shared.settings.menuBarShown
    }
}

extension NSWindow {
    /// The main window or Settings, open (shown or minimized); not the menu bar's panel.
    var isAppWindow: Bool { styleMask.contains(.titled) && !(self is NSPanel) && (isVisible || isMiniaturized) }
}

/// The main window's content. Opened at login into the menu bar, it closes itself at once.
private struct StoreMainWindow: View {
    let model: StoreModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        StoreRootView(disks: model.disks, settings: model.settings, power: model.power)
            .frame(minWidth: 680, minHeight: 420)
            .onAppear {
                if model.suppressesMainWindow {
                    model.suppressesMainWindow = false
                    NSApp.setActivationPolicy(.accessory)
                    dismissWindow(id: StoreAppDelegate.mainWindow)
                } else {
                    NSApp.setActivationPolicy(.regular)
                }
            }
    }
}

enum StoreLink {
    /// Use the bundle's localized brand for the window and sidebar, just as macOS does for its menus.
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Volisle"
    }

    /// The App Store version's own help page, in Chinese or English like the interface.
    static var help: URL {
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
        return URL(string: chinese ? "https://qisw.top/volisle/store/" : "https://qisw.top/volisle/en/store/")!
    }
    static let feedback = URL(string: "https://github.com/qsw745/volisle-feedback/issues")!
    /// The complete corresponding source of this build (GPL).
    static let source = URL(string: "https://github.com/qsw745/volisle")!
}

struct StoreBrandMark: View {
    private static let image = Bundle.main.url(forResource: "BrandMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var width: CGFloat = 32
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: width, height: width * 460 / 760).accessibilityHidden(true)
        }
    }
}

func storeBytes(_ value: Int64?) -> String {
    guard let value, value >= 0 else { return String(localized: "未知") }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
}
