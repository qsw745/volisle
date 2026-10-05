#!/usr/bin/env python3
"""Preserving replacement and crash recovery on fresh, detached 64 MiB images."""
import ctypes as C
import copy
from datetime import datetime, timezone
import errno
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, IO, ImageIO
from ntfs_replacement_recovery import prepare_plan, recover

LIB.nk_replace_preserving.argtypes = [C.c_void_p] + [C.c_char_p] * 4
LIB.nk_replace_preserving.restype = C.c_int
BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
OLD = b'previous-document\x00' * 8192
NEW = b'updated-document\xff' * 16384
SENTINEL = b'do-not-change-this-file\x00' * 4096


def replace(volume, source=b'draft', target=b'document', backup=b'.saved-old'):
    return LIB.nk_replace_preserving(volume, b'/', source, target, backup)


def read(image, name):
    result = subprocess.run([BIN / 'ntfscat', '-f', image, name],
                            capture_output=True, timeout=15)
    return result.stdout if result.returncode == 0 else None


def create(volume, name, data):
    assert LIB.nk_create(volume, b'/', name) == 0
    buf = C.create_string_buffer(data)
    assert LIB.nk_write(volume, b'/' + name, 0, len(data), buf) == len(data)


def retained(image):
    values = {path: read(image, path) for path in ['/draft', '/document', '/.saved-old']}
    assert OLD in values.values(), '旧内容在所有候选路径丢失'
    assert NEW in values.values(), '新内容在所有候选路径丢失'
    assert read(image, '/sentinel') == SENTINEL, '无关文件受到影响'
    return {key: 'old' if value == OLD else 'new' if value == NEW else 'absent' if value is None else 'unexpected'
            for key, value in values.items()}


