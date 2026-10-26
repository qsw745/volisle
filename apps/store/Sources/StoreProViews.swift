// SPDX-License-Identifier: GPL-2.0-only
import StoreKit
import SwiftUI

/// How one disk is mounted, as the picker offers it.
private enum StoreDiskMode: Hashable {
    case general, readOnly, readWrite

    init(_ preference: StoreDiskPreference?) {
        switch preference {
        case .readOnly: self = .readOnly
        case .readWrite: self = .readWrite
        case nil: self = .general
        }
    }

    var preference: StoreDiskPreference? {
        switch self {
        case .general: return nil
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        }
    }
}

/// Pro, in the disk's detail: its own way of mounting and what to do when it is connected.
struct StoreDiskChoiceSection: View {
    let settings: StoreProSettings
    let serial: String
    let name: String

    var body: some View {
        let choice = settings.choice(serial: serial)
        VStack(alignment: .leading, spacing: 10) {
            Text("这块盘").font(.headline)
            Picker("读写方式", selection: Binding(
                get: { StoreDiskMode(choice?.preference) },
                set: { settings.setPreference($0.preference, serial: serial, name: name) })) {
                Text("跟随“默认只读”设置").tag(StoreDiskMode.general)
                Text("总是只读").tag(StoreDiskMode.readOnly)
                Text("总是读写").tag(StoreDiskMode.readWrite)
            }
            .fixedSize()
            Toggle("接上后在访达中显示", isOn: Binding(
                get: { choice?.revealsOnConnect ?? false },
                set: { settings.setRevealsOnConnect($0, serial: serial, name: name) }))
            Text("推出后重新接上才会生效。“总是读写”不会盖过盘屿的安全检查：需要检查、来自休眠的 Windows 或写保护的盘仍然只读。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

/// Settings → 高级: the Pro offer, or once bought, its switches.
struct StoreAdvancedSettingsView: View {
    @Bindable var settings: StoreProSettings
    let purchase: StorePurchase

    var body: some View {
        if settings.unlocked {
            StoreProSwitches(settings: settings)
        } else {
            StoreProOffer(purchase: purchase)
        }
    }
}

private struct StoreProOffer: View {
    let purchase: StorePurchase
    @Environment(\.purchase) private var buy

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StoreBrandMark(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("盘屿 Pro").font(.title2.weight(.semibold))
                    Text("一次购买，以后的高级功能都包含在内。").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("menubar.rectangle", "菜单栏", "一眼看到哪块盘正在写入，一键推出全部。")
                feature("moon.zzz", "睡眠保护", "写入时不让 Mac 自动睡眠；合盖或睡眠前自动推出磁盘。")
                feature("externaldrive.badge.checkmark", "每块盘单独设置", "让某块盘总是只读或总是读写，接上后自动在访达中显示。")
            }
            Text("读写 NTFS 磁盘本身一直免费，不需要购买。").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task { await purchase.purchase { try await buy($0) } }
                } label: {
                    if let product = purchase.product { Text("购买 \(product.displayPrice)") } else { Text("购买") }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(purchase.product == nil || purchase.working)
                Button("恢复购买") { Task { await purchase.restore() } }.disabled(purchase.working)
                if purchase.working { ProgressView().controlSize(.small).accessibilityLabel("正在处理") }
            }
            if let problem = purchase.productProblem {
                HStack(alignment: .firstTextBaseline) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await purchase.loadProduct() } }.buttonStyle(.borderless)
                }
            }
            if let problem = purchase.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StoreProSwitches: View {
    @Bindable var settings: StoreProSettings

    var body: some View {
        Form {
            Section {
                Toggle("在菜单栏显示盘屿", isOn: $settings.showsMenuBar)
                Toggle("登录时打开", isOn: Binding(get: { settings.opensAtLogin }, set: { settings.setOpensAtLogin($0) }))
                    .disabled(!settings.showsMenuBar && !settings.opensAtLogin)
                Text("打开菜单栏图标后，关掉窗口盘屿也会继续运行；登录时打开会直接进入菜单栏。")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = settings.loginProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Label("已解锁盘屿 Pro", systemImage: "checkmark.seal.fill")
            }
            Section("睡眠") {
                Toggle("正在写入时不让 Mac 自动睡眠", isOn: $settings.preventsSleepWhileWriting)
                Text("只挡住闲置时的自动睡眠，挡不住合盖。").font(.caption).foregroundStyle(.secondary)
                Toggle("合盖或睡眠前推出 NTFS 磁盘", isOn: $settings.ejectsBeforeSleep)
                Text("最多等 20 秒；有文件正在使用的盘不会被强制推出，醒来后会告诉你。推出的盘要重新接上才能使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("这两项需要盘屿开着（窗口或菜单栏图标）。").font(.caption).foregroundStyle(.secondary)
            }
            Section("每块盘的设置") {
                if settings.choices.isEmpty {
                    Text("在主窗口里选中一块盘，就可以单独设置。").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.choices.keys.sorted(), id: \.self) { serial in
                        if let choice = settings.choices[serial] {
                            LabeledContent {
                                Button("忘记") { settings.forget(serial: serial) }
                            } label: {
                                Text(choice.name)
                                Text(summary(choice))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ choice: StoreDiskChoice) -> String {
        var parts: [String] = []
        switch choice.preference {
        case .readOnly: parts.append(String(localized: "总是只读"))
        case .readWrite: parts.append(String(localized: "总是读写"))
        case nil: break
        }
        if choice.revealsOnConnect { parts.append(String(localized: "接上后在访达中显示")) }
        return parts.joined(separator: " · ")
    }
}
