#!/usr/bin/env python3
"""A folder entry naming a record that was freed or reused since ("stale"),
the inconsistency behind the user report of 2026-10-10 ("inconsistent record
N: listed as a folder, record is a file"). Disposable regular images only;
never a device.

1. "Check on This Mac" refuses every stale entry, also one reached after the
   record's own entry, and names the folder and both sequence numbers
   (numbers only, in the fixed wording CheckMarkerRefusal accepts).
2. Repair on the Mac (nk_stale_entries_repair) removes only those index
   entries: the record they name, file contents and every other entry stay.
3. Everything else is refused with nothing written.
4. Interrupted at every write (an error, or the process gone), the disk is
   put back exactly from the before-images saved ahead of each write, and
   every state left behind is marked "needs check" (or unreadable) with the
   Windows log untouched: what the helper requires before replaying a leftover
   undo record.

  python3 test-ntfs-stale-entry.py [--keep-images DIR]
--keep-images keeps the image as damaged and as repaired (stale-before.img,
stale-after.img) for Windows chkdsk to review in a virtual machine."""
import ctypes as C
import errno
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, PREAD, PWRITE, SYNC, IO
import ntfs_stale_entry_fixture as fixture

TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
KEEP = Path(sys.argv[sys.argv.index('--keep-images') + 1]) if '--keep-images' in sys.argv else None
NK_STALE_MAX = 8
CHECK_CLEAN, CHECK_DIRTY, CHECK_UNKNOWN = 0, 1, 4


class StaleEntry(C.Structure):
    _fields_ = [('folder', C.c_uint64), ('reference', C.c_uint64), ('record_in_use', C.c_int), ('record_seq', C.c_int)]


