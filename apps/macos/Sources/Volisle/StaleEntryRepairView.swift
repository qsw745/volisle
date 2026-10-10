import SwiftUI
import VolisleCore

/// "Repair on This Mac": after "Check on This Mac" found folder entries that
/// name files or folders deleted since (stale entries). First a read-only look
/// at the whole disk; then, only when nothing else is wrong and the user
/// agrees, those entries are removed. Windows' disk check stays the safer way,
/// and the sheet says so before asking.
struct StaleEntryRepairView: View {
    let target: CheckMarkerTarget
    let repairer: StaleEntryRepairer
    /// Called after "OK" on a successful repair: turn writing on.
    let finished: () -> Void
    /// A repair interrupted earlier: "Check on This Mac" puts the disk back as
    /// it was before it, then checks again (and offers the repair again).
    let recheck: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case examining
        case examined(StaleEntryExamination)
        case repairing(StaleEntryExamination)
        case done(StaleEntryRepairResult)
        case failed(String)
        /// The read-only look itself did not complete: nothing was attempted.
        case examineFailed(String)
    }
    @State private var stage = Stage.examining
    /// The user agrees the entries go, knowing Windows' check is the safer way.
    @State private var accepted = false

    var body: some View {
        SheetScaffold(Text("在 Mac 上修复“\(target.name)”"),
                      subtitle: Text("检查发现这块盘的文件夹里有失效的条目。盘屿先只读检查，再告诉你能不能在 Mac 上修。"),
                      systemImage: "wrench.and.screwdriver", tint: .blue) {
            content
        } buttons: {
            Spacer()
            switch stage {
            case .examining, .repairing:
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isRepairing)
            case .examined(let found):
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if found.leftoverRestore {
                    Button("还原并重新检查") { dismiss(); recheck() }.keyboardShortcut(.defaultAction)
                } else if found.repairable {
                    Button("删除失效条目并开启读写") { repair(found) }
                        .keyboardShortcut(.defaultAction).disabled(!accepted)
                }
            case .done(let result):
                if result.removed > 0 {
                    Button("好") { dismiss(); finished() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .failed, .examineFailed:
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 620)
        .interactiveDismissDisabled(isRepairing)
        .task { await examine() }
    }

    private var isRepairing: Bool { if case .repairing = stage { true } else { false } }

    // MARK: Stages

    @ViewBuilder private var content: some View {
        switch stage {
        case .examining:
            SheetPlaceholder(title: Text("正在只读检查这块盘…"), message: Text("不会修改盘上的任何内容。文件较多时需要几分钟。"))
        case .repairing:
            SheetPlaceholder(title: Text("正在删除失效条目并检查…"),
                             message: Text("请不要拔下这块盘。要改动的部分会先原样备份，任何一步不通过都会还原；万一中途断开，下次检查这块盘时会先还原。"))
        case .done(let result):
            if result.restoredLeftover {
                SheetPlaceholder(systemImage: "arrow.uturn.backward.circle.fill", tint: .blue, title: Text("已还原到修复前"),
                                 message: Text("上次没有完成的修复已经撤销，这块盘已恢复为修复前的样子。需要的话，请重新打开“在 Mac 上检查…”。"))
            } else if result.removed > 0 {
                SheetPlaceholder(systemImage: "checkmark.circle.fill", tint: .green, title: Text("已修复，可以开启读写"),
                                 message: Text("删除了 \(result.removed) 条失效条目，检查了 \(result.checkedItems) 个文件和文件夹，没有发现问题。点“好”为这块盘开启读写。"))
            } else {
                SheetPlaceholder(systemImage: "checkmark.circle.fill", tint: .green, title: Text("没有需要修复的条目"),
                                 message: Text("这块盘上已经没有失效条目，没有做任何修改。可以点“在 Mac 上检查…”清除“需要检查”标记。"))
            }
        case .failed(let message):
            SheetPlaceholder(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: Text("没有修复"), message: Text(message))
        case .examineFailed(let message):
            SheetPlaceholder(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: Text("没能检查这块盘"),
                             message: Text(String(localized: "没有做任何修改。") + message))
        case .examined(let found):
            examined(found)
        }
    }

    private func examined(_ found: StaleEntryExamination) -> some View {
        Form {
            Section { verdict(found) }
            if !found.leftoverRestore {
                Section {
                    if found.staleEntries > 0 {
                        finding(ok: true, Text("\(found.staleEntries) 个目录条目已失效：指向的文件夹或文件已被删除"),
                                String(localized: "这些条目已经打不开：它们指向的位置在 Windows 上删除后，已经被别的文件使用或空着。通常是盘在 Windows 中没有安全弹出，最后一次整理文件夹没来得及写完。"))
                    }
                    if found.repairable {
                        finding(ok: true, Text("其余 \(found.checkedItems) 个文件和文件夹检查正常"), nil)
                        finding(ok: true, Text("只删除这些条目"),
                                String(localized: "文件内容、其他条目，以及这些条目指向的位置现在存放的文件，都不会改动。"))
                    } else {
                        finding(ok: false, Text("还有别的问题，或条目的位置不适合在 Mac 上删除"),
                                String(localized: "见下面的技术信息。"))
                    }
                    DisclosureGroup("技术信息") {
                        VStack(alignment: .leading, spacing: 4) {
                            if !found.folders.isEmpty {
                                Text("所在文件夹的记录号：\(found.folders.map { String($0) }.joined(separator: ", "))")
                            }
                            if found.reusedRecords > 0 { Text("其中 \(found.reusedRecords) 条指向的记录已被别的文件使用") }
                            if let detail = found.detail { Text("检查：\(detail)") }
                        }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("检查结果")
                }
            }
            if found.repairable {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet(String(localized: "更稳妥的办法是把盘接到 Windows，在“属性 → 工具 → 检查”中检查磁盘：Windows 的磁盘检查能处理更多种问题。"))
                        bullet(String(localized: "盘屿只删除上面这些已经打不开的条目，不做别的修复；删除前会先原样备份，任何一步不通过都会还原。"))
                        bullet(String(localized: "以后接到 Windows 时，建议仍在“属性 → 工具 → 检查”中检查一次。"))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    Toggle("我已了解：盘屿会删除这些失效条目，Windows 的磁盘检查是更稳妥的办法", isOn: $accepted)
                } header: {
                    Text("在 Mac 上删除失效条目")
                }
            }
        }
        .sheetForm()
        .frame(minHeight: found.repairable ? 640 : 420, maxHeight: 780)
    }

    // MARK: Pieces

    /// One sentence on top: what can be done with this disk.
    private func verdict(_ found: StaleEntryExamination) -> some View {
        let (icon, tint, title, detail): (String, Color, Text, String) =
            if found.leftoverRestore {
                ("arrow.uturn.backward.circle.fill", .orange, Text("上次的修复没有完成"),
                 String(localized: "上次在 Mac 上修复这块盘时中途断开了。盘屿会先把它原样还原到修复前的样子，再重新检查。"))
            } else if found.repairable {
                ("checkmark.seal.fill", .green, Text("可以在 Mac 上修复"),
                 String(localized: "删除这些失效条目后，盘屿会再检查一遍全部文件和文件夹，没有问题才开启读写。"))
            } else if found.staleEntries == 0 && found.detail == nil {
                ("checkmark.seal.fill", .green, Text("没有发现失效条目"),
                 String(localized: "可以点“在 Mac 上检查…”清除“需要检查”标记。"))
            } else {
                ("xmark.octagon.fill", .red, Text("需要在 Windows 中检查"), HelperDiskFailure.staleEntriesNotRepairable.errorDescription ?? "")
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

    // MARK: Actions

    private func examine() async {
        do { stage = .examined(try await repairer.examine(partition: target.bsdName)) }
        catch { stage = .examineFailed(error.errorDescription ?? error.localizedDescription) }
    }

    private func repair(_ found: StaleEntryExamination) {
        guard found.repairable && accepted else { return }
        stage = .repairing(found)
        Task {
            // Hidden or minimized, the sheet alone would not hold a quit back.
            let running = QuitGuard.begin(String(localized: "正在修复这块盘"))
            defer { QuitGuard.end(running) }
            do {
                stage = .done(try await repairer.repair(partition: target.bsdName, accepted: accepted))
            } catch {
                stage = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
