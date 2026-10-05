#!/usr/bin/env python3
"""Bounded FSKit writes to a new 64/512 MiB fixture, never an arbitrary device."""
import argparse
from contextlib import contextmanager
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_manifest import sha256
from fskit_fixture import validate_fixture, WORK, ALLOWED_SIZES

INSTALLED = Path.home() / 'Applications/Volisle Test.app'
SEED = 'Volisle-中文读取.txt'


def run(args):
    return subprocess.run([str(x) for x in args], capture_output=True, check=True, timeout=45)


@contextmanager
def mounted(image, readonly, result):
    image = Path(image)
    if image.is_symlink() or image.parent.resolve().parent != WORK.resolve() or not re.fullmatch(r'fskit-readonly-[a-z0-9_]+', image.parent.name) or image.name != 'fixture.img':
        raise ValueError('挂载仅允许项目内的受限镜像')
    fixture_size = json.loads((image.parent / 'fixture.json').read_text()).get('size')
    if not image.is_file() or fixture_size not in ALLOWED_SIZES or image.stat().st_size != fixture_size:
        raise ValueError('镜像容量与记录不符')
    mountpoint = Path(tempfile.mkdtemp(prefix='volisle-fskit-write-', dir='/private/tmp'))
    device = None
    session = {'readonly': readonly, 'detached': False, 'mountpoint_removed': False}
    result['sessions'].append(session)
    try:
        attachment = plistlib.loads(run(['hdiutil', 'attach', *(['-readonly'] if readonly else []),
            '-nomount', '-nobrowse', '-noautoopen', '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [x['dev-entry'] for x in attachment['system-entities'] if 'dev-entry' in x]
        whole = [x for x in devices if re.fullmatch(r'/dev/disk[0-9]+', x)]
        if len(whole) == 1:
            device = whole[0]
        if len(devices) != 1 or device is None:
            raise ValueError('镜像不是单个无分区设备')
        attachments = plistlib.loads(run(['hdiutil', 'info', '-plist']).stdout)
        owners = [x for x in attachments['images'] if any(y.get('dev-entry') == device for y in x.get('system-entities', []))]
        if len(owners) != 1 or Path(owners[0]['image-path']).resolve() != image.resolve():
            raise ValueError('镜像设备绑定不匹配')
        info = plistlib.loads(run(['diskutil', 'info', '-plist', device]).stdout)
        if info.get('TotalSize') != fixture_size or info.get('Writable') is not (not readonly):
            raise ValueError('设备容量或写入属性不匹配')
        opts = 'rdonly,nosuid,nodev' if readonly else 'volisle-rw,nosuid,nodev'
        run(['/sbin/mount', '-F', '-t', 'volisle', '-o', opts, device, mountpoint])
        if bool(os.statvfs(mountpoint).f_flag & os.ST_RDONLY) != readonly:
            raise ValueError('系统实际挂载模式不匹配')
        session['mounted'] = True
        yield mountpoint
    except BaseException as error:
        session['operation_error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            session['operation_stderr'] = error.stderr.decode(errors='replace')[-3000:]
        raise
    finally:
        if device is None:
            attachments = plistlib.loads(run(['hdiutil', 'info', '-plist']).stdout)
            own = [x for x in attachments['images'] if Path(x.get('image-path', '')).resolve() == image.resolve()]
            devices = [y['dev-entry'] for x in own for y in x.get('system-entities', []) if re.fullmatch(r'/dev/disk[0-9]+', y.get('dev-entry', ''))]
            if len(devices) == 1:
                device = devices[0]
        if device:
            try:
                run(['hdiutil', 'detach', device])
                session['detached'] = True
            except subprocess.SubprocessError as error:
                session['cleanup_error'] = str(error)
                if 'operation_error' not in session:
                    raise
        if not os.path.ismount(mountpoint):
            mountpoint.rmdir()
            session['mountpoint_removed'] = True


def main(folder, signed, ui_review=False, daily=False):
    fixture = validate_fixture(folder)
    folder = folder.resolve()
    image = folder / 'fixture.img'
    if (folder / 'write-result.json').exists():
        raise ValueError('此镜像已有写入测试记录，不能覆盖或重复使用')
    signing = json.loads((signed / 'signing-result.json').read_text())
    if daily:
        if signing.get('write_mode') != 'daily-write-candidate' or signing.get('fixture') is not None:
            raise ValueError('候选不是明确选择的日常读写构建')
    elif signing.get('write_mode') != 'fixture-only' or signing.get('fixture') != fixture:
        raise ValueError('签名候选没有准确绑定此镜像')
    candidate = signed / 'top.qisw.volisle.app'
    relative = Path('Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS')
    if sha256(INSTALLED / relative) != sha256(candidate / relative):
        raise ValueError('当前安装扩展不是指定实验候选')
    run(['codesign', '--verify', '--deep', '--strict', INSTALLED])
    modules = json.loads(run([WORK / 'probe-fskit']).stdout).get('modules', [])
    if len(modules) != 1 or modules[0].get('enabled') is not True or Path(modules[0]['path']).resolve() != (INSTALLED / 'Contents/Extensions/VolisleFS.appex').resolve():
        raise ValueError('指定扩展未唯一启用')
    receipt = json.loads((folder / 'fixture.json').read_text())
    result = {'sessions': [], 'checks': [], 'success': False}
    directory = 'Volisle-测试-' + uuid.uuid4().hex
    expected = {}
    try:
        with mounted(image, False, result) as root:
            assert sha256(root / SEED) == receipt['payload_sha256']
            testdir = root / directory
            testdir.mkdir()
            data = ('新建文件 中文 空格 🌊\n' * 100).encode()
            first = testdir / '原始 文件 🌊.txt'
            with first.open('xb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            assert first.read_bytes() == data
            result['checks'].append('create-write-fsync-read')
            renamed = first.with_name('改名 文件 🌊.txt')
            first.rename(renamed)
            assert not first.exists() and renamed.read_bytes() == data
            child = testdir / '子目录'; child.mkdir()
            moved = child / renamed.name
            moved_relative = moved.relative_to(root)
            renamed.rename(moved)
            assert not renamed.exists() and moved.read_bytes() == data
            expected[str(moved.relative_to(root))] = hashlib.sha256(data).hexdigest()
            result['checks'].append('rename-move')
            # An application may keep its file descriptor across a rename or
            # a parent-directory move. The FSItem identity must keep working.
            open_path = testdir / '打开时改名.bin'
            with open_path.open('x+b') as stream:
                stream.write(b'before-rename'); stream.flush(); os.fsync(stream.fileno())
                final_path = testdir / '打开时已改名.bin'
                open_path.rename(final_path)
                stream.seek(0); assert stream.read() == b'before-rename'
                stream.seek(0); stream.write(b'after--rename'); stream.flush(); os.fsync(stream.fileno())
            assert final_path.read_bytes() == b'after--rename'
            expected[str(final_path.relative_to(root))] = hashlib.sha256(b'after--rename').hexdigest()
            old_parent = testdir / '打开目录'; old_parent.mkdir()
            nested = old_parent / 'child.bin'
            with nested.open('x+b') as stream:
                stream.write(b'child-before'); stream.flush()
                new_parent = testdir / '移动后目录'; old_parent.rename(new_parent)
                stream.seek(0); assert stream.read() == b'child-before'
                stream.seek(0); stream.write(b'child-after!'); stream.flush(); os.fsync(stream.fileno())
            nested = new_parent / 'child.bin'
            assert nested.read_bytes() == b'child-after!'
            expected[str(nested.relative_to(root))] = hashlib.sha256(b'child-after!').hexdigest()
            unlinked = testdir / '打开时删除.bin'
            with unlinked.open('x+b') as stream:
                stream.write(b'open-unlink'); stream.flush(); os.fsync(stream.fileno())
                unlinked.unlink(); assert not unlinked.exists()
                stream.seek(0); assert stream.read() == b'open-unlink'
                stream.seek(0); stream.write(b'still-open!'); stream.flush(); os.fsync(stream.fileno())
                stream.seek(0); assert stream.read() == b'still-open!'
            assert not unlinked.exists()
            result['checks'].append('open-descriptor-rename-parent-move-unlink')
            scratch = testdir / '删除测试.txt'
            scratch.write_bytes(b'delete only this test file')
            scratch.unlink(); assert not scratch.exists()
            empty = testdir / '空目录'; empty.mkdir(); empty.rmdir(); assert not empty.exists()
            result['checks'].append('delete-file-directory')
            payload = bytes(range(256)) * 16384
            large = testdir / '4MiB.bin'
            with large.open('xb') as stream:
                stream.write(payload); stream.flush(); os.fsync(stream.fileno())
            assert large.read_bytes() == payload
            expected[str(large.relative_to(root))] = hashlib.sha256(payload).hexdigest()
            result['checks'].append('4MiB-write-read')
            for index in range(32):
                name = testdir / f'批量-{index:02}.txt'
                data = f'fixture-{index}\n'.encode()
                name.write_bytes(data)
                expected[str(name.relative_to(root))] = hashlib.sha256(data).hexdigest()
            assert len(list(testdir.iterdir())) == 36
            result['checks'].append('32-files-enumeration')
            # In-place writes and truncation must persist independently of cache.
            with large.open('r+b') as stream:
                stream.seek(4093); stream.write(b'cross-sector-edit')
                stream.truncate(2 * 1024 * 1024 + 17)
                stream.flush(); os.fsync(stream.fileno())
            edited = bytearray(payload)
            edited[4093:4093 + len(b'cross-sector-edit')] = b'cross-sector-edit'
            edited = bytes(edited[:2 * 1024 * 1024 + 17])
            assert large.read_bytes() == edited
            expected[str(large.relative_to(root))] = hashlib.sha256(edited).hexdigest()
            result['checks'].append('partial-write-truncate')
            timestamp = 1700000000
            requested_times = (1700000000123456789, 1700000000987654321)
            expected_times = (1700000000123456700, 1700000000987654300)
            os.utime(moved, ns=requested_times)
            updated = moved.stat()
            assert (updated.st_atime_ns, updated.st_mtime_ns) == expected_times
            result['checks'].append('100ns-timestamps-live')
            current = moved.stat()
            os.chmod(moved, current.st_mode & 0o7777)
            os.chown(moved, current.st_uid, current.st_gid)
            os.chflags(moved, 0)
            try:
                os.chmod(moved, 0o600)
            except OSError as error:
                assert error.errno == errno.ENOTSUP
            else:
                raise AssertionError('不支持的权限变化不应静默成功')
            assert moved.stat().st_mode & 0o7777 == 0o644
            private = testdir / '私有权限拒绝.txt'
            try:
                fd = os.open(private, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except OSError as error:
                assert error.errno == errno.ENOTSUP
            else:
                os.close(fd)
                raise AssertionError('不支持的私有权限创建不应静默创建公开权限文件')
            assert not private.exists()
            result['checks'].append('fixed-permissions-noop-and-rejection')
            locked = testdir / '只读模式.txt'
            locked.write_bytes(b'windows-readonly-content')
            os.chmod(locked, 0o444)
            assert locked.stat().st_mode & 0o7777 == 0o444
            for flags in [os.O_WRONLY, os.O_WRONLY | os.O_TRUNC]:
                try:
                    fd = os.open(locked, flags)
                except OSError as error:
                    assert error.errno in [errno.EACCES, errno.EPERM], error
                else:
                    os.close(fd); raise AssertionError('只读文件不应允许打开写入')
            assert locked.read_bytes() == b'windows-readonly-content'
            os.chmod(locked, 0o644)
            with locked.open('r+b') as stream:
                stream.write(b'WINDOWS'); stream.flush(); os.fsync(stream.fileno())
            os.chmod(locked, 0o444)
            locked_relative = str(locked.relative_to(root))
            expected[locked_relative] = hashlib.sha256(b'WINDOWS-readonly-content').hexdigest()
            result['checks'].append('persistent-readonly-mode-reject-write-and-unlock')

            run(['/usr/bin/xattr', '-wx', 'com.volisle.fixture', b'fixture-xattr'.hex(), moved])
            assert bytes.fromhex(run(['/usr/bin/xattr', '-px', 'com.volisle.fixture', moved]).stdout.decode()) == b'fixture-xattr'
            assert b'com.volisle.fixture' in run(['/usr/bin/xattr', moved]).stdout.splitlines()
            run(['/usr/bin/xattr', '-w', 'com.volisle.remove', 'temporary', moved])
            run(['/usr/bin/xattr', '-d', 'com.volisle.remove', moved])
            assert b'com.volisle.remove' not in run(['/usr/bin/xattr', moved]).stdout.splitlines()
            result['checks'].append('timestamps-xattrs')
            # Replacement rename is intentionally unsupported until crash safety
            # is implemented. Rejection must preserve both source and target.
            source = testdir / '覆盖源.txt'; source.write_bytes(b'new')
            target = testdir / '覆盖目标.txt'; target.write_bytes(b'original')
            if signing.get('experimental_replacement', False):
                os.replace(source, target)
                assert not source.exists() and target.read_bytes() == b'new'
                target.unlink()
                result['checks'].append('replacement-preserves-new')
            else:
                try:
                    os.replace(source, target)
                except OSError as error:
                    assert error.errno == errno.ENOTSUP, error
                else:
                    raise AssertionError('未验收的替换改名意外成功')
                assert source.read_bytes() == b'new' and target.read_bytes() == b'original'
                source.unlink(); target.unlink()
                result['checks'].append('replacement-rejected-preserves-both')
            # Regression: mixed-size allocation after truncation exposed stale
            # allocation-bitmap cache entries during Finder/fseventsd activity.
            # Keep every small allocation until offline verification so reused
            # clusters cannot hide behind successful reads from the file cache.
            for index in range(64):
                allocation = testdir / f'分配-{index}.bin'
                block = hashlib.sha256(str(index).encode()).digest()
                with allocation.open('xb') as stream:
                    stream.write((block * 26559)[:849862])
                    stream.flush(); os.fsync(stream.fileno())
                allocation.unlink()
                survivor = testdir / f'保留-{index}.bin'
                data = (block * 23)[:707]
                with survivor.open('xb') as stream:
                    stream.write(data); stream.flush(); os.fsync(stream.fileno())
                expected[str(survivor.relative_to(root))] = hashlib.sha256(data).hexdigest()
            assert large.read_bytes() == edited
            result['checks'].append('64-mixed-allocation-delete-cycles')
            if ui_review:
                (folder / 'write-ui-ready.json').write_text(json.dumps({'mountpoint': str(root), 'test_directory': str(testdir)}) + '\n')
                print('供 Finder 写入核验的测试目录：' + str(testdir), flush=True)
                deadline = time.monotonic() + 180
                while not (folder / 'write-ui-finished').exists() and time.monotonic() < deadline:
                    time.sleep(1)
                # Finder may copy only the seeded test file into a new folder.
                copied = root / 'Finder 测试' / SEED
                if copied.exists():
                    assert sha256(copied) == receipt['payload_sha256']
                    expected[str(copied.relative_to(root))] = receipt['payload_sha256']
                    result['checks'].append('finder-copy-hash')
            assert sha256(root / SEED) == receipt['payload_sha256']
        # Independent offline reader after normal unmount, before remount.
        for name, checksum in expected.items():
            observed = run([WORK / 'ntfs-3g-2026.7.7/ntfsprogs/ntfscat', image, '/' + name]).stdout
            assert hashlib.sha256(observed).hexdigest() == checksum, name
        result['checks'].append('independent-ntfscat')
        from ntfs_bridge_test_support import ImageIO
        offline = ImageIO(image, readonly=True)
        try:
            assert offline.inspect() == 0 and offline.writes == 0
        finally:
            offline.close()
        result['checks'].append('clean-ntfs-after-detach')
        with mounted(image, True, result) as root:
            for name, checksum in expected.items():
                assert sha256(root / name) == checksum, name
            assert sha256(root / SEED) == receipt['payload_sha256']
            assert (root / locked_relative).stat().st_mode & 0o7777 == 0o444
            result['checks'].append('readonly-mode-after-system-remount')
            remounted = root / moved_relative
            assert int(remounted.stat().st_mtime) == timestamp
            assert remounted.stat().st_mtime_ns == expected_times[1]
            result['checks'].append('100ns-mtime-readonly-remount')
            assert bytes.fromhex(run(['/usr/bin/xattr', '-px', 'com.volisle.fixture', remounted]).stdout.decode()) == b'fixture-xattr'
            try:
                (root / directory / '只读拒绝.txt').open('xb').close()
            except OSError as error:
                assert error.errno == errno.EROFS
            else:
                raise AssertionError('只读重挂未拒绝写入')
        result['checks'].extend(['readonly-remount-hashes', 'seed-preserved', 'readonly-write-denied'])
        result['allocation_check'] = json.loads(run([sys.executable,
            Path(__file__).with_name('verify-fixture-allocation.py'), folder]).stdout)
        assert result['allocation_check']['success']
        result['checks'].append('independent-run-overlap-and-bitmap-check')
        result['success'] = True
    except BaseException as error:
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['stderr'] = error.stderr.decode(errors='replace')[-3000:]
        raise
    finally:
        result['final_image_sha256'] = sha256(image)
        result['expected_files'] = expected
        (folder / 'write-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({k:v for k,v in result.items() if k != 'expected_files'}, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--signed-dir', required=True, type=Path)
    parser.add_argument('--daily-write', action='store_true', help='在指定新建镜像上验收已安装日常读写候选')
    parser.add_argument('--ui-review', action='store_true')
    args = parser.parse_args()
    main(args.fixture, args.signed_dir, args.ui_review, args.daily_write)
