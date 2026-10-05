#!/usr/bin/env python3
"""R1/R3 on the INSTALLED extension: real FSKit mounts of a new disposable
NTFS image. Kills only the Volisle extension process, and only when this
image is its sole Volisle mount. Never touches any other disk."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ntfs_bridge_test_support import ROOT, LIB, ImageIO  # noqa: E402

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
APP = Path.home() / 'Applications/Volisle Test.app'
EXT = APP / 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'
SENTINEL = b'fskit-journal-existing-data\n' * 512
SIZE = 512 * 1024 * 1024
RETAINED = 25  # past WriteJournalLimits.retentionSeconds


def run(args, check=True, timeout=120):
    return subprocess.run([str(x) for x in args], capture_output=True, check=check, timeout=timeout)


def volisle_mounts():
    return [l for l in run(['/sbin/mount']).stdout.decode().splitlines() if '(volisle' in l or 'volisle,' in l]


def extension_pids():
    out = run(['pgrep', '-x', 'VolisleFS'], check=False).stdout.decode().split()
    pids = []
    for pid in out:
        comm = run(['ps', '-p', pid, '-o', 'comm='], check=False).stdout.decode().strip()
        if Path(comm).resolve() == EXT.resolve():
            pids.append(int(pid))
    return pids


def log_since(start):
    """The extension's own journal log; its container is not readable here."""
    stamp = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(start - 1))
    return run(['/usr/bin/log', 'show', '--info', '--style', 'compact', '--start', stamp, '--predicate',
                'subsystem == "Volisle.NTFSModule"'], check=False).stdout.decode(errors='replace')


def journal_dirs():
    base = Path.home() / 'Library/Containers'
    return [p for p in base.glob('*/Data/Library/Application Support/VolisleWriteJournal') if p.is_dir()]


def journal_records():
    found = []
    for d in journal_dirs():
        try:
            found += [f'{d.parent.parent.parent.parent.name}/{x.name}' for x in d.iterdir() if x.suffix in ('.session', '.epoch')]
        except PermissionError:
            found.append(f'{d}: unreadable')
    return sorted(found)


class Image:
    def __init__(self, folder):
        self.path = folder / 'fixture.img'
        self.device = None
        self.mountpoint = None

    def attach(self):
        info = plistlib.loads(run(['hdiutil', 'attach', '-nomount', '-nobrowse', '-noautoopen',
                                   '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', self.path]).stdout)
        devices = [x['dev-entry'] for x in info['system-entities'] if 'dev-entry' in x]
        assert len(devices) == 1 and re.fullmatch(r'/dev/disk[0-9]+', devices[0]), devices
        self.device = devices[0]
        disk = plistlib.loads(run(['diskutil', 'info', '-plist', self.device]).stdout)
        assert disk['TotalSize'] == SIZE and disk.get('Writable') is True

    def mount(self):
        assert not volisle_mounts(), volisle_mounts()
        self.mountpoint = Path(tempfile.mkdtemp(prefix='volisle-journal-', dir='/private/tmp'))
        run(['/sbin/mount', '-F', '-t', 'volisle', '-o', 'volisle-rw,nosuid,nodev', self.device, self.mountpoint])
        assert not (os.statvfs(self.mountpoint).f_flag & os.ST_RDONLY), 'mounted read-only'
        return self.mountpoint

    def unmount(self, force=False):
        if self.mountpoint and os.path.ismount(self.mountpoint):
            run(['/sbin/umount', *(['-f'] if force else []), self.mountpoint], check=not force)
        if self.mountpoint and not os.path.ismount(self.mountpoint):
            self.mountpoint.rmdir()
        self.mountpoint = None

    def detach(self):
        if self.device:
            run(['hdiutil', 'detach', *([] if not self.mountpoint else ['-force']), self.device], check=False)
            self.device = None


def make_image(folder):
    path = folder / 'fixture.img'
    with path.open('xb') as f:
        f.truncate(SIZE)
    run([BIN / 'mkntfs', '-F', '-Q', '-L', 'VolisleJournal', path])
    io = ImageIO(path); v = io.mount(); assert v
    assert LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0; io.close()


def offline_check(image_path):
    """Independent tools on the detached image: clean flag, mountable."""
    io = ImageIO(image_path, readonly=True)
    try:
        status = io.inspect()
    finally:
        io.close()
    listing = run([BIN / 'ntfsls', '-f', image_path], check=False)
    sentinel = run([BIN / 'ntfscat', '-f', image_path, '/sentinel'], check=False).stdout
    return {'inspect': status, 'ntfsls_rc': listing.returncode,
            'names': sorted(listing.stdout.decode(errors='replace').split()),
            'sentinel_ok': sentinel == SENTINEL,
            'error': listing.stderr.decode(errors='replace')[-300:]}


