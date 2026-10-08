import SwiftUI
import AppKit
import VolisleCore

/// Copies onto a disk that Volisle runs itself: they pause when the disk goes
/// away and continue, after comparing what is already there, once it is
/// writable again.
struct CopyJobsSection: View {
    let jobs: [CopyQueue.Job]
    let queue: CopyQueue
    /// The disk these copies go to is connected / writable right now.
    let diskPresent: Bool
    let diskWritable: Bool
    /// A stopped write session is still awaiting recovery, not yet read-only.
    var diskNeedsRecovery = false
    var diskReadOnly = false
    var openCopiedFiles: ((CopyQueue.Job) -> Void)? = nil
    @State private var cancelling: CopyQueue.Job?
    var body: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(jobs) { job in row(job) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .volisleCloseSheetsForQuit)) { _ in cancelling = nil }
            .confirmationDialog("取消这次拷贝？", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                                titleVisibility: .visible, presenting: cancelling) { job in
                Button("取消拷贝", role: .destructive) { Task { await queue.cancel(job.id) } }
                Button("继续拷贝", role: .cancel) {}
            } message: { _ in
                if diskPresent {
                    Text("已经拷好的文件保留在盘上；没拷完的那个文件不会留下，盘上原来的同名文件也不会被改动。")
                } else {
                    Text("已经拷好的文件保留在盘上。没拷完的那个文件会在这块盘下次开启读写时清理掉；盘上原来的同名文件不会被改动。")
                }
            }
        }
    }

    @ViewBuilder private func row(_ job: CopyQueue.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(job)).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                buttons(job)
            }
            if job.running && job.status.checking {
                Text("核对进度").font(.caption).foregroundStyle(.secondary)
                if job.status.bytesToCheck > 0 {
                    ProgressView(value: Double(job.status.checkedBytes), total: Double(job.status.bytesToCheck))
                        .accessibilityLabel("核对进度")
                } else {
                    ProgressView().accessibilityLabel("核对进度")
                }
            } else {
                Text("拷贝进度").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: job.fraction).accessibilityLabel("拷贝进度")
            }
            Text(detail(job)).font(.caption).foregroundStyle(job.progress.pause == .problem ? .red : .secondary).lineLimit(4)
                .textSelection(.enabled)
        }
    }

    private func title(_ job: CopyQueue.Job) -> String {
        let folder = job.plan.destination.isEmpty ? job.plan.volumeName : (job.plan.destination as NSString).lastPathComponent
        return String(localized: "拷贝 \(job.topLevelCount) 个项目到“\(folder)”")
    }

    private func detail(_ job: CopyQueue.Job) -> String {
        let done = Self.size(job.copiedBytes)
        let total = Self.size(job.plan.totalBytes)
        if job.progress.finished {
            let text = job.confirmed ? String(localized: "已拷完 \(total)。")
                : String(localized: "已拷完 \(total)，正在确认写入（通常半分钟内）。这段时间里拔线，插回后会自动复查补齐；拔线前请先推出。")
            var lines = [text]
            let skipped = job.progress.skipped.count, vanished = job.progress.vanished.count
            if skipped > 0 { lines.append(String(localized: "有 \(skipped) 项按你的选择跳过，没有拷贝。")) }
            if vanished > 0 { lines.append(String(localized: "有 \(vanished) 项的原文件已经不在了，无法复查盘上的那份是否完整。")) }
            return lines.joined(separator: "\n")
        }
        if job.running {
            if job.status.checking {
                let checked = Self.size(job.status.checkedBytes), toCheck = Self.size(job.status.bytesToCheck)
                let text = job.status.checkingWholeFile
                    ? String(localized: "正在核对盘上已有的同名文件：\(checked) / \(toCheck)。")
                    : String(localized: "正在核对已拷部分：\(checked) / \(toCheck)。")
                return [text, String(localized: "上次已拷 \(done) / \(total)。核对完成后会自动继续。")].joined(separator: "\n")
            }
            let name = job.status.current.map { ($0 as NSString).lastPathComponent } ?? ""
            return String(localized: "已拷 \(done) / \(total) · \(name)")
        }
        let completed = job.progress.observedBytes == nil
            ? String(localized: "已完成文件 \(done) / \(total)。未完成部分会在继续时核对续传。")
            : String(localized: "上次已拷 \(done) / \(total)。继续时会核对并续传。")
        func waiting(_ message: String) -> String {
            // Say what happened when the disk itself failed, not only that it went away.
            let failed = (job.progress.deviceErrors ?? 0) > 0
                ? String(localized: "上次写入时这块盘出现读写错误（可能是坏道，或数据线、接口、供电不稳）。") : nil
            return [completed, failed, message].compactMap { $0 }.joined(separator: "\n")
        }
        switch job.progress.pause {
        case .disk?:
            if !diskPresent { return waiting(String(localized: "盘已断开或已推出，插回并开启读写后会自动继续。")) }
            if diskNeedsRecovery { return waiting(String(localized: "磁盘写入已中断。请先恢复只读，排除故障后重新开启读写；任务会核对未完成部分并接着拷。")) }
            if !diskWritable {
                return waiting(diskReadOnly
                    ? String(localized: "这块盘现在只读，开启读写后会自动继续。")
                    : String(localized: "这块盘目前无法写入，恢复可写后会自动继续。"))
            }
            if let problem = job.progress.problem { return waiting(String(localized: "写入时出错，稍后会自动重试：\(problem)")) }
            return waiting(String(localized: "等待中…"))
        case .user?:
            return [String(localized: "已暂停。"), completed, job.progress.problem].compactMap { $0 }.joined(separator: "\n")
        case .problem?:
            return job.progress.problem ?? String(localized: "拷贝遇到问题，已暂停。")
        case nil:
            return String(localized: "等待中…")
        }
    }

    /// "0 KB" rather than "Zero KB" before anything is copied.
    private static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    @ViewBuilder private func buttons(_ job: CopyQueue.Job) -> some View {
        HStack(spacing: 8) {
            if job.progress.finished {
                if job.confirmed {
                    Button("打开文件") { openCopiedFiles?(job) }
                        .disabled(!diskPresent || openCopiedFiles == nil)
                        .help("在访达中选中拷贝完成的文件或文件夹。")
                    Button("关闭拷贝记录", systemImage: "xmark") { queue.dismiss(job.id) }
                        .labelStyle(.iconOnly)
                        .help("关闭拷贝记录")
                }
            } else {
                if job.running {
                    Button("暂停") { Task { await queue.pause(job.id) } }
                } else if job.progress.pause == .problem {
                    if job.progress.failedAt != nil {
                        Button("跳过此项") { Task { await queue.skip(job.id) } }.help("不拷这一项，接着拷后面的。")
                    }
                    Button("重试") { Task { await queue.resume(job.id) } }
                } else if job.progress.pause == .user {
                    Button("继续") { Task { await queue.resume(job.id) } }
                }
                Button("取消…") { cancelling = job }
            }
        }.controlSize(.small)
    }
}

