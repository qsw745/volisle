import SwiftUI
import AppKit
import VolisleCore

struct VolisleApp: App {
    @NSApplicationDelegateAdaptor(UpdateAppDelegate.self) private var appDelegate
    @State private var updates: AppUpdates
    @State private var discovery: DiskDiscovery
    @State private var actions: DiskActions
    @State private var autoMount: AutoMountController
    @State private var engineStatus: EngineStatus
    @State private var mountCycle: MountCycleClient
    @State private var manualMount: ManualMountController
    @State private var runtime: BackgroundDiskRuntime
    @State private var helperService: HelperServiceController
    init() {
        let discovery = DiskDiscovery()
        let actions = DiskActions(backend: SystemDiskActions(discovery: discovery))
        let mountCycle = MountCycleClient(onActivity: { actions.clearMessage() })
        _mountCycle = State(initialValue: mountCycle)
        _discovery = State(initialValue: discovery)
        _actions = State(initialValue: actions)
        let engine = ReadOnlyFSKitEngine(expectedExtension: Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/VolisleFS.appex"),
                                        identifier: (Bundle.main.bundleIdentifier ?? "top.qisw.volisle") + ".filesystem", dailyWrites: DailyWriteAvailability.enabled)
        let coordinator = MountCoordinator(engine: engine, resolver: discovery)
        _manualMount = State(initialValue: ManualMountController(coordinator: coordinator, resolver: discovery))
        let engineStatus = EngineStatus(engine: engine)
        let helperService = HelperServiceController()
        let updates = AppUpdates(cycle: mountCycle, helper: helperService)
        _updates = State(initialValue: updates)
        _helperService = State(initialValue: helperService)
        _engineStatus = State(initialValue: engineStatus)
        let autoMount = AutoMountController(preferences: AutoMountPreferences(defaultAutomatic: DailyWriteAvailability.enabled), engine: engine,
            coordinator: coordinator, helperEnable: { volume in
                guard DailyWriteAvailability.allows(volume), !mountCycle.blocksActions else { throw VolumeError.busy }
                guard await mountCycle.startWrite(volume, resolver: discovery) else { throw AutoMountDeferred() }
                guard mountCycle.isWritable(volume) else {
                    throw mountCycle.lastError == nil ? VolumeError.mountNotVerified : AutoMountReported()
                }
            }, helperReady: {
                // One write volume at a time: while a write operation is mounted or
                // awaiting recovery (e.g. just unplugged), do not spend another
                // connection's single automatic attempt; it runs once this ends.
                !updates.maintenance.blocking && helperService.state == .connected && !mountCycle.blocksActions && !mountCycle.isBusy && !mountCycle.canRecover
            })
        _autoMount = State(initialValue: autoMount)
        _runtime = State(initialValue: BackgroundDiskRuntime(discovery: discovery, actions: actions,
            automatic: autoMount, cycle: mountCycle, engine: engineStatus, helper: helperService, updates: updates.maintenance))
    }
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("盘屿", id: "main") {
            MainView(discovery: discovery, engineStatus: engineStatus, actions: actions, autoMount: autoMount, manualMount: manualMount, mountCycle: mountCycle, helperService: helperService,
                     refreshRuntime: { await runtime.refresh() })
                .frame(minWidth: 700, minHeight: 430)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { appDelegate.updates = updates; await updates.start(); runtime.start() }
        }
        .defaultSize(width: 840, height: 540)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出盘屿") { UpdateAppDelegate.closeSheetsAndTerminate() }.keyboardShortcut("q")
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.check() }.disabled(!updates.available || (!updates.canCheck && !updates.canRetryInstallation))
            }
            CommandGroup(replacing: .help) {
                Link("盘屿帮助", destination: WebsiteLink.help.url)
                Link("提交反馈…", destination: WebsiteLink.feedback.url)
                Divider()
                Link("请我喝杯奶茶…", destination: WebsiteLink.support.url)
            }
            CommandGroup(after: .newItem) {
            Button("刷新磁盘") { discovery.refresh() }.keyboardShortcut("r").disabled(mountCycle.blocksActions || !actions.activeDevices.isEmpty || !autoMount.activeConnections.isEmpty || !manualMount.activeDevices.isEmpty)
        } }
        Settings {
            SettingsView(discovery: discovery, engineStatus: engineStatus, autoMount: autoMount,
                         helperService: helperService, mountCycle: mountCycle, updates: updates, refreshRuntime: { await runtime.refresh() }).frame(width: 470, height: 500)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        MenuBarExtra {
            DiskMenu(mountCycle: mountCycle, discovery: discovery, actions: actions)
        } label: {
            Image(nsImage: Brand.menuBarImage).accessibilityLabel("盘屿")
        }
    }
}

struct DiskMenu: View {
    var mountCycle: MountCycleClient
    var discovery: DiskDiscovery
    var actions: DiskActions
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    var body: some View {
        Text("盘屿")
        let volumes = discovery.volumes.filter(\.isNTFS)
        if volumes.isEmpty { Text("未连接 NTFS 磁盘") }
        ForEach(volumes) { volume in
            Menu(volume.name) {
                Button("打开 Finder") {
                    Task {
                        do {
                            if mountCycle.isWritable(volume) { NSWorkspace.shared.open(try await mountCycle.verifiedWritableURL(for: volume)) }
                            else { try FinderService.open(volume, discovery: discovery) }
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(!mountCycle.isWritable(volume) && (volume.mountURL == nil || actions.isBusy(volume)))
                Button("推出") { confirmEject(volume) }.disabled(!mountCycle.isWritable(volume) && actions.isBusy(volume))
            }
        }
        if mountCycle.needsAttention {
            Button("查看磁盘恢复状态") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        if let message = actions.lastError ?? error { Text(message) }
        Divider()
        Text("本地处理 · 无需账号")
        Button("打开盘屿") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        SettingsLink { Text("设置…") }
        Button("退出盘屿") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
    private func confirmEject(_ volume: VolumeSnapshot) {
        // Like Finder: a single-volume device ejects directly.
        guard discovery.volumes.filter({ $0.deviceGroup == volume.deviceGroup }).count > 1 else { eject(volume); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "推出整个设备？")
        let names = discovery.volumes.filter { $0.deviceGroup == volume.deviceGroup }.map(\.name).joined(separator: String(localized: "、"))
        alert.informativeText = String(localized: "将卸载此设备上的所有卷：\(names)。如有文件正在使用，操作会停止。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "推出设备"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { eject(volume) }
    }
    private func eject(_ volume: VolumeSnapshot) {
        Task {
            do { try await mountCycle.prepareForEject(volume); await actions.perform(.ejectDevice, on: volume.identity) }
            catch {
                // Disk operations pause while another disk is read-write; say so instead of "busy".
                let otherWriting = mountCycle.operation?.phase == .writeMounted && !mountCycle.isWritable(volume)
                self.error = otherWriting ? String(localized: "另一块磁盘正在读写，请在 Finder 中推出“\(volume.name)”。") : error.localizedDescription
            }
        }
    }
}

@MainActor enum FinderService {
    static func open(_ volume: VolumeSnapshot, discovery: DiskDiscovery) throws {
        guard let current = discovery.revalidate(volume.identity), let url = current.mountURL else { throw VolumeError.disconnected }
        guard current.identity == volume.identity, url.isFileURL else { throw VolumeError.identityChanged }
        guard NSWorkspace.shared.open(url) else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
