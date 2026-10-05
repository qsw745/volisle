import Foundation
import Observation

/// Owns the user-initiated action only. All device exclusion and preflight
/// remain in MountCoordinator; a returned path alone is not success evidence.
@MainActor @Observable public final class ManualMountController {
    public private(set) var activeDevices: Set<String> = []
    public private(set) var lastError: String?
    public private(set) var notice: String?
    private let coordinator: MountCoordinator
    private let resolver: any VolumeResolver

    public init(coordinator: MountCoordinator, resolver: any VolumeResolver) {
        self.coordinator = coordinator; self.resolver = resolver
    }
    public func isBusy(_ volume: VolumeSnapshot) -> Bool {
        activeDevices.contains(volume.deviceGroup) || coordinator.isBusy(volume)
    }
    public func requiresVerification(_ volume: VolumeSnapshot) -> Bool { coordinator.requiresVerification(volume) }
    public func clearMessage() { lastError = nil; notice = nil }
    public func verifyRecovery(_ volume: VolumeSnapshot) async {
        guard !activeDevices.contains(volume.deviceGroup) else { lastError = VolumeError.busy.localizedDescription; return }
        activeDevices.insert(volume.deviceGroup)
        defer { activeDevices.remove(volume.deviceGroup) }
        clearMessage()
        do {
            switch try await coordinator.verifyRecovery(deviceGroup: volume.deviceGroup) {
            case .readOnly: notice = String(localized: "已确认恢复只读，可以继续查看文件。")
            case .unmounted: notice = String(localized: "已确认磁盘未挂载，待核验状态已解除。")
            case .disconnected: notice = String(localized: "已确认原设备断开，待核验状态已解除。")
            case .nothingPending: break
            }
        } catch { lastError = error.localizedDescription }
    }
    public func enable(_ volume: VolumeSnapshot) async {
        guard !activeDevices.contains(volume.deviceGroup) else { lastError = VolumeError.busy.localizedDescription; return }
        activeDevices.insert(volume.deviceGroup)
        defer { activeDevices.remove(volume.deviceGroup) }
        clearMessage()
        do {
            try Task.checkCancellation()
            guard volume.mountState == .readOnly || volume.mountState == .unmounted else { throw VolumeError.busy }
            let mounted = try await coordinator.enableReadWrite(expected: volume.identity)
            let current = try await resolver.resolve(volume.identity)
            guard current.identity == volume.identity else { throw VolumeError.identityChanged }
            guard mounted.isFileURL, current.mountState == .readWrite,
                  current.mountURL?.standardizedFileURL == mounted.standardizedFileURL else {
                throw VolumeError.mountNotVerified
            }
            lastError = nil
            notice = String(localized: "已启用读写，可在 Finder 中复制文件。")
        } catch is CancellationError {
            // An unstarted/cancelled request never becomes a success message.
        } catch { lastError = error.localizedDescription }
    }
}
