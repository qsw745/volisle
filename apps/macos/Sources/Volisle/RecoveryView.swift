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
        SheetScaffold(Text("恢复文件"),
                      subtitle: Text("保存文件时如果磁盘中途断开，盘屿会留下这个文件新旧两个版本的记录。核对后可以另存到其他位置，原磁盘不会被改动。"),
                      systemImage: "clock.arrow.circlepath", tint: .blue) {
            if isLoading {
                SheetPlaceholder(title: Text("正在读取恢复记录…"))
            } else if records.isEmpty {
                if let error {
                    SheetPlaceholder(systemImage: "exclamationmark.triangle", tint: .orange,
                                     title: Text("没有读取到恢复记录"), message: Text(error))
                } else {
                    SheetPlaceholder(systemImage: "checkmark.shield", tint: .green,
                                     title: Text("没有需要恢复的文件"), message: Text("最近没有中途断开的文件保存。"))
                }
            } else {
                chooser
            }
            status
        } buttons: {
            Button("刷新") { Task { await load() } }.disabled(isLoading || isExporting)
            Button("导入记录…") { Task { await importRecord() } }.disabled(isLoading || isExporting)
                .help("导入从备份或另一台 Mac 拷来的恢复记录文件夹。")
            Spacer()
            if isExporting { ProgressView().controlSize(.small) }
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isExporting)
            if isExporting {
                Button("取消导出") { exportTask?.cancel() }
            } else if let result {
                Button("查看导出文件") { NSWorkspace.shared.open(result.directory) }.buttonStyle(.borderedProminent)
            } else if !records.isEmpty {
                Button("选择位置并导出…") { Task { await chooseDestination() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || record?.canExport != true || !sourceReady)
            }
        }
        .frame(width: 560)
        .background(RecoveryWindowReader { hostWindow = $0 })
        .interactiveDismissDisabled(isExporting)
        .task { selectedDisk = preferredVolume; await load() }
        .onChange(of: selectedRecord) { _, _ in result = nil; error = nil }
        .onChange(of: selectedDisk) { _, _ in result = nil; error = nil }
    }

    /// A list, not custom rows: Tab reaches it and the arrow keys change the choice.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("待恢复的文件").font(.headline)
            List(records, selection: $selectedRecord) { row($0) }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: CGFloat(min(records.count, 4)) * 46 + 8)
                .disabled(isExporting)
            HStack {
                Text("来源磁盘")
                Spacer()
                if disks.isEmpty {
                    Text("未连接").foregroundStyle(.secondary)
                } else {
                    Picker("来源磁盘", selection: $selectedDisk) {
                        Text("选择磁盘").tag(VolumeIdentity?.none)
                        ForEach(disks) { disk in Text(describe(disk)).tag(Optional(disk.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .disabled(isExporting)
            .padding(.top, 6)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    /// Why exporting is not possible yet, what went wrong, or what was saved:
    /// always in view above the buttons.
    @ViewBuilder private var status: some View {
        if let result {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(result.exportedCount == 2 ? String(localized: "新旧两个版本均已校验并导出。")
                         : String(localized: "已导出 1 个通过校验的版本；另一版本未找到或未通过校验。"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text("原文件及记录仍保留；导出不会修复磁盘或启用写入。").font(.caption).foregroundStyle(.secondary)
            }
            .sheetStatus()
        } else if !records.isEmpty, let sourceNote {
            Label(sourceNote, systemImage: "info.circle").foregroundStyle(.secondary).sheetStatus()
        }
        if let error, !records.isEmpty {
            Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                .sheetStatus()
        }
    }

    private func row(_ item: ReplacementRecoveryRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.canExport ? "doc" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.canExport ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// An imported record carries the time it was imported, not when saving
    /// was interrupted: no date for those.
    private func detail(_ item: ReplacementRecoveryRecord) -> String {
        if importedRecords.contains(where: { $0.id == item.id }) { return item.status + " · " + String(localized: "导入的记录") }
        guard item.modified != .distantPast else { return item.status }
        return item.status + " · " + item.modified.formatted(date: .abbreviated, time: .shortened)
    }

    private func describe(_ disk: VolumeSnapshot) -> String {
        let state = switch disk.mountState {
        case .readOnly: String(localized: "只读")
        case .unmounted: String(localized: "未挂载")
        default: String(localized: "请先恢复只读")
        }
        return disk.name + " · " + state
    }

    /// What exporting needs from the source disk, or why it cannot be done.
    private var sourceNote: String? {
        if record?.canExport == false { return String(localized: "这份记录无法验证，已保留原始记录，暂不能自动导出。") }
        if disks.isEmpty { return String(localized: "请连接这个文件所在的磁盘，再点“刷新”。") }
        guard let volume else { return String(localized: "请选择这个文件所在的磁盘。") }
        if volume.mountState == .unmounted { return String(localized: "导出时会以只读方式连接这块磁盘。") }
        if sourceReady { return String(localized: "核对磁盘时会短暂重新连接只读挂载，请先关闭正在使用的文件。") }
        return String(localized: "请将原磁盘恢复只读，或重新连接让 macOS 只读挂载后刷新。")
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
            let running = QuitGuard.begin(String(localized: "正在导出恢复的文件"))
            defer { isExporting = false; exportTask = nil; QuitGuard.end(running) }
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
