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
        let moved = entries.filter { $0.key == old || $0.key.hasPrefix(old + "/") }
        for key in moved.keys { entries[key] = nil }
        for (key, entry) in moved {
            let destination = path + key.dropFirst(old.count)
            entry.item?.path = destination
            entries[destination] = entry
        }
        item.path = path
    }
}
