#!/usr/bin/env python3
"""Real Disk Arbitration claim tests on one newly made read-only NTFS image."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.workbench/held-device-20260925'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, timeout=60, **kwargs)


def main():
    OUT.mkdir(exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix='native-claim-', dir=ROOT / '.workbench'))
    image = folder / 'readonly.img'
    with image.open('xb') as stream:
        stream.truncate(64*1024*1024)
    mkntfs = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs'
    run([mkntfs, '-F', '-Q', '-L', 'Volisle Claim Test', image])
    original = hashlib.sha256(image.read_bytes()).hexdigest()
    device = None
    success = False
    detached = False
    try:
        attached = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nomount', '-nobrowse', '-noautoopen',
                                      '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', image]).stdout)
        devices = [v['dev-entry'] for v in attached['system-entities'] if 'dev-entry' in v]
        assert len(devices) == 1
        device = devices[0]
        info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device]).stdout)
        (folder / 'disk-info.json').write_text(json.dumps({k:info.get(k) for k in ['TotalSize', 'Writable', 'Mounted', 'MountPoint', 'DeviceIdentifier', 'BusProtocol']}, indent=2))
        assert info['TotalSize'] == 64*1024*1024 and info['Writable'] is False
        manifest = folder / 'fixture.json'
        manifest.write_text(json.dumps({'image': str(image), 'bsdName': device.removeprefix('/dev/')}))
        env = os.environ.copy()
        env['VOLISLE_NATIVE_CLAIM_FIXTURE'] = str(manifest)
        with (folder / 'test.log').open('wb') as log:
            child = subprocess.Popen(['swift', 'test', '--package-path', 'packages/VolisleCore', '--filter',
                                      'NativeRecoveryClaimTests'],
                                     cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=150)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=15)
                raise
        assert code == 0, (code, str(folder / 'test.log'))
        log = (folder / 'test.log').read_text()
        assert 'actualReadOnlyImageClaimLifecycle() passed' in log and 'actualWaitingCancellationAndLateCleanup() passed' in log and 'actualWorkerRetainsClaimUntilUnwind() passed' in log and 'actualHeldReadOnlyDeviceLifecycle() passed' in log and 'skipped' not in log.lower(), str(folder / 'test.log')
        assert hashlib.sha256(image.read_bytes()).hexdigest() == original
        success = True
    finally:
        if device:
            # Verify ownership again; detach only this test image, never force.
            attachments = plistlib.loads(run(['/usr/bin/hdiutil', 'info', '-plist']).stdout)
            owned = [x for x in attachments['images'] if Path(x.get('image-path', '')).resolve() == image.resolve()]
            assert len(owned) == 1
            assert [x['dev-entry'] for x in owned[0]['system-entities'] if 'dev-entry' in x] == [device]
            run(['/usr/bin/hdiutil', 'detach', device])
            detached = True
        result = {'success': success, 'detached': detached, 'image': str(image), 'device': device,
                  'sha256': original, 'imageUnchanged': hashlib.sha256(image.read_bytes()).hexdigest() == original,
                  'physicalDiskTouched': False, 'testLog': str(folder / 'test.log')}
        (folder / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
        (OUT / 'runtime-result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)
        if success and detached:
            image.unlink()  # Only the newly created successful fixture.


if __name__ == '__main__':
    main()
