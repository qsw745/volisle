"""Read-only export of checkpoint-matching data from native journal fixtures.

Development tool only. A mismatch is retained/reported, never repaired or
silently labeled recovered. It does not resume writes or authorize cleanup.
"""
import ctypes as C
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from ntfs_bridge_test_support import ROOT, LIB
from ntfs_replacement_recovery import readonly, fingerprint, export_verified, image_hash, write_new, sync_directory

LIB.nk_reference_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_uint64)]
LIB.nk_reference_path.restype = C.c_int


def export_checkpoints(folder):
    folder = Path(folder).absolute()
    if (folder != folder.resolve() or folder.parent.parent != ROOT / '.workbench' or
            not folder.parent.name.startswith('volisle-journal-')):
        raise ValueError('仅接受本项目的恢复记录实验目录')
    image = folder / 'fixture.img'
    # The native reader validates the ordinary 64 MiB file, rejects links,
    # and binds the record chain to the image's serial and boot hash.
    result = subprocess.run([ROOT / '.workbench/test-journal-image', 'inspect', folder],
                            check=True, capture_output=True, text=True, timeout=15)
    inspection = json.loads(result.stdout)
    if not inspection['valid'] or inspection['cleanupAuthorized']:
        raise ValueError('恢复记录不完整，不创建导出')
    attached = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist'], timeout=10))
    if any(Path(x.get('image-path', '')).resolve() == image for x in attached.get('images', [])):
        raise ValueError('镜像未断开，不能离线导出')
    output = folder / 'exports'
    if output.exists() or output.is_symlink():
        raise ValueError('导出目录已存在')
    before = image_hash(image)
    state = inspection['state']; binding = state['binding']
    path = lambda key: (binding.get('sourceDirectory') or binding['directory'] if key == 'source' else binding['directory']).rstrip('/') + '/' + binding[key]
    versions, selected = {}, {}
    with readonly(image) as (io, volume):
        for role, candidates, reference, expected in [
            ('old', [path('target'), path('backup')], binding['oldReference'], state['before']),
            ('new', [path('source'), path('target')], binding['newReference'], state['after'])
        ]:
            versions[role] = {'status': 'unavailable'}
            for candidate in candidates:
                observed = C.c_uint64()
                if LIB.nk_reference_path(volume, candidate.encode(), C.byref(observed)) != 0:
                    continue
                if observed.value != reference:
                    continue
                observed_fingerprint = fingerprint(volume, candidate)
                if observed_fingerprint is None:
                    continue
                if observed_fingerprint != expected:
                    versions[role] = {'status': 'checkpoint-mismatch', 'path': candidate}
                    continue
                selected[role] = (candidate, expected)
                versions[role] = {'status': 'checkpoint-match', 'path': candidate,
                                  'file': role + '.bin', **expected}
                break
        if image_hash(image) != before:
            raise ValueError('检查期间源镜像发生变化')
        output.mkdir(mode=0o700)
        for role, (candidate, expected) in selected.items():
            export_verified(volume, candidate, output / f'{role}.bin', expected)
    report = {'records_valid': True, 'phase': state['phase'], 'cleanup_authorized': False,
              'versions': versions, 'exported_versions': len(selected), 'image_sha256': before,
              'write_callbacks': io.writes, 'image_unchanged': image_hash(image) == before,
              'scope': 'checkpoint-matching unnamed data only; no filesystem repair or write resumption'}
    if not report['image_unchanged']:
        raise ValueError('导出期间镜像发生变化')
    write_new(output / 'recovery.json', (json.dumps(report, ensure_ascii=False, indent=2) + '\n').encode())
    sync_directory(output); sync_directory(folder)
    return report


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    print(json.dumps(export_checkpoints(args.folder), ensure_ascii=False, indent=2))
