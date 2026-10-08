import FSKit
import ExtensionFoundation
/// Unary: FSKit runs one process per mounted volume. Several disks written at
/// once are several processes, each with its own engine and journal session;
/// a few things rely on that and are not safe with two volumes in one process:
/// NTFSVolume ends the process after a refused activation (exit), and the
/// NTFS-3G bridge sets process-wide state (names.inc, logging).
@main struct VolisleExtension: UnaryFileSystemExtension {
    let fileSystem = VolisleFileSystem()
}