def main():
    report = {'success': False, 'checks': [], 'write_failures': [],
              'sync_failures': [], 'crashes': []}
    with tempfile.TemporaryDirectory(prefix='volisle-replacement-', dir=ROOT / '.workbench') as tmp:
        folder = Path(tmp); base = folder / 'base.img'
        with base.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True,
                       capture_output=True, timeout=45)
        io = ImageIO(base); volume = io.mount(); assert volume
        for name, data in [(b'draft', NEW), (b'document', OLD), (b'sentinel', SENTINEL)]:
            create(volume, name, data)
        assert LIB.nk_mkdir(volume, b'/', b'folder') == 0
        assert LIB.nk_umount(volume) == 0; io.close()

        # The app's normal C build has no replacement experiment macro.
        # Exercise that compiled branch with a real clean writable image.
        guarded_library = folder / 'default-bridge.dylib'
        upstream = ROOT / '.workbench/ntfs-3g-2026.7.7'
        subprocess.run(['clang', '-shared', '-fPIC', '-DHAVE_CONFIG_H', '-I', str(upstream),
                        '-I', str(upstream / 'include'), str(ROOT / 'packages/VolisleNTFS/bridge/ntfs_bridge.c'),
                        str(upstream / 'libntfs-3g/.libs/libntfs-3g.a'), '-framework', 'CoreFoundation',
                        '-o', str(guarded_library)], check=True, capture_output=True, timeout=45)
        guarded = C.CDLL(str(guarded_library), use_errno=True)
        guarded.nk_mount_io.argtypes = [C.POINTER(IO), C.c_void_p, C.c_size_t]
        guarded.nk_mount_io.restype = C.c_void_p
        guarded.nk_umount.argtypes = [C.c_void_p]; guarded.nk_umount.restype = C.c_int
        guarded.nk_replace_preserving.argtypes = [C.c_void_p] + [C.c_char_p] * 4
        guarded.nk_replace_preserving.restype = C.c_int
        io = ImageIO(base); volume = guarded.nk_mount_io(C.byref(io.io), None, 0); assert volume
        before = io.writes
        assert guarded.nk_replace_preserving(volume, b'/', b'draft', b'document', b'.saved-old') == -1
        assert C.get_errno() == errno.ENOTSUP and io.writes == before
        assert guarded.nk_umount(volume) == 0; io.close()
        report['checks'].append('default-compiled-bridge-refuses-replacement-with-zero-mutation')

        plan_path = folder / 'plan.json'
        prepare_plan(base, plan_path, '/', 'draft', 'document', '.saved-old')

        def export_checked(image, dirty=1):
            before = hashlib.sha256(image.read_bytes()).hexdigest()
            output = folder / (image.stem + '-recovered')
            result = recover(image, plan_path, output)
            assert result['success'] and result['image_unchanged'] and result['write_callbacks'] == 0
            assert result['dirty'] == dirty
            assert (output / 'before.bin').read_bytes() == OLD
            assert (output / 'after.bin').read_bytes() == NEW
            assert hashlib.sha256(image.read_bytes()).hexdigest() == before
            return result

        normal = folder / 'normal.img'; shutil.copyfile(base, normal)
        io = ImageIO(normal); volume = io.mount(); assert volume
        before, sync_before = io.writes, io.syncs
        assert replace(volume) == 0, ('保留旧版本的替换尚未实现', C.get_errno())
        writes, syncs = io.writes - before, io.syncs - sync_before
        assert 0 < writes < 128 and syncs >= 4
        assert LIB.nk_umount(volume) == 0 and io.inspect() == 0; io.close()
        assert retained(normal) == {'/draft': 'absent', '/document': 'new', '/.saved-old': 'old'}
        export_checked(normal, dirty=0)
        with tempfile.TemporaryDirectory(prefix='fskit-readonly-', dir=ROOT / '.workbench') as scan:
            shutil.copyfile(normal, Path(scan) / 'fixture.img')
            scanner = subprocess.run([sys.executable, ROOT / 'scripts/verify-fixture-allocation.py', scan],
                                     check=True, capture_output=True, text=True, timeout=45)
            report['allocation_check'] = json.loads(scanner.stdout)
            assert report['allocation_check']['success']
        report['checks'].append('replacement-publishes-new-retains-old-independent-read')

        # A changed plan must not authorize exporting the wrong data, reading
        # arbitrary paths or overwriting an existing recovery directory.
        original_plan = json.loads(plan_path.read_text())
        bad_plans = []
        for key, value in [('serial_hex', '00' * 8), ('directory', '/../'),
                           ('source', '../sentinel'), ('backup', 'document')]:
            bad = copy.deepcopy(original_plan); bad[key] = value; bad_plans.append(bad)
        for key, value in [('sha256', '00' * 32), ('size', True), ('size', 2**63)]:
            bad = copy.deepcopy(original_plan); bad['before'][key] = value; bad_plans.append(bad)
        before = hashlib.sha256(normal.read_bytes()).hexdigest()
        for index, plan in enumerate(bad_plans):
            invalid = folder / f'bad-plan-{index}.json'
            invalid.write_text(json.dumps(plan))
            output = folder / f'bad-export-{index}'
            try:
                recover(normal, invalid, output)
                raise AssertionError('无效恢复计划被接受')
            except ValueError:
                pass
            assert not output.exists()
        existing = folder / 'existing-export'; existing.mkdir()
        keep = existing / 'before.bin'; keep.write_bytes(SENTINEL)
        symlink = folder / 'output-link'; symlink.symlink_to(existing, target_is_directory=True)
        for output in [existing, symlink]:
            try:
                recover(normal, plan_path, output)
                raise AssertionError('已有目录或软链接被覆盖')
            except ValueError:
                pass
            assert keep.read_bytes() == SENTINEL
        linked_image = folder / 'linked.img'; linked_image.symlink_to(normal)
        try:
            recover(linked_image, plan_path, folder / 'linked-export')
            raise AssertionError('软链接镜像被接受')
        except ValueError:
            pass
        assert hashlib.sha256(normal.read_bytes()).hexdigest() == before
        report['checks'].append('bad-plan-hash-identity-path-and-existing-output-rejected')

        # Recovery must preserve an empty new version and a resident old file,
        # with Chinese/emoji paths rather than only ASCII non-resident data.
        small = folder / 'small.img'; shutil.copyfile(base, small)
        io = ImageIO(small); volume = io.mount(); assert volume
        names = ['新稿 😀', '原文.txt', '.旧版本']
        for name, data in [(names[0], b''), (names[1], '小文件'.encode())]:
            assert LIB.nk_create(volume, b'/folder', name.encode()) == 0
            assert LIB.nk_write(volume, ('/folder/' + name).encode(), 0, len(data),
                                C.create_string_buffer(data)) == len(data)
        assert LIB.nk_umount(volume) == 0; io.close()
        small_plan = folder / 'small-plan.json'
        prepare_plan(small, small_plan, '/folder', *names)
        io = ImageIO(small); volume = io.mount(); assert volume
        assert LIB.nk_replace_preserving(volume, b'/folder', *[name.encode() for name in names]) == 0
        assert LIB.nk_umount(volume) == 0; io.close()
        small_output = folder / 'small-recovered'
        assert recover(small, small_plan, small_output)['success']
        assert (small_output / 'before.bin').read_bytes() == '小文件'.encode()
        assert (small_output / 'after.bin').read_bytes() == b''
        report['checks'].append('resident-empty-and-unicode-content-export')

        io = ImageIO(base); volume = io.mount(); assert volume
        # Bad input must be rejected before either original name changes.
        cases = [(b'draft', b'document', b'sentinel', errno.EEXIST),
                 (b'draft', b'document', b'DOCUMENT', errno.EEXIST),
                 (b'draft', b'document', b'SENTINEL', errno.EEXIST),
                 (b'draft', b'draft', b'.saved-old', errno.EINVAL),
                 (b'missing', b'document', b'.saved-old', errno.ENOENT),
                 (b'draft', b'missing', b'.saved-old', errno.ENOENT),
                 (b'draft', b'folder', b'.saved-old', errno.EISDIR),
                 (b'folder', b'document', b'.saved-old', errno.EISDIR),
                 (b'draft', b'document', b'../outside', errno.EINVAL),
                 (b'draft', b'document', b'$MFT', errno.EINVAL),
                 (b'draft', b'document', b'z' * 256, errno.EINVAL)]
        for source, target, backup, error in cases:
            before = io.writes
            assert replace(volume, source, target, backup) == -1, (source, target, backup)
            assert C.get_errno() == error and io.writes == before, (source, target, C.get_errno(), error)
        for directory in [None, b'relative', b'/folder/..', b'/folder//', b'/folder/']:
            before = io.writes
            assert LIB.nk_replace_preserving(volume, directory, b'draft', b'document', b'.saved-old') == -1
            assert C.get_errno() == errno.EINVAL and io.writes == before
        assert LIB.nk_umount(volume) == 0 and io.inspect() == 0; io.close()
        assert read(base, '/draft') == NEW and read(base, '/document') == OLD
        report['checks'].append('invalid-input-collision-directory-and-alias-zero-writes')

        io = ImageIO(base, readonly=True); volume = io.mount(); assert volume
        assert replace(volume) == -1 and C.get_errno() == errno.EROFS and io.writes == 0
        assert LIB.nk_umount(volume) == 0; io.close()
        report['checks'].append('read-only-denial')

        for kind, count in [('write', writes), ('sync', syncs), ('crash', writes)]:
            for point in range(1, count + 1):
                image = folder / f'{kind}-{point}.img'; shutil.copyfile(base, image)
                if kind == 'crash':
                    child = subprocess.run([sys.executable, __file__, '--crash', str(image), str(point)],
                                           capture_output=True, timeout=15)
                    assert child.returncode == 86, (point, child.returncode, child.stderr[-500:])
                else:
                    io = ImageIO(image); volume = io.mount(); assert volume
                    if kind == 'write': io.fail_write_at = io.writes + point
                    else: io.fail_sync_at = io.syncs + point
                    assert replace(volume) == -1, (kind, point)
                    io.fail_write_at = None; io.fail_sync_at = None
                    before = io.writes
                    assert LIB.nk_create(volume, b'/', b'blocked') == -1 and io.writes == before
                    assert LIB.nk_umount(volume) == -1; io.close()
                io = ImageIO(image)
                assert io.inspect() == 1 and not io.mount() and io.writes == 0
                io.close()
                observed = retained(image)
                export_checked(image)
                key = 'crashes' if kind == 'crash' else f'{kind}_failures'
                report[key].append({'point': point, 'names': observed})
        report['checks'].append('all-complete-write-prefixes-and-failures-retain-both-versions')
        report['checks'].append('read-only-export-both-versions-after-every-failure-and-crash')
        report['not_covered'] = ['POSIX atomic replacement', 'FSKit open target handles',
                                 'torn-sector writes', 'physical power loss', 'Windows recovery']
        report['success'] = True
        report['verified_at'] = datetime.now(timezone.utc).isoformat()
    (ROOT / 'docs/testing/ntfs-replacement-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: len(value) if key.endswith('failures') or key == 'crashes' else value
                      for key, value in report.items()}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--crash':
        image = Path(sys.argv[2]).resolve()
        assert image.parent.parent == ROOT / '.workbench' and image.parent.name.startswith('volisle-replacement-')
        assert image.is_file() and image.stat().st_size == 64 * 1024 * 1024
        io = ImageIO(image); volume = io.mount(); assert volume
        io.crash_after_write_at = io.writes + int(sys.argv[3])
        replace(volume)
        raise AssertionError('指定退出点未触发')
    else:
        main()
