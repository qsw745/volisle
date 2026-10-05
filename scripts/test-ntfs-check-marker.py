#!/usr/bin/env python3
"""Clearing the NTFS "needs check" marker on the Mac (nk_clear_check_marker),
on disposable regular images only. Never touches a device."""
import ctypes as C
import errno
import hashlib
import json
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_clear_check_marker.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_clear_check_marker.restype = C.c_int
LIB.nk_create_symlink.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p]
LIB.nk_create_symlink.restype = C.c_int


class Dirent(C.Structure):
    _fields_ = [('name', C.c_char_p), ('is_dir', C.c_int), ('size', C.c_longlong),
                ('inode', C.c_uint64), ('is_symlink', C.c_int)]


DIR_CB = C.CFUNCTYPE(C.c_int, C.c_void_p, C.POINTER(Dirent))
LIB.nk_list.argtypes = [C.c_void_p, C.c_char_p, DIR_CB, C.c_void_p]
LIB.nk_list.restype = C.c_int
TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
MIB = 1 << 20
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def geometry(path):
    with path.open('rb') as f:
        boot = f.read(512)
    sector = struct.unpack_from('<H', boot, 11)[0]
    cluster = sector * boot[13]
    cpr = struct.unpack_from('b', boot, 64)[0]
    record = (1 << -cpr) if cpr < 0 else cpr * cluster
    return cluster, record, struct.unpack_from('<Q', boot, 48)[0], struct.unpack_from('<Q', boot, 56)[0]


def mark_dirty(path):
    """Set VOLUME_IS_DIRTY in $Volume (record 3) of $MFT and $MFTMirr."""
    cluster, record, mft, mirror = geometry(path)
    with path.open('r+b') as f:
        for lcn in (mft, mirror):
            pos = lcn * cluster + 3 * record
            f.seek(pos)
            data = f.read(record)
            a = struct.unpack_from('<H', data, 20)[0]
            while struct.unpack_from('<I', data, a)[0] != 0xffffffff:
                kind, length = struct.unpack_from('<II', data, a)
                if kind == 0x70:
                    at = pos + a + struct.unpack_from('<H', data, a + 20)[0] + 10
                    f.seek(at)
                    flags = struct.unpack('<H', f.read(2))[0]
                    f.seek(at)
                    f.write(struct.pack('<H', flags | 1))
                    break
                a += length
            else:
                raise AssertionError('$Volume information missing')


def corrupt_record(path, mft_number):
    cluster, record, mft, _ = geometry(path)
    with path.open('r+b') as f:
        f.seek(mft * cluster + mft_number * record)
        assert f.read(4) == b'FILE'
        f.seek(mft * cluster + mft_number * record)
        f.write(b'BAAD')


def clear(device):
    items = C.c_longlong(-1)
    err = C.create_string_buffer(128)
    C.set_errno(0)
    rc = ELIB.nk_clear_check_marker(C.byref(device.io), C.byref(items), err, 128)
    return rc, (C.get_errno() if rc else 0), items.value, err.value.decode()


def listing(v, path):
    found = {}

    @DIR_CB
    def collect(_, entry):
        found[entry.contents.name.decode()] = entry.contents.inode
        return 0
    assert LIB.nk_list(v, path.encode(), collect, None) == 0
    return found


