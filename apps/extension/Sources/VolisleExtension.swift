import FSKit
import ExtensionFoundation
@main struct VolisleExtension: UnaryFileSystemExtension {
    let fileSystem = VolisleFileSystem()
}
