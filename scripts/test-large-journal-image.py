#!/usr/bin/env python3
"""Large-file checkpoint export after real process exit; disposable image only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from journal_image_recovery import export_checkpoints
from ntfs_replacement_recovery import image_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cross-directory', action='store_true')
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='volisle-journal-large-', dir=ROOT / '.workbench'))
    folder = root / 'published'; folder.mkdir()
    image = folder / 'fixture.img'
    with image.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    tools = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
    subprocess.run([tools / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True, timeout=45)
    io = ImageIO(image); volume = io.mount(); assert volume
    expected = {}
    if args.cross_directory:
        for name in [b'incoming', b'saved']:
            assert LIB.nk_mkdir(volume, b'/', name) == 0
    for role, name, blocks in [('old', b'document', 65), ('new', b'draft', 81)]:
        parent = (b'/saved' if role == 'old' else b'/incoming') if args.cross_directory else b'/'
        if args.cross_directory: name = b'document'
        assert LIB.nk_create(volume, parent, name) == 0
        path = parent.rstrip(b'/') + b'/' + name
        hasher = hashlib.sha256(); size = 0
        for index in range(blocks):
            chunk = (bytes([index]) * (256 * 1024)) if index < blocks - 1 else b'partial-tail'
            buffer = C.create_string_buffer(chunk)
            assert LIB.nk_write(volume, path, size, len(chunk), buffer) == len(chunk)
            size += len(chunk); hasher.update(chunk)
        expected[role] = {'size': size, 'sha256': hasher.hexdigest()}
    assert LIB.nk_umount(volume) == 0; io.close()
    before = image_hash(image)
    result = {'success': False, 'folder': str(folder), 'expected': expected, 'initial_hash': before}
    try:
        child = subprocess.run([ROOT / '.workbench/test-journal-image', 'cross-published' if args.cross_directory else 'published', folder], capture_output=True, text=True, timeout=60)
        assert child.returncode == 86, child.stderr
        result['exit_after_publication'] = child.returncode
        report = export_checkpoints(folder)
        assert report['records_valid'] and report['exported_versions'] == 2
        assert report['image_unchanged'] and report['write_callbacks'] == 0 and not report['cleanup_authorized']
        for role in ['old', 'new']:
            path = folder / 'exports' / f'{role}.bin'
            with path.open('rb') as stream:
                assert hashlib.file_digest(stream, 'sha256').hexdigest() == expected[role]['sha256']
            assert path.stat().st_size == expected[role]['size']
        io = ImageIO(image)
        try:
            assert io.inspect() == 1
            assert not io.mount() and io.writes == 0
        finally:
            io.close()
        result['export_report'] = report
        result['dirty_volume_write_refused'] = True
        result['success'] = True
    finally:
        (root / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
