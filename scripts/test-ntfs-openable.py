#!/usr/bin/env python3
"""Whether the engine can open a volume at all (nk_openable), which the store
build asks before it claims a disk from the system. Disposable regular images
only; never touches a device. Build the test library first: scripts/build-ntfs-bridge.sh"""
import ctypes as C
import hashlib
import struct
import tempfile
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, IO, ImageIO, PREAD, PWRITE, SYNC

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
LIB.nk_openable.argtypes = [C.POINTER(IO), C.c_char_p, C.c_size_t]
LIB.nk_openable.restype = C.c_int
MIB = 1 << 20
count = 0


def passed(name):
    global count
    count += 1
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def formatted(path):
    with path.open('wb') as f:
        f.truncate(64 * MIB)
    device = ImageIO(path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(device.io), b'OPENABLE', 0, err, 256) == 0, err.value
    device.close()


def geometry(path):
    with path.open('rb') as f:
        boot = f.read(512)
    sector = struct.unpack_from('<H', boot, 11)[0]
    cluster = sector * boot[13]
    cpr = struct.unpack_from('b', boot, 64)[0]
    record = (1 << -cpr) if cpr < 0 else cpr * cluster
    return cluster, record, struct.unpack_from('<Q', boot, 48)[0], struct.unpack_from('<Q', boot, 56)[0]


def set_dirty(path, copies):
    """Set VOLUME_IS_DIRTY in $Volume (record 3) of the chosen copies: 'mft', 'mirror'."""
    cluster, record, mft, mirror = geometry(path)
    with path.open('r+b') as f:
        for lcn in [{'mft': mft, 'mirror': mirror}[c] for c in copies]:
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
                raise AssertionError('no $VOLUME_INFORMATION in record 3')


def openable(path, **faults):
    """(result, writes, image unchanged). The device is opened writable on
    purpose: the question must not write even when it could."""
    before = digest(path)
    device = ImageIO(path)
    for name, value in faults.items():
        setattr(device, name, value)
    label = C.create_string_buffer(b'untouched', 256)
    result = LIB.nk_openable(C.byref(device.io), label, 256)
    writes = device.writes
    device.close()
    # The label is what the system names the mount after; none unless the volume opens.
    assert label.value == (b'OPENABLE' if result else b''), label.value
    return result, writes, digest(path) == before


with tempfile.TemporaryDirectory(prefix='volisle-openable-', dir=ROOT / '.workbench') as tmp:
    image = Path(tmp) / 'volume.img'

    formatted(image)
    assert openable(image) == (1, 0, True)
    passed('干净的卷：能打开，零写入，镜像不变')

    set_dirty(image, ['mft', 'mirror'])
    assert openable(image) == (1, 0, True)
    passed('带“需要检查”标记的卷：仍能打开（只读或读写由激活决定）')

    # What a 2 TB test disk was left with on 2026-10-11: the flag write reached one copy only.
    formatted(image)
    set_dirty(image, ['mft'])
    assert openable(image) == (0, 0, True)
    passed('$Volume 记录与镜像不一致（只有 $MFT 一份带标记）：打不开，零写入')

    formatted(image)
    set_dirty(image, ['mirror'])
    assert openable(image) == (0, 0, True)
    passed('$Volume 记录与镜像不一致（只有镜像一份带标记）：打不开，零写入')

    formatted(image)
    assert openable(image, fail_read=True) == (0, 0, True)
    passed('设备读不出来：打不开')
    assert openable(image, fail_read_from=4) == (0, 0, True)
    passed('读到一半失败：打不开')

    with image.open('r+b') as f:
        f.write(b'\0' * 512)
    assert openable(image) == (0, 0, True)
    passed('引导扇区不是 NTFS：打不开')

    assert LIB.nk_openable(None, None, 0) == 0
    assert LIB.nk_openable(C.byref(IO(None, PREAD(), PWRITE(), 64 * MIB, 1, SYNC())), None, 0) == 0
    small = ImageIO(image, readonly=True)
    small.io.size = 256
    assert LIB.nk_openable(C.byref(small.io), None, 0) == 0
    small.close()
    passed('没有读取回调或容量不足一个扇区：打不开')

    formatted(image)
    device = ImageIO(image, readonly=True)
    assert LIB.nk_openable(C.byref(device.io), None, 0) == 1
    device.close()
    passed('不要卷标时也能问')

    # Why a volume would not open reaches the log only while a sink is installed,
    # and never a message built from a string (those can carry names from the disk).
    LOG = C.CFUNCTYPE(None, C.c_char_p)
    LIB.nk_log_capture.argtypes = [LOG]
    LIB.nk_log_capture.restype = None
    heard = []
    sink = LOG(lambda message: heard.append(message.decode()))
    set_dirty(image, ['mft'])
    LIB.nk_log_capture(sink)
    assert openable(image)[0] == 0
    assert any('$MFTMirr does not match $MFT (record 3)' in line for line in heard), heard
    passed('捕获期间：引擎说明了打不开的原因')
    heard.clear()
    formatted(image)
    LIB.nk_log_capture(sink)  # formatting installs the formatter's own log handler
    assert openable(image, fail_read_from=4)[0] == 0
    assert heard and not any('%' in line for line in heard), heard
    passed('捕获期间：读取失败也有说明')
    heard.clear()
    LIB.nk_log_capture(LOG())
    set_dirty(image, ['mirror'])
    assert openable(image)[0] == 0 and heard == []
    passed('停止捕获后：不再转发')

print(f'{count} 项通过；一次性普通镜像，未访问设备')
