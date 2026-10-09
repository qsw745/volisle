import Foundation
import Testing
@testable import VolisleCore

/// Several read-write sessions at once: one slot per disk, each pausing only
/// its own disk, ended one by one, found again after a relaunch.
@MainActor struct MountCyclesTests {
    private func volume(_ bsd: String, _ registry: UInt64, device: String) -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: device, mediaRegistryID: registry),
              bsdName: bsd, name: bsd, fileSystem: "ntfs", deviceName: "USB",
              totalBytes: 4096, availableBytes: nil, mountURL: URL(filePath: "/Volumes/" + bsd), mountState: .readOnly,
              isExternal: true, isProtected: false)
    }
    private let a = MountCyclesTests.make("disk7s1", 71, "usb-a")
    private let b = MountCyclesTests.make("disk8s1", 81, "usb-b")
    private let c = MountCyclesTests.make("disk9s1", 91, "usb-c")
    private static func make(_ bsd: String, _ registry: UInt64, _ device: String) -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: device, mediaRegistryID: registry),
              bsdName: bsd, name: bsd, fileSystem: "ntfs", deviceName: "USB",
              totalBytes: 4096, availableBytes: nil, mountURL: URL(filePath: "/Volumes/" + bsd), mountState: .readOnly,
              isExternal: true, isProtected: false)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-cycles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func cycles(_ backend: Daemon, _ directory: URL, _ gate: DeviceOperationGate) -> MountCycles {
        let volumes = [a, b, c]
        return MountCycles(backend: backend, directory: directory, gate: gate) { disk in
            volumes.first { $0.bsdName == disk.bsdName && $0.identity.mediaRegistryID == disk.registryID }?.deviceGroup
        }
    }

    @Test func twoDisksHaveTheirOwnSessionsAndEachPausesOnlyItsDisk() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cycles = cycles(backend, directory, gate)
        #expect(gate.isBusy("usb-c"), "everything waits until the daemon's records are known")
        await cycles.refresh()
        #expect(!gate.isBusy("usb-c"))
        #expect(await cycles.startWrite(a, resolver: Fixed(a)))
        #expect(await cycles.startWrite(b, resolver: Fixed(b)))
        #expect(cycles.isWritable(a) && cycles.isWritable(b) && !cycles.isWritable(c))
        #expect(gate.isBusy("usb-a") && gate.isBusy("usb-b") && !gate.isBusy("usb-c"))
        #expect(try await cycles.verifiedWritableURL(for: b).lastPathComponent == backend.ids["disk8s1"]!.uuidString.lowercased())
        // Full: the third disk waits, and says which disks hold the places.
        #expect(cycles.writeRefusal(for: c) == .full(cycles.slots.compactMap { $0.disk }))
        #expect(cycles.writeRefusal(for: a) == .ownSession)
        #expect(await cycles.startWrite(c, resolver: Fixed(c)) == false)
        #expect(!backend.started.contains("disk9s1"))
        // Ending A's session leaves B written and frees a place for C.
        var ended: [String] = []
        cycles.willEndWriteSession = { operation, _ in ended.append(operation?.disk.bsdName ?? "-") }
        try await cycles.prepareForEject(a)
        #expect(ended == ["disk7s1"])
        #expect(!cycles.isWritable(a) && cycles.isWritable(b) && !gate.isBusy("usb-a") && gate.isBusy("usb-b"))
        #expect(await cycles.startWrite(c, resolver: Fixed(c)))
        #expect(cycles.isWritable(c) && cycles.writeSessions.count == 2)
        await cycles.endAllSessions()
        #expect(cycles.writeSessions.isEmpty && !gate.isBusy("usb-b") && !gate.isBusy("usb-c"))
        #expect(!gate.hasOtherOperations(excluding: nil), "nothing left paused for an update")
    }

    @Test func aRelaunchFindsEverySessionAgain() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = cycles(backend, directory, gate)
        await first.refresh()
        #expect(await first.startWrite(a, resolver: Fixed(a)))
        #expect(await first.startWrite(b, resolver: Fixed(b)))
        // Quit without ending them: a new process reads both intents back.
        let relaunchGate = DeviceOperationGate()
        let again = cycles(backend, directory, relaunchGate)
        await again.refresh()
        #expect(again.isWritable(a) && again.isWritable(b))
        #expect(relaunchGate.isBusy("usb-a") && relaunchGate.isBusy("usb-b") && !relaunchGate.isBusy("usb-c"))
        #expect(backend.actions.filter { $0 == .resolveWrite }.count == 2, "each by its own ID, never started again")
    }

    @Test func recordsWithoutALocalIntentAreTakenOverOneSlotEach() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // E.g. the intent files were lost: the daemon still holds two sessions.
        _ = try backend.make(a, write: true)
        _ = try backend.make(b, write: true)
        let cycles = cycles(backend, directory, gate)
        await cycles.refresh()
        #expect(cycles.isWritable(a) && cycles.isWritable(b) && cycles.slots.count == 2)
        #expect(!backend.started.contains("disk7s1"), "taken over, not started")
    }

    @Test func aRequestThatCouldNotBeResolvedIsNeverTakenOverBySecondSlot() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = cycles(backend, directory, gate)
        await first.refresh()
        #expect(await first.startWrite(a, resolver: Fixed(a)))
        // Relaunch; resolving A's own request fails once, the daemon's list still shows it.
        backend.resolveFails = true
        let again = cycles(backend, directory, DeviceOperationGate())
        await again.refresh()
        #expect(again.slots.count == 1, "A's record stays with the slot that owns its request")
        #expect(FileMountCycleIntentStore.slots(in: directory).count == 1)
        backend.resolveFails = false
        await again.refresh()
        #expect(again.isWritable(a) && again.hasFreePlace)
    }

    @Test func aSessionSettledWhileItsDiskWasNotListedPausesOnlyItsDiskOnceListed() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var listed: [VolumeSnapshot] = []
        let cycles = MountCycles(backend: backend, directory: directory, gate: gate) { disk in
            listed.first { $0.bsdName == disk.bsdName && $0.identity.mediaRegistryID == disk.registryID }?.deviceGroup
        }
        await cycles.refresh()
        #expect(await cycles.startWrite(a, resolver: Fixed(a)))
        #expect(gate.isBusy("usb-b"), "the disk list was empty: every disk waits")
        listed = [a, b]
        cycles.settleBarriers()
        #expect(gate.isBusy("usb-a") && !gate.isBusy("usb-b"))
    }

    @Test func aRefusalStaysWithItsDiskWhileAnotherStarts() async throws {
        let backend = Daemon(), gate = DeviceOperationGate(), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.refuse["disk7s1"] = .ntfsDirty
        let cycles = cycles(backend, directory, gate)
        await cycles.refresh()
        #expect(await cycles.startWrite(a, resolver: Fixed(a)))
        #expect(cycles.session(for: a)?.lastError == HelperDiskFailure.ntfsDirty.localizedDescription)
        #expect(cycles.lastRefusal?.failure == .ntfsDirty && !cycles.isWritable(a))
        #expect(await cycles.startWrite(b, resolver: Fixed(b)))
        #expect(cycles.isWritable(b))
        #expect(cycles.session(for: a)?.lastError == HelperDiskFailure.ntfsDirty.localizedDescription, "A still says why")
    }
}