def write_file(path, data):
    with open(path, 'xb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())


def kill_extension(image):
    mounts = volisle_mounts()
    assert len(mounts) == 1 and str(image.mountpoint) in mounts[0], mounts
    # FSKit may keep an idle instance; this image is the only Volisle mount,
    # so every instance of THIS extension can be ended.
    pids = extension_pids()
    assert pids, 'no extension process'
    for pid in pids:
        os.kill(pid, signal.SIGKILL)
    for _ in range(50):
        if not set(pids) & set(extension_pids()):
            return pids
        time.sleep(0.1)
    raise AssertionError('extension did not exit')


def main():
    work = ROOT / '.workbench'
    folder = Path(tempfile.mkdtemp(prefix='fskit-journal-', dir=work))
    result = {'folder': str(folder), 'checks': [], 'success': False}
    image = Image(folder)
    try:
        assert not volisle_mounts(), 'another Volisle mount exists; refusing'
        make_image(folder)
        big = os.urandom(64 * 1024 * 1024)
        # 1. Normal session.
        t0 = time.time()
        image.attach(); root = image.mount()
        assert (root / 'sentinel').read_bytes() == SENTINEL
        write_file(root / 'a.bin', big)
        write_file(root / '中文 文件.txt', '你好，盘屿\n'.encode() * 1000)
        (root / 'dir').mkdir(); (root / 'a.bin').rename(root / 'dir' / 'a.bin')
        image.unmount(); image.detach()
        text = log_since(t0)
        assert '写入日志会话开始' in text and '写入日志会话正常结束' in text, text[-2000:]
        check = offline_check(image.path); result['after_normal'] = check
        assert check['inspect'] == 0 and check['ntfsls_rc'] == 0 and check['sentinel_ok'] and 'dir' in check['names']
        result['checks'].append('normal-session-journal-created-and-cleared-clean-volume')

        # 2. Idle crash: writes, then past the retention window (20 s of uptime),
        # then SIGKILL; a write made just before the kill is still inside it.
        image.attach(); root = image.mount()
        write_file(root / 'kept.bin', big[:8 * 1024 * 1024])
        time.sleep(RETAINED)
        write_file(root / 'recent.bin', b'inside the retention window')
        time.sleep(4)
        result['killed_idle'] = kill_extension(image)
        image.unmount(force=True); image.detach()
        result['offline_after_idle_kill'] = offline_check(image.path)
        t1 = time.time()
        image.attach(); root = image.mount()   # activation recovery
        assert '已回滚到最后一致点' in log_since(t1), 'no recovery on reconnect'
        assert (root / 'kept.bin').read_bytes() == big[:8 * 1024 * 1024], 'checkpointed data lost'
        # Checkpointed, but the drive may not have it yet: rolled back with its window.
        assert not (root / 'recent.bin').exists(), 'write inside the retention window kept'
        assert (root / 'sentinel').read_bytes() == SENTINEL
        write_file(root / 'after-idle-recovery.txt', b'ok')
        image.unmount(); image.detach()
        assert '写入日志会话正常结束' in log_since(t1)
        check = offline_check(image.path); result['after_idle_recovery'] = check
        assert check['inspect'] == 0 and check['sentinel_ok'] and 'after-idle-recovery.txt' in check['names']
        result['checks'].append('idle-kill-kept-data-past-window-rolled-back-recent-writable-again')

        # 3. Kill during a large write: roll back to the last checkpoint.
        image.attach(); root = image.mount()
        write_file(root / 'before-crash.txt', b'checkpointed')
        time.sleep(RETAINED)
        child = subprocess.Popen([sys.executable, '-c',
            'import os,sys\nf=open(sys.argv[1],"xb")\nwhile True: f.write(os.urandom(1<<20))', root / 'streaming.bin'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)
        result['killed_busy'] = kill_extension(image)
        child.kill(); child.wait()
        image.unmount(force=True); image.detach()
        result['offline_after_busy_kill'] = offline_check(image.path)
        t2 = time.time()
        image.attach(); root = image.mount()
        assert '已回滚到最后一致点' in log_since(t2), 'no recovery on reconnect'
        assert (root / 'before-crash.txt').read_bytes() == b'checkpointed'
        assert (root / 'kept.bin').read_bytes() == big[:8 * 1024 * 1024]
        result['streaming_after_recovery'] = (root / 'streaming.bin').stat().st_size if (root / 'streaming.bin').exists() else None
        write_file(root / 'after-busy-recovery.txt', b'ok')
        image.unmount(); image.detach()
        assert '写入日志会话正常结束' in log_since(t2)
        check = offline_check(image.path); result['after_busy_recovery'] = check
        assert check['inspect'] == 0 and check['sentinel_ok'] and 'after-busy-recovery.txt' in check['names']
        result['checks'].append('busy-kill-rolled-back-to-checkpoint-writable-again')
        result['success'] = True
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        try:
            image.unmount(force=True)
        finally:
            image.detach()
        result['log'] = run(['/usr/bin/log', 'show', '--last', '10m', '--style', 'compact', '--predicate',
                             'subsystem == "Volisle.NTFSModule"'], check=False).stdout.decode(errors='replace')[-6000:]
        (folder / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'log'}, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
