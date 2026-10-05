import Foundation
import VolisleCore
// 仅输出聚合结果；不得把磁盘描述原文写入公开日志。
let mountPrerequisites = NativeMountPrerequisites.current
print("原生挂载接口：\(mountPrerequisites.nativeAPIAvailable)，签名权限：\(mountPrerequisites.mountEntitlement.rawValue)，接入状态：\(mountPrerequisites.blocker.rawValue)")
let discovery = DiskDiscovery()
discovery.start()
RunLoop.main.run(until: Date().addingTimeInterval(3))
print(discovery.diagnosticSummary())
print("物理设备分组：\(Set(discovery.volumes.map(\.deviceGroup)).count)")
for volume in discovery.volumes {
    print("卷：\(volume.fileSystem)，状态：\(volume.mountState.rawValue)，稳定身份：\(volume.identity.supportsPersistentPreference)，MBR 摘要身份：\(volume.identity.mediaUUID == nil && volume.identity.mediaFingerprint != nil)，本次身份复核：\(discovery.revalidate(volume.identity)?.identity == volume.identity)，容量已知：\(volume.totalBytes != nil)")
}
discovery.stop()
