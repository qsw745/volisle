#!/usr/bin/env python3
"""A full volume must fail with ENOSPC and stay usable: the user can delete
files to make room, the session is not locked, the volume unmounts clean and
an independent NTFS-3G check finds nothing. Device errors still lock it."""
import ctypes as C
import errno
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
LIB.nk_write.argtypes = [C.c_void_p, C.c_char_p, C.c_longlong, C.c_longlong, C.c_char_p]
LIB.nk_write.restype = C.c_longlong
LIB.nk_read.argtypes = [C.c_void_p, C.c_char_p, C.c_longlong, C.c_longlong, C.c_char_p]
LIB.nk_read.restype = C.c_longlong
LIB.nk_statvfs.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.POINTER(C.c_longlong), C.POINTER(C.c_int)]
KEEP = os.urandom(200_000)
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True}); print('PASS', name, flush=True)


def fresh(folder, name, size=64 << 20):
    image = Path(folder) / f'{name}.img'
    with image.open('xb') as f:
        f.truncate(size)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True)
    io = ImageIO(image); v = io.mount(); assert v
    assert LIB.nk_create(v, b'/', b'keep') == 0 and LIB.nk_write(v, b'/keep', 0, len(KEEP), KEEP) == len(KEEP)
    return image, io, v


def free(v):
    total, avail, cluster = C.c_longlong(), C.c_longlong(), C.c_int()
    assert LIB.nk_statvfs(v, C.byref(total), C.byref(avail), C.byref(cluster)) == 0
    return avail.value


def err():
    return errno.errorcode.get(C.get_errno(), C.get_errno())


def after_full(image, io, v, cleanup, label):
    """Common checks once a fill attempt reported ENOSPC."""
    out = C.create_string_buffer(len(KEEP))
    assert LIB.nk_read(v, b'/keep', 0, len(KEEP), out) == len(KEEP) and out.raw == KEEP, f'{label}: 原有文件被改动'
    cleanup()
    room = free(v)
    assert room > 32 << 20, f'{label}: 删除后空间没有回来（{room}）'
    data = os.urandom(4 << 20)
    assert LIB.nk_create(v, b'/', b'after') == 0, (label, err())
    assert LIB.nk_write(v, b'/after', 0, len(data), data) == len(data), (label, err())
    assert LIB.nk_umount(v) == 0, f'{label}: 卸载失败（会话被锁）'
    io.close()
    check = ImageIO(image, readonly=True)
    try:
        assert check.inspect() == 0, f'{label}: 卸载后不是干净状态'
        rv = check.mount(); assert rv
        back = C.create_string_buffer(len(data))
        assert LIB.nk_read(rv, b'/after', 0, len(data), back) == len(data) and back.raw == data
        assert LIB.nk_read(rv, b'/keep', 0, len(KEEP), out) == len(KEEP) and out.raw == KEEP
        assert LIB.nk_umount(rv) == 0
    finally:
        check.close()
    # Independent check by upstream NTFS-3G, read-only.
    fix = subprocess.run([BIN / 'ntfsfix', '-n', image], capture_output=True, text=True)
    assert fix.returncode == 0 and 'Error' not in fix.stdout, (label, fix.stdout, fix.stderr)


def delete(v, path):
    assert LIB.nk_delete(v, path) == 0, (path, err())


def expect_enospc(result, label):
    assert result == -1 and C.get_errno() == errno.ENOSPC, (label, result, err())


