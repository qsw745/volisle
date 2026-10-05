#!/usr/bin/env python3
"""Extended attribute names that NTFS stream names cannot hold (':' '/'), on disposable images only."""
import ctypes as C
import errno
import json
from datetime import datetime, timezone
from pathlib import Path
import tempfile

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
ELIB = C.CDLL(LIB._name, use_errno=True)
NAME_CB = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_char_p)
ELIB.nk_xattr_set.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_void_p, C.c_longlong, C.c_int]
ELIB.nk_xattr_set.restype = C.c_int
ELIB.nk_xattr_get.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_void_p, C.c_longlong]
ELIB.nk_xattr_get.restype = C.c_longlong
ELIB.nk_xattr_list.argtypes = [C.c_void_p, C.c_char_p, NAME_CB, C.c_void_p]
ELIB.nk_xattr_list.restype = C.c_int
ELIB.nk_xattr_remove.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
ELIB.nk_xattr_remove.restype = C.c_int
checks = []
WHERE = 'com.apple.metadata:kMDItemWhereFroms'
DATE = 'com.apple.metadata:kMDItemDownloadedDate'
SLASH = 'org.example/中文:属性'


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def xset(v, path, name, value):
    C.set_errno(0)
    rc = ELIB.nk_xattr_set(v, path.encode(), name.encode(), value, len(value), 0)
    return rc, (C.get_errno() if rc else 0)


def xget(v, path, name):
    buf = C.create_string_buffer(4096)
    n = ELIB.nk_xattr_get(v, path.encode(), name.encode(), buf, 4096)
    return None if n < 0 else buf.raw[:n]


def xlist(v, path):
    names = []

    @NAME_CB
    def collect(_, name):
        names.append(name.decode())
        return 0
    assert ELIB.nk_xattr_list(v, path.encode(), collect, None) == 0
    return sorted(names)


with tempfile.TemporaryDirectory(prefix='volisle-xattr-', dir=ROOT / '.workbench') as tmp:
    path = Path(tmp) / 'xattr.img'
    with path.open('xb') as f:
        f.truncate(64 << 20)
    device = ImageIO(path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(device.io), b'XATTR', 0, err, 256) == 0, err.value
    v = device.mount()
    assert LIB.nk_create(v, b'/', b'download.dmg') == 0
    f = '/download.dmg'
    plist = b'bplist00\xa1\x01_\x10\x13https://example.com'
    assert xset(v, f, WHERE, plist) == (0, 0)
    assert xset(v, f, DATE, b'2026-09-29') == (0, 0)
    assert xset(v, f, SLASH, b'x') == (0, 0)
    assert xset(v, f, 'com.apple.quarantine', b'0083;66f;Safari;') == (0, 0)
    assert xlist(v, f) == sorted([WHERE, DATE, SLASH, 'com.apple.quarantine'])
    assert xget(v, f, WHERE) == plist and xget(v, f, SLASH) == b'x'
    passed('下载文件常见的带冒号属性、带斜杠与中文的属性可写入，按原名列出并读回')

    writes = device.writes
    assert xset(v, f, 'bad\\name', b'x') == (-1, errno.EINVAL)
    assert xset(v, f, '$DATA', b'x') == (-1, errno.EINVAL)
    assert device.writes == writes
    assert LIB.nk_create(v, b'/', b'after.txt') == 0, '拒绝后会话必须仍可写'
    passed('反斜杠与 $ 开头的名字被拒绝，零写入且会话不被锁定')

    assert ELIB.nk_xattr_remove(v, f.encode(), DATE.encode()) == 0
    assert xget(v, f, DATE) is None
    assert LIB.nk_sync(v) == 0 and LIB.nk_umount(v) == 0 and device.inspect() == 0
    v = device.mount()
    assert xlist(v, f) == sorted([WHERE, SLASH, 'com.apple.quarantine']) and xget(v, f, WHERE) == plist
    assert LIB.nk_umount(v) == 0
    device.close()
    passed('删除后读不到；卸载后卷干净，重新挂载属性仍在')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '一次性普通镜像；不涉及设备、FSKit 或实盘'}
(ROOT / 'docs/testing/ntfs-xattr-names-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
