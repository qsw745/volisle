#!/usr/bin/env python3
"""nk_format (patched mkntfs over host block callbacks) on disposable regular images only.
Never touches a device, a mounted filesystem, or a user-supplied path.
"""
import ctypes as C
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
LIB.nk_label.argtypes = [C.c_void_p, C.c_char_p, C.c_size_t]
LIB.nk_label.restype = C.c_int
TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
MIB = 1024 * 1024
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def image(folder, name, size=64 * MIB):
    path = folder / name
    with path.open('xb') as f:
        f.truncate(size)
    return path


def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()


def fmt(device, label='VOLISLE', sector=0):
    err = C.create_string_buffer(256)
    rc = LIB.nk_format(C.byref(device.io), label.encode() if label is not None else None, sector, err, 256)
    return rc, err.value.decode(errors='replace')


def serial(path):
    with path.open('rb') as f:
        f.seek(0x48)
        return f.read(8)


def label_of(device):
    v = device.mount()
    assert v, 'mount after format failed'
    buf = C.create_string_buffer(256)
    assert LIB.nk_label(v, buf, 256) == 0
    assert LIB.nk_umount(v) == 0
    return buf.value.decode()


def independent_check(path):
    # NTFS-3G's own tools, run on the image file: ntfsfix -n changes nothing.
    fix = subprocess.run([str(TOOLS / 'ntfsfix'), '-n', str(path)], capture_output=True, text=True, timeout=60)
    assert fix.returncode == 0, fix.stdout + fix.stderr
    info = subprocess.run([str(TOOLS / 'ntfsinfo'), '-m', str(path)], capture_output=True, text=True, timeout=60)
    assert info.returncode == 0, info.stdout + info.stderr
    return info.stdout


with tempfile.TemporaryDirectory(prefix='volisle-format-', dir=ROOT / '.workbench') as tmp:
    folder = Path(tmp)

    first = image(folder, 'first.img')
    device = ImageIO(first)
    rc, err = fmt(device, '测试盘 Volisle')
    assert rc == 0, err
    assert device.syncs > 0 and device.inspect() == 0
    assert label_of(device) == '测试盘 Volisle'
    info = independent_check(first)
    assert 'Volume Name: 测试盘 Volisle' in info or '测试盘 Volisle' in info, info
    passed('64 MiB 镜像格式化：刷盘、只读预检干净、中文卷名、NTFS-3G 独立工具检查通过')

    v = device.mount()
    payload = bytes(range(256)) * 4096
    assert LIB.nk_create(v, b'/', '新文件.bin'.encode()) == 0
    buf = C.create_string_buffer(payload)
    assert LIB.nk_write(v, '/新文件.bin'.encode(), 0, len(payload), buf) == len(payload)
    assert LIB.nk_sync(v) == 0 and LIB.nk_umount(v) == 0
    assert device.inspect() == 0
    v = device.mount()
    out = C.create_string_buffer(len(payload))
    assert LIB.nk_read(v, '/新文件.bin'.encode(), 0, len(payload), out) == len(payload) and out.raw == payload
    assert LIB.nk_umount(v) == 0
    independent_check(first)
    passed('格式化后可读写：写入 1 MiB、卸载后重挂逐字节一致，卷仍干净')

    before = serial(first)
    rc, err = fmt(device, 'AGAIN')
    assert rc == 0, err
    assert serial(first) != before and label_of(device) == 'AGAIN'
    v = device.mount()
    assert LIB.nk_read(v, '/新文件.bin'.encode(), 0, 16, C.create_string_buffer(16)) < 0
    assert LIB.nk_umount(v) == 0
    passed('同一进程再次格式化：卷序列号改变、旧文件不存在（mkntfs 全局状态已复位）')

    serials = set()
    for i in range(3):
        path = image(folder, f'serial{i}.img', 8 * MIB)
        d = ImageIO(path)
        assert fmt(d, f'S{i}')[0] == 0
        serials.add(serial(path))
        d.close()
    assert len(serials) == 3
    passed('同一秒内连续格式化 3 块镜像：卷序列号互不相同')
    device.close()

    large = image(folder, 'sector4k.img', 64 * MIB)
    d = ImageIO(large)
    rc, err = fmt(d, 'SECTOR4K', 4096)
    assert rc == 0, err
    with large.open('rb') as f:
        f.seek(0x0B)
        assert int.from_bytes(f.read(2), 'little') == 4096
    assert d.inspect() == 0 and label_of(d) == 'SECTOR4K'
    d.close()
    passed('4096 字节扇区格式化：引导扇区记录 4096，卷干净可挂载')

    path = image(folder, 'label.img', 16 * MIB)
    d = ImageIO(path)
    rc, err = fmt(d, 'L' * 33)
    assert rc == -1 and err == 'invalid volume name' and d.writes == 0
    assert fmt(d, '中' * 32)[0] == 0 and label_of(d) == '中' * 32
    d.close()
    passed('卷名上限 32 个字符（与 Windows 一致）：33 个直接拒绝且零写入，32 个中文字符正常')

    blank = image(folder, 'reject.img', 16 * MIB)
    blank_hash = digest(blank)
    ro = ImageIO(blank, readonly=True)
    assert fmt(ro)[0] == -1 and ro.writes == 0
    ro.close()
    for sector in (1000, 256, 8192):
        d = ImageIO(blank)
        assert fmt(d, 'X', sector)[0] == -1 and d.writes == 0
        d.close()
    tiny = image(folder, 'tiny.img', 512 * 1024)
    d = ImageIO(tiny)
    assert fmt(d)[0] == -1 and d.writes == 0
    d.close()
    assert digest(blank) == blank_hash
    passed('拒绝：只读描述符、非法扇区大小、小于 1 MiB 的设备，均零写入')

    broken = image(folder, 'broken.img', 16 * MIB)
    d = ImageIO(broken)
    d.fail_write_at = 5
    rc, err = fmt(d, 'BROKEN')
    assert rc == -1 and 'mkntfs failed' in err, err
    d.fail_write_at = None
    assert d.inspect() != 0
    d.close()
    d = ImageIO(broken)
    d.fail_sync = True
    rc, err = fmt(d, 'NOSYNC')
    assert rc == -1, err
    d.close()
    healthy = ImageIO(image(folder, 'after-failure.img', 16 * MIB))
    assert fmt(healthy, 'OK')[0] == 0 and healthy.inspect() == 0
    healthy.close()
    passed('写入失败与刷盘失败都返回失败、不崩溃，损坏结果不会通过预检；之后同进程可正常格式化')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '一次性普通镜像；不涉及设备、FSKit 或实盘'}
(ROOT / 'docs/testing/ntfs-format-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
