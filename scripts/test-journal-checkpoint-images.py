#!/usr/bin/env python3
"""Checkpoint rollover while real NTFS files are open; detached images only."""
import ctypes as C
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from journal_image_recovery import export_checkpoints
OLD = b'old-version' + b'A' * 16384
NEW = b'new-version' + b'B' * 32768
OLD_EDIT = b'OLD-edited!' + b'A' * 16384
NEW_EDIT = b'NEW-edited!' + b'B' * 32768

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
DRIVER = ROOT / '.workbench/test-journal-image'
POINTS = ['created', 'written', 'synced', 'renamed', 'committed', 'pruned-1', 'pruned-128', 'prune-committed']


def main():
    cases = []
    with tempfile.TemporaryDirectory(prefix='volisle-journal-rollover-', dir=ROOT / '.workbench') as temp:
        root = Path(temp); base = root / 'base.img'
        with base.open('xb') as f: f.truncate(64 * 1024 * 1024)
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
        io = ImageIO(base); volume = io.mount(); assert volume
        for name, value in [(b'document', OLD), (b'draft', NEW), (b'sentinel', b'untouched')]:
            assert LIB.nk_create(volume, b'/', name) == 0
            assert LIB.nk_write(volume, b'/' + name, 0, len(value), C.create_string_buffer(value)) == len(value)
        assert LIB.nk_umount(volume) == 0; io.close()
        for mode in ['sustained', *(f'checkpoint-{action}-{point}' for point in POINTS for action in ['crash', 'failure'])]:
            folder = root / mode; folder.mkdir(); image = folder / 'fixture.img'; shutil.copyfile(base, image)
            child = subprocess.run([DRIVER, mode, folder], capture_output=True, text=True, timeout=60)
            assert child.returncode == (86 if '-crash-' in mode else 0), (mode, child.stderr)
            before = hashlib.sha256(image.read_bytes()).hexdigest()
            observed = json.loads(subprocess.run([DRIVER, 'inspect', folder], check=True, capture_output=True, text=True).stdout)
            complete = mode == 'sustained'
            valid = complete or mode.rsplit('-', 1)[-1] not in ['created', 'written', 'synced']
            assert observed['valid'] == valid and not observed['cleanupAuthorized'], (mode, observed)
            assert observed['records'] == (650 if complete else 129)
            assert observed['state']['phase'] == ('cleaned' if complete else 'published')
            prefix = f'repeat-{319 if complete else 60:03d}'.encode()
            expected = prefix + NEW_EDIT[len(prefix):]
            assert observed['state']['after']['sha256'] == hashlib.sha256(expected).hexdigest()
            def read(path):
                result = subprocess.run([BIN / 'ntfscat', '-f', image, path], capture_output=True)
                return result.stdout if result.returncode == 0 else None
            assert read('/document') == expected and read('/sentinel') == b'untouched'
            assert read('/.old') == (None if complete else OLD_EDIT)
            io = ImageIO(image, readonly=True)
            assert io.inspect() == int(not complete) and io.writes == 0; io.close()
            if not complete:
                io = ImageIO(image); assert not io.mount() and io.writes == 0; io.close()
            if valid:
                result = export_checkpoints(folder)
                assert result['image_unchanged'] and result['write_callbacks'] == 0 and not result['cleanup_authorized']
                assert (folder / 'exports/new.bin').read_bytes() == expected
                if not complete: assert (folder / 'exports/old.bin').read_bytes() == OLD_EDIT
            else:
                try: export_checkpoints(folder)
                except ValueError: pass
                else: raise AssertionError('未提交检查点获得导出权限')
            assert hashlib.sha256(image.read_bytes()).hexdigest() == before
            cases.append({'mode': mode, 'valid': valid, 'records': observed['records'], 'data_verified': True})
    report = {'success': True, 'verified_at': datetime.now(timezone.utc).isoformat(), 'cases': cases,
              'not_covered': ['hardware power loss', 'torn sectors', 'restart cleanup']}
    (ROOT / 'docs/testing/journal-checkpoint-image-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'NTFS 检查点镜像验证通过：{len(cases)} 项；320 次真实写入及压缩边界故障。')


if __name__ == '__main__': main()
