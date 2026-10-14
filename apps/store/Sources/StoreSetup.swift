// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

/// What the window shows for each state of the extension: nothing in the app
/// works until the extension is on, so until then turning it on is the whole window.
struct StoreRootView: View {
    @Bindable var disks: StoreDisks

    var body: some View {
        switch disks.extensionState {
        case .checking: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disabled, .missing:
            StoreSetupView(missing: disks.extensionState == .missing, open: disks.openExtensionSettings, recheck: disks.checkExtension)
        case .enabled, .unavailable: StoreMainView(disks: disks)
        }
    }
}

struct StoreSetupView: View {
    /// The system does not list the extension at all, so there is no switch to point at.
    let missing: Bool
    let open: () -> Void
    let recheck: () -> Void

    /// System Settings can sit next to this window, and switching there does not activate the app.
    private static let recheckInterval = Duration.seconds(2)

    var body: some View {
        VStack(spacing: 24) {
            StoreBrandMark(width: 76)
            VStack(spacing: 8) {
                Text(missing ? "未检测到盘屿文件系统扩展" : "打开文件系统扩展，开始读写 NTFS 磁盘").font(.title2.weight(.semibold))
                Text(missing ? "请把盘屿放在“应用程序”文件夹里，并从那里打开。" : "盘屿通过 macOS 的文件系统扩展读写磁盘，需要在系统设置里打开一次。")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            if missing {
                Text("已经在“应用程序”文件夹里时，退出盘屿后重新打开；仍然没有的话，重新启动 Mac。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "点下面的“打开系统设置”。")
                    step(2, "在“文件系统扩展”列表里打开“盘屿 NTFS”。")
                    step(3, "回到盘屿。已经接着的磁盘，推出后重新接上。")
                }
                .padding(18).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                Button("打开系统设置", action: open).buttonStyle(.borderedProminent).controlSize(.large)
                Text("没有自动跳到这个列表时，它在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 520).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recheckInterval)
                recheck()
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: .circle)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
