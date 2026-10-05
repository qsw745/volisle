import Foundation

/// The three things only the user can switch on, in the order the setup guide
/// asks for them. The helper must run first: it checks the disk permission.
public enum SetupStep: Int, CaseIterable, Sendable {
    case backgroundComponent, fileSystemExtension, fullDiskAccess
}

public struct SetupProgress: Equatable, Sendable {
    public let backgroundComponent: Bool
    public let fileSystemExtension: Bool
    public let fullDiskAccess: Bool

    /// `fullDiskAccess` comes from the connected helper; an older helper that
    /// cannot tell (nil) does not block setup on something it cannot check.
    public init(helperConnected: Bool, extensionEnabled: Bool, fullDiskAccess: Bool?) {
        backgroundComponent = helperConnected
        fileSystemExtension = extensionEnabled
        self.fullDiskAccess = helperConnected && (fullDiskAccess ?? true)
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .backgroundComponent: backgroundComponent
        case .fileSystemExtension: fileSystemExtension
        case .fullDiskAccess: fullDiskAccess
        }
    }
    /// The first step not done yet; nil once setup is complete.
    public var current: SetupStep? { SetupStep.allCases.first { !isDone($0) } }
    public var isComplete: Bool { current == nil }
    public var doneCount: Int { SetupStep.allCases.filter(isDone).count }
}
