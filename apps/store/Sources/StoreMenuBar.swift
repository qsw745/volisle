// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

/// Pro: the disks at a glance from the menu bar. While a disk is mounted it
/// never says "safe to unplug" (the kernel may still hold data for it): only
/// after an eject from here does it say so.
struct StoreMenuBarLabel: View {
    let disks: StoreDisks

    var body: some View {
        Image(systemName: disks.volumes.contains(where: \.writing) ? "externaldrive.fill" : "externaldrive")
            .accessibilityLabel(disks.volumes.contains(where: \.writing) ? "盘屿：正在写入" : "盘屿")
    }
}

struct StoreMenuBarView: View {
    @Bindable var disks: StoreDisks
    let power: StorePower
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = power.sleepReport {
                StoreSleepReportView(report: report, dismiss: power.dismissSleepReport)
                Divider()
            }
            if disks.volumes.isEmpty {
                Text("没有接着 NTFS 磁盘").foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ForEach(disks.volumes) { volume in row(volume) }
            }
            if let error = disks.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("推出全部") { disks.ejectAllShowingFailures() }
                    .disabled(!disks.volumes.contains(where: \.isOurs))
                Spacer()
                Button("打开盘屿") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: StoreAppDelegate.mainWindow)
                    NSApp.activate()
                }
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                .help("退出盘屿").accessibilityLabel("退出盘屿")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func row(_ volume: StoreVolume) -> some View {
        HStack(spacing: 10) {
            Image(systemName: volume.writing ? "externaldrive.fill" : "externaldrive")
                .font(.title3).foregroundStyle(volume.writing ? Color.accentColor : .secondary)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).lineLimit(1)
                Text(status(volume)).font(.caption).foregroundStyle(volume.ejected ? Color.green : .secondary)
            }
            Spacer(minLength: 8)
            if disks.ejecting.contains(volume.id) {
                ProgressView().controlSize(.small).accessibilityLabel("正在推出")
            } else if volume.isOurs {
                Button { disks.eject(volume) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.borderless).help("推出").accessibilityLabel("推出“\(volume.name)”")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(_ volume: StoreVolume) -> String {
        if volume.ejected { return String(localized: "已推出，可以拔下") }
        if disks.ejecting.contains(volume.id) { return String(localized: "正在推出") }
        guard volume.isOurs, !volume.readOnly else { return volume.stateSummary }
        return volume.writing ? String(localized: "正在写入 · 拔下前先推出") : String(localized: "可读写 · 拔下前先推出")
    }
}

/// After waking: which disks were ejected before sleep, and which could not be.
struct StoreSleepReportView: View {
    let report: StoreSleepReport
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !report.ejected.isEmpty {
                Label {
                    Text("睡眠前已推出：\(report.ejected.joined(separator: "、"))。重新接上即可使用。")
                } icon: { Image(systemName: "moon.zzz").foregroundStyle(.secondary) }
            }
            ForEach(report.failed.keys.sorted(), id: \.self) { name in
                Label {
                    Text("睡眠前没能推出“\(name)”：\(report.failed[name] ?? "")")
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Button("知道了", action: dismiss).buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
