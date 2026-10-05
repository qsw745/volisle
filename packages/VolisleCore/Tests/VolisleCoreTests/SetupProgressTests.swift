import Testing
@testable import VolisleCore

@Test("设置进度：按顺序给出下一步，三步都完成才算完成")
func setupProgressOrder() {
    #expect(SetupProgress(helperConnected: false, extensionEnabled: false, fullDiskAccess: nil).current == .backgroundComponent)
    #expect(SetupProgress(helperConnected: false, extensionEnabled: true, fullDiskAccess: nil).current == .backgroundComponent)
    #expect(SetupProgress(helperConnected: true, extensionEnabled: false, fullDiskAccess: true).current == .fileSystemExtension)
    let missingAccess = SetupProgress(helperConnected: true, extensionEnabled: true, fullDiskAccess: false)
    #expect(missingAccess.current == .fullDiskAccess && !missingAccess.isComplete && missingAccess.doneCount == 2)
    let done = SetupProgress(helperConnected: true, extensionEnabled: true, fullDiskAccess: true)
    #expect(done.isComplete && done.current == nil && done.doneCount == 3)
}

@Test("后台组件未连接时无法确认磁盘权限；旧版后台组件不报告时不卡住设置")
func setupProgressFullDiskAccess() {
    #expect(!SetupProgress(helperConnected: false, extensionEnabled: true, fullDiskAccess: true).isDone(.fullDiskAccess))
    #expect(SetupProgress(helperConnected: true, extensionEnabled: true, fullDiskAccess: nil).isComplete)
}

@Test("完全磁盘访问检测：能打开即有权限，打不开即没有")
func fullDiskAccessProbe() {
    #expect(HelperStatus.probeFullDiskAccess(path: "/etc/hosts"))
    #expect(!HelperStatus.probeFullDiskAccess(path: "/nonexistent/volisle-probe"))
}
