#!/usr/bin/env python3
"""Symbolic links (Interix style) through the bridge, on disposable images only."""
import ctypes as C
import errno
import json
from datetime import datetime, timezone
from pathlib import Path
import tempfile

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
# Same library handle, with errno captured right after each call.
ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_create_symlink.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p]
ELIB.nk_create_symlink.restype = C.c_int
LIB.nk_readlink.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_readlink.restype = C.c_int
class Dirent(C.Structure):
    _fields_ = [('name', C.c_char_p), ('is_dir', C.c_int), ('size', C.c_longlong),
                ('inode', C.c_uint64), ('is_symlink', C.c_int)]


DIR_CB = C.CFUNCTYPE(C.c_int, C.c_void_p, C.POINTER(Dirent))
LIB.nk_list.argtypes = [C.c_void_p, C.c_char_p, DIR_CB, C.c_void_p]
LIB.nk_list.restype = C.c_int
checks = []


def listing(v, path):
    found = {}

    @DIR_CB
    def collect(_, entry):
        e = entry.contents
        found[e.name.decode()] = ('link' if e.is_symlink else 'dir' if e.is_dir else 'file')
        return 0
    assert LIB.nk_list(v, path.encode(), collect, None) == 0
    return found


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def link(v, directory, name, target):
    C.set_errno(0)
    rc = ELIB.nk_create_symlink(v, directory.encode(), name.encode(), target.encode())
    return rc, (C.get_errno() if rc else 0)


def readlink(v, path):
    buf = C.create_string_buffer(4096)
    if LIB.nk_readlink(v, path.encode(), buf, 4096) != 0:
        return None
    return buf.value.decode()


with tempfile.TemporaryDirectory(prefix='volisle-symlink-', dir=ROOT / '.workbench') as tmp:
    path = Path(tmp) / 'links.img'
    with path.open('xb') as f:
        f.truncate(64 << 20)
    device = ImageIO(path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(device.io), b'LINKS', 0, err, 256) == 0, err.value
    v = device.mount()
    assert v
    assert LIB.nk_mkdir(v, b'/', 'Versions'.encode()) == 0
    assert LIB.nk_mkdir(v, b'/Versions', b'A') == 0
    assert link(v, '/Versions', 'Current', 'A') == (0, 0)
    assert link(v, '/', 'Resources', 'Versions/Current/Resources')[0] == 0
    assert link(v, '/', '中文链接', '../资源/文件 1.txt')[0] == 0
    assert link(v, '/', 'absolute', '/Applications/Safari.app')[0] == 0
    assert readlink(v, '/Versions/Current') == 'A'
    assert readlink(v, '/Resources') == 'Versions/Current/Resources'
    assert readlink(v, '/中文链接') == '../资源/文件 1.txt'
    assert readlink(v, '/absolute') == '/Applications/Safari.app'
    assert listing(v, '/Versions') == {'A': 'dir', 'Current': 'link'}
    root = listing(v, '/')
    assert root['Resources'] == 'link' and root['中文链接'] == 'link' and root['Versions'] == 'dir', root
    passed('创建框架式相对链接、中文目标、目标尚不存在的链接与绝对路径链接，读回与原文一致；目录列表报告为链接')

    writes = device.writes
    assert link(v, '/Versions', 'Current', 'B') == (-1, errno.EEXIST)
    assert link(v, '/', 'long', 'x' * 1024) == (-1, errno.ENAMETOOLONG)
    assert link(v, '/', 'empty', '') == (-1, errno.EINVAL)
    assert device.writes == writes, '拒绝的请求不能写盘'
    assert LIB.nk_create(v, b'/', b'after.txt') == 0, '拒绝后会话必须仍可写'
    assert readlink(v, '/Versions/Current') == 'A'
    passed('同名、目标超长、空目标都被拒绝且零写入；会话不被锁定，原链接不变')

    assert LIB.nk_create(v, b'/', b'plain.txt') == 0
    assert readlink(v, '/plain.txt') is None
    assert LIB.nk_delete(v, b'/absolute') == 0 and readlink(v, '/absolute') is None
    assert LIB.nk_sync(v) == 0 and LIB.nk_umount(v) == 0
    assert device.inspect() == 0
    v = device.mount()
    assert readlink(v, '/Versions/Current') == 'A' and readlink(v, '/中文链接') == '../资源/文件 1.txt'
    assert LIB.nk_umount(v) == 0
    device.close()
    passed('普通文件不被当成链接；链接可删除；卸载后卷干净，重新挂载链接仍在')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '一次性普通镜像；不涉及设备、FSKit 或实盘'}
(ROOT / 'docs/testing/ntfs-symlink-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