private struct Fixed: VolumeResolver {
    let value: VolumeSnapshot
    init(_ value: VolumeSnapshot) { self.value = value }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { value }
}

/// The daemon's records for several disks, as HelperMountCycleService keeps them.
@MainActor private final class Daemon: MountCycleClientBackend {
    var records: [UUID: HelperMountOperation] = [:]
    var ids: [String: UUID] = [:]
    var refuse: [String: HelperDiskFailure] = [:]
    var started: [String] = []
    var resolveFails = false
    var actions: [HelperMountCommand.Action] = []
    private var sequence: UInt64 = 0
    func make(_ volume: VolumeSnapshot, id: UUID = UUID(), write: Bool) throws -> HelperMountOperation {
        let disk = try prepare(volume)
        sequence += 1
        var record = HelperMountOperation(id: id, disk: disk, ownerUID: 501, bootSession: "boot", phase: .writeMounted,
            restoreRequired: true, report: .init(version: 1, bsdName: disk.bsdName, registryID: disk.registryID, byteCount: 4096,
                bootSHA256: String(repeating: "a", count: 64), effectiveUID: 0, writeAccessAvailable: false, fileSystemHealthChecked: false))
        record.purpose = write ? .readWrite : nil
        record.sequence = sequence
        if let failure = refuse[disk.bsdName] { record.phase = .finished; record.failure = failure }
        else if !write { record.phase = .finished }
        records[id] = record; ids[disk.bsdName] = id
        return record
    }
    func prepare(_ volume: VolumeSnapshot) throws -> HelperDiskRequest {
        try .init(bsdName: volume.bsdName, registryID: volume.identity.mediaRegistryID!, byteCount: 4096)
    }
    func send(_ command: HelperMountCommand) async throws -> HelperMountOperation? {
        actions.append(command.action)
        switch command.action {
        case .start, .startWrite:
            let disk = command.disk!
            guard records.values.filter({ $0.phase != .finished }).count < HelperMountCycleService.maximumActive else { throw HelperDiskFailure.busy }
            started.append(disk.bsdName)
            let volume = MountCyclesTests.volumeFor(disk)
            return try make(volume, id: command.id!, write: command.action == .startWrite)
        case .resolve, .resolveWrite:
            if resolveFails { throw HelperServiceError.unavailable }
            return records[command.id!]
        case .status:
            return records[command.id!]
        case .recover:
            records[command.id!]?.phase = .finished
            return records[command.id!]
        case .latest:
            return records.values.max { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        default: return nil
        }
    }
    func list() async throws -> [HelperMountOperation] {
        let all = records.values.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        let newestFinished = all.last { $0.phase == .finished }
        return all.filter { $0.phase != .finished || $0.id == newestFinished?.id }
    }
    func verifyWritable(_ record: HelperMountOperation) async throws -> URL {
        URL(filePath: "/private/var/run/volisle-write-mounts/" + record.id.uuidString.lowercased())
    }
    func verifyRestored(_ record: HelperMountOperation) throws -> MountCycleVerifiedState { .readOnly }
    func mediaPresent(_ record: HelperMountOperation) -> Bool { true }
    func waitForUpdate() async throws { }
}

extension MountCyclesTests {
    static func volumeFor(_ disk: HelperDiskRequest) -> VolumeSnapshot {
        make(disk.bsdName, disk.registryID, "usb-" + disk.bsdName)
    }
}
