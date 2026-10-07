import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VolisleCore

struct DiagnosticPresentation: Identifiable {
    let id = UUID()
    let report: DiagnosticReport
    /// External volumes' device models, in the report's order: to look up the
    /// errors their disks reported (the models themselves are not exported).
    var models: [String] = []
}

struct DiagnosticsView: View {
    /// The state snapshot; the run log is added once it has been read.
    let base: DiagnosticReport
    let models: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var report: DiagnosticReport?
    @State private var error: String?
    @State private var copied = false

    init(report: DiagnosticReport, models: [String] = []) { base = report; self.models = models }

    var body: some View {
        SheetScaffold(Text("诊断预览"),
                      subtitle: Text("以下是打开此面板时的状态快照和盘屿最近的运行记录。报告仅保存在你选择的位置，不会自动上传；反馈问题时附上它，通常不用来回询问就能定位原因。"),
                      systemImage: "waveform.path.ecg", tint: .indigo) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let report {
                        ScrollView {
                            Text(report.text).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取最近的运行记录…").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 360)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                Label("不含卷名、路径、UUID 或文件内容", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
        } buttons: {
            Button(copied ? "已复制" : "复制") { copy() }.disabled(report == nil)
            Button("提交反馈…") { openURL(WebsiteLink.feedback.url) }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("导出 JSON") { export(json: true) }.disabled(report == nil)
            Button("导出文本") { export(json: false) }.buttonStyle(.borderedProminent).disabled(report == nil)
        }
        .frame(width: 720)
        .task { await load() }
        .alert("无法导出诊断", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() async {
        var full = base
        // Both reads of the system log at once: each takes a few seconds.
        async let found = DiagnosticEvents.collect(since: Date().addingTimeInterval(-DiagnosticEvents.window))
        async let errors = models.isEmpty ? nil : DiskHealth.collect(models: models, since: Date().addingTimeInterval(-DiskHealth.window))
        full.diskErrors = await errors
        if let events = await found {
            full.events = events
            if events.isEmpty { full.eventsNote = String(localized: "最近 24 小时没有运行记录。") }
        } else {
            full.eventsNote = String(localized: "无法读取运行记录（需要管理员账户）。")
        }
        report = full
    }

    private func copy() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
        copied = true
    }

    private func export(json: Bool) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = String(localized: "Volisle-诊断") + (json ? ".json" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try json ? report.jsonData() : Data(report.text.utf8)
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
