#!/usr/bin/env python3
"""Durability and ENOSPC regressions on newly created, detached NTFS images."""
import ctypes as C
import errno
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
LIB.nk_statvfs.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.POINTER(C.c_longlong), C.POINTER(C.c_int)]
LIB.nk_statvfs.restype = C.c_int
SENTINEL = b'unchanged-existing-data' * 128
MIRROR_LAG = '$MFTMirr does not match $MFT (record 0).'


def available(volume):
    free = C.c_longlong()
    assert LIB.nk_statvfs(volume, None, C.byref(free), None) == 0
    return free.value


def preserved(image):
    result = subprocess.run([BIN/'ntfscat', '-f', image, '/sentinel'], capture_output=True)
    assert result.returncode == 0 and result.stdout == SENTINEL, result.stderr.decode(errors='replace')


def mirror_synced_preserved(image):
    """True if the only damage is $MFTMirr lag: ntfsfix on a copy, then read back."""
    copy = image.with_name(image.stem + '-mirror-synced.img')
    shutil.copyfile(image, copy)
    try:
        fixed = subprocess.run([BIN/'ntfsfix', copy], capture_output=True, text=True)
        if fixed.returncode != 0 or 'Correcting differences in $MFTMirr' not in fixed.stdout: return False
        preserved(copy)
        return True
    except AssertionError:
        return False
    finally:
        copy.unlink()


def blocked(io, volume):
    before = io.writes
    assert LIB.nk_create(volume, b'/', b'after-failure') == -1
    assert C.get_errno() == errno.EIO and io.writes == before
    assert LIB.nk_umount(volume) == -1
    status = io.inspect()
    assert status in [1, 4] and not io.mount()
    return status


