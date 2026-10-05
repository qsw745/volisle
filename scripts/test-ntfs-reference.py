#!/usr/bin/env python3
"""Real inode references: replacement isolation, cached stale sequence and reuse."""
import ctypes as C
import errno
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import shutil
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from ntfs_replacement_recovery import Stat

LIB.nk_reference_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_uint64)]
LIB.nk_reference_path.restype = C.c_int
LIB.nk_stat_reference.argtypes = [C.c_void_p, C.c_uint64, C.POINTER(Stat)]
LIB.nk_stat_reference.restype = C.c_int
for name in ['nk_read_reference', 'nk_write_reference']:
    getattr(LIB, name).argtypes = [C.c_void_p, C.c_uint64, C.c_longlong, C.c_longlong, C.c_void_p]
    getattr(LIB, name).restype = C.c_longlong
LIB.nk_replace_preserving.argtypes = [C.c_void_p] + [C.c_char_p] * 4
LIB.nk_replace_preserving.restype = C.c_int
BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'


def reference(volume, path):
    result = C.c_uint64()
    assert LIB.nk_reference_path(volume, path, C.byref(result)) == 0, '稳定文件引用尚未实现'
    assert result.value >> 48, '引用不能丢掉序列号'
    return result.value


def read(volume, ref, expected):
    buf = C.create_string_buffer(len(expected) + 1)
    assert LIB.nk_read_reference(volume, ref, 0, len(expected) + 1, buf) == len(expected)
    assert buf.raw[:len(expected)] == expected


def write(volume, ref, value):
    buf = C.create_string_buffer(value)
    assert LIB.nk_write_reference(volume, ref, 0, len(value), buf) == len(value)


def create(volume, name, data):
    assert LIB.nk_create(volume, b'/', name) == 0
    ref = reference(volume, b'/' + name)
    write(volume, ref, data)
    return ref


