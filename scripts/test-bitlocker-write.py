#!/usr/bin/env python3
"""BitLocker read-write through the engine (nk_bde_io over a writable device),
on copies of the images Windows 11 created (.workbench/bitlocker-fixtures,
regenerate with scripts/bitlocker-fixtures/fetch.sh). The originals are opened
read-only and hashed before and after. Copies of the written images are kept in
.workbench/bitlocker-written/ for the Windows round trip (windows-verify.sh)."""
import ctypes as C
import errno
import hashlib
import json
import os
import random
import shutil
import struct
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, IO

ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_bde_open.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_size_t]
ELIB.nk_bde_open.restype = C.c_void_p
ELIB.nk_bde_io.argtypes = [C.c_void_p]
ELIB.nk_bde_io.restype = IO
ELIB.nk_bde_close.argtypes = [C.c_void_p]
FIXTURES = ROOT / '.workbench/bitlocker-fixtures'
WRITTEN = ROOT / '.workbench/bitlocker-written'
PASSWORD, RECOVERY = 1, 2
META_REGION = 65536
# ctypes only captures errno for its own foreign functions, not for calls through
# the nk_io function pointers: read the thread's errno from libc directly.
_errno = C.CDLL(None).__error
_errno.restype = C.POINTER(C.c_int)
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def reserved(raw):
    """BitLocker's own regions: the three metadata blocks and the relocated header store."""
    metas = [struct.unpack_from('<Q', raw, 176 + 8 * i)[0] for i in range(3)]
    block = raw[metas[0]:metas[0] + 64]
    sector = struct.unpack_from('<H', raw, 11)[0]
    store = struct.unpack_from('<Q', block, 56)[0], struct.unpack_from('<I', block, 28)[0] * sector
    return [(m, META_REGION) for m in metas] + [store]


class Unlocked:
    def __init__(self, path, kind, secret, readonly):
        self.device = ImageIO(path, readonly=readonly)
        err = C.create_string_buffer(96)
        self.handle = ELIB.nk_bde_open(C.byref(self.device.io), kind, secret.encode(), err, 96)
        assert self.handle, err.value
        self.io = ELIB.nk_bde_io(self.handle)

    def pread(self, count, offset):
        buf = C.create_string_buffer(count)
        assert self.io.pread(self.io.ctx, buf, count, offset) == count
        return buf.raw

    def pwrite(self, data, offset):
        _errno()[0] = 0
        result = self.io.pwrite(self.io.ctx, data, len(data), offset)
        return result, (_errno()[0] if result < 0 else 0)

    def close(self):
        ELIB.nk_bde_close(self.handle)
        self.device.close()


def read_file(v, path, size):
    out = C.create_string_buffer(max(1, size))
    assert LIB.nk_read(v, path.encode(), 0, size, out) == size, path
    return sha(out.raw[:size])


def write_file(v, path, data):
    assert LIB.nk_write(v, path.encode(), 0, len(data), data) == len(data), path


names = ['xts128', 'xts256', 'cbc128', 'cbc256']
metas = {n: json.loads((FIXTURES / f'{n}.json').read_text(encoding='utf-8-sig')) for n in names}
before = {n: digest(FIXTURES / f'{n}.img') for n in names}
shutil.rmtree(WRITTEN, ignore_errors=True)
WRITTEN.mkdir(parents=True)
expected = {}

# 1. Only a writable device gives a writable view.
for n in names:
    u = Unlocked(FIXTURES / f'{n}.img', PASSWORD, metas[n]['password'], readonly=True)
    assert u.io.readonly == 1 and not u.io.pwrite and not u.io.sync
    u.close()
    copy = WRITTEN / f'{n}.img'
    shutil.copyfile(FIXTURES / f'{n}.img', copy)
    u = Unlocked(copy, PASSWORD, metas[n]['password'], readonly=False)
    assert u.io.readonly == 0 and u.io.pwrite and u.io.sync
    u.close()
passed('只读设备上解锁得到只读视图；可写设备上得到可写视图')

# 2. Raw sector-level writes: aligned, unaligned, spanning runs; reads see exactly what was written.
rng = random.Random(2026)
for n in names:
    copy = WRITTEN / f'{n}.img'
    raw_before = copy.read_bytes()
    u = Unlocked(copy, PASSWORD, metas[n]['password'], readonly=False)
    size = u.io.size
    # Free space near the end of the volume, clear of the reserved regions and the backup boot sector.
    regions = reserved(raw_before)
    base = size - (8 << 20)
    assert all(not (start < base + (4 << 20) and base < start + length) for start, length in regions)
    model = bytearray(u.pread(4 << 20, base))
    for offset, length in [(0, 512), (4096, 4096), (777, 100), (511, 2), (8191, 70000), (300000, 1 << 20), (1 << 21, 333333)]:
        data = bytes(rng.getrandbits(8) for _ in range(length))
        assert u.pwrite(data, base + offset) == (length, 0)
        model[offset:offset + length] = data
    assert u.pread(4 << 20, base) == bytes(model)
    assert u.io.sync(u.io.ctx) == 0
    u.close()
    # Ciphertext changed only inside the written span.
    raw_after = copy.read_bytes()
    assert raw_after[:base] == raw_before[:base] and raw_after[base + (4 << 20):] == raw_before[base + (4 << 20):]
    assert raw_after[base:base + (4 << 20)] != raw_before[base:base + (4 << 20)]
    assert bytes(model) not in raw_after, '磁盘上只有密文'
    u = Unlocked(copy, RECOVERY, metas[n]['recovery'], readonly=True)
    assert u.pread(4 << 20, base) == bytes(model)
    u.close()
    # Undo for the file-level test below: restore the original ciphertext.
    with open(copy, 'r+b') as f:
        f.seek(base); f.write(raw_before[base:base + (4 << 20)])
