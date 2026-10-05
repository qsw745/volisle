#!/usr/bin/env python3
"""Exercise the installed root service on its signed disposable image only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid
from fskit_fixture import validate_fixture
from bundle_manifest import sha256

ROOT = Path(__file__).resolve().parents[1]
APP = Path.home() / 'Applications/Volisle Test.app'
CLI = APP / 'Contents/MacOS/Volisle'

def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True)

def call(*args):
    return json.loads(run([CLI, *args]).stdout)

def wait(operation_id):
    for _ in range(150):
        record = call('--helper-cycle-status', operation_id)
        if record['phase'] in ['writeMounted', 'finished', 'needsRecovery']:
            return record
        time.sleep(0.2)
    raise RuntimeError('后台未确认终态，保留原操作 ID 供恢复')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--fixture', type=Path, required=True)
    p.add_argument('--candidate', type=Path, required=True)
    args = p.parse_args()
    scope = validate_fixture(args.fixture)
    folder = args.fixture.resolve(); image = folder / 'fixture.img'
    policy = json.loads((APP / 'Contents/Resources/WriteFixturePolicy.json').read_text())
    if policy != json.loads((args.candidate / 'Contents/Resources/WriteFixturePolicy.json').read_text()):
        raise ValueError('安装包与候选后台写入范围不一致')
    if policy['imagePath'] != str(image) or policy['ownerUID'] != os.getuid() or policy['imageSHA256'] != scope['image_sha256']:
        raise ValueError('本次后台授权不是指定镜像')
    for part in ['Contents/MacOS/Volisle', 'Contents/Library/LaunchServices/VolisleMountHelper', 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS']:
        if sha256(APP / part) != sha256(args.candidate / part):
            raise ValueError('安装组件与候选不一致')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', APP])
    previous = call('--helper-cycle-latest')
    if previous and previous['phase'] != 'finished':
        raise ValueError('存在未完成后台操作，拒绝开始')
    output = folder / 'helper-write-result.json'
    if output.exists():
        raise ValueError('已有结果，拒绝覆盖')
    operation_id = str(uuid.uuid4()).upper()
    result = {'success': False, 'operation_id': operation_id, 'detached': False}
    device = None
    started = False
    mount_path = '/private/var/run/volisle-write-mounts/' + operation_id.lower()
    name = '后台事务-' + uuid.uuid4().hex + '.txt'
    payload = ('后台写入和恢复验收\n' * 4096).encode()
    result['payload_name'] = name
    result['payload_sha256'] = hashlib.sha256(payload).hexdigest()
    try:
        attached = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-nomount', '-nobrowse', '-noautoopen', '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [x['dev-entry'] for x in attached['system-entities'] if 'dev-entry' in x]
        if len(devices) != 1:
            raise ValueError('不是单一镜像设备')
        device = devices[0]
        run(['/usr/sbin/diskutil', 'mount', 'readOnly', device])
        probe = ROOT / 'apps/macos/.build/release/VolisleMountProbe'
        binding = json.loads(run([probe, '--write-image-binding', device.removeprefix('/dev/'), image]).stdout)
        result['binding'] = binding
        args_start = ['--helper-write-start', binding['bsdName'], str(binding['registryID']), str(binding['byteCount']), operation_id]
        started = True # A lost reply cannot prove that the request was rejected.
        result['submitted'] = call(*args_start)
        active = wait(operation_id); result['active'] = active
        if active['phase'] != 'writeMounted' or active.get('failure'):
            raise RuntimeError('后台未确认可写挂载')
        if call('--helper-cycle-latest') != active:
            raise RuntimeError('新客户端读取的持久所有权不一致')
        if call(*args_start) != active:
            raise RuntimeError('重复提交未返回原操作')
        lines = run(['/sbin/mount']).stdout.decode().splitlines()
        if not any(x.startswith(device + ' on ' + mount_path + ' (volisle,') for x in lines) or os.statvfs(mount_path).f_flag & os.ST_RDONLY:
            raise RuntimeError('实际可写挂载不匹配')
        result['client_exit_did_not_close_mount'] = True
        path = Path(mount_path) / name
        with path.open('xb') as f:
            f.write(payload); f.flush(); os.fsync(f.fileno())
        if path.read_bytes() != payload:
            raise RuntimeError('写入回读不一致')
        result['write_fsync_read'] = True
        # Refusing removal is a successful protection check, but the support
        # command correctly returns a failure exit code for that request.
        removal = subprocess.run([str(CLI), '--helper-unregister'], capture_output=True)
        result['unregister_attempt'] = json.loads(removal.stdout)
        result['unregister_exit_code'] = removal.returncode
        if removal.returncode != 1 or not result['unregister_attempt'].get('error'):
            raise RuntimeError('后台未明确拒绝注销请求')
        if call('--helper-status')['state'] != 'connected' or call('--helper-cycle-latest')['phase'] != 'writeMounted':
            raise RuntimeError('可写挂载期间后台被错误注销')
        result['active_service_removal_rejected'] = True
        call('--helper-cycle-recover', operation_id)
        finished = wait(operation_id); result['finished'] = finished
        if finished['phase'] != 'finished' or finished.get('failure'):
            raise RuntimeError('后台未确认正常恢复')
        info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        if info.get('FilesystemType') != 'ntfs' or info.get('WritableVolume') is not False or not info.get('MountPoint'):
            raise RuntimeError('系统未恢复原生只读')
        if (Path(info['MountPoint']) / name).read_bytes() != payload:
            raise RuntimeError('原生只读独立回读不一致')
        result['native_readonly_readback'] = True
        result['payload_sha256'] = hashlib.sha256(payload).hexdigest()
        result['success'] = True
    except BaseException as error:
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['stderr'] = (error.stderr or b'').decode(errors='replace')[-5000:]
        raise
    finally:
        if started:
            try:
                current = call('--helper-cycle-latest')
                if current and current['id'] == operation_id and current['phase'] != 'finished':
                    call('--helper-cycle-recover', operation_id)
                    result['cleanup_record'] = wait(operation_id)
                    if result['cleanup_record']['phase'] != 'finished':
                        result['success'] = False
            except BaseException as error:
                result['cleanup_error'] = str(error); result['success'] = False
        if device:
            try:
                run(['/usr/bin/hdiutil', 'detach', device]); result['detached'] = True
            except BaseException as error:
                result['detach_error'] = str(error); result['success'] = False
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if not result['success']:
            raise RuntimeError('后台写入验收未通过，请检查保留的操作与清理状态')

if __name__ == '__main__':
    main()
