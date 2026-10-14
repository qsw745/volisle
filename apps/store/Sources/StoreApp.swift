// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

/// Mac App Store build. The file system extension does the work and the system
/// mounts the disks; this app explains what happened to each disk and holds the
/// one preference. No helper, no updater, no disk access of its own.
@main struct StoreApp: App {
    @State private var disks = StoreDisks()

    var body: some Scene {
        Window("盘屿", id: "main") {
            StoreRootView(disks: disks)
                .frame(minWidth: 680, minHeight: 420)
                .task { disks.start() }
        }
        .defaultSize(width: 820, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("刷新磁盘") { disks.checkExtension(); disks.refresh() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Link("盘屿帮助", destination: StoreLink.help)
                Link("提交反馈…", destination: StoreLink.feedback)
            }
        }
        // Tall enough for every section without scrolling, in all three languages.
        Settings { StoreSettingsView(disks: disks).frame(width: 460, height: 600) }
    }
}

enum StoreLink {
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
