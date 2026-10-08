import Foundation
import Darwin

/// What a write mount reports about its own journal (the extension's
/// NTFSVolume.durabilityReport, a virtual attribute on the mount's root):
/// everything written so far lies in epochs below `writtenBelow`; epochs below
/// `durableBelow` are no longer on record, so an unplug cannot roll them back.
public struct WriteDurability: Equatable, Sendable {
    public let session: UUID
    public let writtenBelow: UInt64
    public let durableBelow: UInt64
    static let attribute = "top.qisw.volisle.durability"

    init(session: UUID, writtenBelow: UInt64, durableBelow: UInt64) {
        self.session = session; self.writtenBelow = writtenBelow; self.durableBelow = durableBelow
    }
    /// "v1 <session> <writtenBelow> <durableBelow>"; anything else is not a report.
    init?(text: String) {
        let parts = text.split(separator: " ")
        guard parts.count == 4, parts[0] == "v1", let session = UUID(uuidString: String(parts[1])),
              let written = UInt64(parts[2]), let durable = UInt64(parts[3]) else { return nil }
        self.init(session: session, writtenBelow: written, durableBelow: durable)
    }
    /// Everything written when `mark` was read is past rollback now, in the same journal session.
    public func covers(_ mark: WriteDurability) -> Bool {
        session == mark.session && durableBelow >= mark.writtenBelow
    }

    /// The report of the write mount at `root`. `flush` first pushes the
    /// kernel's cached writes there into the extension, so the report covers a
    /// copy that just finished. nil: an extension without the report, no write
    /// session (stopped, read-only), or the flush failed.
    static func read(root: URL, flush: Bool) -> WriteDurability? {
        let path = root.path
        if flush && sync_volume_np(path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT) != 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(path, attribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard count > 0 else { return nil }
        return WriteDurability(text: String(decoding: buffer.prefix(count), as: UTF8.self))
    }
}
