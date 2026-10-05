import Foundation

public struct EngineCapability: Equatable, Sendable {
    public let available: Bool
    public let finderReadWrite: Bool
    public let reason: String
    public init(available: Bool, finderReadWrite: Bool, reason: String) {
        self.available = available; self.finderReadWrite = finderReadWrite; self.reason = reason
    }
}
/// 只表达固定操作；未来实现不得向 UI 暴露任意命令和路径写入。
public protocol FileSystemAdapter: Sendable {
    func capability() async -> EngineCapability
    func inspect(_ volume: VolumeSnapshot) async throws -> SafetyStatus
    // Implementation must use normal unmount for a native read-only mount,
    // reject other-driver ownership, and validate the held resource again.
    func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL
    func unmount(_ volume: VolumeSnapshot) async throws
    /// Complete or reconcile the failed operation on the original held device.
    /// This must not inherit cancellation of the initiating UI task or report
    /// settled merely because a timer/XPC connection expired.
    func recoverFailedMount(_ volume: VolumeSnapshot) async -> MountRecoveryDisposition
}
public extension FileSystemAdapter {
    // Adapters without an implemented recovery contract cannot unlock a device
    // after an uncertain failure, even if discovery still shows the old mount.
    func recoverFailedMount(_ volume: VolumeSnapshot) async -> MountRecoveryDisposition { .unresolved }
}
/// Backends whose NTFS inspection requires exclusive device access must keep
/// unmount, authoritative inspection and writable activation in one operation.
/// A thrown error may follow an unmount: the coordinator must await recovery.
public protocol TransactionalFileSystemAdapter: FileSystemAdapter {
    func enableReadWriteTransaction(_ volume: VolumeSnapshot) async throws -> URL
}
/// 实现必须重新读取系统状态，不能返回调用方提交的旧快照。
public protocol VolumeResolver: Sendable {
    func resolve(_ identity: VolumeIdentity) async throws -> VolumeSnapshot
}
/// 产品中的明确缺失状态，绝不模拟引擎成功。
public struct UnavailableEngine: FileSystemAdapter {
    public init() {}
    public func capability() async -> EngineCapability {
        .init(available: false, finderReadWrite: false, reason: VolumeError.engineUnavailable.localizedDescription)
    }
    public func inspect(_ volume: VolumeSnapshot) async throws -> SafetyStatus { throw VolumeError.engineUnavailable }
    public func mountReadWrite(_ volume: VolumeSnapshot) async throws -> URL { throw VolumeError.engineUnavailable }
    public func unmount(_ volume: VolumeSnapshot) async throws { throw VolumeError.engineUnavailable }
}
/// Manual and automatic requests share preflight, exclusion and result checks.
/// The adapter still owns held-resource checks and actual engine readiness.
public actor MountCoordinator {
    private let gate: DeviceOperationGate
    private let engine: any FileSystemAdapter
    private let resolver: any VolumeResolver
    private struct PendingRecovery {
        let volume: VolumeSnapshot
        let lease: DeviceOperationGate.Lease
        let cause: any Error
    }
    private var pending: [String: PendingRecovery] = [:]
    private var checkingRecovery: Set<String> = []
    public init(engine: any FileSystemAdapter, resolver: any VolumeResolver,
                gate: DeviceOperationGate = .shared) {
        self.engine = engine; self.resolver = resolver; self.gate = gate
    }
    public func enableReadWrite(expected: VolumeIdentity, automatic: Bool = false) async throws -> URL {
        let current = try await resolver.resolve(expected)
        guard expected == current.identity else { throw VolumeError.identityChanged }
        let lease = try gate.acquire(current.deviceGroup)
        var keepLease = false
        defer { if !keepLease { gate.release(lease) } }
        let capability = await engine.capability()
        guard capability.available && capability.finderReadWrite else { throw VolumeError.engineUnavailable }
        try WritePolicy.validateTarget(expected: expected, current: current)
        try validateMountState(current)
        if case .risk(let reason) = current.safety { throw VolumeError.unsafeVolume(reason) }
        try Task.checkCancellation()
        let transaction = engine as? any TransactionalFileSystemAdapter
        if transaction == nil {
            switch try await engine.inspect(current) {
            case .unknown: throw VolumeError.safetyUnknown
            case .risk(let reason): throw VolumeError.unsafeVolume(reason)
            case .clean: break
            }
        }
        let refreshed = try await resolver.resolve(expected)
        try WritePolicy.validateTarget(expected: expected, current: refreshed)
        try validateMountState(refreshed)
        if case .risk(let reason) = refreshed.safety { throw VolumeError.unsafeVolume(reason) }
        guard refreshed.deviceGroup == current.deviceGroup else { throw VolumeError.identityChanged }
        try Task.checkCancellation()
        do {
            // Exclusive preflight belongs INSIDE the same recovery scope as
            // writable activation. It is never replaced by a cached clean bit.
            let mounted: URL
            if let transaction { mounted = try await transaction.enableReadWriteTransaction(refreshed) }
            else { mounted = try await engine.mountReadWrite(refreshed) }
            let observed = try await resolver.resolve(expected)
            try WritePolicy.validateTarget(expected: expected, current: observed)
            if case .risk(let reason) = observed.safety { throw VolumeError.unsafeVolume(reason) }
            guard observed.deviceGroup == refreshed.deviceGroup,
                  observed.bsdName == refreshed.bsdName else { throw VolumeError.identityChanged }
            guard Self.isLocalMount(mounted), observed.mountState == .readWrite,
                  observed.mountURL?.standardizedFileURL == mounted.standardizedFileURL else {
                throw VolumeError.mountNotVerified
            }
            return mounted
        } catch {
            if await recoverAndVerify(refreshed) == nil {
                keepLease = true
                pending[current.deviceGroup] = .init(volume: refreshed, lease: lease, cause: error)
                gate.quarantine(lease)
                throw MountRecoveryError(cause: error)
            }
            throw error
        }
    }
    public nonisolated func isBusy(_ volume: VolumeSnapshot) -> Bool { gate.isBusy(volume.deviceGroup) }
    public nonisolated func requiresVerification(_ volume: VolumeSnapshot) -> Bool {
        gate.requiresVerification(volume.deviceGroup)
    }

    /// Explicit recheck only; never retries enabling writes. A new connection
    /// cannot be substituted for the failed request, even at the same USB port.
    public func verifyRecovery(expected: VolumeIdentity) async throws -> MountRecoveryOutcome {
        guard let entry = pending.values.first(where: { $0.volume.identity == expected }) else {
            if gate.requiresVerification(expected.devicePath) { throw VolumeError.identityChanged }
            return .nothingPending
        }
        let device = entry.volume.deviceGroup
        guard checkingRecovery.insert(device).inserted else { throw VolumeError.busy }
        defer { checkingRecovery.remove(device) }
        guard let outcome = await recoverAndVerify(entry.volume) else { throw MountRecoveryError(cause: entry.cause) }
        pending.removeValue(forKey: device)
        gate.release(entry.lease)
        return outcome
    }

    /// A refreshed/reconnected UI may request a recheck by group, but never
    /// supplies the recovery target. Only the retained original is forwarded.
    public func verifyRecovery(deviceGroup: String) async throws -> MountRecoveryOutcome {
        guard let entry = pending[deviceGroup] else { return .nothingPending }
        return try await verifyRecovery(expected: entry.volume.identity)
    }

    private func recoverAndVerify(_ original: VolumeSnapshot) async -> MountRecoveryOutcome? {
        // An unstructured task intentionally does not inherit cancellation.
        // Await it without a timeout race: the device lease outlives its work.
        let engine = self.engine, resolver = self.resolver
        return await Task.detached {
            switch await engine.recoverFailedMount(original) {
            case .unresolved: return nil
            case .deviceGone: return .disconnected
            case .settled: break
            }
            do {
                let current = try await resolver.resolve(original.identity)
                try WritePolicy.validateTarget(expected: original.identity, current: current)
                guard current.deviceGroup == original.deviceGroup, current.bsdName == original.bsdName else { return nil }
                switch current.mountState {
                case .readOnly:
                    guard let url = current.mountURL, Self.isLocalMount(url) else { return nil }
                    return .readOnly
                case .unmounted:
                    return current.mountURL == nil ? .unmounted : nil
                case .readWrite, .unknown: return nil
                }
            } catch { return nil }
        }.value
    }
    private static func isLocalMount(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
        url.query == nil && url.fragment == nil && url.standardizedFileURL.path != "/" &&
        !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
    }
    private func validateMountState(_ volume: VolumeSnapshot) throws {
        guard volume.mountState == .unmounted || volume.mountState == .readOnly else { throw VolumeError.busy }
    }
}
