import SwiftUI
import VolisleCore

/// Erase an external USB disk, or one of its partitions, as NTFS.
struct EraseDiskView: View {
    var discovery: DiskDiscovery
    var mountCycle: MountCycleClient
    /// The whole disk selected in the sidebar (e.g. "disk8"): offered first, so
    /// the sheet never defaults to another, lower-numbered disk.
    var preferredDisk: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var eraser = DiskEraser()
    @State private var selected: String?
    @State private var wholeDisk = true
    @State private var scheme = PartitionScheme.gpt
    @State private var partition: String?
    @State private var name = "NTFS"
    @State private var typed = ""
    @State private var confirming = false
    @State private var error: String?
    @State private var finished = false
    @State private var loading = true

    private var target: EraseTarget? { eraser.targets.first { $0.bsdName == selected } }
    private var partitions: [ErasePartition] { target?.partitions.filter(\.isSelectable) ?? [] }
    private var scope: EraseScope? {
        if wholeDisk { return .wholeDisk(scheme) }
        return partition.map { .partition($0) }
    }
    private var requiredName: String? { target.flatMap { t in scope.flatMap { DiskErasePlanner.confirmationName(target: t, scope: $0) } } }
    /// MBR partitions cannot address beyond 2 TiB.
    private var mbrAllowed: Bool { (target?.size ?? 0) <= 2 * 1024 * 1024 * 1024 * 1024 }
    private var nameError: String? {
        do { try DiskErasePlanner.validate(name: name); return nil } catch { return error.errorDescription }
    }
    private var canErase: Bool {
        guard let target, target.isEligible, scope != nil, nameError == nil, !eraser.isWorking else { return false }
        if wholeDisk && scheme == .mbr && !mbrAllowed { return false }
        return requiredName.map { typed == $0 } ?? true
    }
    /// The partitions shown to the user: the EFI system partition is not their data.
    private var shownPartitions: [ErasePartition] { target?.partitions.filter { $0.content != "EFI" } ?? [] }
    private var affected: [ErasePartition] {
        wholeDisk ? shownPartitions : target?.partitions.filter { $0.bsdName == partition } ?? []
    }

