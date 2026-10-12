import DiskArbitration
import Testing
@testable import VolisleCore

@Suite struct NativeReadOnlyDiskStatusTests {
    @Test func aDissentingClientsBusyIsBusy() {
        #expect(NativeReadOnlyDisk.failure(status: DAReturn(kDAReturnBusy)) == .busy)
    }
    /// 2026-10-12, real disk: a copy in progress, every client approved, and the
    /// unmount call returned 0x10. It was reported as unavailable, so the write
    /// session was not kept.
    @Test func theUnmountCallsOwnBusyIsBusy() {
        #expect(NativeReadOnlyDisk.failure(status: 0xC000 | EBUSY) == .busy)
        #expect(NativeReadOnlyDisk.failure(status: EBUSY) == .busy)
    }
    @Test func permissionAndOtherStatusesKeepTheirMeaning() {
        #expect(NativeReadOnlyDisk.failure(status: DAReturn(kDAReturnNotPermitted)) == .permissionDenied)
        #expect(NativeReadOnlyDisk.failure(status: DAReturn(kDAReturnNotPrivileged)) == .permissionDenied)
        #expect(NativeReadOnlyDisk.failure(status: 0xC000 | EIO) == .unavailable)
        #expect(NativeReadOnlyDisk.failure(status: DAReturn(kDAReturnError)) == .unavailable)
    }
}
