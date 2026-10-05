#!/usr/bin/env python3
"""FSKit smoke test, limited to a newly created 64/512 MiB disposable image.

--prepare only creates ordinary files. --run attaches that image read-only and
uses only the device returned by hdiutil. Never accepts a raw device argument.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
from fskit_fixture import ALLOWED_SIZES

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.workbench'
SIZE = 64 * 1024 * 1024
NAME = 'Volisle-中文读取.txt'


def run(command, timeout=45):
    return subprocess.run([str(part) for part in command], capture_output=True, check=True, timeout=timeout)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(size=SIZE):
    if size not in ALLOWED_SIZES: raise ValueError("仅允许 64 或 512 MiB 镜像")
    folder = Path(tempfile.mkdtemp(prefix='fskit-readonly-', dir=WORK))
    image = folder / 'fixture.img'
    with image.open('xb') as stream:
        stream.truncate(size)
    payload = folder / 'payload.txt'
    payload.write_text('盘屿 FSKit 只读镜像验收\n' * 4096, encoding='utf-8')
    tools = WORK / 'ntfs-3g-2026.7.7/ntfsprogs'
    run([tools / 'mkntfs', '-F', '-Q', '-L', 'VOLISLE_RO_TEST', image])
    run([tools / 'ntfscp', image, payload, '/' + NAME])
    observed = run([tools / 'ntfscat', image, '/' + NAME]).stdout
    assert hashlib.sha256(observed).hexdigest() == digest(payload)
    receipt = {'schema': 1, 'image_sha256': digest(image), 'payload_sha256': digest(payload), 'size': size}
    (folder / 'fixture.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(folder)
    print('仅创建并校验普通镜像文件；尚未连接或挂载。')


def test(folder, ui_review=False):
    folder = folder.resolve(strict=True)
    if folder.parent != WORK.resolve() or not re.fullmatch(r'fskit-readonly-[a-z0-9_]+', folder.name):
        raise ValueError('只接受本脚本创建的隔离测试目录')
    image = folder / 'fixture.img'
    if image.is_symlink() or not image.is_file() or image.stat().st_size not in ALLOWED_SIZES:
        raise ValueError('镜像必须为新建的 64 或 512 MiB 普通文件')
    receipt = json.loads((folder / 'fixture.json').read_text())
    if receipt.get('schema') != 1 or receipt.get('size') != image.stat().st_size or digest(image) != receipt['image_sha256']:
        raise ValueError('镜像与准备记录不一致')
    module = json.loads(run([WORK / 'probe-fskit']).stdout)
    matches = module.get('modules', [])
    if len(matches) != 1 or matches[0].get('enabled') is not True:
        raise ValueError('盘屿 FSKit 扩展尚未唯一启用，停止；未连接镜像')
    existing = plistlib.loads(run(['hdiutil', 'info', '-plist']).stdout)
    if any(Path(item.get('image-path', '')).resolve() == image for item in existing.get('images', [])):
        raise ValueError('此测试镜像已连接，先核对已有测试会话；未重复连接')
    # FSKit validates the caller against the mount directory's real owner.
    # External volumes with ownership disabled may appear owned by uid 99 to
    # fskitd, even when stat in our process reports our uid. Use internal storage.
    mountpoint = Path(tempfile.mkdtemp(prefix='volisle-fskit-mount-', dir='/private/tmp'))
    if mountpoint.stat().st_uid != os.geteuid():
        mountpoint.rmdir()
        raise ValueError('临时挂载目录不属于当前用户')
    device = None
    result = {'mountpoint': str(mountpoint), 'mount_verified': False, 'read_verified': False,
              'write_denied': False, 'detached': False, 'mountpoint_removed': False}
    try:
        attached = plistlib.loads(run(['hdiutil', 'attach', '-readonly', '-nomount', '-nobrowse', '-noautoopen',
                                     '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [entry['dev-entry'] for entry in attached['system-entities'] if 'dev-entry' in entry]
        # This fixture is partitionless. Stop before mount if macOS returns an
        # unexpected topology. Only detach the whole device returned here.
        whole = [item for item in devices if re.fullmatch(r'/dev/disk[0-9]+', item)]
        if len(whole) == 1:
            device = whole[0]
        if len(devices) != 1 or device is None:
            raise ValueError('镜像连接结果不是单个无分区设备')
        info = plistlib.loads(run(['hdiutil', 'info', '-plist']).stdout)
        owners = [item for item in info['images'] if any(entry.get('dev-entry') == device for entry in item.get('system-entities', []))]
        if len(owners) != 1 or Path(owners[0]['image-path']).resolve() != image:
            raise ValueError('设备与新建镜像的绑定不匹配')
        disk = plistlib.loads(run(['diskutil', 'info', '-plist', device]).stdout)
        if disk.get('Writable') is not False or disk.get('TotalSize') != receipt['size']:
            raise ValueError('设备未确认只读或容量不匹配')
        run(['/sbin/mount', '-F', '-t', 'volisle', '-o', 'rdonly,nosuid,nodev', device, mountpoint])
        if not os.statvfs(mountpoint).f_flag & os.ST_RDONLY:
            raise ValueError('系统挂载标志不是只读')
        result['mount_verified'] = True
        if digest(mountpoint / NAME) != receipt['payload_sha256']:
            raise ValueError('FSKit 读取内容校验失败')
        result['read_verified'] = True
        try:
            with (mountpoint / 'forbidden-new-test-file').open('xb'):
                pass
        except OSError as error:
            if error.errno != errno.EROFS:
                raise
            result['write_denied'] = True
        else:
            raise ValueError('只读挂载错误地允许创建文件')
        if ui_review:
            ready = folder / 'ui-ready.json'
            ready.write_text(json.dumps({'mountpoint': str(mountpoint)}) + '\n')
            print('供 Finder 核验的只读挂载点：' + str(mountpoint), flush=True)
            # A review may finish early; timeout always returns to normal cleanup.
            deadline = time.monotonic() + 180
            while not (folder / 'ui-finished').exists() and time.monotonic() < deadline:
                time.sleep(1)
    except (Exception, KeyboardInterrupt) as error:
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['stderr'] = error.stderr.decode(errors='replace')[-4000:]
        raise
    finally:
        if device is None:
            # An attach command may time out after the image was connected.
            # Recover only this fresh image's whole device, never another disk.
            try:
                info = plistlib.loads(run(['hdiutil', 'info', '-plist']).stdout)
                candidates = [item for item in info['images'] if Path(item.get('image-path', '')).resolve() == image]
                own_devices = [entry['dev-entry'] for item in candidates for entry in item.get('system-entities', [])
                               if re.fullmatch(r'/dev/disk[0-9]+', entry.get('dev-entry', ''))]
                if len(own_devices) == 1:
                    device = own_devices[0]
            except Exception as error:
                result['cleanup_discovery_error'] = str(error)
        if device:
            # Normal detach only. Never force; retain fixture on failure.
            try:
                run(['hdiutil', 'detach', device])
                result['detached'] = True
            except Exception as error:
                result['cleanup_error'] = str(error)
        result['image_unchanged'] = digest(image) == receipt['image_sha256']
        if result['detached']:
            try:
                mountpoint.rmdir()
                result['mountpoint_removed'] = True
            except OSError as error:
                result['mountpoint_cleanup_error'] = str(error)
        (folder / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result['detached'] or not result['image_unchanged']:
        raise RuntimeError('镜像释放或内容不变性检查失败')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument('--prepare', action='store_true')
    operation.add_argument('--run', type=Path)
    parser.add_argument('--ui-review', action='store_true', help='测试通过后最多保留挂载 180 秒供 Finder 人工核验')
    parser.add_argument('--size-mib', type=int, choices=[64,512], default=64, help='仅用于准备镜像，容量会记录并精确绑定')
    arguments = parser.parse_args()
    try:
        if arguments.prepare:
            prepare(arguments.size_mib * 1024 * 1024)
        else:
            test(arguments.run, arguments.ui_review)
    except (ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
