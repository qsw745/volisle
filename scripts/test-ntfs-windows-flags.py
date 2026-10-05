#!/usr/bin/env python3
"""Volume flags Windows sets that NTFS-3G does not know (Windows 11 formats
volumes with 0x0080) must survive a write session, its release, recovery's
marker release and "Check on This Mac". Before the fix the session's marker was
written masked (0x0001), release no longer recognized it, and every such volume
stayed marked dirty. Uses a copy of .workbench/bitlocker-fixtures/win11-plain.img
(scripts/bitlocker-fixtures/fetch.sh); the original is only read."""
import ctypes as C
import hashlib
import json
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, IO

LIB.nk_volume_state.argtypes = [C.POINTER(IO), C.POINTER(C.c_uint16), C.POINTER(C.c_longlong), C.POINTER(C.c_longlong)]
LIB.nk_volume_state.restype = C.c_int
LIB.nk_abort_write_session.argtypes = [C.c_void_p]
LIB.nk_abort_write_session.restype = None
LIB.nk_release_owned_marker.argtypes = [C.POINTER(IO), C.c_uint16, C.c_char_p]
LIB.nk_release_owned_marker.restype = C.c_int
LIB.nk_clear_check_marker.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
LIB.nk_clear_check_marker.restype = C.c_int
FIXTURE = ROOT / '.workbench/bitlocker-fixtures/win11-plain.img'
import struct


def poke_flags(path, value):
    """Overwrite $Volume's flags word in place (record 3, $VOLUME_INFORMATION, in
    both $MFT and $MFTMirr), to recreate states older versions left. Refuses an
    offset under a fixup."""
    data = bytearray(path.read_bytes())
    bps = struct.unpack_from('<H', data, 11)[0]
    cluster = bps * data[13]
    raw = struct.unpack_from('<b', data, 0x40)[0]
    record_size = raw * cluster if raw > 0 else 1 << -raw
    for lcn_at in (0x30, 0x38):
        record = struct.unpack_from('<Q', data, lcn_at)[0] * cluster + 3 * record_size
        assert data[record:record + 4] == b'FILE'
        at = record + struct.unpack_from('<H', data, record + 0x14)[0]
        while struct.unpack_from('<I', data, at)[0] != 0x70:
            assert struct.unpack_from('<I', data, at)[0] != 0xffffffff
            at += struct.unpack_from('<I', data, at + 4)[0]
        offset = at + struct.unpack_from('<H', data, at + 0x14)[0] + 10
        assert (offset - record) % bps < bps - 2, 'flags under a fixup'
        struct.pack_into('<H', data, offset, value)
    path.write_bytes(bytes(data))
DIRTY, WINDOWS_BIT = 0x0001, 0x0080
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def flags(path):
    device = ImageIO(path, readonly=True)
    value, offset, length = C.c_uint16(), C.c_longlong(), C.c_longlong()
    assert LIB.nk_volume_state(C.byref(device.io), C.byref(value), C.byref(offset), C.byref(length)) == 0
    device.close()
    return value.value


original = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
initial = flags(FIXTURE)
assert initial & WINDOWS_BIT and not initial & DIRTY, hex(initial)

with tempfile.TemporaryDirectory(prefix='volisle-flags-', dir=ROOT / '.workbench') as tmp:
    image = Path(tmp) / 'win11.img'

    # 1. A normal session: the marker keeps Windows' bit, release restores the exact word.
    shutil.copyfile(FIXTURE, image)
    device = ImageIO(image)
    v = LIB.nk_mount_io(C.byref(device.io), None, 0)
    assert v
    assert flags(image) == initial | DIRTY
    assert LIB.nk_mkdir(v, b'/', '来自Mac'.encode()) == 0
    assert LIB.nk_umount(v) == 0
    device.close()
    assert flags(image) == initial and ImageIO(image, readonly=True).inspect() == 0
    passed(f'Windows 11 格式化的卷（标志 {initial:#06x}）：写入期间为 {initial | DIRTY:#06x}，卸载成功并恢复原值，卷是干净的')

    # 2. An interrupted session, then the journal's marker release (what recovery calls).
    shutil.copyfile(FIXTURE, image)
    boot = FIXTURE.read_bytes()[:512]
    device = ImageIO(image)
    v = LIB.nk_mount_io(C.byref(device.io), None, 0)
    LIB.nk_abort_write_session(v)
    assert LIB.nk_umount(v) != 0
    device.close()
    assert flags(image) == initial | DIRTY
    device = ImageIO(image)
    assert LIB.nk_release_owned_marker(C.byref(device.io), initial, boot) == 0
    device.close()
    assert flags(image) == initial
    passed('中断的会话留下的标记，恢复流程按原值释放后，标志与 Windows 写的完全一致')

    # 3. "Check on This Mac" clears only the dirty bit.
    shutil.copyfile(FIXTURE, image)
    device = ImageIO(image)
    v = LIB.nk_mount_io(C.byref(device.io), None, 0)
    LIB.nk_abort_write_session(v)
    LIB.nk_umount(v)
    items, err = C.c_longlong(), C.create_string_buffer(128)
    assert LIB.nk_clear_check_marker(C.byref(device.io), C.byref(items), err, 128) == 0, err.value
    device.close()
    assert flags(image) == initial
    passed('“在 Mac 上检查…”只清除需要检查这一位，Windows 的其他标志保留')

    # 4. A volume an older version left behind: its marker lost the unknown bits.
    shutil.copyfile(FIXTURE, image)
    poke_flags(image, (initial | DIRTY) & 0xc03f)
    assert flags(image) == DIRTY
    device = ImageIO(image)
    assert LIB.nk_release_owned_marker(C.byref(device.io), initial, boot) == 0
    device.close()
    assert flags(image) == initial and ImageIO(image, readonly=True).inspect() == 0
    passed('0.5.7 及更早版本留下的标记（未知位被抹掉）也能识别并释放，Windows 的 0x0080 写回')

    # 5. Anything else is still refused without a write.
    for other in (initial | DIRTY | 0x0020, 0x0021, DIRTY | 0x4000):
        shutil.copyfile(FIXTURE, image)
        poke_flags(image, other)
        before = image.read_bytes()
        device = ImageIO(image)
        assert LIB.nk_release_owned_marker(C.byref(device.io), initial, boot) != 0
        device.close()
        assert image.read_bytes() == before, hex(other)
    shutil.copyfile(FIXTURE, image)
    poke_flags(image, initial & 0xc03f | DIRTY)
    device = ImageIO(image)
    assert LIB.nk_release_owned_marker(C.byref(device.io), 0x0020, boot) != 0, '初始值没有未知位时不按旧标记处理'
    device.close()
    passed('其他标志组合一律拒绝释放，磁盘零写入')

assert hashlib.sha256(FIXTURE.read_bytes()).hexdigest() == original
report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks, 'initial_flags': f'{initial:#06x}',
          'scope': 'Windows 11 专业版格式化的 64 MB 普通 NTFS 镜像副本；引擎直接读写；不涉及 FSKit 或实盘'}
(ROOT / 'docs/testing/ntfs-windows-flags-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
