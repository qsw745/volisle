// SPDX-License-Identifier: GPL-2.0-only
import FSKit

/// Access is serialized by NTFSVolume's operation/state locks.
final class ItemIdentityCache {
    private struct Entry {
        let reference: UInt64
        let identifier: FSItem.Identifier
        var item: NTFSItem?
    }
    private var nextID: UInt64 = 100
    private var entries: [String: Entry] = [:]
    /// Paths whose item the kernel released keep their identifier only up to
    /// this many entries: browsing a whole large disk must not grow the
    /// extension's memory without bound. Live items are always kept.
    private let limit: Int
    private var pruneAt: Int
    init(limit: Int = 100_000) { self.limit = limit; pruneAt = limit }

    func item(path: String, kind: FSItem.ItemType, reference: UInt64) -> NTFSItem {
        let id = identifier(path: path, reference: reference)
        if let item = entries[path]?.item { return item }
        let item = NTFSItem(path: path, kind: kind, identifier: id, reference: reference)
        entries[path]?.item = item
        return item
    }
    func identifier(path: String, reference: UInt64) -> FSItem.Identifier {
        if let entry = entries[path], entry.reference == reference { return entry.identifier }
        let id: FSItem.Identifier
        if path == "/" { id = .rootDirectory }
        else { id = FSItem.Identifier(rawValue: nextID)!; nextID += 1 }
        // Do not rewrite the previous object: an open caller still owns its
        // old reference even after this path points to a different record.
        if entries.count >= pruneAt {
            entries = entries.filter { $0.value.item != nil || $0.key == "/" }
            pruneAt = max(limit, entries.count * 2)  // mostly live items: do not filter on every call
        }
        entries[path] = Entry(reference: reference, identifier: id, item: nil)
        return id
    }
    func reclaim(_ item: NTFSItem) {
        if entries[item.path]?.item === item { entries[item.path]?.item = nil }
    }
    func remove(_ item: NTFSItem) {
        if entries[item.path]?.item === item { entries[item.path] = nil }
    }
    func move(_ item: NTFSItem, to path: String) {
        let old = item.path
        // Only a directory has descendants to re-key; a file moves alone
        // (scanning every entry per rename made batch copies quadratic).
        let moved = item.kind == .directory
            ? entries.filter { $0.key == old || $0.key.hasPrefix(old + "/") }
            : entries[old].map { [old: $0] } ?? [:]
        for key in moved.keys { entries[key] = nil }
        for (key, entry) in moved {
            let destination = path + key.dropFirst(old.count)
            entry.item?.path = destination
            entries[destination] = entry
        }
        item.path = path
    }
}
