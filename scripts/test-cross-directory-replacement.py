#!/usr/bin/env python3
"""Cross-directory replacement and every callback write failure on fresh images."""
import ctypes as C
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

OLD, NEW = b'old-version-' * 4096, b'new-version-' * 8192
PATHS = ['/incoming/draft', '/saved/document', '/saved/.backup']


def main():
    replace = LIB.nk_replace_between
    replace.argtypes = [C.c_void_p] + [C.c_char_p] * 5
    replace.restype = C.c_int
    tools = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
    folder = Path(tempfile.mkdtemp(prefix='volisle-replacement-cross-', dir=ROOT / '.workbench'))
    base = folder / 'base.img'
    with base.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
    subprocess.run([tools / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True, timeout=45)
    io = ImageIO(base); volume = io.mount(); assert volume
    for name in [b'incoming', b'saved']:
        assert LIB.nk_mkdir(volume, b'/', name) == 0
    for parent, name, value in [(b'/incoming', b'draft', NEW), (b'/saved', b'document', OLD), (b'/', b'sentinel', b'untouched')]:
        assert LIB.nk_create(volume, parent, name) == 0
        path = parent.rstrip(b'/') + b'/' + name
        assert LIB.nk_write(volume, path, 0, len(value), C.create_string_buffer(value)) == len(value)
    assert LIB.nk_umount(volume) == 0; io.close()
    # Invalid paths and an occupied backup must fail before any mutation.
    io = ImageIO(base); volume = io.mount(); assert volume
    for source_dir, target_dir, backup in [(b'/incoming/..', b'/saved', b'.backup'),
                                          (b'/incoming', b'/saved//', b'.backup'),
                                          (b'/saved/document', b'/saved', b'.backup'),
                                          (b'/incoming', b'/saved', b'document')]:
        start = io.writes
        assert replace(volume, source_dir, b'draft', target_dir, b'document', backup) == -1
        assert io.writes == start
    assert LIB.nk_umount(volume) == 0; io.close()
    report = {'success': False, 'folder': str(folder), 'cases': []}
    points = [None]
    for point in points:
        image = folder / ('normal.img' if point is None else f'failure-{point}.img')
        shutil.copyfile(base, image)
        io = ImageIO(image); volume = io.mount(); assert volume
        initial = io.writes
        if point is not None: io.fail_write_at = initial + point
        rc = replace(volume, b'/incoming', b'draft', b'/saved', b'document', b'.backup')
        count = io.writes - initial
        if point is None:
            assert rc == 0 and 0 < count <= 128
            points.extend(range(1, count + 1))
            report['write_points'] = count
        else:
            assert rc == -1
        closed = LIB.nk_umount(volume); io.close()
        assert closed == (0 if point is None else -1)
        data = {}
        for path in [*PATHS, '/sentinel']:
            read = subprocess.run([tools / 'ntfscat', '-f', image, path], capture_output=True, timeout=15)
            data[path] = read.stdout if read.returncode == 0 else None
        assert data['/sentinel'] == b'untouched'
        assert OLD in data.values() and NEW in data.values(), f'文件版本丢失：{point}'
        if point is None:
            assert data[PATHS[0]] is None and data[PATHS[1]] == NEW and data[PATHS[2]] == OLD
        report['cases'].append({'write_failure': point, 'both_versions_retained': True, 'sentinel_unchanged': True})
    report['success'] = True
    (folder / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
