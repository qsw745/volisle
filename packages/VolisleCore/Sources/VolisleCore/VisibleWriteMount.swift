import Foundation
import Darwin

/// Created only by the helper and saved in its root-owned operation journal.
/// Device/inode bind cleanup to the directory we reserved, never another
/// disk's directory which happens to have the same label after a restart.
struct HelperWriteMountLocation: Codable, Equatable, Sendable {
    let name: String
    let device: UInt64
    let inode: UInt64
    var path: String { "/Volumes/" + name }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 240 &&
        !name.contains("/") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    func validate() throws {
        guard Self.validName(name), device != 0, inode != 0 else { throw HelperServiceError.invalidReply }
    }
    static func volumeName(_ label: String?) -> String {
        let clean = (label ?? "").unicodeScalars.map {
            $0 == "/" || CharacterSet.controlCharacters.contains($0) ? "_" : String($0)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for scalar in clean.unicodeScalars {
            if name.utf8.count + scalar.utf8.count > 200 { break }
            name.unicodeScalars.append(scalar)
        }
        if name.isEmpty || name == "." || name == ".." { return "未命名卷" }
        return name.hasPrefix(".") ? "_" + name : name
    }
}

/// /Volumes is shared with Disk Arbitration: reserve an unused name with an
/// exclusive mkdir, and never reuse or prune an existing directory/symlink.
struct VisibleWriteMountDirectory {
    var root = "/Volumes"
    var rootOwner: uid_t = 0
    private func openRoot() throws -> Int32 {
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperDiskFailure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == rootOwner, info.st_mode & 0o022 == 0 else {
            close(fd); throw HelperDiskFailure.unavailable
        }
        return fd
    }
    private func mounted(_ name: String, _ paths: Set<String>) -> Bool {
        let path = root + "/" + name
        return paths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
    func reserve(label: String?, owner: uid_t, mounted: Set<String>) throws -> HelperWriteMountLocation {
        guard owner != 0, owner != .max else { throw HelperDiskFailure.invalidRequest }
        let fd = try openRoot()
        defer { close(fd) }
        let base = HelperWriteMountLocation.volumeName(label)
        for number in 0..<1000 {
            let name = base + (number == 0 ? "" : " \(number)")
            if self.mounted(name, mounted) { continue }
            if mkdirat(fd, name, 0o700) != 0 {
                if errno == EEXIST { continue }
                throw HelperDiskFailure.unavailable
            }
            let leaf = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard leaf >= 0 else { throw HelperDiskFailure.unavailable }
            defer { close(leaf) }
            var info = stat(), parent = stat()
            guard fstat(leaf, &info) == 0, fstat(fd, &parent) == 0, info.st_dev == parent.st_dev,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700,
                  fchown(leaf, owner, gid_t.max) == 0 else { throw HelperDiskFailure.unavailable }
            return .init(name: name, device: UInt64(truncatingIfNeeded: info.st_dev), inode: info.st_ino)
        }
        throw HelperDiskFailure.busy
    }
    private func matches(_ info: stat, _ location: HelperWriteMountLocation, owner: uid_t) -> Bool {
        UInt64(truncatingIfNeeded: info.st_dev) == location.device && info.st_ino == location.inode &&
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == owner && info.st_mode & 0o7777 == 0o700
    }
    func verify(_ location: HelperWriteMountLocation, owner: uid_t, mounted: Set<String>) throws {
        try location.validate()
        guard !self.mounted(location.name, mounted) else { throw HelperDiskFailure.busy }
        let fd = try openRoot()
        defer { close(fd) }
        var info = stat()
        guard fstatat(fd, location.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              matches(info, location, owner: owner) else { throw HelperDiskFailure.unavailable }
    }
    func remove(_ location: HelperWriteMountLocation, owner: uid_t, mounted: Set<String>) throws {
        try location.validate()
        guard !self.mounted(location.name, mounted) else { throw HelperDiskFailure.busy }
        let fd = try openRoot()
        defer { close(fd) }
        var info = stat()
        if fstatat(fd, location.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw HelperDiskFailure.unavailable
        }
        guard matches(info, location, owner: owner), unlinkat(fd, location.name, AT_REMOVEDIR) == 0 else {
            throw HelperDiskFailure.unavailable
        }
    }
}
