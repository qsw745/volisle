#!/usr/bin/env python3
"""Exercise the Swift system transport with one prepared disposable image.
No sudo, physical-device arguments, formatting, force or service installation.
"""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from fskit_fixture import validate_fixture
from bundle_manifest import sha256


def run(arguments, timeout=45):
    return subprocess.run([str(arg) for arg in arguments], check=True, capture_output=True, timeout=timeout)


def image_devices(image):
    info = plistlib.loads(run(['/usr/bin/hdiutil', 'info', '-plist']).stdout)
    return [entry['dev-entry'] for record in info.get('images', [])
            if Path(record.get('image-path', '')).resolve() == image
            for entry in record.get('system-entities', []) if 'dev-entry' in entry]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--native-cycle', action='store_true', help='同时要求 Debug 验收程序完成原生只读卸载、引导核对和恢复')
    args = parser.parse_args()
    fixture = args.fixture.resolve(strict=True)
    validate_fixture(fixture)
    image = fixture / 'fixture.img'
    receipt = json.loads((fixture / 'fixture.json').read_text())
    probe = args.probe.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    if not probe.is_relative_to(root / 'apps/macos/.build') or probe.name != 'VolisleMountProbe':
        raise ValueError('只接受本项目本地构建的挂载验收程序')
    destination = fixture / 'system-transport-result.json'
    if destination.exists() or image_devices(image):
        raise ValueError('夹具已有验收结果或已连接，拒绝重复运行')
    result = {'transport_passed': False, 'detached': False, 'image_unchanged': False}
    device = None
    failure = None
    try:
        attached = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nomount', '-nobrowse', '-noautoopen',
                                     '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [x['dev-entry'] for x in attached['system-entities'] if 'dev-entry' in x]
        if len(devices) != 1 or not re.fullmatch(r'/dev/disk[0-9]+', devices[0]):
            raise ValueError('只接受新建无分区镜像的单一设备')
        device = devices[0]
        if image_devices(image) != [device]:
            raise ValueError('镜像设备绑定变化')
        info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        if info.get('TotalSize') != 67_108_864 or info.get('Writable') is not False:
            raise ValueError('镜像设备并非只读 64 MiB')
        # Do not kill a process while its system mount request is in flight.
        completed = run([probe, device.removeprefix('/dev/'), image, receipt['payload_sha256']], timeout=None)
        result['probe'] = json.loads(completed.stdout)
        required = ('incorrect_resource_binding_rejected', 'mount_verified', 'read_verified', 'write_denied',
                    'normally_unmounted', 'mountpoint_removed')
        if args.native_cycle:
            required += ('native_readonly_restore_verified', 'native_normally_unmounted', 'native_unmount_inspect_restore_cycle_verified')
        if not all(result['probe'].get(key) is True for key in required):
            raise ValueError('Swift 执行层未完成所有验收步骤')
        result['transport_passed'] = True
    except Exception as error:
        failure = error
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['stderr'] = error.stderr.decode(errors='replace')[-5000:]
    finally:
        try:
            owned = image_devices(image)
            if len(owned) == 1 and re.fullmatch(r'/dev/disk[0-9]+', owned[0]) and (device is None or device == owned[0]):
                result['mounts_before_detach'] = [line for line in run(['/sbin/mount']).stdout.decode().splitlines()
                                                 if line.startswith(owned[0] + ' ') or 'volisle-system-mount-' in line]
                run(['/usr/bin/hdiutil', 'detach', owned[0]])
                result['detached'] = image_devices(image) == []
            elif not owned:
                result['detached'] = True
            else:
                result['cleanup_error'] = '镜像设备身份无法确认，未尝试卸载其他设备'
        except Exception as error:
            result['cleanup_error'] = str(error)
        result['image_unchanged'] = sha256(image) == receipt['image_sha256']
        destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))
    if failure or not all(result[key] for key in ('transport_passed', 'detached', 'image_unchanged')):
        raise RuntimeError('系统挂载执行层验收未全部通过；详见保留的结果') from failure


if __name__ == '__main__':
    main()
