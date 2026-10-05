#!/usr/bin/env python3
"""Large-volume gate test on a new ordinary detached image only."""
import ctypes as C
from pathlib import Path
import subprocess
import tempfile
import errno
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
LIB.nk_replace_preserving.argtypes = [C.c_void_p] + [C.c_char_p] * 4
LIB.nk_replace_preserving.restype = C.c_int
with tempfile.TemporaryDirectory(prefix='volisle-large-volume-', dir=ROOT/'.workbench') as tmp:
    image = Path(tmp)/'fixture.img'
    with image.open('xb') as f: f.truncate(512 * 1024 * 1024)
    subprocess.run([ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs','-F','-Q',image],capture_output=True,check=True)
    io=ImageIO(image);v=io.mount();assert v
    try:
        for name,data in [(b'draft',b'new'),(b'document',b'old')]:
            assert LIB.nk_create(v,b'/',name)==0
            assert LIB.nk_write(v,b'/'+name,0,3,data)==3
        assert LIB.nk_replace_preserving(v,b'/',b'draft',b'document',b'.saved-old')==0, '512 MiB 隔离镜像不能执行覆盖'
    finally:
        assert LIB.nk_umount(v)==0;io.close()
    for name,expected in [('/document',b'new'),('/.saved-old',b'old')]:
        assert subprocess.check_output([ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat',image,name])==expected
print('512 MiB 桥接覆盖及独立新旧版本读取通过。')

with tempfile.TemporaryDirectory(prefix='volisle-large-volume-', dir=ROOT/'.workbench') as tmp:
    image=Path(tmp)/'outside-size.img'
    with image.open('xb') as f:f.truncate(128*1024*1024)
    subprocess.run([ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs','-F','-Q',image],capture_output=True,check=True)
    io=ImageIO(image);v=io.mount();assert v
    try:
        before=io.writes
        assert LIB.nk_replace_preserving(v,b'/',b'draft',b'document',b'.saved-old')==-1
        assert C.get_errno()==errno.ENOTSUP and io.writes==before
    finally:
        assert LIB.nk_umount(v)==0;io.close()
print('未明确允许的 128 MiB 容量拒绝覆盖，零元数据修改。')
