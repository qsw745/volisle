#!/usr/bin/env python3
"""Host-side journal failure must prevent successful/clean NTFS teardown."""
import ctypes as C
import json
from pathlib import Path
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

LIB.nk_abort_write_session.argtypes = [C.c_void_p]
LIB.nk_abort_write_session.restype = None
with tempfile.TemporaryDirectory(prefix='volisle-abort-', dir=ROOT / '.workbench') as tmp:
    image = Path(tmp) / 'fixture.img'
    with image.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
    subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs', '-F', '-Q', image],
                   check=True, capture_output=True, timeout=45)
    io = ImageIO(image); volume = io.mount(); assert volume
    assert LIB.nk_create(volume, b'/', b'saved') == 0 and LIB.nk_sync(volume) == 0
    LIB.nk_abort_write_session(volume); LIB.nk_abort_write_session(volume)
    before = io.writes
    assert LIB.nk_create(volume, b'/', b'blocked') == -1, '宿主恢复记录失败后仍可继续修改'
    assert io.writes == before and LIB.nk_sync(volume) == -1
    assert LIB.nk_umount(volume) == -1 and io.inspect() == 1
    assert not io.mount() and io.writes == before
    io.close()
    io = ImageIO(image, readonly=True); volume = io.mount(); assert volume
    LIB.nk_abort_write_session(volume)
    assert LIB.nk_umount(volume) == 0 and io.writes == 0; io.close()
print(json.dumps({'success': True, 'checks': ['host-failure-locks-writes', 'dirty-retained', 'readonly-unaffected']}))
