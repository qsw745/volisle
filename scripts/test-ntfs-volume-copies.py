#!/usr/bin/env python3
"""$Volume and its $MFTMirr copy differing only in the "needs check" mark
(nk_volume_copies_examine / nk_volume_copies_repair), as a USB drive unplugged
between the two writes of the mark leaves them. On disposable regular images
only. Never touches a device."""
import ctypes as C
import errno
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, IO
from ntfs_mirror_records import compare

TOOLS = ROOT / '.workbench/ntfs-3g-2026.9.28/ntfsprogs'
WINDOWS_IMAGE = ROOT / '.workbench/bitlocker-fixtures/win11-plain.img'


class Copies(C.Structure):
    _fields_ = [('differ', C.c_int), ('repairable', C.c_int), ('marked_copy', C.c_int),
                ('marked_newer', C.c_int), ('half_written', C.c_int), ('reason', C.c_char * 96)]


ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_volume_copies_examine.argtypes = [C.POINTER(IO), C.POINTER(Copies)]
ELIB.nk_volume_copies_examine.restype = C.c_int
ELIB.nk_volume_copies_repair.argtypes = [C.POINTER(IO), C.POINTER(Copies), C.c_char_p, C.c_size_t]
ELIB.nk_volume_copies_repair.restype = C.c_int
ELIB.nk_clear_check_marker.argtypes = [C.POINTER(IO), C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_clear_check_marker.restype = C.c_int
MARK_COPIES, UNKNOWN = 5, 4   # NK_CHECK_MARK_COPIES, NK_CHECK_UNKNOWN
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report(path):
    with path.open('rb') as f:
        return compare(lambda count, offset: os.pread(f.fileno(), count, offset))


def volume_record(path, copy):
    """(offset, raw bytes) of $Volume in '$MFT' ('mft') or in $MFTMirr ('mirror')."""
    entry = report(path)['records'][3]
    return entry[copy]['offset'], entry['raw'][copy]


def changed_span(before, after):
    """First and last byte offsets at which two equally long images differ."""
    assert len(before) == len(after) and before != after
    step = 1 << 20
    chunks = [i for i in range(0, len(before), step) if before[i:i + step] != after[i:i + step]]
    first = next(i for i in range(chunks[0], chunks[0] + step) if before[i] != after[i])
    last = next(i for i in range(min(chunks[-1] + step, len(before)) - 1, chunks[-1] - 1, -1) if before[i] != after[i])
    return first, last


def poke(path, offset, data):
    with path.open('r+b') as f:
        f.seek(offset); f.write(data)


def examine(path):
    io = ImageIO(path, readonly=True)
    try:
        out = Copies()
        rc = ELIB.nk_volume_copies_examine(C.byref(io.io), C.byref(out))
        return rc, C.get_errno(), out
    finally:
        io.close()


def repair(path, fail_write=False):
    io = ImageIO(path)
    io.fail_write = fail_write
    try:
        before, errbuf = Copies(), C.create_string_buffer(128)
        rc = ELIB.nk_volume_copies_repair(C.byref(io.io), C.byref(before), errbuf, len(errbuf))
        return rc, C.get_errno(), errbuf.value.decode(), before
    finally:
        io.close()


def check_on_this_mac(path):
    io = ImageIO(path)
    try:
        items, errbuf = C.c_longlong(0), C.create_string_buffer(256)
        rc = ELIB.nk_clear_check_marker(C.byref(io.io), C.byref(items), errbuf, len(errbuf))
        return rc, C.get_errno(), errbuf.value.decode(), items.value
    finally:
        io.close()


def inspect(path):
    io = ImageIO(path, readonly=True)
    try:
        return io.inspect()
    finally:
        io.close()


def session(path, name):
    """A write session left open: the mark is set in both copies."""
    io = ImageIO(path)
    volume = io.mount()
    assert volume and LIB.nk_create(volume, b'/', name) == 0
    return io, volume


def release_lost(path, copy):
    """The session ends cleanly, but the release never reached `copy`."""
    io, volume = session(path, b'during-session')
    assert LIB.nk_sync(volume) == 0
    offset, marked = volume_record(path, copy)
    assert LIB.nk_umount(volume) == 0
    io.close()
    poke(path, offset, marked)
    return marked


def main():
    with tempfile.TemporaryDirectory(prefix='volisle-volume-copies-', dir=ROOT / '.workbench') as tmp:
        tmp = Path(tmp)
        base = tmp / 'base.img'
        with base.open('xb') as f:
            f.truncate(64 * 1024 * 1024)
        subprocess.run([TOOLS / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
        io, volume = session(base, b'existing')
        assert LIB.nk_umount(volume) == 0
        io.close()

        def fresh(name):
            image = tmp / f'{name}.img'
            shutil.copyfile(base, image)
            return image

        # Nothing differs: nothing to do, nothing written.
        image = fresh('agree')
        rc, _, out = examine(image)
        assert rc == 0 and not out.differ and not out.repairable, (rc, out.differ)
        before = digest(image)
        rc, code, why, _ = repair(image)
        assert rc == -1 and code == errno.EALREADY and digest(image) == before, (rc, code, why)
        passed('两份一致：研判为无事可做，修复不写盘')

        # The real case (2026-10-11): the release reached $MFT, not $MFTMirr; and the reverse.
        for copy, marked_copy in [('mirror', 1), ('mft', 0)]:
            image = fresh(f'release-lost-{copy}')
            marked = release_lost(image, copy)
            assert inspect(image) == MARK_COPIES, '预检应当认出这种状态'
            before, damaged = digest(image), image.read_bytes()
            rc, _, out = examine(image)
            assert rc == 0 and out.differ and out.repairable and out.marked_copy == marked_copy and not out.marked_newer, \
                (rc, out.differ, out.repairable, out.marked_copy, out.marked_newer, out.reason)
            assert digest(image) == before, '研判写了盘'
            rc, code, why, _ = repair(image)
            assert rc == 0, (code, why)
            after = report(image)
            assert all(r['same'] for r in after['records']), '修复后两份仍不一致'
            assert after['records'][3]['raw']['mft'] == marked and after['records'][3]['raw']['mirror'] == marked
            # Exactly one record changed on the whole image: the other copy's.
            offset, _ = volume_record(image, 'mft' if copy == 'mirror' else 'mirror')
            first, last = changed_span(damaged, image.read_bytes())
            assert offset <= first and last < offset + len(marked), (offset, first, last)
            assert inspect(image) == 1, '修复后应当是“需要检查”'
            rc, code, why, items = check_on_this_mac(image)
            assert rc == 0 and items >= 2 and inspect(image) == 0, (rc, code, why, items)
            listing = subprocess.run([TOOLS / 'ntfsls', '-f', image], capture_output=True, check=True).stdout.decode().split()
            assert {'existing', 'during-session'} <= set(listing), listing
            passed(f'释放标记只写到一处（{copy} 那份没写上）：带标记的那份写回，卷一致地需要检查，全盘检查后可读写')

        # The mark was being set: the marked copy is the newer one.
        image = fresh('mark-lost')
        offset, unmarked = volume_record(image, 'mirror')
        io, volume = session(image, b'interrupted')
        assert LIB.nk_sync(volume) == 0
        io.close()   # no clean end: both copies stay marked
        poke(image, offset, unmarked)
        rc, _, out = examine(image)
        assert rc == 0 and out.repairable and out.marked_copy == 0 and out.marked_newer, (out.marked_copy, out.marked_newer, out.reason)
        rc, code, why, _ = repair(image)
        assert rc == 0 and all(r['same'] for r in report(image)['records']) and inspect(image) == 1, (code, why)
        passed('设置标记只写到一处：同样以带标记的那份为准')

        # NTFS-3G compares what a record uses, not the unused rest of it: copies
        # that differ only there are the same, the volume opens, and nothing
        # here stands in the check's way.
        image = fresh('unused-tail')
        io, volume = session(image, b'still-open')
        assert LIB.nk_sync(volume) == 0
        io.close()   # both copies marked, same content
        entry = report(image)['records'][3]
        assert entry['mirror']['bytesInUse'] < 600
        poke(image, entry['mirror']['offset'] + 600, b'\x5a')
        assert inspect(image) == 1, 'NTFS-3G 应当照常打开这卷'
        before = digest(image)
        rc, _, out = examine(image)
        assert rc == 0 and not out.differ and not out.repairable, (out.differ, out.reason)
        rc, code, why, _ = repair(image)
        assert rc == -1 and code == errno.EALREADY and digest(image) == before, (rc, code, why)
        rc, code, why, items = check_on_this_mac(image)
        assert rc == 0 and inspect(image) == 0, (rc, code, why)
        passed('两份只在记录未使用的部分不同：与 NTFS-3G 一样视为一致，不拦“在 Mac 上检查”')

        # Both marked, differing only in the sequence number: NTFS-3G refuses
        # that too (the number is part of what it compares), and it is not an
        # unfinished marker write. Left alone.
        image = fresh('numbers-only')
        io, volume = session(image, b'still-open')
        assert LIB.nk_sync(volume) == 0
        io.close()
        entry = report(image)['records'][3]
        raw = bytearray(entry['raw']['mirror'])
        number = (entry['mirror']['updateSequence'] + 7).to_bytes(2, 'little')
        raw[48:50] = number; raw[510:512] = number; raw[1022:1024] = number
        poke(image, entry['mirror']['offset'], bytes(raw))
        before = digest(image)
        rc, _, out = examine(image)
        assert inspect(image) == UNKNOWN and rc == 0 and out.differ and not out.repairable, (out.differ, out.reason)
        rc, code, why, _ = repair(image)
        assert rc == -1 and code == errno.ENOTSUP and digest(image) == before, (rc, code, why)
        passed('不处理：两份都带标记、只差更新序号（NTFS-3G 同样拒绝）')

        # Anything beyond that one difference is not ours to settle: nothing written.
        def refused(name, damage, reason):
            image = fresh(name)
            release_lost(image, 'mirror')
            damage(image)
            before = digest(image)
            rc, _, out = examine(image)
            assert rc == 0 and out.differ and not out.repairable and out.reason.decode() == reason, (name, out.reason)
            assert inspect(image) == UNKNOWN, name
            rc, code, why, _ = repair(image)
            assert rc == -1 and code == errno.ENOTSUP and why == reason and digest(image) == before, (name, rc, code, why)
            passed(f'不处理：{reason}')

        def more_in_record(image):
            offset, raw = volume_record(image, 'mirror')
            poke(image, offset + 0x60, bytes([raw[0x60] ^ 0xff]))
        refused('more-in-record', more_in_record, 'the record differs in more')

        def other_record(image):
            entry = report(image)['records'][0]
            poke(image, entry['mirror']['offset'] + 0x60, bytes([entry['raw']['mirror'][0x60] ^ 0xff]))
        refused('other-record', other_record, 'another record differs')

        def torn(image):
            offset, raw = volume_record(image, 'mirror')
            poke(image, offset + 510, bytes([raw[510] ^ 0xff]))
        refused('torn', torn, 'a record is incomplete')

        def other_flags(image):
            entry = report(image)['records'][3]
            at = entry['mirror']['offset'] + entry['mirror']['flagsOffset']
            poke(image, at, bytes([entry['raw']['mirror'][entry['mirror']['flagsOffset']] | 0x80]))
        refused('other-flags', other_flags, 'other flags differ')

        # The repair's own write cut off between two sectors: the other copy is
        # part marked, part not, and no longer a complete record. Repairing again
        # finishes it, whichever sector had landed.
        for landed in (0, 1):
            image = fresh(f'half-written-{landed}')
            marked = release_lost(image, 'mirror')
            offset, _ = volume_record(image, 'mft')
            poke(image, offset + landed * 512, marked[landed * 512:(landed + 1) * 512])
            rc, _, out = examine(image)
            assert rc == 0 and out.repairable and out.half_written and out.marked_copy == 1, (out.half_written, out.reason)
            assert inspect(image) == MARK_COPIES
            rc, code, why, _ = repair(image)
            after = report(image)
            assert rc == 0 and all(r['same'] for r in after['records']) and after['records'][3]['raw']['mft'] == marked, (code, why)
            assert inspect(image) == 1
        passed('写回本身被打断（只写上一个扇区）：再做一次即可写齐')

        # A whole session lies between the two copies: not one unfinished write.
        image = fresh('sessions-apart')
        io, volume = session(image, b'first')
        assert LIB.nk_sync(volume) == 0
        offset, marked = volume_record(image, 'mirror')
        assert LIB.nk_umount(volume) == 0
        io.close()
        io, volume = session(image, b'second')
        assert LIB.nk_umount(volume) == 0
        io.close()
        poke(image, offset, marked)
        before = digest(image)
        rc, _, out = examine(image)
        assert rc == 0 and out.differ and not out.repairable and out.reason == b'more than one write apart', out.reason
        rc, code, why, _ = repair(image)
        assert rc == -1 and code == errno.ENOTSUP and digest(image) == before, (rc, code, why)
        passed('不处理：两份之间隔了不止一次写入')

        # The write fails: reported, never called done.
        image = fresh('write-fails')
        release_lost(image, 'mirror')
        before = digest(image)
        rc, code, why, _ = repair(image, fail_write=True)
        assert rc == -1 and code == errno.EIO and why == 'write failed' and digest(image) == before, (rc, code, why)
        passed('写入失败：报告失败，镜像未变')

        # The same unplug lost more than the mark: the copies are settled, the
        # volume stays "needs check", and the full check refuses to clear it.
        image = fresh('more-lost')
        listed = subprocess.run([TOOLS / 'ntfsinfo', '-f', '-F', '/existing', image], capture_output=True, check=True).stdout.decode()
        number = int(next(line for line in listed.splitlines() if line.startswith('Dumping Inode')).split()[2])
        release_lost(image, 'mirror')
        geometry = report(image)['geometry']
        poke(image, geometry['mft'] + number * geometry['record'], bytes(geometry['record']))
        rc, code, why, _ = repair(image)
        assert rc == 0, (code, why)
        rc, code, why, _ = check_on_this_mac(image)
        assert rc == -1 and code == errno.EIO and why.startswith('inconsistent record'), (rc, code, why)
        assert inspect(image) == 1 and all(r['same'] for r in report(image)['records'])
        passed('同一次拔线还丢了别的：两份写齐后仍是“需要检查”，全盘检查拒绝清除标记')

        # Large clusters: NTFS-3G compares a cluster's worth of records (up to
        # sixteen), so a difference past the fourth is seen here as well.
        large = tmp / 'large-clusters.img'
        with large.open('xb') as f:
            f.truncate(256 * 1024 * 1024)
        subprocess.run([TOOLS / 'mkntfs', '-F', '-Q', '-c', '65536', large], check=True, capture_output=True)
        release_lost(large, 'mirror')
        rc, _, out = examine(large)
        assert rc == 0 and out.repairable and inspect(large) == MARK_COPIES, out.reason
        geometry = report(large)['geometry']
        with large.open('rb') as f:
            f.seek(geometry['mirror'] + 9 * geometry['record'] + 0x60)
            byte = f.read(1)
        poke(large, geometry['mirror'] + 9 * geometry['record'] + 0x60, bytes([byte[0] ^ 0xff]))
        before = digest(large)
        rc, _, out = examine(large)
        assert rc == 0 and out.differ and not out.repairable and out.reason == b'another record differs', out.reason
        rc, code, why, _ = repair(large)
        assert rc == -1 and code == errno.ENOTSUP and digest(large) == before and inspect(large) == UNKNOWN, (rc, code, why)
        passed('大簇卷：第四条之后的记录不一致也不处理')

        # Not an NTFS volume.
        image = tmp / 'blank.img'
        with image.open('xb') as f:
            f.truncate(8 * 1024 * 1024)
        rc, code, _ = examine(image)
        assert rc == -1 and code == errno.EINVAL, (rc, code)
        passed('不是 NTFS 卷：研判报告无法读取')

        # A volume Windows 11 formatted reads as agreeing (when the fixture is there).
        if WINDOWS_IMAGE.is_file():
            rc, _, out = examine(WINDOWS_IMAGE)
            assert rc == 0 and not out.differ, (rc, out.differ, out.reason)
            passed('Windows 11 格式化的卷：研判为一致')

    result = {'executed_at': datetime.now(timezone.utc).isoformat(timespec='seconds'), 'engine': 'NTFS-3G 2026.9.28',
              'scope': '离线可丢弃镜像；不是实盘验证', 'checks': checks}
    output = ROOT / 'docs/testing/ntfs-volume-copies-result.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f'通过：{len(checks)} 项；{output.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
