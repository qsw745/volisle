import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VolisleCore

struct DiagnosticsView: View {
    let report: DiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                BrandMark()
                Text("诊断预览").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("以下是打开此面板时的状态快照。报告仅保存在你选择的位置，不会自动上传。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(report.text).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("不含卷名、路径、UUID 或文件内容").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出 JSON") { export(json: true) }
                Button("导出文本") { export(json: false) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 660, height: 460)
            .alert("无法导出诊断", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func export(json: Bool) {
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
