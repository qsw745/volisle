import SwiftUI
import AppKit
import VolisleCore

struct RecoveryView: View {
    var discovery: DiskDiscovery
    let preferredVolume: VolumeIdentity?
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ReplacementRecoveryRecord] = []
    @State private var importedRecords: [ReplacementRecoveryRecord] = []
    @State private var selectedRecord: String?
    @State private var selectedDisk: VolumeIdentity?
    @State private var isLoading = true
    @Binding var isExporting: Bool
    @State private var error: String?
    @State private var result: ReplacementRecoveryResult?
    @State private var exportTask: Task<Void, Never>?
    @State private var hostWindow: NSWindow?
    private var record: ReplacementRecoveryRecord? { records.first { $0.id == selectedRecord } }
    private var disks: [VolumeSnapshot] { discovery.volumes.filter(\.isNTFS) }
    private var volume: VolumeSnapshot? { disks.first { $0.id == selectedDisk } }
    private var sourceReady: Bool { (volume?.mountState == .readOnly && volume?.mountURL != nil) || volume?.mountState == .unmounted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("恢复文件").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isExporting)
            }
            if isLoading {
                ProgressView("正在读取恢复记录…").frame(maxWidth: .infinity, minHeight: 240)
            } else if records.isEmpty {
                ContentUnavailableView("没有待恢复文件", systemImage: "checkmark.shield", description: Text(error == nil ? "未发现未完成的覆盖记录。" : "恢复记录尚未读取成功。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                Text("选择文件，将可核对的版本保存到另一处。原磁盘保持不变。")
                    .font(.callout).foregroundStyle(.secondary)
                List(records, selection: $selectedRecord) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.filename).lineLimit(1)
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(item.id)
                }.listStyle(.bordered).frame(minHeight: 170).disabled(isExporting)
                if !disks.isEmpty {
                    Picker("来源磁盘", selection: $selectedDisk) {
                        Text("选择磁盘").tag(VolumeIdentity?.none)
                        ForEach(disks) { disk in
                            Text(disk.name + " · " + (disk.mountState == .readOnly ? String(localized: "只读") : disk.mountState == .unmounted ? String(localized: "未挂载") : String(localized: "请先恢复只读")))
                                .tag(Optional(disk.id))
                        }
                    }.disabled(isExporting)
                }
                if record?.canExport == false {
                    Text("这份记录无法验证，已保留原始记录，暂不能自动导出。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if volume?.mountState == .unmounted {
                    Text("导出时会以只读方式连接这块磁盘。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if sourceReady {
                    Text("核对磁盘时会短暂重新连接只读挂载，请先关闭正在使用的文件。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !sourceReady {
                    Text("请将原磁盘恢复只读，或重新连接让 macOS 只读挂载后刷新。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let result {
                Label(result.exportedCount == 2 ? "新旧两个版本均已校验并导出。" : "已导出 1 个通过校验的版本；另一版本未找到或未通过校验。", systemImage: "checkmark.circle")
                    .font(.callout)
                Text("原文件及记录仍保留；导出不会修复磁盘或启用写入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("刷新") { Task { await load() } }.disabled(isLoading || isExporting)
                Button("导入记录…") { Task { await importRecord() } }.disabled(isLoading || isExporting)
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                    Button("取消导出") { exportTask?.cancel() }
                } else if let result {
                    Button("查看导出文件") { NSWorkspace.shared.open(result.directory) }.buttonStyle(.borderedProminent)
                } else {
                    Button("选择位置并导出…") { Task { await chooseDestination() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || record?.canExport != true || !sourceReady)
                }
            }
        }.padding(24).frame(width: 560, height: 470)
            .background(RecoveryWindowReader { hostWindow = $0 })
            .interactiveDismissDisabled(isExporting)
            .task { selectedDisk = preferredVolume; await load() }
            .onChange(of: selectedRecord) { _, _ in result = nil; error = nil }
            .onChange(of: selectedDisk) { _, _ in result = nil; error = nil }
    }
    private func load() async {
        isLoading = true; error = nil; result = nil
        defer { isLoading = false }
        do {
            records = try await Task.detached { try ReplacementRecoveryCatalog.scan() }.value
            records += importedRecords.filter { imported in !records.contains { $0.id == imported.id } }
            if !records.contains(where: { $0.id == selectedRecord }) { selectedRecord = records.first?.id }
            if !disks.contains(where: { $0.id == selectedDisk }) { selectedDisk = disks.first?.id }
        } catch { records = importedRecords; self.error = error.localizedDescription }
    }
    private func chooseFolder(title: String, prompt: String, create: Bool = false) async -> URL? {
        guard let parent = hostWindow else {
            error = String(localized: "窗口尚未准备好，请稍后重试。"); return nil
        }
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = prompt
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: parent) { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    private func importRecord() async {
        guard let url = await chooseFolder(title: String(localized: "选择备份的恢复记录文件夹"), prompt: String(localized: "导入记录")) else { return }
        do {
            let item = try ReplacementRecoveryCatalog.importRecord(at: url)
            if !records.contains(where: { $0.id == item.id }) { importedRecords.append(item); records.append(item) }
            selectedRecord = item.id; error = nil; result = nil
        } catch { self.error = error.localizedDescription }
    }
    private func chooseDestination() async {
        guard let record, let volume, sourceReady, !isExporting else { return }
        guard let selected = await chooseFolder(title: String(localized: "选择恢复文件的保存位置"), prompt: String(localized: "导出到此处"), create: true) else { return }
        let destination = selected.resolvingSymlinksInPath()
        isExporting = true; error = nil; result = nil
        exportTask = Task {
            defer { isExporting = false; exportTask = nil }
            do {
                result = try await ReplacementRecoveryCoordinator().export(record, volume: volume,
                    destination: destination, resolver: discovery)
            } catch is CancellationError { error = String(localized: "已取消导出，原文件和恢复记录保持不变。") }
            catch { self.error = error.localizedDescription }
        }
    }
}


/// Bind dialogs to this exact SwiftUI sheet even when the app is not the
/// foreground application's key window (for example during automation).
private struct RecoveryWindowReader: NSViewRepresentable {
    let resolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader {
        let view = Reader(); view.resolve = resolve; return view
    }
    func updateNSView(_ view: Reader, context: Context) { view.resolve = resolve }
    final class Reader: NSView {
        var resolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let host = window
            DispatchQueue.main.async { [weak self] in self?.resolve?(host) }
        }
    }
}