def main():
    report = {'success': False, 'checks': []}
    with tempfile.TemporaryDirectory(prefix='volisle-reference-', dir=ROOT / '.workbench') as tmp:
        image = Path(tmp) / 'fixture.img'
        with image.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True, timeout=45)
        io = ImageIO(image); volume = io.mount(); assert volume
        old = create(volume, b'document', b'old-version')
        new = create(volume, b'draft', b'new-version')
        assert old != new
        assert LIB.nk_replace_preserving(volume, b'/', b'draft', b'document', b'.saved-old') == 0
        assert reference(volume, b'/document') == new and reference(volume, b'/.saved-old') == old
        read(volume, old, b'old-version'); read(volume, new, b'new-version')
        write(volume, old, b'OLD-edited!'); write(volume, new, b'NEW-edited!')
        read(volume, old, b'OLD-edited!'); read(volume, new, b'NEW-edited!')
        info = Stat()
        assert LIB.nk_stat_reference(volume, old, C.byref(info)) == 0 and info.size == 11
        report['checks'].append('old-reference-and-new-path-remain-independent-after-replacement')

        # Upstream inode cache keys only by record number. A forged sequence
        # must fail even when the correct inode is already cached.
        wrong_sequence = (old & ((1 << 48) - 1)) | (((old >> 48) % 65535 + 1) << 48)
        assert wrong_sequence >> 48 and wrong_sequence != old
        for bad in [wrong_sequence, old & ((1 << 48) - 1)]:
            before = io.writes
            buf = C.create_string_buffer(b'wrong-write')
            assert LIB.nk_read_reference(volume, bad, 0, 11, buf) == -1
            assert C.get_errno() in (errno.ESTALE, errno.EINVAL)
            assert LIB.nk_write_reference(volume, bad, 0, 11, buf) == -1
            assert C.get_errno() in (errno.ESTALE, errno.EINVAL) and io.writes == before
            assert LIB.nk_stat_reference(volume, bad, C.byref(info)) == -1
        read(volume, old, b'OLD-edited!')
        report['checks'].append('cached-sequence-mismatch-and-zero-sequence-rejected-without-writes')

        before = io.writes; buf = C.create_string_buffer(32)
        for offset, count in [(-1, 1), (0, -1), (2**63 - 1, 1)]:
            assert LIB.nk_read_reference(volume, new, offset, count, buf) == -1 and C.get_errno() == errno.EINVAL
            assert LIB.nk_write_reference(volume, new, offset, count, buf) == -1 and C.get_errno() == errno.EINVAL
        root = reference(volume, b'/')
        assert LIB.nk_read_reference(volume, root, 0, 1, buf) == -1 and C.get_errno() == errno.EISDIR
        assert LIB.nk_write_reference(volume, root, 0, 1, buf) == -1 and C.get_errno() == errno.EISDIR
        assert io.writes == before
        report['checks'].append('invalid-range-and-directory-reference-rejected-before-mutation')

        # References do not pin unlinked files. Force real record reuse and
        # ensure the old reference cannot access the unrelated new occupant.
        assert LIB.nk_delete(volume, b'/.saved-old') == 0
        before = io.writes; buf = C.create_string_buffer(64)
        assert LIB.nk_write_reference(volume, old, 0, 1, buf) == -1 and io.writes == before
        reused = None
        for index in range(128):
            name = f'reuse-{index}'.encode()
            ref = create(volume, name, b'unrelated-data')
            if ref & ((1 << 48) - 1) == old & ((1 << 48) - 1):
                reused = ref; break
            assert LIB.nk_delete(volume, b'/' + name) == 0
        assert reused is not None and reused != old, '未触发 MFT 记录复用，不能声称通过此项'
        read(volume, reused, b'unrelated-data')
        before = io.writes
        assert LIB.nk_read_reference(volume, old, 0, 1, buf) == -1 and C.get_errno() == errno.ESTALE
        assert LIB.nk_write_reference(volume, old, 0, 1, buf) == -1 and C.get_errno() == errno.ESTALE
        assert io.writes == before
        read(volume, reused, b'unrelated-data'); read(volume, new, b'NEW-edited!')
        report['checks'].append('actual-mft-reuse-does-not-redirect-stale-reference')
        assert LIB.nk_umount(volume) == 0; io.close()
        assert subprocess.check_output([BIN / 'ntfscat', image, '/document']) == b'NEW-edited!'
        assert subprocess.check_output([BIN / 'ntfscat', image, '/' + name.decode()]) == b'unrelated-data'
        report['checks'].append('independent-content-read-after-clean-close')

        # Resolve fresh references on each mount; references are volume scoped.
        before = hashlib.sha256(image.read_bytes()).hexdigest()
        io = ImageIO(image, readonly=True); volume = io.mount(); assert volume
        current = reference(volume, b'/document')
        read(volume, current, b'NEW-edited!')
        assert LIB.nk_write_reference(volume, current, 0, 1, buf) == -1 and C.get_errno() == errno.EROFS
        assert io.writes == 0 and LIB.nk_umount(volume) == 0; io.close()
        assert hashlib.sha256(image.read_bytes()).hexdigest() == before
        report['checks'].append('read-only-reopen-and-reference-write-denial')
        for fault in ['fail_write', 'short_write']:
            failed = Path(tmp) / (fault + '.img'); shutil.copyfile(image, failed)
            io = ImageIO(failed); volume = io.mount(); assert volume
            ref = reference(volume, b'/document')
            setattr(io, fault, True)
            assert LIB.nk_write_reference(volume, ref, 0, 1, buf) == -1
            setattr(io, fault, False)
            before = io.writes
            assert LIB.nk_write_reference(volume, ref, 0, 1, buf) == -1 and io.writes == before
            assert LIB.nk_umount(volume) == -1 and io.inspect() == 1; io.close()
        report['checks'].append('reference-write-failure-and-short-write-lock-session-and-retain-dirty')
    report['success'] = True
    report['verified_at'] = datetime.now(timezone.utc).isoformat()
    (ROOT / 'docs/testing/ntfs-reference-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