    var body: some View {
        SheetScaffold(Text("抹掉为 NTFS"),
                      subtitle: Text("抹掉会删除所选磁盘或分区上的全部数据，且无法撤销。完成后可在 Windows 和 Mac 上读写。"),
                      systemImage: "externaldrive.fill", tint: .red) {
            if loading {
                SheetPlaceholder(title: Text("正在读取外接磁盘…"))
            } else if eraser.targets.isEmpty {
                SheetPlaceholder(systemImage: "externaldrive.badge.questionmark", title: Text("没有可抹掉的外接磁盘"),
                                 message: Text("连接 USB 硬盘或 U 盘后点“刷新”。"))
            } else {
                form
            }
            status
        } buttons: {
            if eraser.isWorking {
                ProgressView().controlSize(.small)
                Text("正在抹掉，请勿拔出磁盘…").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("刷新") { Task { await reload() } }.disabled(loading)
            }
            Spacer()
            if finished {
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            } else {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(eraser.isWorking)
                // Not the default button: Return must never start erasing.
                Button("抹掉…", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(!canErase)
            }
        }
        .frame(width: 560)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .volisleCloseSheetsForQuit)) { _ in
            if !eraser.isWorking { dismiss() }
        }
        .onChange(of: selected) { _, _ in resetForTarget() }
        .onChange(of: wholeDisk) { _, _ in typed = ""; error = nil; finished = false }
        // Changing anything after a successful erase offers erasing again.
        .onChange(of: scheme) { _, _ in finished = false }
        .onChange(of: partition) { _, _ in finished = false }
        .onChange(of: name) { _, _ in finished = false }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("抹掉", role: .destructive) { Task { await erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            let names = affected.map(describe)
            Text(names.isEmpty ? String(localized: "将删除这块磁盘上的全部数据，无法撤销。")
                 : String(localized: "将删除以下全部数据，无法撤销：\(names.joined(separator: String(localized: "、")))"))
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("磁盘", selection: $selected) {
                    ForEach(eraser.targets) { t in
                        Text("\(t.model) · \(bytes(t.size)) · \(t.bsdName)").tag(Optional(t.bsdName)).disabled(!t.isEligible)
                    }
                }
                if let target {
                    if let refusal = target.refusal {
                        Label(refusal.message, systemImage: "lock.fill").foregroundStyle(.secondary)
                    } else {
                        LabeledContent("现有内容") {
                            VStack(alignment: .trailing, spacing: 3) {
                                ForEach(shownPartitions) { Text(describe($0)) }
                                if shownPartitions.isEmpty { Text("没有分区") }
                            }
                        }
                    }
                }
            }
            .disabled(eraser.isWorking)
            if let target, target.isEligible {
                Section {
                    Picker("抹掉范围", selection: $wholeDisk) {
                        Text("整块磁盘").tag(true)
                        Text("单个分区").tag(false).disabled(partitions.isEmpty)
                    }.pickerStyle(.segmented)
                    if wholeDisk {
                        Picker("分区方案", selection: $scheme) {
                            Text("GUID（推荐）").tag(PartitionScheme.gpt)
                            Text("MBR（兼容较旧的电视、车机等设备）").tag(PartitionScheme.mbr)
                        }
                    } else {
                        Picker("分区", selection: $partition) {
                            ForEach(partitions) { p in Text(describe(p)).tag(Optional(p.bsdName)) }
                        }
                    }
                    LabeledContent("新卷名称") { TextField("新卷名称", text: $name).formField() }
                    if let requiredName {
                        LabeledContent("确认名称") {
                            TextField("确认名称", text: $typed, prompt: Text(requiredName)).formField()
                        }
                    }
                } footer: {
                    notes
                }
                .disabled(eraser.isWorking)
            }
        }
        .sheetForm()
    }

    /// Outside the form: a sheet is never taller than its window, and the form
    /// scrolls then, but what went wrong must stay in view.
    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                .sheetStatus()
        } else if finished {
            Label {
                Text("已抹掉为 NTFS。盘屿会自动检查并开启读写。")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .sheetStatus()
        }
    }

    /// What blocks erasing, and what to type to confirm a Mac volume.
    @ViewBuilder private var notes: some View {
        let mbrTooLarge = wholeDisk && scheme == .mbr && !mbrAllowed
        if mbrTooLarge || nameError != nil || requiredName != nil {
            VStack(alignment: .leading, spacing: 4) {
                if mbrTooLarge { Text("MBR 不支持大于 2 TB 的磁盘，请选择 GUID。").foregroundStyle(.red) }
                if let nameError { Text(nameError).foregroundStyle(.red) }
                if let requiredName {
                    Text("这块磁盘上有 Mac 格式的卷。输入“\(requiredName)”确认要抹掉它。").foregroundStyle(.secondary)
                }
            }.sectionNote()
        }
    }

    private var confirmTitle: String {
        guard let target else { return "" }
        return wholeDisk ? String(localized: "抹掉“\(target.model)”（\(bytes(target.size))，\(target.bsdName)）上的所有数据？")
            : String(localized: "抹掉“\(target.model)”（\(target.bsdName)）上这个分区的所有数据？")
    }

    private func describe(_ p: ErasePartition) -> String {
        let name = p.name.flatMap { $0.isEmpty ? nil : $0 } ?? p.bsdName
        return String(localized: "\(name)（\(kind(p))，\(bytes(p.size))）")
    }

    /// The file system when macOS knows the volume, else what the partition type says.
    private func kind(_ p: ErasePartition) -> String {
        switch discovery.volumes.first(where: { $0.bsdName == p.bsdName })?.fileSystem.lowercased() {
        case "ntfs"?: return "NTFS"
        case "exfat"?: return "exFAT"
        case "msdos"?: return "FAT"
        case "apfs"?: return "APFS"
        case "hfs"?: return String(localized: "Mac OS 扩展")
        default: break
        }
        switch p.content {
        case "Microsoft Basic Data", "Windows_NTFS": return String(localized: "Windows 分区")
        case "Apple_APFS": return "APFS"
        case "Apple_HFS", "Apple_HFSX": return String(localized: "Mac OS 扩展")
        case "DOS_FAT_32", "Windows_FAT_32", "DOS_FAT_16", "DOS_FAT_12": return "FAT"
        default: return p.content
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }

    private func reload() async {
        loading = true
        await eraser.refresh()
        loading = false
        if target == nil {
            selected = eraser.targets.first { $0.bsdName == preferredDisk }?.bsdName
                ?? eraser.targets.first(where: \.isEligible)?.bsdName ?? eraser.targets.first?.bsdName
        }
    }

    private func resetForTarget() {
        typed = ""; error = nil; finished = false
        partition = partitions.first?.bsdName
        if !mbrAllowed { scheme = .gpt }
        wholeDisk = true
    }

    private func erase() async {
        guard let target, let scope else { return }
        let running = QuitGuard.begin(String(localized: "正在抹掉磁盘"))
        defer { QuitGuard.end(running) }
        error = nil; finished = false
        do {
            try await eraser.erase(target, scope: scope, name: name, typedConfirmation: typed) {
                // End Volisle's own write session if it is on this device (another
                // disk's session stays); diskutil unmounts the rest. Unlocked
                // BitLocker volumes are unknown to it: lock them first.
                let prefix = target.bsdName + "s"
                if let writing = discovery.volumes.first(where: { $0.bsdName.hasPrefix(prefix) && $0.bsdName == mountCycle.operation?.disk.bsdName }) {
                    try await mountCycle.prepareForEject(writing)
                }
                try UpdateMaintenance.lockBitLockerVolumes(onDisk: target.bsdName)
            }
            finished = true
            discovery.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
