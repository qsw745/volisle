import SwiftUI
import VolisleCore

/// Erase an external USB disk, or one of its partitions, as NTFS.
struct EraseDiskView: View {
    var discovery: DiskDiscovery
    var mountCycle: MountCycleClient
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
    private var affected: [ErasePartition] {
        guard let target else { return [] }
        return wholeDisk ? target.partitions : target.partitions.filter { $0.bsdName == partition }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("抹掉为 NTFS").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(eraser.isWorking)
            }
            Text("抹掉会删除所选磁盘或分区上的全部数据，且无法撤销。完成后可在 Windows 和 Mac 上读写。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView("正在读取外接磁盘…").frame(maxWidth: .infinity, minHeight: 200)
            } else if eraser.targets.isEmpty {
                ContentUnavailableView("没有可抹掉的外接磁盘", systemImage: "externaldrive",
                                       description: Text("连接 USB 硬盘或 U 盘后点“刷新”。"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                form
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if finished { Label("已抹掉为 NTFS。盘屿会自动检查并开启读写。", systemImage: "checkmark.circle").font(.callout) }
            HStack {
                Button("刷新") { Task { await reload() } }.disabled(eraser.isWorking)
                Spacer()
                if eraser.isWorking { ProgressView().controlSize(.small); Text("正在抹掉，请勿拔出磁盘…").font(.callout) }
                Button("抹掉…", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent).disabled(!canErase)
            }
        }
        .padding(24).frame(width: 560).frame(minHeight: 470)
        .task { await reload() }
        .onChange(of: selected) { _, _ in resetForTarget() }
        .onChange(of: wholeDisk) { _, _ in typed = ""; error = nil }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("抹掉", role: .destructive) { Task { await erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除以下全部数据，无法撤销：\(affected.map(describe).joined(separator: String(localized: "、")))")
        }
    }

    @ViewBuilder private var form: some View {
        Picker("磁盘", selection: $selected) {
            ForEach(eraser.targets) { t in
                Text("\(t.model) · \(bytes(t.size)) · \(t.bsdName)").tag(Optional(t.bsdName)).disabled(!t.isEligible)
            }
        }
        if let target {
            if let refusal = target.refusal {
                Label(refusal.message, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(target.partitions) { p in
                        Text(describe(p)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("范围", selection: $wholeDisk) {
                    Text("整块磁盘").tag(true)
                    Text("单个分区").tag(false).disabled(partitions.isEmpty)
                }.pickerStyle(.segmented)
                if wholeDisk {
                    Picker("分区方案", selection: $scheme) {
                        Text("GUID（推荐）").tag(PartitionScheme.gpt)
                        Text("MBR（兼容较旧的电视、车机等设备）").tag(PartitionScheme.mbr)
                    }
                    if scheme == .mbr && !mbrAllowed {
                        Text("MBR 不支持大于 2 TB 的磁盘，请选择 GUID。").font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Picker("分区", selection: $partition) {
                        ForEach(partitions) { p in Text(describe(p)).tag(Optional(p.bsdName)) }
                    }
                }
                TextField("名称", text: $name)
                if let nameError { Text(nameError).font(.caption).foregroundStyle(.red) }
                if let requiredName {
                    TextField("输入“\(requiredName)”以确认抹掉 Mac 格式的卷", text: $typed)
                }
            }
        }
    }

    private var confirmTitle: String {
        guard let target else { return "" }
        return wholeDisk ? String(localized: "抹掉“\(target.model)”上的所有数据？") : String(localized: "抹掉这个分区上的所有数据？")
    }

    private func describe(_ p: ErasePartition) -> String {
        let name = p.name.flatMap { $0.isEmpty ? nil : $0 } ?? p.bsdName
        return String(localized: "\(name)（\(p.content)，\(bytes(p.size))）")
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }

    private func reload() async {
        loading = true
        await eraser.refresh()
        loading = false
        if target == nil { selected = eraser.targets.first(where: \.isEligible)?.bsdName ?? eraser.targets.first?.bsdName }
    }

    private func resetForTarget() {
        typed = ""; error = nil; finished = false
        partition = partitions.first?.bsdName
        if !mbrAllowed { scheme = .gpt }
        wholeDisk = true
    }

    private func erase() async {
        guard let target, let scope else { return }
        error = nil; finished = false
        do {
            try await eraser.erase(target, scope: scope, name: name, typedConfirmation: typed) {
                // End Volisle's own write sessions on this device; diskutil unmounts the rest.
                let prefix = target.bsdName + "s"
                for volume in discovery.volumes where volume.bsdName.hasPrefix(prefix) {
                    try await mountCycle.prepareForEject(volume)
                }
            }
            finished = true
            discovery.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