passed('对齐、不对齐、跨扇区与 1 MiB 以上的写入读回一致；磁盘上只变动写入范围，且只有密文；换恢复密钥重新解锁读到同样内容')

# 3. Reserved regions refuse writes, as a whole and before anything reaches the disk.
for n in names:
    copy = WRITTEN / f'{n}.img'
    raw_before = copy.read_bytes()
    u = Unlocked(copy, PASSWORD, metas[n]['password'], readonly=False)
    writes = u.device.writes
    for start, length in reserved(raw_before):
        for offset, count in [(start, 512), (start + length - 1, 1), (start - 4096, 8192), (start + length - 512, 4096)]:
            got = u.pwrite(b"\xa5" * count, offset); assert got == (-1, errno.EIO), (n, start, offset, got)
        assert u.pread(length, start) == bytes(length), '保留区域读出全零'
    assert u.device.writes == writes
    u.close()
    assert copy.read_bytes() == raw_before
passed('写入 BitLocker 元数据与卷头存放区一律报 I/O 错误，跨边界的写入整体拒绝，磁盘零写入')

# 4. File-level writes through NTFS, then a fresh unlock (recovery key) reads them back.
for n in names:
    copy = WRITTEN / f'{n}.img'
    raw_before = copy.read_bytes()
    u = Unlocked(copy, PASSWORD, metas[n]['password'], readonly=False)
    v = LIB.nk_mount_io(C.byref(u.io), None, 0)
    assert v, n
    big = random.Random(n).randbytes(9 * 1024 * 1024 + 123)
    small = f'盘屿在 Mac 上写入 {n}\n'.encode()
    assert LIB.nk_mkdir(v, b'/', '来自Mac'.encode()) == 0
    assert LIB.nk_create(v, '/来自Mac'.encode(), '大文件.bin'.encode()) == 0
    write_file(v, '/来自Mac/大文件.bin', big)
    assert LIB.nk_create(v, '/来自Mac'.encode(), '说明.txt'.encode()) == 0
    write_file(v, '/来自Mac/说明.txt', small)
    # Overwrite the middle of a file Windows wrote, and grow another.
    pattern = next(f for f in metas[n]['files'] if f['path'].endswith('pattern.bin'))
    patch = b'VOLISLE' * 1000
    assert LIB.nk_write(v, ('/' + pattern['path']).encode(), 1_000_003, len(patch), patch) == len(patch)
    old = bytes(((i * 7 + 13) % 251) for i in range(pattern['size']))
    new_pattern = old[:1_000_003] + patch + old[1_000_003 + len(patch):]
    note = next(f for f in metas[n]['files'] if f['path'].endswith('.txt') and '/' not in f['path'])
    extra = '再加一行\n'.encode()
    assert LIB.nk_write(v, ('/' + note['path']).encode(), note['size'], len(extra), extra) == len(extra)
    # PowerShell's [Text.Encoding]::UTF8 writes a byte order mark.
    original_note = b'\xef\xbb\xbf' + f'盘屿 BitLocker 测试 {n}\n'.encode()
    assert sha(original_note) == note['sha256']
    assert LIB.nk_create(v, b'/', b'delete-me.tmp') == 0
    write_file(v, '/delete-me.tmp', b'x' * 70000)
    assert LIB.nk_delete(v, b'/delete-me.tmp') == 0
    assert LIB.nk_rename(v, '/来自Mac/说明.txt'.encode(), b'/', '来自Mac-说明.txt'.encode()) == 0
    assert LIB.nk_umount(v) == 0
    u.close()
    raw_after = copy.read_bytes()
    for start, length in reserved(raw_before):
        assert raw_after[start:start + length] == raw_before[start:start + length], '保留区域密文不变'
    assert raw_after[:512] == raw_before[:512], 'BitLocker 卷头不变'
    files = {
        '来自Mac/大文件.bin': (len(big), sha(big)),
        '来自Mac-说明.txt': (len(small), sha(small)),
        pattern['path']: (len(new_pattern), sha(new_pattern)),
        note['path']: (note['size'] + len(extra), sha(original_note + extra)),
    }
    u = Unlocked(copy, RECOVERY, metas[n]['recovery'], readonly=True)
    plain = u.io
    assert LIB.nk_inspect(C.byref(plain)) == 0, '卸载后卷是干净的'
    v = LIB.nk_mount_io(C.byref(plain), None, 0)
    assert v
    for path, (size, digest_) in files.items():
        assert read_file(v, '/' + path, size) == digest_, (n, path)
    assert LIB.nk_umount(v) == 0
    u.close()
    expected[n] = [{'path': p, 'size': s, 'sha256': d} for p, (s, d) in files.items()]
passed('在加密卷上新建文件夹与中文名文件（9 MiB 与小文件）、改写 Windows 写的文件中段、追加、删除、改名；卸载后卷是干净的，换恢复密钥解锁读回全部一致；元数据与卷头密文不变')

assert all(digest(FIXTURES / f'{n}.img') == before[n] for n in names)
passed('四块原始加密镜像在全部测试前后逐字节不变')

(WRITTEN / 'expected.json').write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'fixtures': {n: metas[n]['method'] for n in names},
          'scope': 'Windows 11 专业版生成的 BitLocker 镜像副本（160 MB，完全加密）；引擎直接读写；不涉及 FSKit、写入日志或实盘；Windows 回读见 windows-verify'}
(ROOT / 'docs/testing/bitlocker-write-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