class StaleEntries(C.Structure):
    _fields_ = [('dirty', C.c_int), ('count', C.c_int), ('repairable', C.c_int), ('checked_items', C.c_longlong),
                ('entry', StaleEntry * NK_STALE_MAX), ('reason', C.c_char * 192)]


ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_clear_check_marker.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_clear_check_marker.restype = C.c_int
ELIB.nk_stale_entries_examine.argtypes = [C.c_void_p, C.POINTER(StaleEntries), C.c_char_p, C.c_size_t]
ELIB.nk_stale_entries_examine.restype = C.c_int
ELIB.nk_stale_entries_repair.argtypes = [C.c_void_p, C.POINTER(StaleEntries), C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_stale_entries_repair.restype = C.c_int
ELIB.nk_volume_state.argtypes = [C.c_void_p, C.POINTER(C.c_uint16), C.POINTER(C.c_longlong), C.POINTER(C.c_longlong)]
ELIB.nk_volume_state.restype = C.c_int
# The same pattern HelperFormat.swift's CheckMarkerRefusal accepts.
REFUSAL = re.compile(r'(inconsistent record [0-9]+: [a-z ,]+(; folder [0-9]+, entry seq [0-9]+(, record seq [0-9]+)?)?'
                     r'|read failed at record [0-9]+)')
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UndoImageIO:
    """An image as the helper's RawPartitionIO sees a partition: before every
    write, what it overwrites is appended to an undo file and flushed. Can
    fail the n-th write, or end the process right after it."""

    def __init__(self, path, undo_path, fail_write_at=None, exit_after_write_at=None):
        self.fd = os.open(path, os.O_RDWR)
        self.undo = open(undo_path, 'ab')
        self.writes = 0

        @PREAD
        def read(_, buf, count, offset):
            try:
                data = os.pread(self.fd, count, offset)
                C.memmove(buf, data, len(data))
                return len(data)
            except OSError:
                return -1

        @PWRITE
        def write(_, buf, count, offset):
            self.writes += 1
            if self.writes == fail_write_at:
                return -1
            old = os.pread(self.fd, count, offset)
            self.undo.write(struct.pack('<QI', offset, len(old)) + old)
            self.undo.flush()
            os.fsync(self.undo.fileno())
            written = os.pwrite(self.fd, C.string_at(buf, count), offset)
            if self.writes == exit_after_write_at:
                os.fsync(self.fd)
                os._exit(86)  # forked child only: the helper is gone mid-repair
            return written

        @SYNC
        def sync(_):
            try:
                os.fsync(self.fd)
                return 0
            except OSError:
                return -1
        self.callbacks = (read, write, sync)
        self.io = IO(None, read, write, os.fstat(self.fd).st_size, 0, sync)

    def close(self):
        os.close(self.fd)
        self.undo.close()


def restore(path, undo_path):
    """Newest first; a record cut short was never followed by its write."""
    data, entries, at = Path(undo_path).read_bytes(), [], 0
    while at + 12 <= len(data):
        offset, length = struct.unpack_from('<QI', data, at)
        if at + 12 + length > len(data):
            break
        entries.append((offset, data[at + 12:at + 12 + length]))
        at += 12 + length
    with path.open('r+b') as f:
        for offset, old in reversed(entries):
            f.seek(offset)
            f.write(old)
    return len(entries)


def examine(path):
    device = ImageIO(path, readonly=True)
    out, err = StaleEntries(), C.create_string_buffer(256)
    C.set_errno(0)
    rc = ELIB.nk_stale_entries_examine(C.byref(device.io), C.byref(out), err, 256)
    error = C.get_errno() if rc else 0
    device.close()
    return rc, error, out, err.value.decode()


def repair(path, undo_path=None, **faults):
    device = UndoImageIO(path, undo_path or os.devnull, **faults) if (undo_path or faults) else ImageIO(path)
    out, items, err = StaleEntries(), C.c_longlong(0), C.create_string_buffer(256)
    C.set_errno(0)
    rc = ELIB.nk_stale_entries_repair(C.byref(device.io), C.byref(out), C.byref(items), err, 256)
    error = C.get_errno() if rc else 0
    writes = device.writes
    device.close()
    return {'rc': rc, 'errno': error, 'reason': err.value.decode(), 'items': items.value, 'writes': writes, 'before': out}


def check(path, size=256):
    device = ImageIO(path)
    items, err = C.c_longlong(-1), C.create_string_buffer(size)
    C.set_errno(0)
    rc = ELIB.nk_clear_check_marker(C.byref(device.io), C.byref(items), err, size)
    error = C.get_errno() if rc else 0
    writes = device.writes
    device.close()
    return rc, error, err.value.decode(), writes


def inspect(path):
    device = ImageIO(path, readonly=True)
    status = device.inspect()
    device.close()
    return status


def log_location(path):
    device = ImageIO(path, readonly=True)
    flags, offset, length = C.c_uint16(), C.c_longlong(), C.c_longlong()
    assert ELIB.nk_volume_state(C.byref(device.io), C.byref(flags), C.byref(offset), C.byref(length)) == 0
    device.close()
    return offset.value, length.value


def log_head(path, where=None):
    """The first bytes of $LogFile: Windows rewrites them whenever it mounts the
    disk, and nothing here writes them. Read where they were before (`where`),
    as the helper does: a disk left half-written may not mount."""
    offset, length = where or log_location(path)
    return fixture.read_at(path, offset, length)


def names(path, folder_path):
    device = ImageIO(path, readonly=True)
    v = device.mount()
    assert v
    found = fixture.listing(v, folder_path)
    assert LIB.nk_umount(v) == 0
    device.close()
    return found


def read_file(path, file_path, size):
    device = ImageIO(path, readonly=True)
    v = device.mount()
    out = C.create_string_buffer(size)
    assert LIB.nk_read(v, file_path.encode(), 0, size, out) == size
    assert LIB.nk_umount(v) == 0
    device.close()
    return out.raw


def refused_check(path, size=256):
    before = digest(path)
    rc, error, reason, writes = check(path, size)
    assert (rc, error) == (-1, errno.EIO), (rc, error, reason)
    assert writes == 0 and inspect(path) == CHECK_DIRTY and digest(path) == before, '检查未通过时必须零写入'
    assert REFUSAL.fullmatch(reason) and len(reason) <= 160, reason
    return reason


def stale_detail(made, kind='stale entry, record reused'):
    return (f"inconsistent record {made['record']}: {kind}; folder {made['folder']}, "
            f"entry seq {made['entry_seq']}, record seq {made['record_seq']}")


def build(folder, name, dirty=True, **options):
    path = folder / name
    made = fixture.stale_folder_entry(path, **options)
    if dirty:
        fixture.mark_dirty(path)
    return path, made


def repaired_as_expected(path, made):
    """Only the stale entry gone: /b keeps its other names, the reused record and
    its file are byte for byte what they were, and the disk checks clean."""
    assert set(names(path, '/b')) == set(made['keep']), names(path, '/b')
    if made['new_ref'] is not None:
        assert names(path, '/' + made['new_in'])['new.bin'][0] == made['new_ref']
        assert read_file(path, f"/{made['new_in']}/new.bin", len(made['payload'])) == made['payload']
    assert inspect(path) == CHECK_CLEAN
    fixture.mark_dirty(path)
    rc, error, reason, _ = check(path)
    assert rc == 0, ('修复后的盘应当通过检查', reason)
    fix = subprocess.run([str(TOOLS / 'ntfsfix'), '-n', str(path)], capture_output=True, text=True, timeout=60)
    assert fix.returncode == 0, fix.stdout + fix.stderr


def refused_repair(path, reason_part, error=errno.ENOTSUP):
    before = digest(path)
    rc, examined_error, out, _ = examine(path)
    assert rc == 0 and not out.repairable, (rc, examined_error, out.reason)
    assert reason_part in out.reason.decode(), out.reason
    result = repair(path)
    assert (result['rc'], result['errno']) == (-1, error), result
    assert reason_part in result['reason'] and result['writes'] == 0, result
    assert digest(path) == before, '拒绝修复时必须零写入'
    return result['reason']


with tempfile.TemporaryDirectory(prefix='volisle-stale-', dir=ROOT / '.workbench') as tmp:
    folder = Path(tmp)

    # --- 1. The check -------------------------------------------------------
    path, made = build(folder, 'stale.img')
    assert made['entry_seq'] != made['record_seq']
    assert refused_check(path) == stale_detail(made)
    passed('文件夹删除后记录被文件重用、上级索引保留旧条目：检查判为失效条目，带所在文件夹记录号与两个不同的序列号，零写入')

    path, made = build(folder, 'stale-after.img', new_in='c')
    assert refused_check(path) == stale_detail(made)
    passed('先经新文件自己的条目到达被重用的记录、后遇到失效条目：以前会被跳过，现在同样判为失效条目，零写入')

    path, made = build(folder, 'stale-free.img', reuse=False)
    assert refused_check(path) == stale_detail(made, 'stale entry, record free')
    passed('记录已空闲、未被重用的失效条目：检查判为失效条目（记录空闲），零写入')

    path = folder / 'flag.img'
    flag = fixture.folder_flag_on_file(path)
    fixture.mark_dirty(path)
    expected = (f"inconsistent record {flag['record']}: listed as a folder, record is a file; "
                f"folder {flag['folder']}, entry seq {flag['entry_seq']}, record seq {flag['entry_seq']}")
    assert refused_check(path) == expected
    passed('序列号相同、只是索引项标成文件夹：两个序列号相同，仍报类型不符（这种不在 Mac 上修），零写入')

    path, made = build(folder, 'short.img')
    assert refused_check(path, size=80) == f"inconsistent record {made['record']}: stale entry, record reused"
    passed('调用方缓冲区放不下附加信息时只回固定格式，不截断成半句')

    # --- 2. Repair ----------------------------------------------------------
    path, made = build(folder, 'repair.img')
    if KEEP:
        KEEP.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, KEEP / 'stale-before.img')
    record_before = fixture.read_record(path, made['record'])
    head = log_head(path)
    before = digest(path)
    rc, error, out, _ = examine(path)
    assert rc == 0 and out.count == 1 and out.repairable and out.dirty, (rc, error, out.reason)
    entry = out.entry[0]
    assert (entry.folder, entry.reference, entry.record_in_use, entry.record_seq) == \
        (made['folder'], made['old_ref'], 1, made['record_seq'])
    assert digest(path) == before, '研判不得写盘'
    result = repair(path)
    assert result['rc'] == 0 and result['items'] > 0, result
    assert fixture.read_record(path, made['record']) == record_before, '被指向的记录不得改动'
    assert log_head(path) == head, 'Windows 日志不得改动'
    if KEEP:
        shutil.copyfile(path, KEEP / 'stale-after.img')
    repaired_as_expected(path, made)
    passed('修复：只删除失效条目；被重用的记录逐字节不变，新文件内容不变，/b 其余条目都在，'
           'Windows 日志不动，之后检查通过、NTFS-3G ntfsfix 独立检查通过')

    path, made = build(folder, 'repair-free.img', reuse=False)
    result = repair(path)
    assert result['rc'] == 0, result
    repaired_as_expected(path, made)
    passed('修复记录已空闲的失效条目，结果同上')

    path, made = build(folder, 'repair-after.img', new_in='c')
    result = repair(path)
    assert result['rc'] == 0, result
    repaired_as_expected(path, made)
    passed('修复“先经合法条目到达”的失效条目，结果同上')

    path, made = build(folder, 'repair-block.img', crowd=60)
    rc, _, out, _ = examine(path)
    assert rc == 0 and out.repairable, out.reason
    result = repair(path)
    assert result['rc'] == 0, result
    repaired_as_expected(path, made)
    passed('失效条目在文件夹的索引块里（60 多个条目的文件夹）：删除后其余条目都能按索引找到，检查通过')

    path, made = build(folder, 'repair-clean.img', dirty=False)
    assert inspect(path) == CHECK_CLEAN
    result = repair(path)
    assert result['rc'] == 0, result
    repaired_as_expected(path, made)
    passed('没有“需要检查”标记的盘：先标记、修复、检查通过后才清除，结果干净')

    # --- 3. Refusals ----------------------------------------------------------
    path = folder / 'flag-repair.img'
    fixture.folder_flag_on_file(path)
    fixture.mark_dirty(path)
    before = digest(path)
    rc, _, out, _ = examine(path)
    assert rc == 0 and out.count == 0 and not out.repairable and 'listed as a folder' in out.reason.decode(), out.reason
    result = repair(path)
    assert (result['rc'], result['errno'], result['writes']) == (-1, errno.ENOTSUP, 0), result
    assert digest(path) == before
    passed('序列号相同的类型不符：不修，零写入（交给 Windows chkdsk）')

    path, made = build(folder, 'unreachable.img', new_in='b')
    refused_repair(path, 'stale entry, record unreachable')
    passed('重用该记录的新文件只能经失效条目到达（它自己的条目也丢了）：拒绝修复，零写入，免得它变成看不见的孤儿')

    path, made = build(folder, 'orphan.img', child=True)
    refused_repair(path, 'stale folder still holds items')
    passed('仍有在用记录把已删的旧文件夹当作上级：拒绝修复，零写入')

    path = folder / 'clean.img'
    fixture.format_image(path).close()
    fixture.mark_dirty(path)
    before = digest(path)
    rc, _, out, _ = examine(path)
    assert rc == 0 and out.count == 0 and not out.repairable and not out.reason.decode(), out.reason
    result = repair(path)
    assert (result['rc'], result['errno'], result['writes']) == (-1, errno.EALREADY, 0), result
    assert digest(path) == before
    passed('没有失效条目的盘：不修，零写入')

    for name, extra, error, why in [('hibernated.img', 'hiber', errno.EBUSY, 'hibernated'),
                                    ('maintenance.img', 0x4000, errno.EBUSY, 'Windows maintenance pending')]:
        path, made = build(folder, name, dirty=False)  # a marked disk does not mount to add a file
        if extra == 'hiber':
            device = ImageIO(path)
            v = device.mount()
            assert v and LIB.nk_create(v, b'/', b'hiberfil.sys') == 0
            fixture.write_file(v, b'/hiberfil.sys', b'hibr' + bytes(4092))
            assert LIB.nk_umount(v) == 0
            device.close()
            fixture.mark_dirty(path)
        else:
            fixture.mark_dirty(path)
            _, cluster, record, mft_lcn, mirror_lcn = fixture.geometry(path)
            for lcn in (mft_lcn, mirror_lcn):  # VOLUME_CHKDSK_UNDERWAY next to the dirty flag
                raw = bytearray(fixture.read_at(path, lcn * cluster + 3 * record, record))
                a = struct.unpack_from('<H', raw, 20)[0]
                while struct.unpack_from('<I', raw, a)[0] != 0x70:
                    a += struct.unpack_from('<I', raw, a + 4)[0]
                at = a + struct.unpack_from('<H', raw, a + 20)[0] + 10
                struct.pack_into('<H', raw, at, struct.unpack_from('<H', raw, at)[0] | extra)
                fixture.write_at(path, lcn * cluster + 3 * record, bytes(raw))
        before = digest(path)
        result = repair(path)
        assert (result['rc'], result['errno'], result['reason'], result['writes']) == (-1, error, why, 0), result
        assert digest(path) == before
    passed('Windows 休眠、Windows 维护未完成的盘：拒绝修复，零写入')

    # --- 4. Interrupted at every write ----------------------------------------
    for dirty, crowd in ((True, 0), (False, 0), (True, 60)):
        pristine, made = build(folder, f'pristine-{int(dirty)}-{crowd}.img', dirty=dirty, crowd=crowd)
        where = log_location(pristine)
        head = log_head(pristine, where)
        probe = folder / 'probe.img'
        shutil.copyfile(pristine, probe)
        result = repair(probe, folder / 'probe.undo')
        total = result['writes']
        assert result['rc'] == 0 and total > 0, result
        work, undo = folder / 'work.img', folder / 'work.undo'
        for point in range(1, total + 1):
            # The write fails: the bridge stops with EIO and the host puts everything back.
            shutil.copyfile(pristine, work)
            undo.unlink(missing_ok=True)
            result = repair(work, undo, fail_write_at=point)
            assert (result['rc'], result['errno']) == (-1, errno.EIO), (point, result)
            restore(work, undo)
            assert digest(work) == digest(pristine), ('写入出错后未能原样还原', point)
            # The helper is gone right after this write (killed, power cut, unplugged).
            shutil.copyfile(pristine, work)
            undo.unlink(missing_ok=True)
            child = os.fork()
            if child == 0:
                repair(work, undo, exit_after_write_at=point)
                os._exit(0)
            _, status = os.waitpid(child, 0)
            assert os.WEXITSTATUS(status) == 86, (point, status)
            assert log_head(work, where) == head, ('修复写到了 Windows 日志', point)
            state = inspect(work)
            if state in (CHECK_DIRTY, CHECK_UNKNOWN):
                # Still marked "needs check" (or unreadable): nothing mounts it for
                # writing, and the leftover undo record puts it back exactly.
                restore(work, undo)
                assert digest(work) == digest(pristine), ('中断后未能用遗留撤销记录原样还原', point)
            else:
                # Only the last write clears the mark: the repair had finished.
                assert state == CHECK_CLEAN and point == total, ('中途出现了没有“需要检查”标记的状态', point, state)
                repaired_as_expected(work, made)
        passed(f'{"带" if dirty else "不带"}“需要检查”标记的盘{"（失效条目在索引块里）" if crowd else ""}，修复的 {total} 次写入逐一出错或中途进程消失：'
               '出错时按撤销记录原样还原；中途消失时盘始终标着“需要检查”（或读不出），Windows 日志不变，遗留撤销记录可原样还原')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'scope': '一次性普通镜像；不涉及设备、后台组件或实盘；Windows chkdsk 复核另做'}
(ROOT / 'docs/testing/ntfs-stale-entry-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
