// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import os

struct AttributeUpdate {
    private static let log = Logger(subsystem: "Volisle.NTFSModule", category: "AttributeUpdate")
    private let request: FSItem.SetAttributesRequest
    private let noChanges: FSItem.Attribute
    private let mode: UInt32?
    private let size: Int64?
    private let atime: nk_timestamp?
    private let mtime: nk_timestamp?
    private let btime: nk_timestamp?
    /// Finder's hidden flag, stored as the Windows HIDDEN attribute.
    private let hidden: Bool?
    private let flagsHeld: Bool

    /// `creating`: the attributes a new item is created with. Its write bit is
    /// not applied then: POSIX checks permissions when a file is opened, so
    /// `open(O_CREAT|O_WRONLY, 0444)` followed by writes (as git does) must work.
    init(_ request: FSItem.SetAttributesRequest, kind: FSItem.ItemType, privateModes: Bool = false,
         currentFlags: UInt32 = 0, creating: Bool = false) throws {
        self.request = request
        request.consumedAttributes = []
        // What NTFS cannot hold (link count, ctime, backup and added time, other
        // owners, other flags) is left unconsumed, as FSKit asks, not refused:
        // refusing made a Finder copy of, e.g., a folder with a custom icon stop.
        if request.isValid(.type) && request.type != kind { throw POSIXError(.EINVAL) }
        let hiddenFlag = UInt32(UF_HIDDEN)
        if request.isValid(.flags), request.flags & hiddenFlag != currentFlags & hiddenFlag {
            hidden = request.flags & hiddenFlag != 0
        } else { hidden = nil }
        // Other flag bits have no NTFS counterpart: consumed only when unchanged.
        flagsHeld = request.isValid(.flags) && request.flags & ~hiddenFlag == currentFlags & ~hiddenFlag
        if privateModes {
            mode = request.isValid(.mode) && (kind == .file || kind == .directory) ? request.mode & 0o7777 : nil
        } else if creating {
            mode = nil
        } else {
            // Like exFAT on macOS: a Windows disk carries no Mac permissions,
            // and this noowners mount gives every local user owner access.
            // Keep only what NTFS can hold: a file's owner-write bit, stored
            // as the Windows READONLY attribute. Other bits are not persisted.
            mode = request.isValid(.mode) && kind == .file ? (request.mode & 0o200 != 0 ? 0o644 : 0o444) : nil
        }
        if request.isValid(.mode) {
            let permissions = request.mode & 0o7777
            let expectedType: UInt32 = kind == .directory ? 0o040000 : kind == .symlink ? 0o120000 : 0o100000
            guard request.mode & ~0o177777 == 0,
                  request.mode & 0o170000 == 0 || request.mode & 0o170000 == expectedType else { throw POSIXError(.EINVAL) }
            let supported: [UInt32] = kind == .file ? [0o400, 0o600, 0o444, 0o644] : (kind == .directory ? [0o700, 0o755] : [0o755])
            guard !privateModes || supported.contains(permissions) else {
                // Log only capability metadata, never document names or contents.
                Self.log.error("拒绝未支持的权限：目录=\(kind == .directory, privacy: .public) 模式=\(String(permissions, radix: 8), privacy: .public)；未修改文件")
                throw POSIXError(.ENOTSUP)
            }
        }
        var accepted: FSItem.Attribute = []
        if request.isValid(.type) { accepted.insert(.type) }
        if request.isValid(.uid) && request.uid == getuid() { accepted.insert(.uid) }
        if request.isValid(.gid) && request.gid == getgid() { accepted.insert(.gid) }
        if flagsHeld && hidden == nil { accepted.insert(.flags) }
        if (kind != .file || creating) && !privateModes && request.isValid(.mode) { accepted.insert(.mode) }
        noChanges = accepted
        if request.isValid(.size) {
            guard kind == .file else { throw POSIXError(kind == .directory ? .EISDIR : .ENOTSUP) }
            guard let value = Int64(exactly: request.size) else { throw POSIXError(.EFBIG) }
            size = value
        } else { size = nil }
        atime = try request.isValid(.accessTime) ? Self.timestamp(request.accessTime) : nil
        mtime = try request.isValid(.modifyTime) ? Self.timestamp(request.modifyTime) : nil
        btime = try request.isValid(.birthTime) ? Self.timestamp(request.birthTime) : nil
    }

    private static func timestamp(_ value: timespec) throws -> nk_timestamp {
        guard (0..<1000000000).contains(value.tv_nsec) else { throw POSIXError(.EINVAL) }
        // Validate before ANY mutation, including size in the same request.
        let (epochSeconds, addOverflow) = Int64(value.tv_sec).addingReportingOverflow(11644473600)
        let (ticks, multiplyOverflow) = epochSeconds.multipliedReportingOverflow(by: 10000000)
        let (_, fractionOverflow) = ticks.addingReportingOverflow(Int64(value.tv_nsec / 100))
        guard !addOverflow, epochSeconds >= 0, !multiplyOverflow, !fractionOverflow else { throw POSIXError(.EINVAL) }
        return nk_timestamp(seconds: Int64(value.tv_sec), nanoseconds: Int32(value.tv_nsec))
    }

    func apply(setMode: (UInt32) throws -> Void, truncate: (Int64) throws -> Void,
               setTimes: (nk_timestamp?, nk_timestamp?, nk_timestamp?) throws -> Void,
               setHidden: (Bool) throws -> Void = { _ in }) throws {
        request.consumedAttributes.formUnion(noChanges)
        if let hidden {
            try setHidden(hidden)
            if flagsHeld { request.consumedAttributes.insert(.flags) }
        }
        // Clear READONLY before an explicitly requested truncate, and set it
        // only after other changes succeed. Consume only persisted attributes.
        if let mode, mode & 0o200 != 0 { try setMode(mode); request.consumedAttributes.insert(.mode) }
        if let size {
            try truncate(size)
            request.consumedAttributes.insert(.size)
        }
        if atime != nil || mtime != nil || btime != nil {
            try setTimes(atime, mtime, btime)
            if atime != nil { request.consumedAttributes.insert(.accessTime) }
            if mtime != nil { request.consumedAttributes.insert(.modifyTime) }
            if btime != nil { request.consumedAttributes.insert(.birthTime) }
        }
        if let mode, mode & 0o200 == 0 { try setMode(mode); request.consumedAttributes.insert(.mode) }
    }
}
