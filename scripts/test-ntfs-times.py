#!/usr/bin/env python3
"""Real bridge timestamp round trips, restricted to a disposable image."""
import ctypes as C
import errno
import json
from pathlib import Path
import subprocess
import struct
import shutil
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

assert hasattr(LIB, 'nk_set_times_precise'), '桥接尚未提供可保留亚秒精度的时间写入接口'

class Timestamp(C.Structure):
    _fields_ = [('seconds', C.c_longlong), ('nanoseconds', C.c_int)]

class Stat(C.Structure):
    _fields_ = [('is_dir', C.c_int), ('size', C.c_longlong), ('alloc_size', C.c_longlong),
                ('inode', C.c_uint64), ('atime', C.c_longlong), ('mtime', C.c_longlong),
                ('ctime', C.c_longlong), ('btime', C.c_longlong), ('is_symlink', C.c_int),
                ('koio_ok', C.c_int), ('is_resident', C.c_int),
                ('atime_nsec', C.c_int), ('mtime_nsec', C.c_int),
                ('ctime_nsec', C.c_int), ('btime_nsec', C.c_int), ('mac_mode', C.c_uint32), ('file_flags', C.c_uint32)]

LIB.nk_set_times_precise.argtypes = [C.c_void_p, C.c_char_p] + [C.POINTER(Timestamp)] * 3
LIB.nk_set_times_precise.restype = C.c_int
LIB.nk_stat_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(Stat)]
LIB.nk_stat_path.restype = C.c_int

with tempfile.TemporaryDirectory(prefix='volisle-times-', dir=ROOT / '.workbench') as tmp:
    image = Path(tmp) / 'fixture.img'
    with image.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    subprocess.run([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs', '-F', '-Q', image],
                   check=True, capture_output=True, timeout=45)
    io = ImageIO(image); volume = io.mount(); assert volume
    try:
        assert LIB.nk_create(volume, b'/', b'timestamps') == 0
        # NTFS rounds down to 100 ns. Negative seconds must use POSIX's
        # non-negative fractional component rather than losing the fraction.
        atime = Timestamp(1700000000, 123456789)
        mtime = Timestamp(-2, 987654321)
        btime = Timestamp(0, 999999999)
        assert LIB.nk_set_times_precise(volume, b'/timestamps', C.byref(atime), C.byref(mtime), C.byref(btime)) == 0
        valid = Timestamp(1800000000, 0)
        for invalid in [Timestamp(0, -1), Timestamp(0, 1000000000),
                        Timestamp(-11644473601, 0), Timestamp(2**63 - 1, 0)]:
            writes = io.writes
            assert LIB.nk_set_times_precise(volume, b'/timestamps', C.byref(valid), C.byref(invalid), None) == -1
            assert C.get_errno() == errno.EINVAL and io.writes == writes
        assert LIB.nk_umount(volume) == 0; volume = None
    finally:
        if volume:
            LIB.nk_umount(volume)
        io.close()
    io = ImageIO(image, readonly=True); volume = io.mount(); assert volume
    try:
        st = Stat()
        assert LIB.nk_stat_path(volume, b'/timestamps', C.byref(st)) == 0
        assert (st.atime, st.atime_nsec) == (1700000000, 123456700)
        assert (st.mtime, st.mtime_nsec) == (-2, 987654300)
        assert (st.btime, st.btime_nsec) == (0, 999999900)
        assert LIB.nk_set_times_precise(volume, b'/timestamps', None, C.byref(valid), None) == -1
        assert C.get_errno() == errno.EROFS
        assert io.writes == 0
    finally:
        LIB.nk_umount(volume); io.close()
    mft = subprocess.check_output([ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat',
                                   image, '/$MFT'], timeout=15)
    record = mft[st.inode * 1024:(st.inode + 1) * 1024]
    offset = struct.unpack_from('<H', record, 20)[0]
    while struct.unpack_from('<I', record, offset)[0] != 0x10:
        kind, length = struct.unpack_from('<II', record, offset)
        assert kind != 0xffffffff and length >= 24 and offset + length < 1024
        offset += length
    assert record[offset + 8] == 0
    value = offset + struct.unpack_from('<H', record, offset + 20)[0]
    assert value + 32 < 510  # timestamps don't cross this record's fixup boundary
    birth, modified, _, access = struct.unpack_from('<qqqq', record, value)
    assert (access, modified, birth) == (133444736001234567, 116444735989876543, 116444736009999999)
    failing = Path(tmp) / 'failure.img'; shutil.copyfile(image, failing)
    io = ImageIO(failing); volume = io.mount(); assert volume
    io.fail_write = True
    assert LIB.nk_set_times_precise(volume, b'/timestamps', None, C.byref(valid), None) == -1
    io.fail_write = False
    writes = io.writes
    assert LIB.nk_create(volume, b'/', b'must-remain-blocked') == -1 and io.writes == writes
    assert LIB.nk_umount(volume) == -1 and io.inspect() == 1
    io.close()
    print(json.dumps({'success': True, 'checks': ['100ns-roundtrip', 'pre-epoch-roundtrip',
        'invalid-request-zero-writes', 'readonly-reopen-and-denial', 'independent-mft-values',
        'timestamp-io-failure-locks-session']}, ensure_ascii=False))
