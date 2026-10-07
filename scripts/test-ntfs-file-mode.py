#!/usr/bin/env python3
"""Persisted Windows READONLY flag, without rewriting ownership/ACLs."""
import ctypes as C
import errno
import hashlib
from pathlib import Path
import subprocess
import tempfile
import shutil
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

assert hasattr(LIB, 'nk_set_file_mode'), '尚未实现持久化文件只读权限'
LIB.nk_set_file_mode.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
LIB.nk_set_file_mode.restype = C.c_int
LIB.nk_reference_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_uint64)]
LIB.nk_reference_path.restype = C.c_int
LIB.nk_write_reference.argtypes = [C.c_void_p, C.c_uint64, C.c_longlong, C.c_longlong, C.c_void_p]
LIB.nk_write_reference.restype = C.c_longlong
BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'


def tool(image, *args):
    return subprocess.check_output([str(BIN / args[0]), *map(str, args[1:]), str(image)], stderr=subprocess.DEVNULL)


def info(image):
    return tool(image, 'ntfsinfo', '-f', '-F', '/document').decode()


def security(image):
    # New files inherit the parent's descriptor through a $Secure security ID
    # (no per-file 0x50 attribute): the ID must not change.
    lines = [l for l in info(image).splitlines() if 'Security ID' in l]
    assert len(lines) == 1, lines
    return lines[0].encode()


def content(volume):
    data=C.create_string_buffer(8)
    assert LIB.nk_read(volume, b'/document', 0, 8, data)==8
    assert data.raw==b'original'


with tempfile.TemporaryDirectory(prefix='volisle-file-mode-', dir=ROOT / '.workbench') as tmp:
    image=Path(tmp)/'fixture.img'
    with image.open('xb') as f: f.truncate(64*1024*1024)
    subprocess.run([BIN/'mkntfs','-F','-Q',image],check=True,capture_output=True)
    io=ImageIO(image); v=io.mount(); assert v
    assert LIB.nk_create(v,b'/',b'document')==0
    assert LIB.nk_write(v,b'/document',0,8,b'original')==8
    assert LIB.nk_mkdir(v,b'/',b'folder')==0
    assert LIB.nk_umount(v)==0;io.close()
    acl=security(image); assert acl
    pristine=Path(tmp)/'before-mode.img'; shutil.copyfile(image,pristine)
    io=ImageIO(image);v=io.mount();assert v
    writes=io.writes
    for mode in [0o600,0o666,0o755,0o4644,0o100444,0xffffffff]:
        assert LIB.nk_set_file_mode(v,b'/document',mode)==-1 and C.get_errno()==errno.ENOTSUP
    assert LIB.nk_set_file_mode(v,b'/folder',0o444)==-1 and C.get_errno()==errno.EISDIR
    assert io.writes==writes, '不支持的权限不得修改介质'
    assert LIB.nk_set_file_mode(v,b'/document',0o444)==0
    assert LIB.nk_umount(v)==0;io.close()
    assert security(image)==acl,'只读位不能改写 Windows 安全描述符'
    dump=info(image); assert 'READONLY' in dump or 'READ_ONLY' in dump, dump
    io=ImageIO(image);v=io.mount();assert v
    ref=C.c_uint64();assert LIB.nk_reference_path(v,b'/document',C.byref(ref))==0
    writes=io.writes
    for call in [lambda:LIB.nk_write(v,b'/document',0,1,b'X'),lambda:LIB.nk_write_reference(v,ref.value,0,1,b'X'),lambda:LIB.nk_truncate(v,b'/document',0)]:
        assert call()==-1 and C.get_errno()==errno.EACCES
    assert io.writes==writes;content(v)
    assert LIB.nk_set_file_mode(v,b'/document',0o644)==0
    assert LIB.nk_write(v,b'/document',0,1,b'O')==1
    assert LIB.nk_umount(v)==0;io.close()
    assert security(image)==acl
    dump=info(image); assert 'READONLY' not in dump and 'READ_ONLY' not in dump
    before=hashlib.sha256(image.read_bytes()).hexdigest()
    io=ImageIO(image,readonly=True);v=io.mount();assert v
    assert LIB.nk_set_file_mode(v,b'/document',0o444)==-1 and C.get_errno()==errno.EROFS
    assert io.writes==0;assert LIB.nk_umount(v)==0;io.close()
    assert hashlib.sha256(image.read_bytes()).hexdigest()==before
    failed=Path(tmp)/'failed-mode.img'; shutil.copyfile(pristine,failed)
    io=ImageIO(failed);v=io.mount();assert v
    io.fail_write_at=io.writes+1
    assert LIB.nk_set_file_mode(v,b'/document',0o444)==-1
    assert LIB.nk_write(v,b'/document',0,1,b'X')==-1 and C.get_errno()==errno.EIO
    assert LIB.nk_umount(v)==-1;io.close()
    io=ImageIO(failed,readonly=True)
    assert io.inspect()!=0 and io.writes==0
    io.close()
print('文件只读权限通过：持久化、ACL 不变、拒绝写入/截断、恢复可写、非法请求零写入、只读卷零写入。')
