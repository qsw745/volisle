import Foundation
import DiskArbitration
import Observation
import Darwin

@MainActor @Observable
public final class DiskDiscovery {
    public private(set) var volumes: [VolumeSnapshot] = []
    public private(set) var error: String?
    public private(set) var isRunning = false
    private var session: DASession?
    private var records: [String: VolumeSnapshot] = [:]
    public init() {}
    public func start() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            error = String(localized: "无法连接系统磁盘服务，请重新打开应用。"); return
        }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<DiskDiscovery>.fromOpaque(context).takeUnretainedValue().update(disk)
            }
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated {
                guard let context, let bsd = DADiskGetBSDName(disk) else { return }
                let owner = Unmanaged<DiskDiscovery>.fromOpaque(context).takeUnretainedValue()
                owner.records.removeValue(forKey: String(cString: bsd)); owner.publish()
            }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<DiskDiscovery>.fromOpaque(context).takeUnretainedValue().update(disk)
            }
        }, context)
        DASessionSetDispatchQueue(session, .main)
        error = nil; isRunning = true
    }
    public func stop() {
        if let session { DASessionSetDispatchQueue(session, nil) }
        session = nil; records.removeAll(); publish(); isRunning = false
    }
    public func refresh() { stop(); start() }
    /// 回调和 UI 均在主队列；只读取描述、挂载 flags 和容量，不遍历用户文件。
    private func update(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk), let copied = DADiskCopyDescription(disk) else { return }
        let name = String(cString: bsd)
        let d = copied as NSDictionary
        func text(_ key: CFString) -> String? { d[key] as? String }
        guard d[kDADiskDescriptionDeviceInternalKey] as? Bool == false else {
            records.removeValue(forKey: name); publish(); return
        }
        let kind = text(kDADiskDescriptionVolumeKindKey)
        // 系统认不出文件系统的 Windows 数据分区：可能是 BitLocker，交给后台组件确认。
        let unrecognizedWindows = kind == nil && d[kDADiskDescriptionMediaLeafKey] as? Bool == true &&
            d[kDADiskDescriptionMediaWholeKey] as? Bool == false &&
            text(kDADiskDescriptionMediaContentKey).map(HelperFormatPolicy.ntfsContents.contains) == true
        // 物理整盘/分区容器不当作卷；未知分区若系统没有卷信息也不冒称支持。
        guard kind != nil || d[kDADiskDescriptionVolumeNameKey] != nil || unrecognizedWindows else {
            records.removeValue(forKey: name); publish(); return
        }
        let url = d[kDADiskDescriptionVolumePathKey] as? URL
        var state: MountState = url == nil ? .unmounted : .unknown
        var available: Int64?
        var total = (d[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.int64Value
        if let url {
            var status = statfs()
            if statfs(url.path, &status) == 0 {
                state = status.f_flags & UInt32(MNT_RDONLY) != 0 ? .readOnly : .readWrite
                available = Int64(clamping: status.f_bavail) * Int64(status.f_bsize)
                total = Int64(clamping: status.f_blocks) * Int64(status.f_bsize)
            }
        }
        func uuid(_ key: CFString) -> String? {
            guard let value = d[key] else { return nil }
            if CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
                return CFUUIDCreateString(nil, (value as! CFUUID)) as String
            }
            return value as? String
        }
        let path = text(kDADiskDescriptionDevicePathKey) ?? ""
        let volumeID = uuid(kDADiskDescriptionVolumeUUIDKey)
        let mediaID = uuid(kDADiskDescriptionMediaUUIDKey)
        let evidence = MediaIdentityReader.read(disk)
        let previous = records[name]
        let same = previous?.identity.volumeUUID == volumeID && previous?.identity.mediaUUID == mediaID && previous?.identity.devicePath == path &&
            previous?.identity.mediaRegistryID == evidence.registryID && previous?.identity.mediaFingerprint == evidence.fingerprint
        let identity = VolumeIdentity(volumeUUID: volumeID, mediaUUID: mediaID, devicePath: path,
                                      connection: same ? (previous?.identity.connection ?? UUID()) : UUID(),
                                      mediaRegistryID: evidence.registryID, mediaFingerprint: evidence.fingerprint)
        let model = text(kDADiskDescriptionDeviceModelKey)?.trimmingCharacters(in: .whitespaces) ?? String(localized: "外接设备")
        records[name] = .init(identity: identity, bsdName: name,
            name: text(kDADiskDescriptionVolumeNameKey) ?? (unrecognizedWindows ? String(localized: "加密的 Windows 分区") : String(localized: "未命名卷")),
            fileSystem: unrecognizedWindows ? VolumeSnapshot.unrecognizedWindowsKind : kind ?? String(localized: "未知"),
            deviceName: model, totalBytes: total, availableBytes: available, mountURL: url,
            mountState: state, isExternal: true,
            isProtected: url?.path == "/" || url?.path.hasPrefix("/System/") == true,
            deviceProtocol: text(kDADiskDescriptionDeviceProtocolKey))
        publish()
    }
    private func publish() {
        volumes = records.values.sorted { ($0.deviceGroup, $0.name, $0.bsdName) < ($1.deviceGroup, $1.name, $1.bsdName) }
    }
    public func revalidate(_ identity: VolumeIdentity) -> VolumeSnapshot? {
        guard let cached = current(identity), let session,
              let disk = DADiskCreateFromBSDName(nil, session, cached.bsdName),
              DADiskCopyDescription(disk) != nil else { return nil }
        update(disk)
        return current(identity)
    }
    public func current(_ identity: VolumeIdentity) -> VolumeSnapshot? { volumes.first { $0.identity == identity } }
    /// 主动导出的诊断只包含版本、聚合数和文件系统种类，不含卷名、UUID、设备路径及文件内容。
    public func diagnosticSummary() -> String {
        DiagnosticReport(volumes: volumes, diskServiceRunning: isRunning,
                         engine: .init(available: false, finderReadWrite: false, reason: String(localized: "未接入"))).text
    }
}

extension DiskDiscovery: VolumeResolver {
    public func resolve(_ identity: VolumeIdentity) async throws -> VolumeSnapshot {
        guard let volume = revalidate(identity) else { throw VolumeError.disconnected }
        return volume
    }
}
