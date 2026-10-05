import Testing
@testable import VolisleCore

@Suite struct MountRefusalTests {
    @Test func recognizesFileSystemRefusalsFromMountOutput() {
        let prefix = "mount: Operation ended with error: "
        #expect(HelperDiskFailure.mountRefusal(prefix + "NTFS 卷带有脏标记，拒绝可写挂载。\nmount: Unable to invoke task") == .ntfsDirty)
        #expect(HelperDiskFailure.mountRefusal(prefix + "无法排除 Windows 休眠风险，拒绝可写挂载。") == .windowsHibernated)
        #expect(HelperDiskFailure.mountRefusal(prefix + "NTFS 日志未通过安全检查，拒绝可写挂载。") == .windowsLogUnclean)
    }

    @Test func unknownOrMissingReasonsStayGeneric() {
        #expect(HelperDiskFailure.mountRefusal("") == nil)
        #expect(HelperDiskFailure.mountRefusal("mount: Operation ended with error: 无法确认 NTFS 卷安全，拒绝可写挂载。") == nil)
        #expect(HelperDiskFailure.mountRefusal("脏标记 without the mount prefix") == nil)
        #expect(HelperDiskFailure.from(HelperDiskFailure.windowsLogUnclean) == .windowsLogUnclean)
    }
}
