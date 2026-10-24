// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import DiskArbitration
import FSKit
import Observation

/// An NTFS volume as the store app shows it. The app never reads a disk: what
/// it knows comes from Disk Arbitration, the mount table and the extension's record.
struct StoreVolume: Identifiable, Equatable {
    /// Who mounted it: the store extension, the system's own driver, or the website build of Volisle.
    enum Driver: Equatable { case volisle, system, website }
    /// BSD name: the identity for as long as the disk stays connected.
    let id: String
    let name: String
    let device: String
    let size: Int64?
    let free: Int64?
    let driver: Driver
    let mountPoint: URL?
    let readOnly: Bool
    /// Why a volume the extension mounted is read-only.
    let explanation: StoreExplanation?
    /// Writes the extension had to undo before mounting it.
    let recovery: StoreExplanation?
    var serial: [UInt8]? = nil
    var status: StoreVolumeStatus? = nil
    var writeStopped: Bool { status?.stopped == true }
}

enum StoreExtensionState: Equatable { case checking, enabled, disabled, missing, unavailable }

/// One instance for the life of the process: Disk Arbitration and the
/// notification center hold it unretained and are never unregistered.
@MainActor @Observable final class StoreDisks {
    private(set) var volumes: [StoreVolume] = []
    private(set) var extensionState: StoreExtensionState = .checking
    private(set) var ejecting: Set<String> = []
    private(set) var lastError: String?
    var preferReadOnly: Bool {
        didSet { shared?.set(preferReadOnly, forKey: StoreMountStatus.preferReadOnlyKey) }
    }
    /// The website build is on this Mac too. With this extension on, the system hands
    /// it the disks that build releases, and that build's eject then fails.
    private(set) var websiteVersionInstalled = false
    var hidesWebsiteNotice = UserDefaults.standard.bool(forKey: StoreDisks.hidesWebsiteNoticeKey) {
        didSet { UserDefaults.standard.set(hidesWebsiteNotice, forKey: Self.hidesWebsiteNoticeKey) }
    }

    private static let hidesWebsiteNoticeKey = "HidesWebsiteNotice"
    private static let websiteBundle = "top.qisw.volisle"
    /// An answer about the extension normally comes at once. Without one the window must not wait forever.
    private static let extensionAnswerLimit = 3.0
    /// The mount types of the store extension (its FSShortName) and of the system's own driver.
    private static let kinds: [String: StoreVolume.Driver] = ["volislemas": .volisle, "ntfs": .system]
    private let shared = UserDefaults(suiteName: StoreMountStatus.group)
    @ObservationIgnored private var session: DASession?
    @ObservationIgnored private var disks: [String: DADisk] = [:]
    @ObservationIgnored private var recheck: DispatchWorkItem?

