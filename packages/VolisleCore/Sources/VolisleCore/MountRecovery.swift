import Foundation

/// A backend assertion, not proof from a UI snapshot. `settled` means every
/// submitted OS/helper request has completed and cannot perform a late mount.
/// The backend must bind recovery to its original held resource, normally
/// unmount only a mount it owns, and restore read-only access when possible.
/// Never force, repair, clear flags, or act on a replacement disk by BSD name.
public enum MountRecoveryDisposition: Sendable {
    case settled, unresolved
    /// The backend verified removal of the ORIGINAL held media and completion
    /// of all its requests. Missing UI discovery records are not this evidence.
    case deviceGone
}

public enum MountRecoveryOutcome: Equatable, Sendable {
    case readOnly, unmounted, disconnected, nothingPending
}

/// Preserve the initiating error separately from the uncertain recovery state.
public struct MountRecoveryError: Error, LocalizedError, Sendable {
    public let cause: any Error
    public var errorDescription: String? {
        String(localized: "\(cause.localizedDescription) 尚未确认挂载操作已结束并恢复安全状态，已暂停此设备的后续操作。请检查磁盘状态。")
    }
}