/// Copies waiting for disks that are not connected: they can be cancelled here.
struct CopyManagerSheet: View {
    let queue: CopyQueue
    let presentVolumes: Set<String>
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let jobs = queue.jobs.filter { !presentVolumes.contains($0.plan.diskKey) }
        SheetScaffold(Text("等待中的拷贝"),
                      subtitle: Text("这些拷贝要去的盘现在没有连接。插回盘并开启读写后会自动继续；不需要了可以取消。"),
                      systemImage: "doc.on.doc", tint: .blue) {
            if jobs.isEmpty {
                SheetPlaceholder(systemImage: "checkmark.circle", tint: .green, title: Text("没有等待中的拷贝。"))
            } else {
                Form {
                    Section { CopyJobsSection(jobs: jobs, queue: queue, diskPresent: false, diskWritable: false).padding(.vertical, 4) }
                }
                .sheetForm()
                .frame(maxHeight: 440)
            }
        } buttons: {
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 540)
    }
}

/// The two panels of "Copy to This Disk": what to copy, then where on the disk.
@MainActor enum CopyPicker {
    static func sources() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.title = String(localized: "选择要拷贝的文件或文件夹")
        panel.prompt = String(localized: "下一步")
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }

    /// A folder on the disk, as a path below its root ("" for the root), or nil if cancelled.
    static func destination(root: URL, volumeName: String) throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.title = String(localized: "选择拷到“\(volumeName)”上的哪个文件夹")
        panel.prompt = String(localized: "拷贝到这里")
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let folder = chosen.resolvingSymlinksInPath().standardizedFileURL.path
        if folder == base { return "" }
        guard folder.hasPrefix(base + "/") else { throw CopyPickerError.outsideDisk(volumeName) }
        return String(folder.dropFirst(base.count + 1))
    }
}

enum CopyPickerError: LocalizedError {
    case outsideDisk(String), noVolumeID
    var errorDescription: String? {
        switch self {
        case .outsideDisk(let name): String(localized: "请选择“\(name)”上的文件夹。")
        case .noVolumeID: String(localized: "无法识别这块盘的卷标识，不能续传拷贝。请用 Finder 拷贝。")
        }
    }
}
