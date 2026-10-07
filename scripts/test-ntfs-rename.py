#!/usr/bin/env python3
"""Rename preflight and per-write failures in disposable ordinary images."""
import ctypes as C
import errno
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

PAYLOAD = b'original-rename-payload\x00' * 8192
SENTINEL = b'existing-target-preserved\x00' * 1024


def create(volume, name, data):
    assert LIB.nk_create(volume, b'/', name) == 0
    buf = C.create_string_buffer(data)
    assert LIB.nk_write(volume, b'/' + name, 0, len(data), buf) == len(data)


def read(image, name):
    result = subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat',
                             '-f', image, name], capture_output=True, timeout=15)
    return result.stdout if result.returncode == 0 else None


def listing(image, path):
    result = subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfsls', '-f', '-p', path, image],
                            capture_output=True, timeout=15)
    return sorted(set(result.stdout.decode().split()) - {'.', '..'}) if result.returncode == 0 else None


def main():
    report = {'checks': [], 'failure_points': [], 'sync_failure_points': [], 'crash_points': [], 'success': False}
    with tempfile.TemporaryDirectory(prefix='volisle-rename-', dir=ROOT / '.workbench') as tmp:
        folder = Path(tmp); base = folder / 'base.img'
        with base.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
        subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs', '-F', '-Q', base],
                       check=True, capture_output=True, timeout=45)
        io = ImageIO(base); volume = io.mount(); assert volume
        create(volume, b'source', PAYLOAD); create(volume, b'existing', SENTINEL)
        assert LIB.nk_mkdir(volume, b'/', b'directory') == 0
        assert LIB.nk_mkdir(volume, b'/directory', b'child') == 0
        assert LIB.nk_umount(volume) == 0; io.close()

        io = ImageIO(base); volume = io.mount(); assert volume
        before = io.writes
        assert LIB.nk_rename(volume, b'/source', b'/', b'source') == 0, '同名改名应成功且不产生写入'
        assert io.writes == before
        assert LIB.nk_rename(volume, b'/source', b'/', b'existing') == -1
        assert C.get_errno() == errno.EEXIST and io.writes == before
        assert LIB.nk_rename(volume, b'/directory', b'/directory/child', b'cycle') == -1
        assert C.get_errno() == errno.EINVAL and io.writes == before
        assert LIB.nk_umount(volume) == 0 and io.inspect() == 0; io.close()
        assert read(base, '/source') == PAYLOAD and read(base, '/existing') == SENTINEL
        report['checks'].append('no-op-collision-and-directory-cycle-zero-writes')

        # Non-empty folders (an app's package document, a folder renamed in
        # Finder) rename and move like files: the new name is linked before the
        # old one goes. Only removing a non-empty folder is refused, unchanged,
        # and the session stays writable.
        tree = folder / 'tree.img'; shutil.copyfile(base, tree)
        io = ImageIO(tree); volume = io.mount(); assert volume
        assert LIB.nk_mkdir(volume, b'/', b'saving') == 0 and LIB.nk_mkdir(volume, b'/', b'documents') == 0
        assert LIB.nk_mkdir(volume, b'/saving', b'report.rtfd') == 0
        assert LIB.nk_mkdir(volume, b'/saving/report.rtfd', b'Data') == 0
        assert LIB.nk_create(volume, b'/saving/report.rtfd', b'TXT.rtf') == 0
        buf = C.create_string_buffer(PAYLOAD)
        assert LIB.nk_write(volume, b'/saving/report.rtfd/TXT.rtf', 0, len(PAYLOAD), buf) == len(PAYLOAD)
        assert LIB.nk_rename(volume, b'/saving/report.rtfd', b'/documents', b'report.rtfd') == 0, ('移动非空文件夹', C.get_errno())
        assert LIB.nk_rename(volume, b'/directory', b'/', b'renamed-directory') == 0, ('改名非空文件夹', C.get_errno())
        writes = io.writes
        assert LIB.nk_delete(volume, b'/documents/report.rtfd') == -1 and C.get_errno() == errno.ENOTEMPTY
        assert io.writes == writes
        assert LIB.nk_create(volume, b'/', b'still-writable') == 0, '拒绝删除非空文件夹后会话必须仍可写'
        assert LIB.nk_delete(volume, b'/saving') == 0
        assert LIB.nk_umount(volume) == 0 and io.inspect() == 0; io.close()
        assert read(tree, '/documents/report.rtfd/TXT.rtf') == PAYLOAD
        assert listing(tree, '/documents/report.rtfd') == ['Data', 'TXT.rtf']
        assert listing(tree, '/renamed-directory') == ['child'] and listing(tree, '/directory') is None
        assert 'saving' not in listing(tree, '/') and 'still-writable' in listing(tree, '/')
        assert subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfsfix', '-n', tree],
                              capture_output=True, timeout=30).returncode == 0
        report['checks'].append('non-empty-folders-rename-and-move-delete-refused-without-lock')

        normal = folder / 'normal.img'; shutil.copyfile(base, normal)
        io = ImageIO(normal); volume = io.mount(); assert volume
        before = io.writes; before_sync = io.syncs
        assert LIB.nk_rename(volume, b'/source', b'/', b'renamed') == 0
        points = io.writes - before
        sync_points = io.syncs - before_sync
        assert 0 < points < 128
        assert LIB.nk_umount(volume) == 0; io.close()
        assert read(normal, '/renamed') == PAYLOAD and read(normal, '/source') is None
        report['checks'].append('normal-rename-independent-read')
        for point in range(1, points + 1):
            image = folder / f'fail-{point}.img'; shutil.copyfile(base, image)
            io = ImageIO(image); volume = io.mount(); assert volume
            io.fail_write_at = io.writes + point
            rc = LIB.nk_rename(volume, b'/source', b'/', b'renamed')
            assert rc == -1, ('写入失败不能报告改名成功', point, rc)
            io.fail_write_at = None
            writes = io.writes
            assert LIB.nk_create(volume, b'/', b'must-stay-blocked') == -1 and io.writes == writes
            assert LIB.nk_umount(volume) == -1 and io.inspect() == 1
            io.close()
            old, new = read(image, '/source'), read(image, '/renamed')
            assert old == PAYLOAD or new == PAYLOAD, ('两条路径均无法读回原内容', point)
            assert read(image, '/existing') == SENTINEL, point
            report['failure_points'].append({'write': point, 'source_readable': old == PAYLOAD,
                                             'destination_readable': new == PAYLOAD})
        report['checks'].append('each-write-failure-reported-and-content-retained')
        for point in range(1, sync_points + 1):
            image = folder / f'sync-{point}.img'; shutil.copyfile(base, image)
            io = ImageIO(image); volume = io.mount(); assert volume
            io.fail_sync_at = io.syncs + point
            assert LIB.nk_rename(volume, b'/source', b'/', b'renamed') == -1
            io.fail_sync_at = None
            assert LIB.nk_umount(volume) == -1 and io.inspect() == 1
            io.close()
            old, new = read(image, '/source'), read(image, '/renamed')
            assert old == PAYLOAD or new == PAYLOAD
            assert read(image, '/existing') == SENTINEL
            report['sync_failure_points'].append({'sync': point, 'source_readable': old == PAYLOAD,
                                                  'destination_readable': new == PAYLOAD})
        assert sync_points > 0, '改名过程中缺少持久化边界'
        report['checks'].append('each-sync-failure-reported-and-content-retained')
        for point in range(1, points + 1):
            image = folder / f'crash-{point}.img'; shutil.copyfile(base, image)
            child = subprocess.run([sys.executable, __file__, '--crash', str(image), str(point)],
                                   capture_output=True, timeout=15)
            assert child.returncode == 86, (point, child.returncode, child.stderr[-500:])
            io = ImageIO(image)
            before = io.writes
            assert io.inspect() == 1 and not io.mount() and io.writes == before
            io.close()
            old, new = read(image, '/source'), read(image, '/renamed')
            assert old == PAYLOAD or new == PAYLOAD, ('完整写回调边界退出后两条路径都丢失', point)
            assert read(image, '/existing') == SENTINEL
            report['crash_points'].append({'after_write': point, 'source_readable': old == PAYLOAD,
                                          'destination_readable': new == PAYLOAD})
        report['checks'].append('process-exit-after-each-complete-write-content-retained')
        report['not_covered'] = ['torn-sector writes', 'physical power loss', 'replacement rename', 'Windows recovery']
        report['success'] = True
    (ROOT / 'docs/testing/ntfs-rename-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--crash':
        image = Path(sys.argv[2]).resolve()
        assert image.parent.parent == ROOT / '.workbench' and image.parent.name.startswith('volisle-rename-')
        assert image.is_file() and image.stat().st_size == 64 * 1024 * 1024
        io = ImageIO(image); volume = io.mount(); assert volume
        io.crash_after_write_at = io.writes + int(sys.argv[3])
        LIB.nk_rename(volume, b'/source', b'/', b'renamed')
        raise AssertionError('指定退出点未触发')
    else:
        main()
