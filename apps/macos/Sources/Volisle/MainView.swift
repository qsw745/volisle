import SwiftUI
import AppKit
import VolisleCore

struct MainView: View {
    var discovery: DiskDiscovery
    var engineStatus: EngineStatus
    var actions: DiskActions
    var autoMount: AutoMountController
    var manualMount: ManualMountController
    var mountCycle: MountCycleClient
    var helperService: HelperServiceController
    var refreshRuntime: () async -> Void
    @State private var showSetup = false
    @State private var setupOffered = false
    @State private var selection: VolumeIdentity?
    @State private var operationError: String?
    @State private var checkingVolume: VolumeSnapshot?
    @State private var writingVolume: VolumeSnapshot?
    @State private var showDetails = false
    @State private var showRecovery = false
    @State private var showErase = false
    @State private var recovering = false
    @State private var ejecting: VolumeSnapshot?
    @State private var markerTarget: CheckMarkerTarget?
    @State private var markerClearer = CheckMarkerClearer()
    @State private var markerResult: String?
    @State private var bitLocker = BitLockerController()
    /// A Windows-disk assistant: other file systems belong to Finder and Disk Utility.
    private var volumes: [VolumeSnapshot] { discovery.volumes.filter { $0.isNTFS || bitLocker.isBitLocker($0) } }
    /// Partitions macOS could not read that may be BitLocker; asked again when the helper connects.
    private var bitLockerCandidates: [String] {
        discovery.volumes.filter(\.isUnrecognizedWindows).map { $0.identity.connection.uuidString } + [String(describing: helperService.state), "\(showErase)"]
    }
    private var selected: VolumeSnapshot? { volumes.first { $0.id == selection } }
    private var bottomMessage: String? {
        if markerClearer.isWorking { return String(localized: "正在 Mac 上检查磁盘，请勿拔出…") }
        if let error = mountCycle.lastError { return named(error) }
        if mountCycle.isBusy { return named(String(localized: "正在检查磁盘，请稍候…")) }
        let errors: [String?] = [actions.lastError, autoMount.lastError, manualMount.lastError]
        if let error = errors.compactMap({ $0 }).first { return error }
        if let notice = actions.notice { return notice }
        if let notice = mountCycle.notice { return named(notice) }
        return manualMount.notice
    }
    /// The disk the read-write session (and the bar's button) is about, when
    /// another one is selected, e.g. an unlocked BitLocker partition.
    private var cycleDiskName: String? {
        guard let operation = mountCycle.operation, let selected,
              operation.disk.registryID != selected.identity.mediaRegistryID else { return nil }
        return discovery.volumes.first { $0.identity.mediaRegistryID == operation.disk.registryID }?.name
    }
    private func named(_ message: String) -> String {
        guard let name = cycleDiskName else { return message }
        return String(localized: "“\(name)”：\(message)")
    }
    /// The disk refused for writing only because NTFS marks it "needs check".
    /// Taken from the refused operation itself, so a disk list that has not
    /// caught up with the unmount/restore does not hide the button.
    private var checkMarkerTarget: CheckMarkerTarget? {
        guard !markerClearer.isWorking, bottomMessage == HelperDiskFailure.ntfsDirty.errorDescription else { return nil }
        let external = volumes.filter(CheckMarkerClearer.applies(to:))
        let bsd = mountCycle.operation?.disk.bsdName
            ?? selected.flatMap { CheckMarkerClearer.applies(to: $0) ? $0.bsdName : nil }
            ?? (external.count == 1 ? external.first?.bsdName : nil)
        guard let bsd, CheckMarkerClearer.applies(toPartition: bsd) else { return nil }
        let known = discovery.volumes.first { $0.bsdName == bsd }
        return CheckMarkerTarget(bsdName: bsd, name: known?.name ?? bsd, volumeUUID: known?.identity.volumeUUID)
    }
    /// Survives a relaunch: the helper keeps the last refused operation.
    private func markedNeedsCheck(_ volume: VolumeSnapshot) -> Bool {
        guard let refusal = mountCycle.lastRefusal, refusal.failure == .ntfsDirty else { return false }
        return refusal.disk.bsdName == volume.bsdName && refusal.disk.registryID == volume.identity.mediaRegistryID
    }
    private func checkTarget(for volume: VolumeSnapshot) -> CheckMarkerTarget {
        CheckMarkerTarget(bsdName: volume.bsdName, name: volume.name, volumeUUID: volume.identity.volumeUUID)
    }
    private var groups: [String] { Array(Set(volumes.map(\.deviceGroup))).sorted() }
    var body: some View {
        // The disk list is the window's main content: keep it visible. macOS 26's
        // reveal animation swaps the sidebar content in abruptly at the end.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                ForEach(groups, id: \.self) { group in
                    Section(volumes.first { $0.deviceGroup == group }?.deviceName ?? String(localized: "外接设备")) {
                        ForEach(volumes.filter { $0.deviceGroup == group }) { volume in
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(volume.name).lineLimit(1)
                                    Text(sidebarState(volume)).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: bitLocker.isBitLocker(volume) ? (bitLocker.mountURL(for: volume) == nil ? "lock" : "lock.open") : "externaldrive") }
                            .padding(.vertical, 5).tag(volume.id)
                        }
                    }
                }
            }
            .navigationTitle("我的磁盘")
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 280)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) { BrandMark(); Text("盘屿").font(.callout.weight(.semibold)); Spacer(); SettingsLink { Image(systemName: "gearshape") }.help("设置").accessibilityLabel("设置") }
                    .buttonStyle(.plain).padding()
            }
        } detail: {
            // Only the detail column: across the whole split view the bar covered the sidebar's settings button.
            VStack(spacing: 0) {
            // Not while the setup sheet says the same. Texts here use lineLimit, not
            // fixedSize: measured at a tiny width inside NavigationSplitView it grew the
            // whole window content past both edges (columns shifted under the title bar).
            if let reason = setupReason, !showSetup {
                // First launch: without this, a new user only sees "insert a disk"
                // and never learns that setup is unfinished.
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("还差一步：完成首次设置").font(.headline)
                        Text(reason).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                    Button("完成设置…") { showSetup = true }.buttonStyle(.borderedProminent)
                }.padding(14).background(.bar)
                Divider()
            }
            Group {
                if let selected, bitLocker.isBitLocker(selected) {
                    BitLockerDetail(volume: selected, bitLocker: bitLocker) {
                        if discovery.volumes.filter({ $0.deviceGroup == selected.deviceGroup }).count > 1 { ejecting = selected }
                        else { eject(selected) }
                    }
                } else if let selected {
                    let holder = writeHolder(for: selected)
                    VolumeDetail(volume: selected, busy: recovering || (mountCycle.blocksActions && holder == nil) || actions.isBusy(selected) || autoMount.isBusy(selected) || manualMount.isBusy(selected),
                                 waitingFor: holder.map { WriteSlotWait(holder: $0, automatic: autoMount.preferences.isEnabled(selected.identity)) },
                                 backgroundNeedsAttention: mountCycle.needsAttention,
                                 controlledWrite: mountCycle.isWritable(selected),
                                 testDirectory: PhysicalWriteAvailability.testDirectory(for: selected),
                                 requiresVerification: manualMount.requiresVerification(selected),
                                 verifyingRecovery: mountCycle.isBusy || manualMount.activeDevices.contains(selected.deviceGroup),
                                 verifyRecovery: { Task {
                                     if mountCycle.needsAttention { await mountCycle.recover() }
                                     else { await manualMount.verifyRecovery(selected) }
                                 } },
                                 capability: engineStatus.capability, checkingEngine: engineStatus.isChecking, enableWriting: {
                        if DailyWriteAvailability.allows(selected) || PhysicalWriteAvailability.testDirectory(for: selected) != nil { writingVolume = selected }
                        else { Task { await manualMount.enable(selected) } }
                    }, openFinder: {
                        if mountCycle.isWritable(selected) {
                            Task {
                                do { NSWorkspace.shared.open(try await mountCycle.verifiedWritableURL(for: selected)) }
                                catch { operationError = error.localizedDescription }
                            }
                        } else {
                            do { try FinderService.open(selected, discovery: discovery) }
                            catch { operationError = error.localizedDescription }
                        }
                    }, eject: {
                        // Like Finder: one volume ejects directly; confirm only when siblings go too.
                        if discovery.volumes.filter({ $0.deviceGroup == selected.deviceGroup }).count > 1 { ejecting = selected }
                        else { eject(selected) }
                    }, needsCheck: markedNeedsCheck(selected), checkOnMac: { markerTarget = checkTarget(for: selected) })
                } else {
                    ContentUnavailableView {
                        Label(discovery.error == nil ? "插入 Windows 格式的磁盘" : "暂时无法读取磁盘", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text(discovery.error ?? String(localized: "插入 NTFS 格式的移动硬盘或 U 盘，盘屿会自动检查并开启读写。"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                if let message = bottomMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: mountCycle.lastError == nil && actions.lastError == nil && autoMount.lastError == nil && manualMount.lastError == nil ? "checkmark.circle" : "exclamationmark.circle")
                        Text(message).lineLimit(4)
                        Spacer()
                        if let target = checkMarkerTarget {
                            Button("在 Mac 上检查…") { markerTarget = target }
                        }
                        if mountCycle.isBusy || markerClearer.isWorking { ProgressView().controlSize(.small) }
                        else if mountCycle.needsAttention || mountCycle.canRecover {
                            Button(mountCycle.canRecover && mountCycle.operation?.phase == .writeMounted
                                   ? cycleDiskName.map { String(localized: "将“\($0)”恢复只读") } ?? String(localized: "恢复只读")
                                   : String(localized: "重新核验")) { Task { await mountCycle.recover() } }
                        } else {
                            Button("关闭", systemImage: "xmark") { actions.clearMessage(); autoMount.clearMessage(); manualMount.clearMessage(); mountCycle.clearMessage() }.labelStyle(.iconOnly).buttonStyle(.plain)
                        }
                    }.font(.callout).padding(14).background(.bar)
                }
            }

        }
        .toolbar {
            ToolbarItem {
                Button("刷新", systemImage: "arrow.clockwise") { discovery.refresh(); Task { await engineStatus.refresh() } }
                    .disabled(mountCycle.blocksActions || !actions.activeDevices.isEmpty || !autoMount.activeConnections.isEmpty || !manualMount.activeDevices.isEmpty).help("刷新磁盘")
            }
            ToolbarItem {
                Menu {
                    Button("磁盘详情", systemImage: "info.circle") { showDetails = true }.keyboardShortcut("i").disabled(selected == nil)
                    SettingsLink { Text("设置与诊断…") }
                    Divider()
                    Button("在 Mac 上检查…", systemImage: "checkmark.shield") { if let selected { markerTarget = checkTarget(for: selected) } }
                        .disabled(selected.map { !CheckMarkerClearer.applies(to: $0) || mountCycle.isWritable($0) || actions.isBusy($0) } ?? true
                                  || markerClearer.isWorking || mountCycle.isBusy)
                    Button("抹掉磁盘…", systemImage: "eraser") { showErase = true }
                        .disabled((mountCycle.blocksActions && !mountCycle.onlyHoldsWriteSession) || mountCycle.isBusy || !actions.activeDevices.isEmpty || !manualMount.activeDevices.isEmpty)
                    Divider()
                    Menu("高级") {
                        if let selected {
                            Button("检查只读挂载…", systemImage: "externaldrive.badge.checkmark") {
                                checkingVolume = selected
                            }.disabled(!selected.isNTFS || mountCycle.blocksActions || actions.isBusy(selected) || autoMount.isBusy(selected) || manualMount.isBusy(selected))
                            Button("仅卸载此卷", systemImage: "externaldrive.badge.minus") {
                                Task { await actions.perform(.unmountVolume, on: selected.identity) }
                            }.disabled(!selected.isNTFS || mountCycle.blocksActions || actions.isBusy(selected) || autoMount.isBusy(selected) || manualMount.isBusy(selected) || selected.mountURL == nil)
                        }
                        Button("恢复文件…", systemImage: "doc.badge.arrow.up") { showRecovery = true }
                            .disabled(mountCycle.blocksActions || !actions.activeDevices.isEmpty || !manualMount.activeDevices.isEmpty)
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                .help("磁盘详情与更多操作")
            }
        }
        .onAppear { selectIfNeeded(volumes.map(\.id)) }
        .task(id: bitLockerCandidates) {
            // Erasing creates an empty Windows partition; asking about it could hold the device just as formatting starts.
            guard !showErase else { return }
            await bitLocker.removeDisconnected()
            await bitLocker.check(discovery.volumes)
        }
        // Disk Arbitration does not report the helper's BitLocker mounts; Finder ejects do reach here.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in bitLocker.refreshMounts() }
        .onReceive(NotificationCenter.default.publisher(for: .volisleCloseSheetsForQuit)) { _ in
            showSetup = false; showDetails = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in bitLocker.refreshMounts() }
        // Mounts made outside this window (another unlock, a command line) send no notification.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in bitLocker.refreshMounts() }

        .onChange(of: volumes.map(\.id)) { _, ids in selectIfNeeded(ids) }
        .alert("无法完成操作", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("知道了", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "") }
        .confirmationDialog("启用这块磁盘的读写？", isPresented: Binding(get: { writingVolume != nil }, set: { if !$0 { writingVolume = nil } }), titleVisibility: .visible) {
            if let volume = writingVolume {
                Button("启用读写") {
                    writingVolume = nil
                    Task {
                        guard DailyWriteAvailability.allows(volume) || PhysicalWriteAvailability.testDirectory(for: volume) != nil else {
                            operationError = String(localized: "测试范围已过期或磁盘连接已变化。"); return
                        }
                        await mountCycle.startWrite(volume, resolver: discovery)
                    }
                }
            }
            Button("取消", role: .cancel) { writingVolume = nil }
        } message: {
            if let volume = writingVolume, DailyWriteAvailability.allows(volume) {
                Text("将检查“\(volume.name)”并切换为读写。请先关闭正在使用盘内文件的应用；使用完毕后点击“推出”。")
            } else if let volume = writingVolume, let directory = PhysicalWriteAvailability.testDirectory(for: volume) {
                Text("将暂时卸载“\(volume.name)”。本次仅允许写入测试目录 \(directory)，使用完毕后请恢复只读。")
            }
        }
        .confirmationDialog("检查这块磁盘？", isPresented: Binding(get: { checkingVolume != nil }, set: { if !$0 { checkingVolume = nil } }), titleVisibility: .visible) {
            if let volume = checkingVolume {
                Button("开始检查") { checkingVolume = nil; Task { await mountCycle.start(volume, resolver: discovery) } }
            }
            Button("取消", role: .cancel) { checkingVolume = nil }
        } message: {
            if let volume = checkingVolume {
                Text(volume.mountState == .unmounted ? "将只读检查“\(volume.name)”，完成后保持未挂载。不会修改盘内文件。" : "检查“\(volume.name)”期间会暂时卸载磁盘，完成后恢复原来的只读状态。请先关闭正在使用盘内文件的应用。不会修改盘内文件。")
            }
        }
        .confirmationDialog("推出整个设备？", isPresented: Binding(get: { ejecting != nil }, set: { if !$0 { ejecting = nil } }), titleVisibility: .visible) {
            if let volume = ejecting {
                Button("推出设备") { ejecting = nil; eject(volume) }
            }
            Button("取消", role: .cancel) { ejecting = nil }
        } message: {
            if let volume = ejecting {
                Text("将卸载此设备上的所有卷：\(discovery.volumes.filter { $0.deviceGroup == volume.deviceGroup }.map(\.name).joined(separator: String(localized: "、")))。如有文件正在使用，操作会停止。")
            }
        }
        .confirmationDialog("在 Mac 上检查这块盘？", isPresented: Binding(get: { markerTarget != nil }, set: { if !$0 { markerTarget = nil } }), titleVisibility: .visible) {
            if let target = markerTarget {
                Button("检查并清除标记") { markerTarget = nil; Task { await clearCheckMarker(target) } }
            }
            Button("取消", role: .cancel) { markerTarget = nil }
        } message: {
            if let volume = markerTarget {
                Text("盘屿会只读检查“\(volume.name)”上全部文件和文件夹的记录，没有发现问题才清除“需要检查”标记，随后开启读写；发现问题则不做任何修改。这不等同于 Windows 的完整磁盘检查：如果盘里有重要且没有备份的数据，建议优先在 Windows 中检查。检查期间磁盘会暂时卸载，文件较多时需要几分钟。")
            }
        }
        .alert("检查完成", isPresented: Binding(get: { markerResult != nil }, set: { if !$0 { markerResult = nil } })) {
            Button("好", role: .cancel) { markerResult = nil }
        } message: { Text(markerResult ?? "") }
        .sheet(isPresented: $showSetup) {
            SetupGuideView(helperService: helperService, engineStatus: engineStatus, refreshRuntime: refreshRuntime)
        }
        // Offer the guide once per launch, once both first checks say setup is unfinished.
        .onChange(of: setupReason, initial: true) { offerSetup() }
        .onChange(of: helperService.hasChecked) { offerSetup() }
        .onChange(of: engineStatus.checkedAt) { offerSetup() }
        .sheet(isPresented: $showErase) {
            EraseDiskView(discovery: discovery, mountCycle: mountCycle)
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryView(discovery: discovery, preferredVolume: selection, isExporting: $recovering)
        }
        .sheet(isPresented: $showDetails) {
            if let selected { VolumeInfoView(volume: selected, engineStatus: engineStatus, bitLocker: bitLocker.isBitLocker(selected)) }
            else { Text("磁盘已断开").padding(40) }
        }
    }
    private func offerSetup() {
        let forced = UserDefaults.standard.bool(forKey: "VolisleShowSetupGuide")  // support and screenshots
        guard !setupOffered, forced || (setupReason != nil && helperService.hasChecked &&
              engineStatus.checkedAt != nil && !engineStatus.isChecking) else { return }
        setupOffered = true; showSetup = true
    }
    /// Nil once the background component and file system extension are ready.
    private var setupReason: String? {
        // Not before the first checks finish: at login the helper connects a few
        // seconds after launch, and a banner flashing in and out disturbed the layout.
        guard helperService.hasChecked, engineStatus.checkedAt != nil, !engineStatus.isChecking else { return nil }
        switch helperService.state {
        case .notRegistered, .unavailable: return String(localized: "在设置中允许盘屿的后台组件并启用文件系统扩展，插入的磁盘才能自动读写。")
        case .requiresApproval: return String(localized: "请在“系统设置 → 通用 → 登录项与扩展”中允许盘屿在后台运行。")
        case .failed: return helperService.lastError ?? String(localized: "后台组件暂时无法连接，请在设置中重新检查。")
        case .connected:
            guard engineStatus.capability.available else { return engineStatus.capability.reason }
            return helperService.fullDiskAccess == false ? String(localized: "还需允许盘屿读取磁盘：在“系统设置 → 隐私与安全性 → 完全磁盘访问”中打开“盘屿”。") : nil
        }
    }
    /// Only one NTFS disk is read-write at a time. While another one holds that
    /// slot, name it so this disk does not look stuck "processing".
    private func writeHolder(for volume: VolumeSnapshot) -> String? {
        guard let operation = mountCycle.operation, operation.phase == .writeMounted,
              !mountCycle.isBusy, !mountCycle.needsAttention, !mountCycle.isWritable(volume),
              operation.disk.registryID != volume.identity.mediaRegistryID else { return nil }
        return discovery.volumes.first { $0.identity.mediaRegistryID == operation.disk.registryID }?.name ?? String(localized: "另一块磁盘")
    }
    /// Sidebar subtitle: the one fact a user scans for across several disks.
    private func sidebarState(_ volume: VolumeSnapshot) -> String {
        if bitLocker.isBitLocker(volume) {
            return bitLocker.mountURL(for: volume) == nil ? String(localized: "BitLocker · 已锁定")
                : bitLocker.isWritable(volume) ? String(localized: "BitLocker · 可读写") : String(localized: "BitLocker · 只读")
        }
        let state = mountCycle.isWritable(volume) ? String(localized: "可读写") : volume.mountState == .readOnly ? String(localized: "只读") : volume.mountState == .unmounted ? String(localized: "未挂载") : ""
        return state.isEmpty ? volume.fileSystem.uppercased() : volume.fileSystem.uppercased() + " · " + state
    }
    private func clearCheckMarker(_ volume: CheckMarkerTarget) async {
        do {
            let items = try await markerClearer.run(partition: volume.bsdName)
            autoMount.clearMessage()
            markerResult = items > 0
                ? String(localized: "已检查 \(items) 个文件和文件夹，没有发现问题，已清除“需要检查”标记。")
                : String(localized: "这块盘没有“需要检查”标记，无需处理。")
            // The partition was mounted again; turn writing back on like the button
            // does. No discovery.refresh(): that would issue new connection IDs
            // and make automatic writing retry. The mount event updates the list.
            try? await Task.sleep(for: .seconds(2))
            if let fresh = discovery.volumes.first(where: { $0.bsdName == volume.bsdName && (volume.volumeUUID == nil || $0.identity.volumeUUID == volume.volumeUUID) }),
               DailyWriteAvailability.allows(fresh) {
                await mountCycle.startWrite(fresh, resolver: discovery)
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func eject(_ volume: VolumeSnapshot) {
        Task {
            do {
                // The system does not know the unlocked BitLocker mounts: unmount them first.
                for sibling in discovery.volumes where sibling.deviceGroup == volume.deviceGroup && bitLocker.mountURL(for: sibling) != nil {
                    try await bitLocker.lock(sibling)
                }
                // A sibling partition in a write session is returned to read-only first.
                let writing = discovery.volumes.first { $0.deviceGroup == volume.deviceGroup && $0.bsdName == mountCycle.operation?.disk.bsdName }
                try await mountCycle.prepareForEject(writing ?? volume); await actions.perform(.ejectDevice, on: volume.identity)
            }
            catch { operationError = error.localizedDescription }
        }
    }
    private func selectIfNeeded(_ ids: [VolumeIdentity]) {
        if selection == nil || !ids.contains(selection!) { selection = ids.first }
    }
}

/// Another NTFS disk is read-write; this one waits for it to be ejected.
struct WriteSlotWait {
    let holder: String
    let automatic: Bool
    var message: String {
        automatic ? String(localized: "同一时间只能为一块 NTFS 磁盘开启读写。推出“\(holder)”后，这块盘会自动开启读写。")
            : String(localized: "同一时间只能为一块 NTFS 磁盘开启读写。推出“\(holder)”后，即可为这块盘开启读写。")
    }
    /// The waiting note under the buttons: files stay readable meanwhile.
    var detail: String { String(localized: "\(message)现在可以正常查看和复制盘内文件。") }
}

struct VolumeDetail: View {
    let volume: VolumeSnapshot
    let busy: Bool
    let waitingFor: WriteSlotWait?
    let backgroundNeedsAttention: Bool
    let controlledWrite: Bool
    let testDirectory: String?
    let requiresVerification: Bool
    let verifyingRecovery: Bool
    let verifyRecovery: () -> Void
    let capability: EngineCapability
    let checkingEngine: Bool
    let enableWriting: () -> Void
    let openFinder: () -> Void
    let eject: () -> Void
    /// The last write attempt was refused because NTFS marks the disk "needs check".
    var needsCheck = false
    var checkOnMac: () -> Void = {}
    private var state: String {
        if backgroundNeedsAttention { return String(localized: "等待后台核验") }
        if controlledWrite { return testDirectory == nil ? String(localized: "可读写") : String(localized: "可读写（测试目录）") }
        if requiresVerification && !verifyingRecovery { return String(localized: "状态待核验") }
        if busy { return String(localized: "正在处理，请稍候…") }
        switch volume.mountState {
        case .readOnly: return String(localized: "只读")
        case .readWrite: return String(localized: "可读写")
        case .unmounted: return String(localized: "未挂载")
        case .unknown: return String(localized: "状态待确认")
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 18) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 52, weight: .light))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(volume.name).font(.title.weight(.semibold)).textSelection(.enabled)
                        Text("\(volume.fileSystem.uppercased()) · \(state)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("存储空间"); Spacer(); Text(formatBytes(volume.totalBytes)).foregroundStyle(.secondary) }
                    if let total = volume.totalBytes, let free = volume.availableBytes, total > 0, free >= 0, free <= total {
                        ProgressView(value: Double(total - free), total: Double(total)).accessibilityLabel("已用存储空间")
                        Text("可用 \(formatBytes(free))").font(.caption).foregroundStyle(.secondary)
                    } else { Text("挂载后可查看可用空间").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    if requiresVerification {
                        Button("检查磁盘状态", systemImage: "arrow.clockwise") { verifyRecovery() }
                            .disabled(verifyingRecovery)
                    }
                    Button("打开 Finder", systemImage: "folder") { openFinder() }
                        .keyboardShortcut("o")
                        .buttonStyle(.borderedProminent).disabled(!controlledWrite && (volume.mountURL == nil || busy))
                    if volume.isNTFS && volume.mountState != .readWrite && !requiresVerification && !controlledWrite {
                        Button(testDirectory == nil ? "启用读写" : "启用测试读写", systemImage: "lock.open") { enableWriting() }
                            .disabled(busy || waitingFor != nil || checkingEngine || !capability.available || (!capability.finderReadWrite && testDirectory == nil))
                            .help(waitingFor?.message ?? (testDirectory == nil ? capability.reason : String(localized: "仅写入本次专用测试目录，完成后恢复只读。")))
                    }
                    if needsCheck && !controlledWrite {
                        Button("在 Mac 上检查…", systemImage: "checkmark.shield") { checkOnMac() }.disabled(busy)
                    }
                    // Disk operations pause while another disk is read-write; Finder can still eject this one.
                    Button("推出", systemImage: "eject") { eject() }.keyboardShortcut("e").disabled((busy && !controlledWrite) || waitingFor != nil)
                        .help(waitingFor == nil ? "" : "另一块磁盘读写期间，可在 Finder 中推出这块盘。")
                    if busy && !controlledWrite && !backgroundNeedsAttention && (!requiresVerification || verifyingRecovery) {
                        ProgressView().controlSize(.small).accessibilityLabel("正在操作磁盘")
                    }
                }.controlSize(.large)
                if volume.isNTFS, needsCheck, !controlledWrite, waitingFor == nil {
                    Label("这块盘被标记为需要检查，为保护数据暂时只读。可以点上面的“在 Mac 上检查…”，也可以在 Windows 中检查后安全弹出再插回。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if volume.isNTFS, let waitingFor {
                    Label(waitingFor.detail, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if volume.isNTFS {
                    Label(controlledWrite || volume.mountState == .readWrite ? (testDirectory == nil ? String(localized: "可以直接在 Finder 和其他应用中新建、编辑和保存文件。") : String(localized: "本次仅开放测试目录；完成后请恢复只读。")) : (checkingEngine ? String(localized: "正在检查扩展状态…") : (testDirectory == nil ? capability.reason : String(localized: "此测试版仅为当前磁盘开放受限读写。"))), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if volume.mountState == .unmounted {
                    Text("这个卷尚未挂载，可前往“磁盘工具”查看。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(36).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

private func formatBytes(_ value: Int64?) -> String {
    guard let value, value >= 0 else { return String(localized: "未知") }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
}

private struct VolumeInfoView: View {
    let volume: VolumeSnapshot
    let engineStatus: EngineStatus
    let bitLocker: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("磁盘详情").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            LabeledContent("名称", value: volume.name)
            LabeledContent("文件系统", value: bitLocker ? String(localized: "BitLocker（NTFS）") : volume.fileSystem.uppercased())
            LabeledContent("设备", value: volume.deviceName)
            LabeledContent("容量", value: formatBytes(volume.totalBytes))
            LabeledContent("盘屿读写引擎", value: engineStatus.title)
            if volume.mountState != .readWrite {
                Text("读写状态来自系统。盘屿启用读写前会先检查磁盘。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if volume.fileSystem.lowercased() == "apfs" {
                Text("APFS 卷可能共享容器空间，各卷容量不能直接相加。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 420)
    }
}

/// What the "Check on This Mac" button acts on: a partition name, plus what the
/// dialog shows. The helper verifies the device itself.
struct CheckMarkerTarget: Equatable {
    let bsdName: String
    let name: String
    let volumeUUID: String?
}
