#!/usr/bin/env python3
"""Replaying the log of a disk Windows let go of without Safe Removal.

Fixture: .workbench/log-fixtures/unclean.img from scripts/log-fixtures/fetch-unclean-ntfs.sh
(Windows 11 was creating, renaming and deleting files when the power was cut).
Checks, on copies only:
  - examine is read-only and reports an unclean, readable log that replays in simulation;
  - recover leaves the volume clean, every record opens, and each baseline file
    Windows had flushed is either intact or one the burst deleted on purpose;
  - a disk also marked "needs check" is replayed, then checked and the mark
    cleared; if that check finds a problem it reports EIO (the helper restores);
  - an already clean disk is refused untouched.
With --windows-image it also writes recovered.vhd for the Windows chkdsk step."""
import ctypes as C
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

FIXTURES = ROOT / '.workbench/log-fixtures'
DIRTY = ROOT / '.workbench/check-fixtures/rich.img'
TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
CHECK_CLEAN, CHECK_DIRTY, CHECK_LOG_UNSAFE = 0, 1, 3
EALREADY, EBUSY, EIO = 37, 16, 5


class WindowsLog(C.Structure):
    _fields_ = [('dirty', C.c_int), ('maintenance_pending', C.c_int), ('hibernated', C.c_int),
                ('log_readable', C.c_int), ('log_clean', C.c_int), ('log_major', C.c_int), ('log_minor', C.c_int),
                ('replay_simulated', C.c_int), ('redo_actions', C.c_longlong), ('note', C.c_char * 256),
                ('discard_checked', C.c_int), ('discard_ok', C.c_int), ('checked_items', C.c_longlong),
                ('discard_reason', C.c_char * 192), ('held_bytes', C.c_longlong)]


ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_windows_log_examine.argtypes = [C.c_void_p, C.POINTER(WindowsLog), C.c_char_p, C.c_size_t]
ELIB.nk_windows_log_examine.restype = C.c_int
ELIB.nk_windows_log_recover.argtypes = [C.c_void_p, C.POINTER(WindowsLog), C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_windows_log_recover.restype = C.c_int


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def as_dict(state):
    return {name: (getattr(state, name).decode() if name in ('note', 'discard_reason') else getattr(state, name)) for name, _ in WindowsLog._fields_}


def examine(image):
    io = ImageIO(image, readonly=True)
    state, errbuf = WindowsLog(), C.create_string_buffer(256)
    rc = ELIB.nk_windows_log_examine(C.byref(io.io), C.byref(state), errbuf, len(errbuf))
    io.close()
    assert rc == 0, f'研判失败：{errbuf.value.decode()}'
    return state


def recover(image):
    io = ImageIO(image)
    state, items, errbuf = WindowsLog(), C.c_longlong(0), C.create_string_buffer(256)
    rc = ELIB.nk_windows_log_recover(C.byref(io.io), C.byref(state), C.byref(items), errbuf, len(errbuf))
    error = C.get_errno()
    inspected = io.inspect()
    io.close()
    return {'rc': rc, 'errno': error, 'reason': errbuf.value.decode(), 'items': items.value, 'inspect': inspected,
            'before': as_dict(state)}


def cat(image, path):
    out = subprocess.run([TOOLS / 'ntfscat', '-f', str(image), path], capture_output=True)
    return out.stdout if out.returncode == 0 else None


def check_baseline(image, manifest):
    intact, deleted, changed = 0, 0, []
    for line in manifest.read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        path, expected = line.split('\t')
        data = cat(image, '/' + path.replace('\\', '/'))
        if data is None:
            deleted += 1  # the burst deletes every fifth iteration's baseline file
        elif hashlib.sha256(data).hexdigest().upper() == expected.upper():
            intact += 1
        else:
            changed.append(path)
    return {'intact': intact, 'deleted': deleted, 'changed': changed}


def mark_dirty(image):
    """Sets VOLUME_IS_DIRTY in $Volume (record 3) of $MFT and $MFTMirr, as
    Windows does when it wants the disk checked."""
    with open(image, 'r+b') as f:
        boot = f.read(512)
        cluster = int.from_bytes(boot[11:13], 'little') * boot[13]
        size_byte = int.from_bytes(boot[64:65], 'little', signed=True)
        record = (2 ** -size_byte) if size_byte < 0 else size_byte * cluster
        for lcn in (int.from_bytes(boot[48:56], 'little'), int.from_bytes(boot[56:64], 'little')):
            pos = lcn * cluster + 3 * record
            f.seek(pos); rec = f.read(record)
            at = int.from_bytes(rec[20:22], 'little')
            while int.from_bytes(rec[at:at + 4], 'little') != 0x70:
                assert int.from_bytes(rec[at:at + 4], 'little') != 0xFFFFFFFF, '$Volume 没有卷信息'
                at += int.from_bytes(rec[at + 4:at + 8], 'little')
            flags = pos + at + int.from_bytes(rec[at + 20:at + 22], 'little') + 10
            f.seek(flags); value = int.from_bytes(f.read(2), 'little')
            f.seek(flags); f.write((value | 1).to_bytes(2, 'little'))


def mark_mft_cluster_free(image):
    """Clears the $Bitmap bit of the first cluster of $MFT, which is always in
    use: the allocation check must catch it and change nothing."""
    with open(image, 'r+b') as f:
        boot = f.read(512)
        sector = int.from_bytes(boot[11:13], 'little')
        cluster = sector * boot[13]
        mft_lcn = int.from_bytes(boot[48:56], 'little')
        size_byte = int.from_bytes(boot[64:65], 'little', signed=True)
        record = (2 ** -size_byte) if size_byte < 0 else size_byte * cluster
        f.seek(mft_lcn * cluster + 6 * record)  # record 6: $Bitmap
        rec = bytearray(f.read(record))
        usa, count = int.from_bytes(rec[4:6], 'little'), int.from_bytes(rec[6:8], 'little')
        for i in range(1, count):  # undo the update sequence fixups
            rec[i * 512 - 2:i * 512] = rec[usa + 2 * i:usa + 2 * i + 2]
        at = int.from_bytes(rec[20:22], 'little')
        while True:
            kind, length = int.from_bytes(rec[at:at + 4], 'little'), int.from_bytes(rec[at + 4:at + 8], 'little')
            assert kind != 0xFFFFFFFF, '$Bitmap 没有数据属性'
            if kind == 0x80 and rec[at + 8] == 1:
                break
            at += length
        pairs = at + int.from_bytes(rec[at + 32:at + 34], 'little')
        header = rec[pairs]
        nlen, olen = header & 0x0F, header >> 4
        first_lcn = int.from_bytes(rec[pairs + 1 + nlen:pairs + 1 + nlen + olen], 'little', signed=True)
        where = first_lcn * cluster + mft_lcn // 8
        f.seek(where); byte = f.read(1)[0]
        assert byte & (1 << (mft_lcn % 8)), '$MFT 的第一个簇应已标记为占用'
        f.seek(where); f.write(bytes([byte & ~(1 << (mft_lcn % 8))]))


def main():
    fixture = FIXTURES / 'unclean.img'
    if not fixture.is_file():
        sys.exit(f'缺少 {fixture}：先运行 scripts/log-fixtures/fetch-unclean-ntfs.sh')
    report = {'fixture_sha256': digest(fixture)}
    with tempfile.TemporaryDirectory(prefix='volisle-winlog-', dir=ROOT / '.workbench') as tmp:
        image = Path(tmp) / 'unclean.img'
        shutil.copyfile(fixture, image)
        io = ImageIO(image, readonly=True)
        assert io.inspect() == CHECK_LOG_UNSAFE, '测试盘应是“日志未清理”'
        io.close()
        before = digest(image)
        state = examine(image)
        report['examine'] = as_dict(state)
        assert digest(image) == before, '研判改动了磁盘'
        assert not state.dirty and not state.hibernated and not state.maintenance_pending
        assert state.log_readable and not state.log_clean and state.replay_simulated, report['examine']
        result = recover(image)
        report['recover'] = result
        assert result['rc'] == 0, result
        assert result['inspect'] == CHECK_CLEAN and result['items'] > 0, result
        report['baseline'] = check_baseline(image, FIXTURES / 'baseline.tsv')
        assert not report['baseline']['changed'], report['baseline']
        assert report['baseline']['intact'] > 0
        again = recover(image)
        report['again'] = {k: again[k] for k in ('rc', 'errno', 'reason')}
        assert again['rc'] == -1 and again['errno'] == EALREADY, again
        if '--windows-image' in sys.argv:
            vhd = FIXTURES / 'unclean.vhd'
            out = FIXTURES / 'recovered.vhd'
            shutil.copyfile(vhd, out)
            raw = open(vhd, 'rb').read(512)
            start = int.from_bytes(raw[446 + 8:446 + 12], 'little') * 512
            with open(out, 'r+b') as f:
                f.seek(start); f.write(image.read_bytes())
            report['windows_image'] = str(out)

        # Unplugged and also marked "needs check": the log is reported first,
        # replayed, then every record checked and the mark cleared.
        both = Path(tmp) / 'both.img'
        shutil.copyfile(fixture, both)
        mark_dirty(both)
        io = ImageIO(both, readonly=True)
        assert io.inspect() == CHECK_LOG_UNSAFE, '日志未完成应先于“需要检查”报告'
        io.close()
        state = examine(both)
        assert state.dirty and state.replay_simulated and not state.log_clean, as_dict(state)
        result = recover(both)
        report['dirty_recover'] = {k: result[k] for k in ('rc', 'errno', 'reason', 'items', 'inspect')}
        assert result['rc'] == 0 and result['inspect'] == CHECK_CLEAN and result['items'] > 0, result
        assert not examine(both).dirty
        assert not check_baseline(both, FIXTURES / 'baseline.tsv')['changed']
        # The same, with a cluster in use marked free: the check after the
        # replay fails and says so (EIO: the helper restores the disk).
        broken = Path(tmp) / 'both-broken.img'
        shutil.copyfile(fixture, broken)
        mark_dirty(broken)
        mark_mft_cluster_free(broken)
        result = recover(broken)
        report['dirty_recover_refused'] = {k: result[k] for k in ('rc', 'errno', 'reason')}
        assert result['rc'] == -1 and result['errno'] == EIO and 'clusters marked free' in result['reason'], result

        if DIRTY.is_file():
            marked = Path(tmp) / 'rich.img'
            shutil.copyfile(DIRTY, marked)
            untouched = digest(marked)
            refused = recover(marked)
            report['dirty_refused'] = {k: refused[k] for k in ('rc', 'errno', 'reason')}
            assert refused['rc'] == -1 and refused['errno'] in (EBUSY, EALREADY), refused
            assert digest(marked) == untouched, '带“需要检查”标记的盘被改动'
            # "Check on This Mac" with a cluster in use marked free: refused, untouched.
            broken = Path(tmp) / 'broken.img'
            shutil.copyfile(DIRTY, broken)
            mark_mft_cluster_free(broken)
            untouched = digest(broken)
            io = ImageIO(broken)
            items, errbuf = C.c_longlong(0), C.create_string_buffer(256)
            ELIB.nk_clear_check_marker.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
            rc = ELIB.nk_clear_check_marker(C.byref(io.io), C.byref(items), errbuf, len(errbuf))
            io.close()
            report['allocation_refused'] = {'rc': rc, 'reason': errbuf.value.decode()}
            assert rc == -1 and 'clusters marked free' in errbuf.value.decode(), report['allocation_refused']
            assert digest(broken) == untouched, '空间占用有误的盘被改动'
    print(json.dumps(report, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
