#!/usr/bin/env python3
"""Real coordinator transaction on one new NTFS image; never accepts a disk."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
from bundle_manifest import sha256
from fskit_fixture import validate_fixture

ROOT = Path(__file__).resolve().parents[1]

def run(args):
    return subprocess.run([str(a) for a in args], capture_output=True, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--expect-readonly-rejection', action='store_true')
    modes.add_argument('--expect-dirty-rejection', action='store_true')
    args = parser.parse_args()
    folder = args.fixture.resolve(strict=True)
    validate_fixture(folder)
    image = folder / 'fixture.img'
    receipt = json.loads((folder / 'fixture.json').read_text())
    probe = ROOT / 'apps/macos/.build/debug/VolisleMountProbe'
    run(['/usr/bin/codesign', '--verify', '--strict', probe])
    signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(probe)], capture_output=True, check=True).stderr.decode()
    if 'TeamIdentifier=6N5T3G6H33\n' not in signature or 'Identifier=top.qisw.volisle.mount-probe\n' not in signature:
        raise ValueError('验收程序须在本次编译后使用项目 Developer ID 重新签名；未连接镜像')
    output = folder / ('transaction-rejection.json' if args.expect_readonly_rejection or args.expect_dirty_rejection else 'transaction-result.json')
    if output.exists():
        raise ValueError('已有结果，拒绝重复执行')
    result = {'success': False, 'sessions_detached': False, 'physical_device_access': False}
    device = None
    try:
        attached = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-nomount', '-nobrowse', '-noautoopen',
            '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [x['dev-entry'] for x in attached['system-entities'] if 'dev-entry' in x]
        if len(devices) != 1:
            raise ValueError('不是单一无分区镜像设备')
        device = devices[0]
        infos = plistlib.loads(run(['/usr/bin/hdiutil', 'info', '-plist']).stdout)
        owners = [x for x in infos['images'] if any(y.get('dev-entry') == device for y in x.get('system-entities', []))]
        if len(owners) != 1 or Path(owners[0]['image-path']).resolve() != image:
            raise ValueError('镜像绑定变化')
        run(['/usr/sbin/diskutil', 'mount', 'readOnly', device])
        before = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        if before.get('FilesystemType') != 'ntfs' or before.get('WritableVolume') is not False or not before.get('MountPoint'):
            raise ValueError('初始状态不是原生 NTFS 只读')
        result['initial_native_readonly'] = True
        completed = subprocess.run([str(probe), '--write-transaction', device.removeprefix('/dev/'),
            str(image), receipt['payload_sha256']], capture_output=True)
        result['exit_code'] = completed.returncode
        result['stderr'] = completed.stderr.decode(errors='replace')[-5000:]
        after = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        result['final_native_readonly'] = after.get('FilesystemType') == 'ntfs' and after.get('WritableVolume') is False and bool(after.get('MountPoint'))
        if args.expect_readonly_rejection:
            if completed.returncode == 0 or 'mountNotVerified' not in result['stderr'] or not result['final_native_readonly']:
                raise ValueError('只读候选未拒绝写入事务或未恢复只读')
            result['readonly_candidate_rejected_and_restored'] = True
        elif args.expect_dirty_rejection:
            if completed.returncode == 0 or 'commandFailed' not in result['stderr'] or '脏标记' not in result['stderr'] or not result['final_native_readonly']:
                raise ValueError('风险预检未拒绝挂载或未恢复只读')
            result['dirty_candidate_rejected_and_restored'] = True
        else:
            completed.check_returncode()
            result['probe'] = json.loads(completed.stdout)
            required = ['coordinator_verified_writable', 'write_fsync_read_verified', 'native_readonly_restored',
                        'independent_native_readback_verified', 'restored_write_denied']
            if not all(result['probe'].get(k) is True for k in required) or not result['final_native_readonly']:
                raise ValueError('事务检查未完成')
        result['success'] = True
    except BaseException as error:
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['operation_stderr'] = (error.stderr or b'').decode(errors='replace')[-5000:]
        raise
    finally:
        if device:
            try:
                run(['/usr/bin/hdiutil', 'detach', device])
                result['sessions_detached'] = True
                if args.expect_readonly_rejection or args.expect_dirty_rejection:
                    result['image_unchanged'] = sha256(image) == receipt['image_sha256']
                    if not result['image_unchanged']:
                        raise ValueError('拒绝写入场景修改了镜像')
            except BaseException as error:
                result['detach_error'] = str(error)
                result['success'] = False
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if not result['success']:
            raise RuntimeError('事务验收未通过，具体失败和清理状态见结果文件')

if __name__ == '__main__':
    main()
