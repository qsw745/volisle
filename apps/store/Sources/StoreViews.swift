// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

struct StoreMainView: View {
    @Bindable var disks: StoreDisks
    @State private var selection: StoreVolume.ID?

    /// Nothing chosen yet: a mounted volume before one that is only connected.
    private var selected: StoreVolume? {
        disks.volumes.first { $0.id == selection } ?? disks.volumes.first { $0.mountPoint != nil } ?? disks.volumes.first
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                ForEach(devices, id: \.self) { device in
                    Section(device) {
                        ForEach(disks.volumes.filter { $0.device == device }) { volume in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.name)
                                    Text(volume.stateSummary).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "externaldrive") }
                            .tag(volume.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            // The sidebar is the app's only navigation and is pinned open: no button that would do nothing.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    StoreBrandMark()
                    Text("盘屿").font(.callout.weight(.semibold))
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
                }
                .padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                if disks.extensionState == .unavailable {
                    StoreNotice(title: String(localized: "暂时无法读取扩展状态"),
                                detail: String(localized: "可以到“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”里确认“盘屿 NTFS”已经打开。"),
                                actionTitle: "打开系统设置", action: disks.openExtensionSettings)
                    Divider()
                }
                if disks.websiteVersionInstalled && !disks.hidesWebsiteNotice {
                    StoreNotice(title: String(localized: "这台 Mac 上还装着官网版盘屿"),
                                detail: String(localized: "两个版本只用一个就够了。同时使用时，磁盘可能被另一个版本接走，出现推出失败。不用官网版的话，先在它的设置里移除后台组件，再把它移到废纸篓。"),
                                actionTitle: "不再提示") { disks.hidesWebsiteNotice = true }
                    Divider()
                }
                if let volume = selected {
                    StoreVolumeDetail(volume: volume, extensionEnabled: disks.extensionState == .enabled,
                                      ejecting: disks.ejecting.contains(volume.id),
                                      show: { disks.showInFinder(volume) }, eject: { disks.eject(volume) })
                } else {
                    ContentUnavailableView {
                        Label("插入 Windows 格式的磁盘", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("NTFS 磁盘接上后会自动出现在访达里，可以直接读写。")
                    }
                }
                if let error = disks.lastError {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
                }
            }
        }
    }

    private var devices: [String] {
        disks.volumes.reduce(into: [String]()) { if !$0.contains($1.device) { $0.append($1.device) } }
    }
}

struct StoreNotice: View {
    let title: String
    let detail: String
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3).accessibilityHidden(true)
            // The text takes the width the button leaves. Sized from its ideal width instead,
            // a long detail grew the bar taller than the window and nothing in it was drawn.
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action).fixedSize()
        }
        .padding(14).background(.bar)
    }
}

struct StoreVolumeDetail: View {
    let volume: StoreVolume
    let extensionEnabled: Bool
    let ejecting: Bool
    let show: () -> Void
    let eject: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(volume.name).font(.title.weight(.semibold)).textSelection(.enabled)
                        Text("NTFS · \(volume.stateSummary)").font(.callout).foregroundStyle(.secondary)
                        if let size = volume.size, let free = volume.free, size > 0 {
                            ProgressView(value: Double(max(0, size - free)), total: Double(size)).accessibilityLabel("已用存储空间")
                            Text("可用 \(storeBytes(free))，共 \(storeBytes(size))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("容量 \(storeBytes(volume.size))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    // A disk the website build is writing to is ejected there, where its session ends properly.
                    Button("在访达中显示", action: show).disabled(volume.mountPoint == nil || volume.driver == .website)
                    Button("推出", action: eject).disabled(volume.mountPoint == nil || ejecting || volume.driver == .website)
                    if ejecting { ProgressView().controlSize(.small).accessibilityLabel("正在推出") }
                }
                if let recovery = volume.recovery {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recovery.title)
                            Text(recovery.advice).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notes: [String] {
        if volume.mountPoint == nil {
            return [String(localized: "这块盘还没有挂载。拔下后重新接上，或在“磁盘工具”里选择“装载”。")]
        }
        switch volume.driver {
        case .volisle:
            guard let explanation = volume.explanation else {
                return [String(localized: "可以直接在访达里拷贝、修改和删除文件。用完后先推出，再拔下磁盘。"),
                        String(localized: "盘屿更新时会中断正在读写的磁盘，更新前请先推出。")]
            }
            return [explanation.title, explanation.advice]
        case .system where extensionEnabled:
            return [String(localized: "这块盘现在由系统挂载，盘屿没有接管它，文件可以照常读取。"),
                    String(localized: "如果它是在打开盘屿的扩展之前接上的，推出后重新接上即可。否则说明盘屿打不开这块盘：请接回 Windows 检查磁盘，安全弹出后再接回 Mac。")]
        case .system:
            return [String(localized: "这块盘现在由系统挂载。打开盘屿的文件系统扩展后重新接上，就可以读写。")]
        case .website:
            return [String(localized: "这块盘现在由官网版盘屿挂载，读写和推出请在官网版里操作。"),
                    String(localized: "两个版本不需要同时使用。想改用这个版本，先在官网版里推出这块盘并退出官网版，再重新接上。")]
        }
    }
}

extension StoreVolume {
    var stateSummary: String {
        if mountPoint == nil { return String(localized: "未挂载") }
        if driver == .website { return String(localized: "官网版盘屿") }
        if driver == .system { return readOnly ? String(localized: "只读（系统挂载）") : String(localized: "系统挂载") }
        return readOnly ? String(localized: "只读") : String(localized: "可读写")
    }
}

struct StoreSettingsView: View {
    @Bindable var disks: StoreDisks

    var body: some View {
        Form {
            Section("通用") {
                Toggle("默认只读", isOn: $disks.preferReadOnly)
                Text("打开后，接上的 NTFS 磁盘只能读取、不会被写入。已经接着的磁盘要推出后重新接上才会生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("更新") {
                Text("盘屿更新时，系统会先结束它的文件系统扩展：正在读写的磁盘会像被拔下一样中断，最后约 20 秒写入的内容会退回。更新前请先推出磁盘。")
                    .font(.callout)
                Text("如果你经常长时间读写磁盘，可以在 App Store 的设置里关闭自动更新，改成用完磁盘后手动更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link("盘屿帮助", destination: StoreLink.help)
                Link("提交反馈…", destination: StoreLink.feedback)
                Link("源代码与开源许可（GNU GPL v2）", destination: StoreLink.source)
                Text("盘屿是自由软件，NTFS 读写使用 NTFS-3G。许可证全文和对应源码见上面的链接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
