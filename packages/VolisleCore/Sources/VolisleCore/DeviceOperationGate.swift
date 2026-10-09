import Foundation

/// Process-wide exclusion for operations that change a physical device's mount
/// state. A lease survives suspension and cancellation until the OS/engine call
/// actually returns. It does not replace the adapter's device-handle validation.
public final class DeviceOperationGate: @unchecked Sendable {
    public static let shared = DeviceOperationGate()
    private let lock = NSLock()
    /// A pause of new operations on every device, or on one (a read-write
    /// session pauses only its own disk; an operation under way, all of them).
    enum Scope: Equatable, Sendable { case all, device(String) }
    private var barriers: [UUID: Scope] = [:]
    private var owners: [String: UUID] = [:]
    private var awaitingVerification: Set<String> = []
    public init() {}

    struct Lease: Sendable { let device: String; let owner: UUID }
    func acquire(_ device: String) throws -> Lease {
        try lock.withLock {
            guard !device.isEmpty else { throw VolumeError.unstableIdentity }
            guard owners[device] == nil, !paused(device) else { throw VolumeError.busy }
            let lease = Lease(device: device, owner: UUID())
            owners[device] = lease.owner
            return lease
        }
    }
    func release(_ lease: Lease) {
        lock.withLock {
            if owners[lease.device] == lease.owner {
                owners.removeValue(forKey: lease.device)
                awaitingVerification.remove(lease.device)
            }
        }
    }
    func quarantine(_ lease: Lease) {
        lock.withLock {
            if owners[lease.device] == lease.owner { awaitingVerification.insert(lease.device) }
        }
    }
    func suspendNewOperations(_ scope: Scope = .all) -> UUID {
        lock.withLock { let id = UUID(); barriers[id] = scope; return id }
    }
    /// Widens or narrows a pause in place, so there is never a moment without it.
    func change(_ id: UUID, to scope: Scope) { lock.withLock { if barriers[id] != nil { barriers[id] = scope } } }
    func resumeOperations(_ id: UUID) { _ = lock.withLock { barriers.removeValue(forKey: id) } }
    /// Anything else under way or paused anywhere (an update needs every disk quiet).
    func hasOtherOperations(excluding id: UUID?) -> Bool {
        lock.withLock { !owners.isEmpty || barriers.keys.contains(where: { $0 != id }) }
    }
    /// Anything else under way on this device, or a pause covering it.
    func hasOtherOperations(on device: String, excluding id: UUID?) -> Bool {
        lock.withLock {
            owners[device] != nil || barriers.contains { $0.key != id && ($0.value == .all || $0.value == .device(device)) }
        }
    }
    private func paused(_ device: String) -> Bool {
        barriers.values.contains { $0 == .all || $0 == .device(device) }
    }
    public func requiresVerification(_ device: String) -> Bool {
        lock.withLock { awaitingVerification.contains(device) }
    }
    public func isBusy(_ device: String) -> Bool { lock.withLock { owners[device] != nil || paused(device) } }
}
