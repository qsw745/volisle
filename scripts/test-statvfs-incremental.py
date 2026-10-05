#!/usr/bin/env python3
"""nk_statvfs scans $Bitmap once per mount; the incremental count must match
a fresh full scan after allocations and releases (disposable image only)."""
import ctypes as C
import json
from pathlib import Path
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
LIB.nk_statvfs.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.POINTER(C.c_longlong), C.POINTER(C.c_int)]
LIB.nk_statvfs.restype = C.c_int


def free(v):
    value = C.c_longlong()
    assert LIB.nk_statvfs(v, None, C.byref(value), None) == 0
    return value.value


def main():
    folder = Path(tempfile.mkdtemp(prefix='statvfs-', dir=ROOT / '.workbench'))
    image = folder / 'fixture.img'
    with image.open('xb') as f:
        f.truncate(128 * 1024 * 1024)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True)
    checks = []
    io = ImageIO(image); v = io.mount(); assert v
    start = free(v)
    reads = io.writes
    data = b'x' * (10 * 1024 * 1024 + 7)
    for name in [b'a', b'b', b'c']:
        assert LIB.nk_create(v, b'/', name) == 0
        assert LIB.nk_write(v, b'/' + name, 0, len(data), data) == len(data)
    after_alloc = free(v)
    assert start - after_alloc >= 3 * len(data), (start, after_alloc)
    checks.append('incremental-allocation')
    assert LIB.nk_delete(v, b'/b') == 0
    assert LIB.nk_truncate(v, b'/c', 4096) == 0
    incremental = free(v)
    assert incremental > after_alloc
    assert LIB.nk_umount(v) == 0; io.close()
    io = ImageIO(image, readonly=True); v = io.mount(); assert v
    fresh = free(v)
    assert LIB.nk_umount(v) == 0; io.close()
    assert fresh == incremental, (fresh, incremental)
    checks.append('incremental-equals-fresh-scan-after-release')
    print(json.dumps({'success': True, 'checks': checks, 'free': [start, after_alloc, incremental, fresh]}))
    for p in folder.iterdir(): p.unlink()
    folder.rmdir()


if __name__ == '__main__':
    main()