with tempfile.TemporaryDirectory(prefix='volisle-full-', dir=ROOT / '.workbench') as folder:
    # 1. Sequential copy of a large file until the disk is full.
    image, io, v = fresh(folder, 'sequential')
    assert LIB.nk_create(v, b'/', b'big') == 0
    chunk, offset = os.urandom(1 << 20), 0
    while True:
        C.set_errno(0)
        n = LIB.nk_write(v, b'/big', offset, len(chunk), chunk)
        if n != len(chunk): break
        offset += n
    expect_enospc(n, 'sequential')
    C.set_errno(0); expect_enospc(LIB.nk_write(v, b'/big', offset, len(chunk), chunk), 'sequential-again')
    after_full(image, io, v, lambda: delete(v, b'/big'), 'sequential')
    passed(f'顺序写大文件写满（约 {offset >> 20} MiB）：返回空间不足，可删除腾出空间、继续写入，卸载干净')

    # 2. A write far beyond the free space (would need more than the volume).
    image, io, v = fresh(folder, 'far')
    assert LIB.nk_create(v, b'/', b'far') == 0
    blob = os.urandom(1 << 20)
    C.set_errno(0); n = LIB.nk_write(v, b'/far', 200 << 20, len(blob), blob)
    if n == len(blob):
        # A sparse file may hold it; then filling the hole must hit ENOSPC.
        C.set_errno(0); fill = os.urandom(8 << 20); off = 0; r = 0
        while off < (200 << 20):
            r = LIB.nk_write(v, b'/far', off, len(fill), fill)
            if r != len(fill): break
            off += r
        expect_enospc(r, 'far-fill')
    else:
        expect_enospc(n, 'far')
    after_full(image, io, v, lambda: delete(v, b'/far'), 'far')
    passed('在远超剩余空间的位置写入：返回空间不足，卷保持一致')

    # 3. Many small files until something runs out.
    image, io, v = fresh(folder, 'small')
    small, names = os.urandom(64 << 10), []
    while True:
        name = f'f{len(names):05d}'.encode()
        C.set_errno(0)
        r = LIB.nk_create(v, b'/', name)
        if r != 0: expect_enospc(r, 'small-create'); break
        names.append(name)
        C.set_errno(0)
        w = LIB.nk_write(v, b'/' + name, 0, len(small), small)
        if w != len(small): expect_enospc(w, 'small-write'); break
    def drop():
        for name in names: delete(v, b'/' + name)
    after_full(image, io, v, drop, 'small')
    passed(f'大量小文件写满（{len(names)} 个）：返回空间不足，全部删除后恢复空间，卷保持一致')

    # 4. Extending a file by truncate beyond the free space.
    image, io, v = fresh(folder, 'truncate')
    assert LIB.nk_create(v, b'/', b'grow') == 0
    C.set_errno(0); r = LIB.nk_truncate(v, b'/grow', 500 << 20)
    if r != 0:
        expect_enospc(r, 'truncate')
    after_full(image, io, v, lambda: delete(v, b'/grow'), 'truncate')
    passed('截断扩大文件超过剩余空间：返回空间不足（或作为稀疏文件成功），卷保持一致')

    # 5. Extended attributes (named streams) until full.
    image, io, v = fresh(folder, 'xattr')
    assert LIB.nk_create(v, b'/', b'attrs') == 0
    value, count = os.urandom(1 << 20), 0
    while True:
        C.set_errno(0)
        r = LIB.nk_xattr_set(v, b'/attrs', f'com.example.blob{count}'.encode(), value, len(value), 0)
        if r != 0: expect_enospc(r, 'xattr'); break
        count += 1
    after_full(image, io, v, lambda: delete(v, b'/attrs'), 'xattr')
    passed(f'扩展属性写满（{count} 个 1 MiB）：返回空间不足，卷保持一致')

    # 6. A real device error still locks the session (the rule is unchanged).
    image, io, v = fresh(folder, 'device-error')
    assert LIB.nk_create(v, b'/', b'victim') == 0
    io.fail_write_at = io.writes + 1
    C.set_errno(0); data = os.urandom(1 << 20)
    assert LIB.nk_write(v, b'/victim', 0, len(data), data) == -1
    io.fail_write_at = None
    assert LIB.nk_create(v, b'/', b'blocked') == -1, '设备写入失败后会话必须锁定'
    assert LIB.nk_umount(v) == -1
    io.close()
    check = ImageIO(image, readonly=True); assert check.inspect() != 0; check.close()
    passed('磁盘写入出错仍然锁定会话并保留需要检查标记（规则未放松）')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '64 MiB 一次性镜像，真实 NTFS 引擎；ntfsfix -n 独立核对'}
(ROOT / 'docs/testing/ntfs-full-volume-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
