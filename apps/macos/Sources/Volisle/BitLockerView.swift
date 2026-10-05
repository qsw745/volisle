import SwiftUI
import AppKit
import VolisleCore

/// A BitLocker partition: unlock it with its password or recovery key, then
/// use it in Finder (read-write when its checks pass, read-only otherwise). The secret is sent to the background component
/// for this unlock only and is not kept.
struct BitLockerDetail: View {
    let volume: VolumeSnapshot
    let bitLocker: BitLockerController
    let eject: () -> Void
    @State private var useRecoveryKey = false
    @State private var secret = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool
    private var mountURL: URL? { bitLocker.mountURL(for: volume) }
    private var working: Bool { bitLocker.isWorking(volume) }
    private var writable: Bool { bitLocker.isWritable(volume) }
    private var state: String {
        mountURL == nil ? String(localized: "BitLocker · 已锁定") : writable ? String(localized: "BitLocker · 可读写") : String(localized: "BitLocker · 只读")
    }
    /// Why it opened read-only, in words that fit a BitLocker partition (the
    /// Mac-side check does not reach inside one).
    private var readOnlyNote: String {
        switch bitLocker.readOnlyReason(for: volume) {
        case .ntfsDirty?: String(localized: "这块盘被标记为需要检查，所以以只读方式打开。请在 Windows 中检查磁盘（属性 → 工具 → 检查），安全弹出后再插回。")
        case let reason?: reason.errorDescription ?? ""
        case nil: String(localized: "已解锁，只读：可以在 Finder 中查看和复制文件，不能修改。锁定后需要再次输入密码。")
        }
    }
    /// The NTFS label inside, once unlocked.
    private var title: String {
        guard let mountURL, let name = try? mountURL.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty else { return volume.name }
        return name
    }
    private var space: (total: Int64, free: Int64)? {
        guard let mountURL, let values = try? mountURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0, free >= 0, free <= total else { return nil }
        return (Int64(total), Int64(free))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 18) {
                    Image(systemName: mountURL == nil ? "lock.fill" : "lock.open.fill").font(.system(size: 46, weight: .light))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(mountURL == nil ? .orange : .blue)
                        .frame(width: 58).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(.title.weight(.semibold)).textSelection(.enabled)
                        Text(state).font(.callout).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("存储空间"); Spacer(); Text(bytes(space?.total ?? volume.totalBytes)).foregroundStyle(.secondary) }
                    if let space {
                        ProgressView(value: Double(space.total - space.free), total: Double(space.total)).accessibilityLabel("已用存储空间")
                        Text("可用 \(bytes(space.free))").font(.caption).foregroundStyle(.secondary)
                    } else { Text("解锁后可查看可用空间").font(.caption).foregroundStyle(.secondary) }
                }
                if let mountURL { unlocked(mountURL) } else { locked }
            }.padding(36).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: useRecoveryKey) { secret = ""; error = nil; fieldFocused = true }
        .onChange(of: volume.id) { secret = ""; error = nil; useRecoveryKey = false }
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("解锁方式", selection: $useRecoveryKey) {
                Text("密码").tag(false)
                Text("恢复密钥").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            HStack(spacing: 12) {
                Group {
                    if useRecoveryKey {
                        TextField("恢复密钥", text: $secret, prompt: Text("000000-000000-000000-000000-000000-000000-000000-000000"))
                            .font(.body.monospacedDigit())
                    } else {
                        SecureField("密码", text: $secret, prompt: Text("BitLocker 密码"))
                    }
                }
                .textFieldStyle(.roundedBorder).focused($fieldFocused).disabled(working)
                .onSubmit { unlock() }
                Button("解锁", systemImage: "lock.open") { unlock() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || secret.isEmpty)
                Button("推出", systemImage: "eject") { eject() }.keyboardShortcut("e").disabled(working)
                if working { ProgressView().controlSize(.small).accessibilityLabel("正在解锁") }
            }.controlSize(.large)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                    .lineLimit(4)
            }
            Label(useRecoveryKey
                  ? String(localized: "恢复密钥是 48 位数字，保存在你的 Microsoft 账户（aka.ms/myrecoverykey）、打印件或当初保存的文件里。")
                  : String(localized: "解锁后可以在 Finder 中读写文件。密码只用于这次解锁，不会保存。"),
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).lineLimit(4)
        }
        .onAppear { fieldFocused = true }
    }

    private func unlocked(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("打开 Finder", systemImage: "folder") { NSWorkspace.shared.open(url) }
                    .keyboardShortcut("o").buttonStyle(.borderedProminent)
                // Only this partition: another partition on the same disk may be in use.
                Button("锁定", systemImage: "lock") { lock() }.keyboardShortcut("l").disabled(working)
                if working { ProgressView().controlSize(.small).accessibilityLabel("正在锁定") }
            }.controlSize(.large)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                    .lineLimit(4)
            }
            Label(writable ? String(localized: "已解锁，可读写：可以在 Finder 中拷贝、修改和删除文件。拔线前请先点“锁定”或在 Finder 中推出。锁定后需要再次输入密码。")
                           : readOnlyNote, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).lineLimit(5)
        }
    }

    private func unlock() {
        guard !working, !secret.isEmpty else { return }
        let value = secret, recovery = useRecoveryKey
        error = nil
        Task {
            do {
                let result = try await bitLocker.unlock(volume, recoveryKey: recovery, secret: value)
                secret = ""
                NSWorkspace.shared.open(result.url)
            } catch {
                self.error = error.localizedDescription
                fieldFocused = true
            }
        }
    }

    private func lock() {
        error = nil
        Task {
            do { try await bitLocker.lock(volume) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return String(localized: "未知") }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
}
