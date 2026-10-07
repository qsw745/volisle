import SwiftUI
import VolisleCore

/// "Disk Info": what the system reports about the selected volume.
struct VolumeInfoView: View {
    /// Nil once the disk is gone while the sheet is open.
    let volume: VolumeSnapshot?
    let engineStatus: EngineStatus
    let bitLocker: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(Text("磁盘详情"), systemImage: "externaldrive.fill", tint: .blue) {
            if let volume {
                Form {
                    Section {
                        LabeledContent("名称", value: volume.name)
                        LabeledContent("文件系统", value: bitLocker ? String(localized: "BitLocker（NTFS）") : volume.displayFileSystem)
                        LabeledContent("设备", value: volume.deviceName)
                        LabeledContent("容量", value: formatBytes(volume.totalBytes))
                        LabeledContent("盘屿读写引擎", value: engineStatus.title)
                    } footer: {
                        notes(volume)
                    }
                }
                .sheetForm()
            } else {
                SheetPlaceholder(systemImage: "externaldrive.badge.xmark", title: Text("磁盘已断开"))
            }
        } buttons: {
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 440)
    }

    @ViewBuilder private func notes(_ volume: VolumeSnapshot) -> some View {
        let lines = [
            volume.mountState != .readWrite ? String(localized: "读写状态来自系统。盘屿启用读写前会先检查磁盘。") : nil,
            volume.fileSystem.lowercased() == "apfs" ? String(localized: "APFS 卷可能共享容器空间，各卷容量不能直接相加。") : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: "\n")).foregroundStyle(.secondary).sectionNote()
        }
    }
}