def main():
    folder = Path(tempfile.mkdtemp(prefix='create-safety-', dir=ROOT/'.workbench'))
    results = []
    recovery_failures = []
    mirror_lag = []
    completed = False
    def inspect_recovery(image, case):
        try: preserved(image)
        except AssertionError as error:
            # The bare bridge has no write journal: an interruption between the
            # $MFT and $MFTMirr writes of record 0 leaves the mirror one write
            # behind, and NTFS-3G refuses the volume (known since 2026-09-24;
            # the production path is covered by test-write-journal.py). Accept
            # exactly that, and only if syncing the mirror the way chkdsk would
            # leaves the existing data intact.
            if MIRROR_LAG in str(error) and mirror_synced_preserved(image):
                mirror_lag.append(case)
                return True
            recovery_failures.append({'case': case, 'image': str(image), 'error': str(error)})
            return False
        return True
    base = folder/'base.img'
    with base.open('xb') as stream: stream.truncate(64*1024*1024)
    subprocess.run([BIN/'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
    io = ImageIO(base); volume = io.mount(); assert volume
    assert LIB.nk_create(volume, b'/', b'sentinel') == 0
    assert LIB.nk_write(volume, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(volume) == 0; io.close()
    try:
        for kind, create in [('file', LIB.nk_create), ('directory', LIB.nk_mkdir)]:
            normal = folder/(kind+'-normal.img'); shutil.copyfile(base, normal)
            io = ImageIO(normal); volume = io.mount(); assert volume
            writes, syncs = io.writes, io.syncs
            assert create(volume, b'/', b'new-node') == 0
            write_count, sync_count = io.writes-writes, io.syncs-syncs
            assert 0 < write_count < 64 and sync_count > 0
            before = io.writes
            for parent, name, error in [(b'/', b'new-node', errno.EEXIST),
                                         (b'/', b'x'*256, errno.ENAMETOOLONG),
                                         (b'/sentinel', b'bad-parent', errno.ENOTDIR)]:
                assert create(volume, parent, name) == -1
                assert C.get_errno() == error and io.writes == before
            assert LIB.nk_create(volume, b'/', b'after-validation-error') == 0
            assert LIB.nk_umount(volume) == 0 and io.inspect() == 0; io.close()
            preserved(normal)
            results.append(kind+'-durable-and-preflight-errors-do-not-poison')
            image = folder/(kind+'-sync.img'); shutil.copyfile(base, image)
            io = ImageIO(image); volume = io.mount(); assert volume
            io.fail_sync = True
            result = create(volume, b'/', b'new-node')
            io.fail_sync = False
            if result != -1:
                LIB.nk_umount(volume); io.close()
                raise AssertionError(kind + ': 创建未持久刷新就报告成功，刷新失败未被检测')
            blocked(io, volume); io.close(); preserved(image)
            results.append(kind+'-flush-failure-blocked')
            for point in range(1, write_count+1):
                image = folder/f'{kind}-write-{point}.img'; shutil.copyfile(base, image)
                io = ImageIO(image); volume = io.mount(); assert volume
                io.fail_write_at = io.writes+point
                assert create(volume, b'/', b'new-node') == -1
                io.fail_write_at = None
                blocked(io, volume); io.close()
                if inspect_recovery(image, f'{kind}-write-{point}'): image.unlink()
                results.append(f'{kind}-write-failure-{point}')
            for point in range(1, write_count+1):
                image = folder/f'{kind}-crash-{point}.img'; shutil.copyfile(base, image)
                child = '''import sys
from pathlib import Path
from ntfs_bridge_test_support import LIB,ImageIO
io=ImageIO(Path(sys.argv[1]));v=io.mount();assert v
io.crash_after_write_at=io.writes+int(sys.argv[2])
getattr(LIB,sys.argv[3])(v,b'/',b'new-node')
raise AssertionError('crash callback not reached')
'''
                process = subprocess.run([sys.executable, '-c', child, str(image), str(point),
                                          'nk_create' if kind=='file' else 'nk_mkdir'],
                                         cwd=ROOT/'scripts', capture_output=True, timeout=30)
                assert process.returncode == 86, process.stderr
                io=ImageIO(image); assert io.inspect() in [1,4] and not io.mount() and io.writes==0; io.close()
                if inspect_recovery(image, f'{kind}-crash-{point}'): image.unlink()
                results.append(f'{kind}-crash-after-write-{point}')
        # Exhaust actual data clusters cleanly, then force namespace/MFT
        # growth. This is allocation ENOSPC, not a simulated I/O error.
        full = folder/'full-clean.img'; shutil.copyfile(base, full)
        io=ImageIO(full); volume=io.mount(); assert volume
        assert LIB.nk_create(volume,b'/',b'filler')==0
        chunk=b'F'*(1024*1024); offset=0
        for _ in range(70):
            free=available(volume)
            if free==0: break
            count=min(free,len(chunk))
            assert LIB.nk_write(volume,b'/filler',offset,count,chunk)==count, ('fill',free,C.get_errno())
            offset+=count
        assert available(volume)==0
        assert LIB.nk_umount(volume)==0;io.close()
        for kind,create in [('file',LIB.nk_create),('directory',LIB.nk_mkdir)]:
            image=folder/(kind+'-full.img');shutil.copyfile(full,image)
            io=ImageIO(image);volume=io.mount();assert volume
            for index in range(512):
                result=create(volume,b'/',('node-'+str(index)+'-'+'n'*180).encode())
                error=C.get_errno()
                if result<0: break
            else: raise AssertionError('bounded metadata allocation did not fail')
            assert error==errno.ENOSPC,(kind,error,index)
            # Since 0.5.4 running out of space is not damage: NTFS-3G backs the
            # allocation out, the session stays usable and the volume clean.
            assert LIB.nk_umount(volume)==0 and io.inspect()==0;io.close();preserved(image)
            results.append(f'{kind}-real-metadata-ENOSPC-keeps-volume-clean-after-{index}-nodes')
        completed = True
        print(json.dumps({'success': not recovery_failures, 'checks': results,
                          'known_mirror_lag': mirror_lag, 'recovery_failures': recovery_failures,
                          'evidence': str(folder)}, ensure_ascii=False))
    finally:
        (folder/'result.json').write_text(json.dumps({'success': completed and not recovery_failures,
                                                    'completed': completed, 'checks': results,
                                                    'known_mirror_lag': mirror_lag,
                                                    'recovery_failures': recovery_failures}, ensure_ascii=False, indent=2)+'\n')
    if recovery_failures: raise SystemExit(1)


if __name__ == '__main__': main()
