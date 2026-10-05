import Foundation
import Testing
import Darwin
@testable import VolisleCore

struct ReplacementRecoveryTests {
    private func fixture() throws -> (URL, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("volisle-recovery-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = root.appendingPathComponent("store"), source = root.appendingPathComponent("source"), dest = root.appendingPathComponent("dest")
        for url in [store, source, dest] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return (root, store, source, dest)
    }
    private func journal(_ store: URL, old: Data, new: Data) throws -> URL {
        let binding = ReplacementBinding(serial: "1234567890abcdef", bootHash: String(repeating: "a", count: 64),
            directory: "/", source: "draft.txt", target: "document.txt", backup: ".old",
            oldReference: 0x1000000000040, newReference: 0x1000000000041)
        let record = try ReplacementJournal(at: store.appendingPathComponent(UUID().uuidString), binding: binding,
            before: .of(old), after: .of(new), failClosed: {})
        try record.publish {}; record.close(); return record.url
    }
    @Test func exportsBothVersionsWithoutChangingSourceOrJournal() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("旧内容".utf8), new = Data(repeating: 53, count: 1024 * 1024 + 7)
        let path = try journal(store, old: old, new: new)
        try old.write(to: source.appendingPathComponent(".old")); try new.write(to: source.appendingPathComponent("document.txt"))
        let records = try ReplacementRecoveryCatalog.scan(at: store)
        #expect(records.count == 1 && records[0].canExport)
        let draft = try ReplacementRecoveryExport.stage(record: records[0], source: source, destination: dest, checkSource: { _ in })
        let result = try draft.commit()
        #expect(result.exportedCount == 2)
        #expect(try Data(contentsOf: result.directory.appendingPathComponent("旧版本.txt")) == old)
        #expect(try Data(contentsOf: result.directory.appendingPathComponent("新版本.txt")) == new)
        #expect(try Data(contentsOf: source.appendingPathComponent(".old")) == old)
        #expect(try Data(contentsOf: source.appendingPathComponent("document.txt")) == new)
        #expect(try ReplacementJournal.inspect(at: path).state?.phase == "published")
    }
    @Test func mismatchAndMissingAreNotReportedAsRecovered() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data("old".utf8), new: Data("new".utf8))
        try Data("changed".utf8).write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        #expect(throws: ReplacementRecoveryError.noMatchingVersions) {
            _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
    @Test func damagedRecordCannotCreateExport() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try journal(store, old: Data(), new: Data())
        try Data("{".utf8).write(to: url.appendingPathComponent("000003.json"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        #expect(!record.canExport)
        #expect(throws: ReplacementRecoveryError.invalidRecord) {
            _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
    @Test func sourceLinksAreNeverFollowedAndPartialResultIsExplicit() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old".utf8), new = Data("new".utf8)
        _ = try journal(store, old: old, new: new)
        let outside = root.appendingPathComponent("outside"); try old.write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent(".old"), withDestinationURL: outside)
        try new.write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let draft = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in })
        let result = try draft.commit()
        #expect(result.exportedCount == 1)
        #expect(result.versions[0].status == "unreadable")
        #expect(try Data(contentsOf: outside) == old)
    }
    @Test func sourceLossDuringStreamingRemovesOnlyOurPartialOutput() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 5, count: 2 * 1024 * 1024)
        _ = try journal(store, old: data, new: data)
        try data.write(to: source.appendingPathComponent("document.txt"))
        let sentinel = dest.appendingPathComponent("existing.txt"); try Data("keep".utf8).write(to: sentinel)
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        var checks = 0
        #expect(throws: ReplacementRecoveryError.changedSource) {
            _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in
                checks += 1; if checks == 4 { throw ReplacementRecoveryError.changedSource }
            })
        }
        #expect(checks == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path) == ["existing.txt"])
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }
    @Test func destinationLinksAndSourceDirectoryAreRejected() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dest)
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        for destination in [link, source, source.appendingPathComponent("child")] {
            #expect(throws: ReplacementRecoveryError.invalidDestination) {
                _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: destination, checkSource: { _ in })
            }
        }
    }
    @Test func finalDestinationCollisionDoesNotOverwriteExistingFiles() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        try Data().write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        do {
            let draft = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in })
            let partial = try #require(FileManager.default.contentsOfDirectory(atPath: dest.path).first)
            let suffix = partial.dropFirst(".Volisle-Recovery-".count).prefix(8)
            let collision = dest.appendingPathComponent("盘屿恢复-" + suffix)
            try Data("keep".utf8).write(to: collision)
            #expect(throws: ReplacementRecoveryError.invalidDestination) { _ = try draft.commit() }
            #expect(try Data(contentsOf: collision) == Data("keep".utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).count == 1)
    }
    @Test func recordChangedAfterListingIsNotExported() throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try journal(store, old: Data(), new: Data())
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        try Data("{".utf8).write(to: url.appendingPathComponent("000003.json"))
        #expect(throws: ReplacementRecoveryError.invalidRecord) {
            _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in })
        }
    }
    @Test func mountValidatorRejectsAnOrdinaryFolderEvenIfSnapshotSaysReadOnly() throws {
        let (root, _, source, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fd = Darwin.open(source.path, O_RDONLY | O_DIRECTORY); defer { Darwin.close(fd) }
        let volume = testVolume(source)
        #expect(throws: ReplacementRecoveryError.sourceNotReadOnly) {
            try ReplacementRecoveryCoordinator.validateMountedSource(fd, volume: volume)
        }
    }
    private func testVolume(_ source: URL, writable: Bool = false) -> VolumeSnapshot {
        .init(identity: .init(volumeUUID: nil, mediaUUID: nil, devicePath: "recovery-device", mediaRegistryID: 123),
            bsdName: "disk999s1", name: "测试", fileSystem: "ntfs", deviceName: "测试", totalBytes: 4096,
            availableBytes: nil, mountURL: source, mountState: writable ? .readWrite : .readOnly, isExternal: true, isProtected: false)
    }
    @Test func wrongVolumeIsRejectedBeforeCreatingDestination() async throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let volume = testVolume(source), gate = DeviceOperationGate()
        let backend = RecoveryAccessBackend(gate: gate)
        let resolver = RecoveryResolver(volume: volume)
        let coordinator = ReplacementRecoveryCoordinator(testBackend: backend, gate: gate, mounts: RecoveryMounts(resolver: resolver), sourceValidator: { _, _ in })
        await #expect(throws: ReplacementRecoveryError.differentVolume) {
            _ = try await coordinator.export(record, volume: volume, destination: dest, resolver: resolver)
        }
        #expect(await backend.lockObserved)
        #expect(await resolver.volume.mountState == .readOnly)
        #expect(!gate.isBusy(volume.deviceGroup))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
    @Test func writableSourceIsRejectedBeforeRequestingAccess() async throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let volume = testVolume(source, writable: true), backend = RecoveryAccessBackend(gate: .init())
        let coordinator = ReplacementRecoveryCoordinator(backend: backend, gate: .init())
        await #expect(throws: ReplacementRecoveryError.sourceNotReadOnly) {
            _ = try await coordinator.export(record, volume: volume, destination: dest, resolver: RecoveryResolver(volume: volume))
        }
        #expect(await backend.inspections == 0)
    }

    @Test func explicitImportedRecordUsesTheSameStrictReader() throws {
        let (root, store, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try journal(store, old: Data(), new: Data())
        let record = try ReplacementRecoveryCatalog.importRecord(at: path)
        #expect(record.canExport && record.filename == "document.txt")
        try Data("{".utf8).write(to: path.appendingPathComponent("000003.json"))
        #expect(throws: ReplacementRecoveryError.invalidRecord) { _ = try ReplacementRecoveryCatalog.importRecord(at: path) }
    }
    @Test func cancellationDuringCopyLeavesNoCompletedOrPartialOutput() async throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 6, count: 2 * 1024 * 1024)
        _ = try journal(store, old: data, new: data)
        try data.write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let task = Task {
            var checks = 0
            _ = try ReplacementRecoveryExport.stage(record: record, source: source, destination: dest, checkSource: { _ in
                checks += 1
                if checks == 4 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
    @Test func mediaRecheckFailureDiscardsStagedOutputAndReleasesGate() async throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        try Data().write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let volume = testVolume(source), gate = DeviceOperationGate()
        let backend = RecoveryAccessBackend(gate: gate, matching: true, failSecond: true)
        let resolver = RecoveryResolver(volume: volume)
        let coordinator = ReplacementRecoveryCoordinator(testBackend: backend, gate: gate, mounts: RecoveryMounts(resolver: resolver), sourceValidator: { _, _ in })
        await #expect(throws: HelperDiskFailure.unavailable) {
            _ = try await coordinator.export(record, volume: volume, destination: dest, resolver: resolver)
        }
        #expect(await backend.preparations == 2)
        #expect(!gate.isBusy(volume.deviceGroup))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func coordinatorReconnectsReadOnlyAndInspectsRawDeviceOnlyOnce() async throws {
        let (root, store, source, dest) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try journal(store, old: Data(), new: Data())
        try Data().write(to: source.appendingPathComponent("document.txt"))
        let record = try #require(ReplacementRecoveryCatalog.scan(at: store).first)
        let volume = testVolume(source), gate = DeviceOperationGate()
        let backend = RecoveryAccessBackend(gate: gate, matching: true)
        let resolver = RecoveryResolver(volume: volume)
        let coordinator = ReplacementRecoveryCoordinator(testBackend: backend, gate: gate, mounts: RecoveryMounts(resolver: resolver), sourceValidator: { _, _ in })
        let result = try await coordinator.export(record, volume: volume, destination: dest, resolver: resolver)
        #expect(result.exportedCount == 2)
        #expect(await backend.inspections == 1)
        #expect(await backend.preparations == 2)
        #expect(await resolver.volume.mountState == .readOnly)
        #expect(!gate.isBusy(volume.deviceGroup))
    }

}