    init() {
        // The extension mounts read-only until this exists (it cannot tell "never
        // chosen" from "cannot read the choice"), so the first launch writes the default.
        let chosen = shared?.object(forKey: StoreMountStatus.preferReadOnlyKey) as? Bool
        preferReadOnly = chosen ?? false
        if chosen == nil { shared?.set(false, forKey: StoreMountStatus.preferReadOnlyKey) }
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            StoreDisks.onMain(context) { $0.appeared(disk) }
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            StoreDisks.onMain(context) { $0.disappeared(disk) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            StoreDisks.onMain(context) { $0.changed(disk) }
        }, context)
        DASessionSetDispatchQueue(session, .main)
        // The extension posts this after recording a mount; the preferences daemon
        // may deliver the value a moment later. Delivery thread is not promised.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), context, { _, context, _, _, _ in
            guard let context else { return }
            let model = Unmanaged<StoreDisks>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { model.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.refresh() }
        }, StoreMountStatus.changed as CFString, nil, .deliverImmediately)
        // Back from System Settings: the switch may have changed.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkExtension(); self?.refresh() }
        }
        checkExtension()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extensionAnswerLimit) { [weak self] in
            MainActor.assumeIsolated { if self?.extensionState == .checking { self?.extensionState = .unavailable } }
        }
    }

    /// Disk Arbitration calls back on the session's queue, which is the main queue.
    private nonisolated static func onMain(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (StoreDisks) -> Void) {
        guard let context else { return }
        let model = Unmanaged<StoreDisks>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { body(model) }
    }

    private func appeared(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        disks[name] = disk
        refresh()
    }

    /// A disk object keeps the description it was created with: a mount or
    /// unmount shows only in the object delivered with the change.
    private func changed(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }), disks[name] != nil else { return }
        disks[name] = disk
        refresh()
    }

    private func disappeared(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        disks[name] = nil
        ejecting.remove(name)
        // Whatever went wrong was about a disk that is no longer here, or no longer the question.
        lastError = nil
        refresh()
    }

    func refresh() {
        volumes = disks.compactMap { name, disk in volume(name: name, disk: disk) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        // A notification can precede its preferences update. Idle mounts must
        // also be rechecked, otherwise a stopped writer can look writable.
        if volumes.contains(where: { $0.driver == .volisle && $0.mountPoint != nil }), recheck == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.recheck = nil; self?.refresh() }
            }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func volume(name bsdName: String, disk: DADisk) -> StoreVolume? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String,
              let probed = Self.kinds[kind] else { return nil }
        let mountPoint = description[kDADiskDescriptionVolumePathKey as String] as? URL
        let values = try? mountPoint?.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityKey])
        let mounted = mountPoint.flatMap(Self.mountTable)
        // Unknown must not read as writable: the system's driver never writes
        // NTFS, and for ours "read-only" only costs an unneeded caution.
        let readOnly = values?.volumeIsReadOnly ?? mounted?.readOnly ?? true
        // The website build mounts through its own helper under its own type,
        // while Disk Arbitration keeps the kind from the system's probe.
        let driver = mounted?.type == Self.websiteType ? .website : probed
        let serial = driver == .volisle && mountPoint != nil ? Self.serial(description) : nil
        let current = serial.flatMap { recordedStatus(serial: $0, bsdName: bsdName, readOnly: readOnly) }
        let previous = volumes.first { $0.id == bsdName && $0.serial == serial && $0.driver == .volisle }
        let status = driver == .volisle && mountPoint != nil
            ? StoreVolumeStatus.resolved(current: current, previous: previous?.status) : nil
        let label = description[kDADiskDescriptionVolumeNameKey as String] as? String
        let maker = [kDADiskDescriptionDeviceVendorKey, kDADiskDescriptionDeviceModelKey]
            .compactMap { (description[$0 as String] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return StoreVolume(
            id: bsdName, name: label?.isEmpty == false ? label! : String(localized: "未命名"),
            device: maker.isEmpty ? String(localized: "外接设备") : maker,
            size: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value,
            free: (values?.volumeAvailableCapacity).map(Int64.init),
            driver: driver, mountPoint: mountPoint, readOnly: readOnly,
            explanation: driver == .volisle && mountPoint != nil && readOnly
                ? status?.reason.map(StoreReadOnlyText.explanation(token:)) ?? StoreReadOnlyText.unexplained
                : nil,
            recovery: status?.recovery.flatMap(StoreRecoveryText.explanation(recovery:)), serial: serial, status: status)
    }

    /// The mount type of the website build's extension.
    private static let websiteType = "volisle"

    private static func mountTable(_ mountPoint: URL) -> (type: String, readOnly: Bool)? {
        var information = statfs()
        guard statfs(mountPoint.path, &information) == 0 else { return nil }
        let type = withUnsafeBytes(of: information.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (type, information.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    /// The extension's record, when it is about this mount.
    private static func serial(_ description: [String: Any]) -> [UInt8]? {
        guard let value = description[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
        // Core Foundation type, not bridged: check before casting.
        guard CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID(),
              let uuid = UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String) else { return nil }
        return StoreVolumeIdentity.serial(volumeUUID: uuid)
    }

    private func recordedStatus(serial: [UInt8], bsdName: String, readOnly: Bool) -> StoreVolumeStatus? {
        guard let status = StoreVolumeStatus(entry: shared?.object(forKey: StoreMountStatus.key(serial: serial))),
              status.describes(mountedReadOnly: readOnly, bsdName: bsdName) else { return nil }
        return status
    }

    func checkExtension() {
        websiteVersionInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.websiteBundle) != nil
        guard let identifier = Bundle.main.bundleIdentifier.map({ $0 + ".filesystem" }) else { return }
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let state: StoreExtensionState
            if error != nil { state = .unavailable }
            else if let module = modules?.first(where: { $0.bundleIdentifier == identifier }) { state = module.isEnabled ? .enabled : .disabled }
            else { state = .missing }
            Task { @MainActor in self.extensionState = state }
        }
    }

    func openExtensionSettings() {
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule")!)
    }

    /// Selects the volume in a Finder window. Opening the volume itself is
    /// refused in the sandbox (Launch Services: permErr): the app has no access
    /// to the disk's contents, and needs none.
    func showInFinder(_ volume: StoreVolume) {
        guard let mountPoint = volume.mountPoint else { return }
        NSWorkspace.shared.activateFileViewerSelecting([mountPoint])
    }

    /// Unmounts every volume of the disk and ejects it, as Finder's eject does.
    func eject(_ volume: StoreVolume) {
        guard let mountPoint = volume.mountPoint, !ejecting.contains(volume.id) else { return }
        ejecting.insert(volume.id)
        lastError = nil
        let id = volume.id, name = volume.name
        FileManager.default.unmountVolume(at: mountPoint, options: [.allPartitionsAndEjectDisk]) { error in
            let message = error.map { String(localized: "“\(name)”没有推出：\($0.localizedDescription)") }
            Task { @MainActor in
                self.ejecting.remove(id)
                // Another disk's failure stays on screen when this one succeeds.
                if let message { self.lastError = message }
                self.refresh()
            }
        }
    }
}
