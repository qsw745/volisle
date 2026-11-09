import Foundation
import Darwin

/// New FSKit mounts use /Volumes. Retain the old locations for recovery of
/// sessions created by an installed helper before this migration; never move
/// a live mount or take a mount path from IPC.
enum FSKitMountPoint: CaseIterable {
    case write, bitLocker
    var root: String {
        switch self {
        case .write: "/Volumes/.volisle-write-mounts"
        case .bitLocker: "/Volumes/.volisle-bitlocker"
        }
    }
    var legacyRoot: String {
        switch self {
        case .write: "/private/var/run/volisle-write-mounts"
        case .bitLocker: "/private/var/run/volisle-bitlocker"
        }
    }
    var roots: [String] { [root, legacyRoot] }
    func path(_ id: UUID) -> String { root + "/" + id.uuidString.lowercased() }
    func candidates(_ id: UUID) -> Set<String> { Set(roots.map { $0 + "/" + id.uuidString.lowercased() }) }
    func canonicalPath(_ path: String) -> String? {
        let alias = String(legacyRoot.dropFirst("/private".count))
        for base in roots + [alias] where path.hasPrefix(base + "/") {
            let name = String(path.dropFirst(base.count + 1))
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { return nil }
            return (base == alias ? legacyRoot : base) + "/" + name
        }
        return nil
    }
    static func writePath(_ id: UUID, device: String, records: [SystemMountRecord]) throws -> String {
        let candidates = Self.write.candidates(id)
        let atPoint = records.filter { Self.write.canonicalPath($0.path).map(candidates.contains) == true }
        guard atPoint.count <= 1, atPoint.allSatisfy({ $0.source == device && $0.type == "volisle" }),
              !records.contains(where: { $0.source == device && $0.type == "volisle" &&
                  Self.write.canonicalPath($0.path).map(candidates.contains) != true }) else { throw HelperDiskFailure.busy }
        return atPoint.first?.path ?? Self.write.path(id)
    }
}

/// Only root may change the parent. All leaf mutations are relative to its
/// verified, no-follow descriptor. Cleanup is rmdir-only: a nonempty directory,
/// symlink, mount or unfamiliar name is never traversed or recursively removed.
struct HelperMountDirectory {
    let root: String
    var rootOwner: uid_t = 0
    static func trustedRoot(_ info: stat, owner: uid_t) -> Bool {
        // /private/var/run uses group daemon, /Volumes uses wheel. Group
        // membership confers no write access under 0711; only uid and mode
        // define this trust boundary. Preserve old helper-created roots.
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == owner && info.st_mode & 0o7777 == 0o711
    }
    private func openRoot(create: Bool) throws -> Int32? {
        if create, mkdir(root, 0o711) != 0 && errno != EEXIST { throw HelperDiskFailure.unavailable }
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw HelperDiskFailure.unavailable
        }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.trustedRoot(info, owner: rootOwner) else { close(fd); throw HelperDiskFailure.unavailable }
        return fd
    }
    func prepare() throws {
        guard let fd = try openRoot(create: true) else { throw HelperDiskFailure.unavailable }
        close(fd)
    }
    private func isMounted(_ path: String, _ mounted: Set<String>) -> Bool {
        mounted.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
    func createLeaf(_ id: UUID, owner: uid_t, mounted: Set<String>) throws {
        guard owner != 0, owner != .max, !isMounted(root + "/" + id.uuidString.lowercased(), mounted),
              let fd = try openRoot(create: true) else { throw HelperDiskFailure.unavailable }
        defer { close(fd) }
        let name = id.uuidString.lowercased()
        if mkdirat(fd, name, 0o700) != 0 {
            guard errno == EEXIST else { throw HelperDiskFailure.unavailable }
            try removeLeaf(id, owner: owner, mounted: mounted)
            guard mkdirat(fd, name, 0o700) == 0 else { throw HelperDiskFailure.unavailable }
        }
        let leaf = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard leaf >= 0 else { throw HelperDiskFailure.unavailable }
        defer { close(leaf) }
        var info = stat()
        guard fchown(leaf, owner, gid_t.max) == 0, fstat(leaf, &info) == 0,
              info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else {
            throw HelperDiskFailure.unavailable
        }
    }
    func removeLeaf(_ id: UUID, owner: uid_t, mounted: Set<String>) throws {
        let name = id.uuidString.lowercased(), path = root + "/" + name
        guard !isMounted(path, mounted) else { throw HelperDiskFailure.busy }
        guard let fd = try openRoot(create: false) else { return }
        defer { close(fd) }
        var info = stat(), parent = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw HelperDiskFailure.unavailable
        }
        guard fstat(fd, &parent) == 0, info.st_dev == parent.st_dev,
              info.st_mode & S_IFMT == S_IFDIR, [rootOwner, owner].contains(info.st_uid),
              info.st_mode & 0o7777 == 0o700,
              unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw HelperDiskFailure.unavailable }
    }
    func prune(owner: uid_t, mounted: Set<String>, now: time_t = time(nil)) throws {
        guard let fd = try openRoot(create: false) else { return }
        defer { close(fd) }
        for name in try FileManager.default.contentsOfDirectory(atPath: root) {
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_birthtimespec.tv_sec > 0,
                  now - info.st_birthtimespec.tv_sec > Int(HelperLaunchctl.timeout) + 60 else { continue }
            // Busy, unsafe and nonempty entries stay in place. Even a mount
            // arriving after the snapshot cannot be removed by rmdir.
            try? removeLeaf(id, owner: owner, mounted: mounted)
        }
    }
}