private actor RecoveryResolver: VolumeResolver {
    var volume: VolumeSnapshot
    let mounted: VolumeSnapshot
    init(volume: VolumeSnapshot) { self.volume = volume; self.mounted = volume }
    func resolve(_ identity: VolumeIdentity) -> VolumeSnapshot { volume }
    func setMounted(_ mounted: Bool) {
        let v = self.mounted
        volume = .init(identity: v.identity, bsdName: v.bsdName, name: v.name, fileSystem: v.fileSystem,
            deviceName: v.deviceName, totalBytes: v.totalBytes, availableBytes: nil,
            mountURL: mounted ? v.mountURL : nil, mountState: mounted ? .readOnly : .unmounted,
            isExternal: true, isProtected: false)
    }
}
private struct RecoveryMounts: RecoveryReadOnlyMounting {
    let resolver: RecoveryResolver
    func unmount(_ volume: VolumeSnapshot) async { await resolver.setMounted(false) }
    func mount(_ volume: VolumeSnapshot) async { await resolver.setMounted(true) }
}
private actor RecoveryAccessBackend: DiskAccessBackend {
    let gate: DeviceOperationGate
    var inspections = 0
    var preparations = 0
    var lockObserved = false
    let matching: Bool
    let failSecond: Bool
    init(gate: DeviceOperationGate, matching: Bool = false, failSecond: Bool = false) {
        self.gate = gate; self.matching = matching; self.failSecond = failSecond
    }
    func prepare(_ volume: VolumeSnapshot) throws -> HelperDiskRequest {
        preparations += 1
        if failSecond && preparations == 2 { throw HelperDiskFailure.unavailable }
        return try .init(bsdName: "disk999s1", registryID: 123, byteCount: 4096)
    }
    func requestAuthorization(_ request: HelperDiskRequest) {}
    func inspect(_ request: HelperDiskRequest) throws -> HelperDiskReport {
        inspections += 1; lockObserved = gate.isBusy("recovery-device")
        return .init(version: 1, bsdName: "disk999s1", registryID: 123, byteCount: 4096,
            bootSHA256: String(repeating: matching ? "a" : "b", count: 64), effectiveUID: 0, writeAccessAvailable: false, fileSystemHealthChecked: false)
    }
}
