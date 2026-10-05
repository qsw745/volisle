// SPDX-License-Identifier: GPL-2.0-only
// Derived from ntfskit b7153a8; Volisle modifications 2026-09-20. See ../UPSTREAM.md.
import FSKit

/// An object has an immutable MFT+sequence reference for data/attribute reads.
/// Its mutable path is used for namespace operations only after identity checks.
final class NTFSItem: FSItem {
    // "/" for root; rewritten in-place on rename (FSKit tracks by object
    // identity — the same instance must follow the file to its new name).
    // Lock-guarded: I/O upcalls read the path concurrently with rename.
    private let pathLock = NSLock()
    private var _path: String
    var path: String {
        get { pathLock.lock(); defer { pathLock.unlock() }; return _path }
        set { pathLock.lock(); defer { pathLock.unlock() }; _path = newValue }
    }
    let kind: FSItem.ItemType
    let identifier: FSItem.Identifier
    let fileReference: UInt64

    init(path: String, kind: FSItem.ItemType, identifier: FSItem.Identifier, reference: UInt64) {
        self._path = path
        self.kind = kind
        self.identifier = identifier
        self.fileReference = reference
        super.init()
    }

    func childPath(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }
}
