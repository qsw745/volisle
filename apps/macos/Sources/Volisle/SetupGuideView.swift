import SwiftUI
import AppKit
import FSKit
import VolisleCore
import ServiceManagement

/// System Settings panes for the three switches only the user can turn on.
enum SetupLinks {
    static func fileSystemExtensions() {
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        // Opens the File System Extensions list directly (verified on macOS 26.6).
        let direct = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule")!
        if !NSWorkspace.shared.open(direct) { SMAppService.openSystemSettingsLoginItems() }
    }
    static func fullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

extension SetupProgress {
    @MainActor init(helper: HelperServiceController, engine: EngineStatus) {
        // Support and screenshots only: show the guide as if at step N (display only).
        let preview = UserDefaults.standard.integer(forKey: "VolisleSetupGuidePreviewStep")
        if (1...3).contains(preview) {
            self.init(helperConnected: preview > 1, extensionEnabled: preview > 2, fullDiskAccess: false)
            return
        }
        self.init(helperConnected: helper.state == .connected, extensionEnabled: engine.capability.available,
                  fullDiskAccess: helper.fullDiskAccess)
    }
}

/// The three steps, each with what to click in System Settings. Progress is
/// detected, so a step ticks itself once the switch is on.
struct SetupStepsView: View {
    var helperService: HelperServiceController
    var engineStatus: EngineStatus
    var refreshRuntime: () async -> Void
    /// The step whose System Settings pane was opened: only then wait visibly.
    @State private var opened: SetupStep?
    private var progress: SetupProgress { .init(helper: helperService, engine: engineStatus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                row(step)
                if step != SetupStep.allCases.last { Divider().padding(.leading, 44) }
            }
        }
        .task {
            // Each switch is flipped in System Settings: keep checking while shown,
            // in the guide and in Settings alike.
            while !Task.isCancelled {
                await helperService.refresh()
                if !engineStatus.capability.available && !engineStatus.isChecking { await engineStatus.refresh() }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func row(_ step: SetupStep) -> some View {
        let done = progress.isDone(step), current = progress.current == step
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : current ? Color.accentColor : Color.secondary.opacity(0.25))
                if done { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(step.rawValue + 1)").font(.system(size: 14, weight: .semibold)).foregroundStyle(current ? .white : .secondary) }
            }
            .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title(step)).font(.headline).foregroundStyle(done || current ? .primary : .secondary)
                    Spacer()
                    if done { Text("已完成").font(.callout).foregroundStyle(.green) }
                }
                if current {
                    Text(instructions(step)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        action(step)
                        if opened == step {
                            ProgressView().controlSize(.small)
                            Text("打开后这里会自动打勾").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let note = note(step) {
                        Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "第 \(step.rawValue + 1) 步：\(title(step))，\(done ? String(localized: "已完成") : current ? String(localized: "进行中") : String(localized: "未开始"))"))
    }

    private func title(_ step: SetupStep) -> String {
        switch step {
        case .backgroundComponent: String(localized: "允许盘屿在后台运行")
        case .fileSystemExtension: String(localized: "启用盘屿的文件系统扩展")
        case .fullDiskAccess: String(localized: "允许盘屿读取磁盘")
        }
    }

    private func instructions(_ step: SetupStep) -> String {
        switch step {
        case .backgroundComponent:
            String(localized: "点下面的按钮，系统设置会打开“登录项与扩展”。在“允许在后台”里找到“盘屿”，打开右边的开关。系统可能要求输入这台 Mac 的登录密码。")
        case .fileSystemExtension:
            String(localized: "点下面的按钮，系统设置会打开“文件系统扩展”列表。打开“盘屿 NTFS”（有的系统显示为“Volisle NTFS”）右边的开关，再点“完成”。在“按 App”页面里盘屿下面的“FSKit Modules”开关不用管。")
        case .fullDiskAccess:
            String(localized: "点下面的按钮，系统设置会打开“完全磁盘访问”。找到“盘屿”，打开右边的开关。列表里没有盘屿时，点列表下方的“+”，在“应用程序”里选择“盘屿”。如果系统提示退出并重新打开，选“稍后”即可。")
        }
    }

    @ViewBuilder private func action(_ step: SetupStep) -> some View {
        switch step {
        case .backgroundComponent:
            if helperService.state == .requiresApproval {
                Button("打开系统设置") { opened = step; helperService.openApprovalSettings() }.buttonStyle(.borderedProminent)
            } else {
                Button("允许后台运行") {
                    opened = step
                    Task {
                        await helperService.register()
                        if helperService.state == .requiresApproval { helperService.openApprovalSettings() }
                        await refreshRuntime()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(helperService.isBusy || helperService.state == .unavailable)
            }
        case .fileSystemExtension:
            Button("打开系统设置") { opened = step; SetupLinks.fileSystemExtensions() }.buttonStyle(.borderedProminent)
        case .fullDiskAccess:
            Button("打开系统设置") { opened = step; SetupLinks.fullDiskAccess() }.buttonStyle(.borderedProminent)
        }
    }

    private func note(_ step: SetupStep) -> String? {
        switch step {
        case .backgroundComponent:
            if helperService.state == .unavailable {
                return String(localized: "请先把盘屿拖到“应用程序”文件夹，再从那里打开。")
            }
            return helperService.state == .failed ? helperService.lastError : nil
        case .fileSystemExtension:
            // Only when it is not merely switched off (e.g. not found): say what the check found.
            let capability = engineStatus.capability
            guard !engineStatus.isChecking, !capability.available, !capability.reason.isEmpty else { return nil }
            guard capability.reason == ExtensionReadiness.disabledReason else { return capability.reason }
            // Opened System Settings but the switch is still off: users report it
            // not turning on or flipping back.
            return opened == .fileSystemExtension
                ? String(localized: "“盘屿 NTFS”的开关打不开或会自己弹回去？请确认电脑上只有一个盘屿、并且是从“应用程序”文件夹打开的；仍然不行就重启 Mac 后再试。“FSKit Modules”那个开关不用打开。")
                : nil
        case .fullDiskAccess:
            return nil
        }
    }
}

/// Shown on first launch and whenever setup is unfinished: one step at a time.
struct SetupGuideView: View {
    var helperService: HelperServiceController
    var engineStatus: EngineStatus
    var refreshRuntime: () async -> Void
    @Environment(\.dismiss) private var dismiss
    private var progress: SetupProgress { .init(helper: helperService, engine: engineStatus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                BrandMark(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.isComplete ? "设置完成" : "欢迎使用盘屿").font(.title2.weight(.semibold))
                    Text(progress.isComplete
                         ? String(localized: "插入 NTFS 移动硬盘或 U 盘，盘屿会自动开启读写，在 Finder 里直接使用就行。")
                         : 3 - progress.doneCount == 1 ? String(localized: "还差最后 1 步。这个开关 macOS 要求你亲自打开，只需设置一次。")
                         : String(localized: "还差 \(3 - progress.doneCount) 步。这几个开关 macOS 要求你亲自打开，只需设置一次。"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if progress.isComplete {
                Label("后台组件、文件系统扩展和磁盘读取权限都已就绪。", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
                HStack { Spacer(); Button("开始使用") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            } else {
                SetupStepsView(helperService: helperService, engineStatus: engineStatus, refreshRuntime: refreshRuntime)
                    .padding(.horizontal, 16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text("以后也可以在设置 → 首次使用中继续。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("稍后设置") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(26).frame(width: 560).fixedSize(horizontal: false, vertical: true)
        // Turn writing on for a connected disk right away, not at the next poll.
        .onChange(of: progress.isComplete) { _, complete in
            if complete { Task { await refreshRuntime() } }
        }
    }
}
