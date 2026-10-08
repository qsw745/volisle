import SwiftUI
import AppKit
import VolisleCore
import ServiceManagement

struct SettingsView: View {
    var discovery: DiskDiscovery
    var engineStatus: EngineStatus
    var autoMount: AutoMountController
    var helperService: HelperServiceController
    var mountCycle: MountCycleClient
    @Bindable var updates: AppUpdates
    var refreshRuntime: () async -> Void
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(CopySleepGuard.key) private var keepAwakeWhileCopying = true
    @State private var diagnostics: DiagnosticPresentation?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var showEngine = false
    @State private var confirmingRemoval = false
    var body: some View {
        Form {
            Section("通用") {
                Toggle("插入 NTFS 磁盘时自动启用读写", isOn: Binding(
                    get: { autoMount.preferences.automaticEnabled },
                    set: { value in
                        do { try autoMount.preferences.setAutomaticEnabled(value) }
                        catch { loginError = error.localizedDescription }
                    }))
                    .disabled(!DailyWriteAvailability.enabled)
                Text("首次授权后自动处理支持的外接磁盘。关闭窗口后仍在后台运行；关闭此开关不会中断已经启用的读写。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("拷贝期间不让 Mac 自动睡眠", isOn: $keepAwakeWhileCopying)
                Text("用“拷贝到这块盘…”拷贝时，Mac 不会因为闲置而睡眠，屏幕仍会按系统设置关闭。合上笔记本或手动选择睡眠时仍会睡眠，拷贝随之暂停，醒来后磁盘重新开启读写就会接着拷。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
                Toggle("登录时启动盘屿", isOn: Binding(get: { loginEnabled }, set: setLogin))
                    .disabled(Bundle.main.bundleIdentifier == nil)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                if Bundle.main.bundleIdentifier == nil {
                    Text("签名安装版可设置登录启动。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("首次使用") {
                if SetupProgress(helper: helperService, engine: engineStatus).isComplete {
                    Label("已完成设置，插入磁盘即可使用。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("按顺序打开下面三项，每项设置一次即可。打开后会自动打勾。")
                        .font(.caption).foregroundStyle(.secondary)
                    SetupStepsView(helperService: helperService, engineStatus: engineStatus, refreshRuntime: refreshRuntime)
                }
            }
            Section("更新") {
                HStack {
                    Text(updates.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("检查更新") { updates.check() }
                        .disabled(!updates.available || (!updates.canCheck && !updates.canRetryInstallation))
                }
                Toggle("自动检查更新", isOn: $updates.automaticChecks).disabled(!updates.available)
                Toggle("自动下载更新", isOn: $updates.automaticDownloads)
                    .disabled(!updates.available || !updates.automaticChecks)
                Text("安装前会安全结束磁盘读写，磁盘忙碌时暂缓安装。").font(.caption).foregroundStyle(.secondary)
            }
            Section("支持") {
                DisclosureGroup(isExpanded: $showEngine) {
                    LabeledContent("状态", value: engineStatus.title)
                    Text(engineStatus.capability.reason).font(.caption).foregroundStyle(.secondary)
                    Button("重新检查") { Task { await engineStatus.refresh() } }.disabled(engineStatus.isChecking)
                    LabeledContent("后台组件", value: helperService.summary)
                    HStack {
                        if helperService.state == .notRegistered {
                            Button("设置后台组件") { Task { await helperService.register() } }
                        } else if helperService.state == .requiresApproval {
                            Button("打开系统设置") { helperService.openApprovalSettings() }
                        }
                        Button("检查连接") { Task { await helperService.refresh() } }
                        if helperService.state == .connected || helperService.state == .requiresApproval || helperService.state == .failed {
                            Button("移除组件") { confirmingRemoval = true }
                        }
                    }.disabled(helperService.isBusy || !helperService.packageVerified || updates.maintenance.blocking)
                    if let message = helperService.lastError { Text(message).font(.caption).foregroundStyle(.secondary) }
                } label: {
                    // The whole title row toggles, not just the chevron.
                    Button { withAnimation(.snappy) { showEngine.toggle() } } label: {
                        Text("NTFS 引擎").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityHint(showEngine ? "收起" : "展开")
                }
                Button("导出诊断…") {
                    diagnostics = .init(report: .snapshot(discovery: discovery, engineStatus: engineStatus, mountCycle: mountCycle,
                                                          helperService: helperService, autoMount: autoMount),
                                        models: DiagnosticReport.diskModels(discovery.volumes))
                }
                Text("诊断仅保存在本机，不包含文件内容、卷名或完整路径；附带盘屿最近 24 小时的运行记录（已去掉路径、名称和标识），便于定位问题。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("盘屿", value: Self.version)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        Link(destination: WebsiteLink.home.url) { Label("访问网站", systemImage: "safari") }
                        Link(destination: WebsiteLink.help.url) { Label("获得帮助", systemImage: "questionmark.circle") }
                    }
                    GridRow {
                        Link(destination: WebsiteLink.feedback.url) { Label("提交反馈", systemImage: "exclamationmark.bubble") }
                        Link(destination: WebsiteLink.support.url) { Label("请我喝杯奶茶 :)", systemImage: "cup.and.saucer") }
                    }
                }
                Text("盘屿免费开源。打赏全凭自愿，不影响任何功能。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .task { await refreshRuntime(); await helperService.refresh(); loginEnabled = SMAppService.mainApp.status == .enabled }
        .sheet(item: $diagnostics) { DiagnosticsView(report: $0.report, models: $0.models) }
        .onReceive(NotificationCenter.default.publisher(for: .volisleCloseSheetsForQuit)) { _ in
            diagnostics = nil; confirmingRemoval = false
        }
        .confirmationDialog("移除盘屿的后台组件？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除", role: .destructive) { Task { await helperService.unregister() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后插入的 NTFS 磁盘将只能读取，直到重新设置后台组件。卸载盘屿前才需要这样做。")
        }
    }
    private static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return String(localized: "开发版") }
        return (info?["CFBundleVersion"] as? String).map { String(localized: "\(short)（\($0)）") } ?? short
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? String(localized: "请在系统设置的“登录项与扩展”中允许盘屿。") : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = String(localized: "设置未生效，请使用签名安装版，或在系统设置中检查登录项。")
        }
    }
}
