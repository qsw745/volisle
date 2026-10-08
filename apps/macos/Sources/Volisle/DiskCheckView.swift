import SwiftUI
import VolisleCore

/// "Can't write to this disk?": the conditions in order, each with its way out.
/// Read live, so granting a permission in System Settings shows up here.
struct DiskCheckView: View {
    let volumeName: String
    /// Disk Arbitration's device model: the kernel names the disk by it.
    let deviceModel: String
    let items: (DiskReadiness.DiskErrors) -> [DiskReadiness.Item]
    let perform: (DiskReadiness.Action) -> Void
    let diagnosticsReport: () -> DiagnosticPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: DiagnosticPresentation?
    @State private var diskErrors = DiskReadiness.DiskErrors.checking

    var body: some View {
        let items = items(diskErrors)
        let problems = items.filter { $0.status == .problem }.count
        SheetScaffold(Text("“\(volumeName)”的读写条件"),
                      subtitle: Text(problems == 0 ? String(localized: "没有发现需要处理的问题。") : String(localized: "有 \(problems) 处需要处理，从上往下依次处理即可。")),
                      systemImage: "stethoscope", tint: problems == 0 ? .green : .orange) {
            Form {
                Section {
                    ForEach(items) { row($0) }
                } footer: {
                    Text("还是解决不了？导出诊断附在反馈里，里面有盘屿各部分的记录，可以直接看出卡在哪一步。")
                        .foregroundStyle(.secondary).sectionNote()
                }
            }
            .sheetForm()
            .frame(maxHeight: 600)
        } buttons: {
            Button("导出诊断…") { diagnostics = diagnosticsReport() }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 600)
        .sheet(item: $diagnostics) { DiagnosticsView(report: $0.report, models: $0.models) }
        .onReceive(NotificationCenter.default.publisher(for: .volisleCloseSheetsForQuit)) { _ in diagnostics = nil }
        .task {
            let found = await DiskHealth.collect(model: deviceModel, since: Date().addingTimeInterval(-DiskHealth.window))
            diskErrors = found.map { .found($0) } ?? .unreadable
        }
    }

    private func row(_ item: DiskReadiness.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(item.status)).foregroundStyle(color(item.status)).frame(width: 18)
                .accessibilityLabel(label(item.status))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).fontWeight(.medium)
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let action = item.action {
                    Button(title(action)) {
                        if action == .exportDiagnostics { diagnostics = diagnosticsReport(); return }
                        // Those that go on in the main window close this first.
                        if [.enableWriting, .retry, .checkOnMac, .recoverOnMac].contains(action) { dismiss() }
                        perform(action)
                    }.controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func icon(_ status: DiskReadiness.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }
    private func color(_ status: DiskReadiness.Status) -> Color {
        switch status {
        case .ok: .green
        case .problem: .orange
        case .note: .secondary
        }
    }
    private func label(_ status: DiskReadiness.Status) -> String {
        switch status {
        case .ok: String(localized: "正常")
        case .problem: String(localized: "需要处理")
        case .note: String(localized: "说明")
        }
    }
    private func title(_ action: DiskReadiness.Action) -> String {
        switch action {
        case .approveHelper, .fullDiskAccess, .fileSystemExtensions: String(localized: "打开系统设置")
        case .setUpHelper: String(localized: "设置后台组件")
        case .reconnectHelper: String(localized: "重新连接")
        case .enableWriting: String(localized: "启用读写")
        case .retry: String(localized: "重试")
        case .checkOnMac: String(localized: "在 Mac 上检查…")
        case .recoverOnMac: String(localized: "在 Mac 上恢复…")
        case .exportDiagnostics: String(localized: "导出诊断…")
        }
    }
}

extension DiagnosticReport {
    /// The state snapshot for the diagnostics preview; the run log is added there.
    @MainActor static func snapshot(discovery: DiskDiscovery, engineStatus: EngineStatus, mountCycle: MountCycleClient,
                                    helperService: HelperServiceController, autoMount: AutoMountController) -> DiagnosticReport {
        DiagnosticReport(volumes: discovery.volumes, diskServiceRunning: discovery.isRunning, engine: engineStatus.capability,
                         lastOperation: mountCycle.operation, lastRefusal: mountCycle.lastRefusal,
                         helper: .init(state: "\(helperService.state)", fullDiskAccess: helperService.fullDiskAccess,
                                       packageVerified: helperService.packageVerified, launchd: HelperLaunchdState.read()),
                         automaticWrite: autoMount.preferences.automaticEnabled, history: OperationHistory.entries())
    }
}
