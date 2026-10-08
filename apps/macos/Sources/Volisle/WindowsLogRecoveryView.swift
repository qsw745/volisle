import SwiftUI
import VolisleCore

extension CheckMarkerTarget: Identifiable { var id: String { bsdName } }

/// "Recover on This Mac": a disk Windows let go of without Safe Removal.
/// First a read-only look at the disk: one verdict at the top, each finding
/// below, the technical details folded away. Then the one thing the disk
/// cannot tell — how it left Windows — asked of the user. Only an unplug while
/// Windows was running is replayed here; a log that will not replay is given
/// up only with the user's explicit agreement.
struct WindowsLogRecoveryView: View {
    let target: CheckMarkerTarget
    let recoverer: WindowsLogRecoverer
    /// Called after "OK" on a successful (or unneeded) recovery: turn writing on.
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case examining
        case examined(WindowsLogExamination)
        case recovering(WindowsLogExamination)
        case done(WindowsLogRecoveryResult)
        case failed(String)
        /// The read-only look itself did not complete: nothing was attempted.
        case examineFailed(String)
    }
    @State private var stage = Stage.examining
    @State private var answer: WindowsUnplugAnswer?
    /// Giving the log up: the user agrees Windows' unfinished changes go.
    @State private var acceptedLoss = false

    var body: some View {
        SheetScaffold(Text("在 Mac 上恢复“\(target.name)”"),
                      subtitle: Text("这块盘上次在 Windows 中没有安全弹出。盘屿先只读检查，再告诉你能怎样处理。"),
                      systemImage: "arrow.trianglehead.counterclockwise", tint: .blue) {
            content
        } buttons: {
            Spacer()
            switch stage {
            case .examining, .recovering:
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isRecovering)
            case .examined(let found):
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if found.logClean {
                    Button("开启读写") { dismiss(); finished() }.keyboardShortcut(.defaultAction)
                } else if found.replayable {
                    Button("补写并开启读写") { recover(found) }
                        .keyboardShortcut(.defaultAction).disabled(answer != .whileRunning)
                } else if found.discardable {
                    Button("放弃未写完的改动并开启读写") { recover(found) }
                        .keyboardShortcut(.defaultAction).disabled(answer != .whileRunning || !acceptedLoss)
                }
            case .done:
                Button("好") { dismiss(); finished() }.keyboardShortcut(.defaultAction)
            case .failed, .examineFailed:
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 620)
        .interactiveDismissDisabled(isRecovering)
        .task { await examine() }
    }

    private var isRecovering: Bool { if case .recovering = stage { true } else { false } }

    // MARK: Stages

    @ViewBuilder private var content: some View {
        switch stage {
        case .examining:
            SheetPlaceholder(title: Text("正在只读检查这块盘…"), message: Text("不会修改盘上的任何内容。"))
        case .recovering(let found):
            SheetPlaceholder(title: found.replayable ? Text("正在补写并检查…") : Text("正在清理日志…"),
                             message: Text("请不要拔下这块盘。要改动的部分会先原样备份，任何一步不通过都会还原。"))
        case .done(let result):
            SheetPlaceholder(systemImage: "checkmark.circle.fill", tint: .green, title: Text("已恢复，可以开启读写"),
                             message: Text(doneMessage(result)))
        case .failed(let message):
            SheetPlaceholder(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: Text("没有恢复"), message: Text(message))
        case .examineFailed(let message):
            SheetPlaceholder(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: Text("没能检查这块盘"),
                             message: Text(String(localized: "没有做任何修改。") + message))
        case .examined(let found):
            examined(found)
        }
    }

    private func examined(_ found: WindowsLogExamination) -> some View {
        Form {
            Section { verdict(found) }
            Section {
                finding(ok: !found.markedForCheck, Text("没有“需要检查”标记"),
                        found.markedForCheck ? String(localized: "Windows 曾发现这块盘有问题，不只是没有安全弹出。") : nil)
                finding(ok: !found.hibernated && !found.maintenancePending, Text("没有 Windows 休眠或未完成的维护"), nil)
                if found.logClean {
                    finding(ok: true, Text("NTFS 日志已经是完成状态"), nil)
                } else if found.replayable {
                    finding(ok: true, Text("可以按顺序补写"),
                            found.pendingChanges == 0
                                ? String(localized: "模拟补写成功：改动都已写在盘上，只需把日志标记为完成。")
                                : String(localized: "模拟补写成功：有 \(found.pendingChanges) 笔 Windows 已确认的改动等待写入。"))
                } else if found.logReadable {
                    finding(ok: false, Text("不能按顺序补写"), String(localized: "日志里的改动对不上盘上的现状，见下面的技术信息。"))
                } else {
                    finding(ok: false, Text("NTFS 日志读不出来"), nil)
                }
                if found.discardChecked {
                    finding(ok: found.discardPassed, Text("不补写，盘上也完整"),
                            found.discardPassed
                                ? String(localized: "检查了 \(found.checkedItems) 个文件和文件夹：记录都能读到，文件占用的空间都标记为已用。")
                                : String(localized: "检查发现问题，见下面的技术信息。"))
                }
                DisclosureGroup("技术信息") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("日志版本 \(found.logVersion)")
                        if let detail = found.detail { Text("ntfsrecover：\(detail)") }
                        if let detail = found.discardDetail { Text("检查：\(detail)") }
                        if found.heldBytes > 0 {
                            Text("标记为已用但没有文件使用：\(ByteCountFormatter.string(fromByteCount: found.heldBytes, countStyle: .file))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("检查结果")
            }
            if found.fitsUnplug {
                Section {
                    Picker("这块盘是怎么从 Windows 上拿下来的？", selection: $answer) {
                        Text("Windows 开着机，没有点“安全删除硬件”就直接拔了").tag(WindowsUnplugAnswer?.some(.whileRunning))
                        Text("Windows 关机、重启或睡眠之后才拔的").tag(WindowsUnplugAnswer?.some(.afterShutdown))
                        Text("记不清了").tag(WindowsUnplugAnswer?.some(.unsure))
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("这块盘是怎么从 Windows 上拿下来的？")
                } footer: {
                    answerNote(found).foregroundStyle(.secondary).sectionNote()
                }
            }
            if found.discardable && answer == .whileRunning {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet(String(localized: "拔线前最后几秒的改动可能没有生效，例如文件夹里显示的文件大小或时间还是旧的。"))
                        bullet(String(localized: "文件内容和上面检查过的结构不受影响。"))
                        if found.heldBytes > 0 {
                            bullet(String(localized: "约 \(ByteCountFormatter.string(fromByteCount: found.heldBytes, countStyle: .file)) 空间被 Windows 预留但没有用上，会一直显示为已用，直到在 Windows 中检查磁盘。"))
                        }
                        bullet(String(localized: "Linux 上的 NTFS-3G 遇到这种盘默认也是这样处理。下次接到 Windows 时，建议在“属性 → 工具 → 检查”中检查一次。"))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    Toggle("我知道 Windows 最后没写完的改动会被放弃", isOn: $acceptedLoss)
                } header: {
                    Text("放弃 Windows 没写完的改动")
                }
            }
        }
        .sheetForm()
        // A Form in a sheet sizes to its first rows: keep the question and the
        // agreement in view rather than scrolled out of it.
        .frame(minHeight: found.fitsUnplug ? (found.discardable ? 720 : 600) : 420, maxHeight: 780)
    }

    // MARK: Pieces

    /// One sentence on top: what can be done with this disk.
    private func verdict(_ found: WindowsLogExamination) -> some View {
        let (icon, tint, title, detail): (String, Color, Text, String) =
            if found.logClean {
                ("checkmark.seal.fill", .green, Text("日志已经是完成状态"), String(localized: "不需要补写，可以直接开启读写。"))
            } else if found.replayable {
                ("checkmark.seal.fill", .green, Text("可以在 Mac 上补写"),
                 String(localized: "和 Windows 下次插上这块盘时一样，把没写完的改动补上，再开启读写。"))
            } else if found.discardable {
                ("exclamationmark.triangle.fill", .orange, Text("补写不了，但盘上数据完整"),
                 String(localized: "可以放弃 Windows 最后没写完的改动，然后开启读写。"))
            } else {
                ("xmark.octagon.fill", .red, Text("需要接回 Windows 处理"), found.refusal?.errorDescription ?? "")
            }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func answerNote(_ found: WindowsLogExamination) -> some View {
        switch answer {
        case .whileRunning where found.discardable:
            Text("清掉日志前，盘屿会把要改动的部分原样备份，任何一步不通过都会原样还原。")
        case .whileRunning:
            Text("补写前，盘屿会把要改动的部分原样备份；补写后检查全部文件记录，任何一步不通过都会原样还原。和 Windows 一样，拔线那一刻正在写的文件可能不完整。")
        case .afterShutdown:
            Text("Windows 10/11 默认开着“快速启动”：关机或睡眠时，一部分改动只留在那台 Windows 里，盘上看不出来，只有它开机后才会写回盘上。在 Mac 上处理会丢掉这些改动，所以请把盘接回那台 Windows 开机，用“安全删除硬件”弹出后再插回。")
        case .unsure:
            Text("记不清时按关机处理更稳妥：请把盘接回那台 Windows 开机，用“安全删除硬件”弹出后再插回。暂时没有条件的话，盘现在可以只读打开，需要的文件可以先拷出来。")
        case nil:
            Text("盘上看不出是直接拔线，还是 Windows 开着“快速启动”关机后才拔，所以需要你确认。")
        }
    }

    private func finding(ok: Bool, _ title: Text, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange).frame(width: 18)
                .accessibilityLabel(ok ? String(localized: "符合") : String(localized: "不符合"))
            VStack(alignment: .leading, spacing: 3) {
                title
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func doneMessage(_ result: WindowsLogRecoveryResult) -> String {
        if result.discarded {
            var text = String(localized: "已放弃 Windows 没写完的改动，检查了 \(result.checkedItems) 个文件和文件夹，文件占用的空间都标记正确。")
            if result.heldBytes > 0 {
                text += String(localized: "另有约 \(ByteCountFormatter.string(fromByteCount: result.heldBytes, countStyle: .file)) 空间被 Windows 预留但没有用上，不影响数据，在 Windows 中检查磁盘可以收回。")
            }
            return text + String(localized: "点“好”为这块盘开启读写。")
        }
        if result.replayed == 0 && result.checkedItems == 0 {
            return String(localized: "这块盘的日志已经是完成状态，不需要补写。点“好”为它开启读写。")
        }
        return String(localized: "补写了 \(result.replayed) 笔改动，检查了 \(result.checkedItems) 个文件和文件夹，没有发现问题。点“好”为这块盘开启读写。")
    }

    // MARK: Actions

    private func examine() async {
        do { stage = .examined(try await recoverer.examine(partition: target.bsdName)) }
        catch { stage = .examineFailed(error.errorDescription ?? error.localizedDescription) }
    }

    private func recover(_ found: WindowsLogExamination) {
        guard answer == .whileRunning, found.replayable || acceptedLoss else { return }
        stage = .recovering(found)
        let accepted = acceptedLoss
        Task {
            // Hidden or minimized, the sheet alone would not hold a quit back.
            let running = QuitGuard.begin(String(localized: "正在补写这块盘"))
            defer { QuitGuard.end(running) }
            do {
                stage = .done(found.replayable
                    ? try await recoverer.recover(partition: target.bsdName, answer: .whileRunning)
                    : try await recoverer.discard(partition: target.bsdName, answer: .whileRunning, accepted: accepted))
            } catch {
                stage = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
