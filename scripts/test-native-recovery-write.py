#!/usr/bin/env python3
"""Authenticated rollback through a real writable raw node of fresh NTFS images only."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
from test_workdir import finish_workdir, make_workdir

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.workbench/native-write-20260925'


def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, timeout=60)


def digest(image):
    return hashlib.sha256(image.read_bytes()).hexdigest()


def scenario(mode):
    folder = make_workdir('native-write-')
    image = folder / 'recovery.img'
    with image.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs', '-F', '-Q', '-L', 'Volisle Recovery Test', image])
    baseline = digest(image)
    boot = hashlib.sha256(image.read_bytes()[:512]).hexdigest()
    with image.open('r+b') as stream:
        stream.seek(16 * 1024 * 1024)
        assert stream.read(4096) == bytes(4096)
        stream.seek(16 * 1024 * 1024)
        stream.write(bytes([0xa5]) * 4096)
        stream.flush()
        os.fsync(stream.fileno())
    interrupted = digest(image)
    assert interrupted != baseline
    device = None
    success = detached = False
    try:
        attached = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-nomount', '-nobrowse', '-noautoopen',
                                      '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [v['dev-entry'] for v in attached['system-entities'] if 'dev-entry' in v]
        assert len(devices) == 1
        device = devices[0]
        info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        assert info['TotalSize'] == 64 * 1024 * 1024 and info['Writable'] is True and not info.get('Mounted', False)
        (folder / 'disk-info.json').write_text(json.dumps({k: info.get(k) for k in ['TotalSize', 'Writable', 'Mounted', 'MountPoint', 'DeviceIdentifier', 'BusProtocol', 'DeviceBlockSize']}, indent=2))
        with open('/dev/r' + device.removeprefix('/dev/'), 'rb', buffering=0) as stream:
            raw_boot = hashlib.sha256(stream.read(512)).hexdigest()
        assert raw_boot == boot, (raw_boot, boot)
        manifest = folder / 'fixture.json'
        manifest.write_text(json.dumps({'image': str(image), 'bsdName': device.removeprefix('/dev/'),
            'baselineSHA256': baseline, 'bootSHA256': boot, 'mode': mode}))
        env = os.environ.copy()
        env['VOLISLE_NATIVE_WRITE_FIXTURE'] = str(manifest)
        with (folder / 'test.log').open('wb') as log:
            child = subprocess.Popen(['swift', 'test', '--package-path', 'packages/VolisleCore', '-Xswiftc',
                '-DVOLISLE_BLOCK_JOURNAL_TESTING', '--filter', 'NativeRecoveryWriteTests'], cwd=ROOT, env=env,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=15)
                raise
        assert code == 0, str(folder / 'test.log')
        log = (folder / 'test.log').read_text()
        assert 'authenticatedRawDeviceRestore() passed' in log and 'skipped' not in log.lower(), str(folder / 'test.log')
        assert digest(image) == (baseline if mode == 'success' else interrupted)
        success = True
    finally:
        if device:
            attachments = plistlib.loads(run(['/usr/bin/hdiutil', 'info', '-plist']).stdout)
            owned = [x for x in attachments['images'] if Path(x.get('image-path', '')).resolve() == image.resolve()]
            assert len(owned) == 1
            assert [x['dev-entry'] for x in owned[0]['system-entities'] if 'dev-entry' in x] == [device]
            run(['/usr/bin/hdiutil', 'detach', device])
            detached = True
        final = digest(image)
        result = {'mode': mode, 'success': success, 'detached': detached, 'image': str(image), 'device': device,
            'baselineSHA256': baseline, 'interruptedSHA256': interrupted, 'finalSHA256': final,
            'expectedFinalHash': final == (baseline if mode == 'success' else interrupted),
            'physicalDiskTouched': False, 'testLog': str(folder / 'test.log')}
        (folder / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        finish_workdir(folder, success and detached and result['expectedFinalHash'])
    assert success and detached and result['expectedFinalHash']
    return result


def main():
    OUT.mkdir(exist_ok=True)
    results = [scenario(mode) for mode in ['wrong-boot', 'validator-reject', 'success']]
    (OUT / 'writable-runtime-result.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
