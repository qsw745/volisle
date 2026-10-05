#!/usr/bin/env python3
"""R7 soak on the INSTALLED extension: a disposable NTFS image through real
FSKit for a fixed duration. Multi-GB file, batches of small files, in-place
rewrites, renames, deletes and periodic remounts; extension memory sampled
every round. Never touches any other disk."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

_spec = importlib.util.spec_from_file_location('fskit_journal', Path(__file__).resolve().parent / 'test-fskit-journal.py')
_j = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_j)
BIN, LIB, ImageIO, ROOT, SENTINEL = _j.BIN, _j.LIB, _j.ImageIO, _j.ROOT, _j.SENTINEL
SIZE = 8 * 1024 ** 3


def rss_mib():
    out = subprocess.run(['ps', '-axo', 'rss=,comm='], capture_output=True, text=True).stdout
    values = [int(l.split()[0]) for l in out.splitlines() if l.strip().endswith('/VolisleFS')]
    return round(max(values) / 1024, 1) if values else None


def make_image(folder):
    path = folder / 'fixture.img'
    with path.open('xb') as f:
        f.truncate(SIZE)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', '-L', 'VolisleSoak', path], check=True, capture_output=True)
    io = ImageIO(path); v = io.mount(); assert v
    assert LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0; io.close()


class Image(_j.Image):
    def attach(self):
        import plistlib, re
        info = plistlib.loads(subprocess.run(['hdiutil', 'attach', '-nomount', '-nobrowse', '-noautoopen',
            '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', self.path], capture_output=True, check=True).stdout)
        devices = [x['dev-entry'] for x in info['system-entities'] if 'dev-entry' in x]
        assert len(devices) == 1 and re.fullmatch(r'/dev/disk[0-9]+', devices[0]), devices
        self.device = devices[0]


def stream_file(path, mib, seed):
    h = hashlib.sha256()
    block = hashlib.sha256(seed.encode()).digest() * 32768  # 1 MiB pattern
    with open(path, 'xb') as f:
        for i in range(mib):
            chunk = block[i % 997:] + block[:i % 997]
            f.write(chunk); h.update(chunk)
        f.flush(); os.fsync(f.fileno())
    return h.hexdigest()


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 40
    folder = Path(tempfile.mkdtemp(prefix='fskit-soak-', dir=ROOT / '.workbench'))
    result = {'folder': str(folder), 'rounds': [], 'success': False}
    image = Image(folder)
    expected = {}
    try:
        assert not _j.volisle_mounts(), 'another Volisle mount exists; refusing'
        make_image(folder)
        image.attach(); root = image.mount()
        start = time.monotonic()
        t = time.monotonic()
        expected['big.bin'] = stream_file(root / 'big.bin', 3072, 'big')
        result['big_3gib_write_s'] = round(time.monotonic() - t, 1)
        t = time.monotonic(); assert sha(root / 'big.bin') == expected['big.bin']
        result['big_3gib_read_s'] = round(time.monotonic() - t, 1)
        round_no = 0
        while time.monotonic() - start < minutes * 60:
            round_no += 1
            t = time.monotonic()
            d = root / f'round-{round_no % 3}'
            if d.exists():
                for p in d.iterdir():
                    p.unlink()
                d.rmdir()
            d.mkdir()
            for i in range(150):
                data = os.urandom(512 + (i * 97) % 20000)
                with open(d / f'f{i:03}.bin', 'xb') as f:
                    f.write(data)
                expected[f'{d.name}/f{i:03}.bin'] = hashlib.sha256(data).hexdigest()
            for key in [k for k in expected if k.startswith(d.name + '/') and k not in {f'{d.name}/f{i:03}.bin' for i in range(150)}]:
                del expected[key]
            # In-place rewrite (editor save without replace), rename, and a 256 MiB file cycle.
            target = d / 'f000.bin'
            with open(target, 'r+b') as f:
                f.write(b'rewritten' * 100); f.flush(); os.fsync(f.fileno())
            expected[f'{d.name}/f000.bin'] = sha(target)
            os.rename(d / 'f001.bin', d / 'renamed.bin')
            expected[f'{d.name}/renamed.bin'] = expected.pop(f'{d.name}/f001.bin')
            mid = root / 'mid.bin'
            if mid.exists():
                mid.unlink()
            expected['mid.bin'] = stream_file(mid, 256, f'mid{round_no}')
            remount = round_no % 4 == 0
            if remount:
                image.unmount(); image.mount(); root = image.mountpoint
            bad = [k for k, v in expected.items() if sha(root / k) != v]
            assert not bad, bad[:5]
            result['rounds'].append({'round': round_no, 'seconds': round(time.monotonic() - t, 1), 'remounted': remount,
                                     'rss_mib': rss_mib(), 'files': len(expected)})
            print(json.dumps(result['rounds'][-1]), flush=True)
        assert (root / 'sentinel').read_bytes() == SENTINEL
        image.unmount(); image.detach()
        check = _j.offline_check(image.path); result['offline'] = check
        assert check['inspect'] == 0 and check['ntfsls_rc'] == 0 and check['sentinel_ok']
        rss = [r['rss_mib'] for r in result['rounds'] if r['rss_mib']]
        result['rss_first_last_max'] = [rss[0], rss[-1], max(rss)] if rss else None
        result['success'] = True
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        try:
            image.unmount(force=True)
        finally:
            image.detach()
        (folder / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
        summary = {k: v for k, v in result.items() if k != 'rounds'}
        summary['round_count'] = len(result['rounds'])
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        if result['success']:
            (folder / 'fixture.img').unlink()


if __name__ == '__main__':
    main()
