import Darwin
import Foundation
import Testing
@testable import VolisleCore

private typealias Loan = SystemHelperWriteMountBackend.DeviceLoan

/// Only the privileged syscalls are replaced; the real lending, rollback and
/// mount lifetime code operate on both complete device-node snapshots.
private final class DeviceNodes: Loan.Access, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes = [
        "/dev/disk7s1": Loan.Attributes(uid: 0, gid: 5, mode: mode_t(S_IFBLK) | 0o640, device: 700, inode: 1),
        "/dev/rdisk7s1": Loan.Attributes(uid: 0, gid: 5, mode: mode_t(S_IFCHR) | 0o640, device: 701, inode: 2)
    ]
    private var rejectedMode: (String, mode_t)?
    func read(_ path: String) throws -> Loan.Attributes {
        try lock.withLock {
            guard let attributes = nodes[path] else { throw POSIXError(.ENOENT) }
            return attributes
        }
    }
    func changeOwner(_ path: String, uid: uid_t, gid: gid_t) throws {
        try lock.withLock {
            guard var attributes = nodes[path] else { throw POSIXError(.ENOENT) }
            attributes.uid = uid; attributes.gid = gid; nodes[path] = attributes
        }
    }
    func changeMode(_ path: String, mode: mode_t) throws {
        try lock.withLock {
            guard var attributes = nodes[path] else { throw POSIXError(.ENOENT) }
            if let (rejectedPath, rejected) = rejectedMode, path == rejectedPath, mode == rejected {
                throw POSIXError(.EPERM)
            }
            attributes.mode = attributes.mode & mode_t(S_IFMT) | mode; nodes[path] = attributes
        }
    }
    func rejectMode(_ path: String, _ mode: mode_t) { lock.withLock { rejectedMode = (path, mode) } }
    func replaceBlockNode() {
        lock.withLock {
            nodes["/dev/disk7s1"] = Loan.Attributes(uid: 0, gid: 5, mode: mode_t(S_IFBLK) | 0o640,
                                                  device: 900, inode: 9)
        }
    }
    func expectRestored() throws {
        for (path, kind, device, inode) in [("/dev/disk7s1", S_IFBLK, 700, 1), ("/dev/rdisk7s1", S_IFCHR, 701, 2)] {
            #expect(try read(path) == Loan.Attributes(uid: 0, gid: 5, mode: mode_t(kind) | 0o640,
                                                     device: dev_t(device), inode: ino_t(inode)))
        }
    }
}

struct DeviceLoanTests {
    @Test("挂载返回后立即还原设备权限，再允许后续核验")
    func returnsPermissionsBeforeMountScopeReturns() async throws {
        let nodes = DeviceNodes()
        let loan = try Loan.lend("disk7s1", to: 501, using: nodes)
        try await loan.duringMount {
            let block = try nodes.read("/dev/disk7s1"), raw = try nodes.read("/dev/rdisk7s1")
            #expect(block.uid == 501)
            #expect(raw.mode & 0o7777 == 0o600)
        }
        try nodes.expectRestored()
    }

    @Test("挂载失败也还原两种设备节点，并保留挂载错误")
    func failedMountReturnsPermissions() async throws {
        let nodes = DeviceNodes()
        let loan = try Loan.lend("disk7s1", to: 501, using: nodes)
        await #expect(throws: HelperDiskFailure.mountFailed) {
            try await loan.duringMount { throw HelperDiskFailure.mountFailed }
        }
        try nodes.expectRestored()
    }

    @Test("第二个设备节点借出失败，已改变的节点全部回滚")
    func partiallyLentNodesRollBack() throws {
        let nodes = DeviceNodes()
        nodes.rejectMode("/dev/rdisk7s1", 0o600)
        #expect(throws: HelperDiskFailure.unavailable) { try Loan.lend("disk7s1", to: 501, using: nodes) }
        try nodes.expectRestored()
    }

    @Test("任一权限还原失败必须阻止挂载成功，并继续还原另一节点")
    func restorationFailureBlocksMountSuccess() async throws {
        let nodes = DeviceNodes()
        let loan = try Loan.lend("disk7s1", to: 501, using: nodes)
        nodes.rejectMode("/dev/disk7s1", 0o640)
        await #expect(throws: HelperDiskFailure.unavailable) { try await loan.duringMount {} }
        #expect(try nodes.read("/dev/rdisk7s1") == Loan.Attributes(uid: 0, gid: 5,
            mode: mode_t(S_IFCHR) | 0o640, device: 701, inode: 2))
    }

    @Test("热拔插替换同名节点时不改动新设备的权限，并报告未还原")
    func replacedDeviceNodeIsNotRestoredAsOriginal() async throws {
        let nodes = DeviceNodes()
        let loan = try Loan.lend("disk7s1", to: 501, using: nodes)
        await #expect(throws: HelperDiskFailure.unavailable) {
            try await loan.duringMount { nodes.replaceBlockNode() }
        }
        #expect(try nodes.read("/dev/disk7s1") == Loan.Attributes(uid: 0, gid: 5,
            mode: mode_t(S_IFBLK) | 0o640, device: 900, inode: 9))
        #expect(try nodes.read("/dev/rdisk7s1").uid == 0)
    }
}