def build(folder, name, extra=None):
    path = folder / name
    with path.open('xb') as f:
        f.truncate(64 * MIB)
    device = ImageIO(path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(device.io), b'CHECK', 0, err, 256) == 0, err.value
    v = device.mount()
    assert v
    payload = bytes(range(256)) * 12288  # 3 MiB: non-resident, several runs worth
    assert LIB.nk_mkdir(v, b'/', '照片'.encode()) == 0
    assert LIB.nk_mkdir(v, '/照片'.encode(), b'2026') == 0
    assert LIB.nk_create(v, '/照片/2026'.encode(), b'big.bin') == 0
    buf = C.create_string_buffer(payload, len(payload))
    assert LIB.nk_write(v, '/照片/2026/big.bin'.encode(), 0, len(payload), buf) == len(payload)
    assert LIB.nk_create(v, b'/', '说明.txt'.encode()) == 0
    assert LIB.nk_create_symlink(v, b'/', b'latest', '照片/2026'.encode()) == 0
    if extra:
        extra(v)
    inodes = listing(v, '/照片/2026')
    assert LIB.nk_sync(v) == 0 and LIB.nk_umount(v) == 0
    device.close()
    return path, hashlib.sha256(payload).hexdigest(), inodes


def read_hash(device, path, size):
    v = device.mount()
    out = C.create_string_buffer(size)
    assert LIB.nk_read(v, path.encode(), 0, size, out) == size
    assert LIB.nk_umount(v) == 0
    return hashlib.sha256(out.raw).hexdigest()


with tempfile.TemporaryDirectory(prefix='volisle-check-', dir=ROOT / '.workbench') as tmp:
    folder = Path(tmp)

    path, payload_hash, _ = build(folder, 'dirty.img')
    mark_dirty(path)
    device = ImageIO(path)
    assert device.inspect() == 1 and not device.mount()
    rc, error, items, reason = clear(device)
    assert rc == 0, reason
    assert items == 5, items  # 照片, 2026, big.bin, 说明.txt, latest
    assert device.inspect() == 0
    assert read_hash(device, '/照片/2026/big.bin', 3 * MIB) == payload_hash
    device.close()
    fix = subprocess.run([str(TOOLS / 'ntfsfix'), '-n', str(path)], capture_output=True, text=True, timeout=60)
    assert fix.returncode == 0, fix.stdout + fix.stderr
    passed('只带“需要检查”标记的卷：遍历全部 5 个文件和文件夹后清除，卷变干净，文件内容不变，NTFS-3G ntfsfix 独立检查通过')

    before = digest(path)
    device = ImageIO(path)
    assert clear(device)[:2] == (-1, errno.EALREADY) and device.writes == 0
    ro = ImageIO(path, readonly=True)
    assert clear(ro)[:2] == (-1, errno.EINVAL) and ro.writes == 0
    ro.close(); device.close()
    assert digest(path) == before
    passed('没有标记的卷、只读描述符都被拒绝，零写入，镜像不变')

    path, _, inodes = build(folder, 'broken.img')
    corrupt_record(path, inodes['big.bin'])
    mark_dirty(path)
    before = digest(path)
    device = ImageIO(path)
    rc, error, _, reason = clear(device)
    assert (rc, error) == (-1, errno.EIO) and reason.startswith('inconsistent record'), (rc, error, reason)
    assert device.writes == 0 and device.inspect() == 1
    device.close()
    assert digest(path) == before
    passed('文件记录损坏的卷：检查失败并报告记录号，零写入，镜像一个字节不变，仍标记为需要检查')

    def hiberfile(v):
        assert LIB.nk_create(v, b'/', b'hiberfil.sys') == 0
        data = b'hibr' + bytes(4092)
        buf = C.create_string_buffer(data, len(data))
        assert LIB.nk_write(v, b'/hiberfil.sys', 0, len(data), buf) == len(data)

    path, _, _ = build(folder, 'hibernated.img', hiberfile)
    mark_dirty(path)
    before = digest(path)
    device = ImageIO(path)
    rc, error, _, reason = clear(device)
    assert (rc, error, reason) == (-1, errno.EBUSY, 'hibernated'), (rc, error, reason)
    assert device.writes == 0
    device.close()
    assert digest(path) == before
    passed('带 Windows 休眠文件的卷：拒绝（可能有未写完的数据），零写入，镜像不变')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '一次性普通镜像；不涉及设备、后台组件或实盘'}
(ROOT / 'docs/testing/ntfs-check-marker-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
