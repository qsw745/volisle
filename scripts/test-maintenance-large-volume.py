#!/usr/bin/env python3
"""大盘位图、短读拒绝和 MFT 批量读取回归。只操作临时普通文件镜像。"""
import argparse
import ctypes as C
import json
import os
import runpy
import shutil
import subprocess
import tempfile
from pathlib import Path

from ntfs_bridge_test_support import ROOT, IO, ImageIO, PREAD

helpers = runpy.run_path(str(ROOT / 'scripts/test-windows-log-recover.py'))
WindowsLog, mark_dirty = helpers['WindowsLog'], helpers['mark_dirty']


class BoundedImage(ImageIO):
    def __init__(self, path, short_bitmap=False):
        super().__init__(path)
        self.largest_read = 0
        self.rejected = []
        original = self.callbacks[0]

        @PREAD
        def read(ctx, buf, count, offset):
            self.largest_read = max(self.largest_read, count)
            if count > 64 * 1024 * 1024:
                self.rejected.append(count)
                return -1
            if short_bitmap and count >= 1024 * 1024:
                return original(ctx, buf, count - 512, offset)
            return original(ctx, buf, count, offset)

        self.bounded_read = read
        self.io.pread = read


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, default=ROOT / '.workbench/libVolisleNTFS.dylib')
    args = parser.parse_args()
    lib = C.CDLL(str(args.library.resolve()), use_errno=True)
    lib.nk_clear_check_marker.argtypes = [C.POINTER(IO), C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
    lib.nk_windows_log_recover.argtypes = [C.POINTER(IO), C.POINTER(WindowsLog), C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
    lib.nk_inspect.argtypes = [C.POINTER(IO)]
    results = []
    with tempfile.TemporaryDirectory(prefix='maintenance-large-', dir=ROOT / '.workbench') as tmp:
        folder = Path(tmp)
        big = folder / 'four-tb.img'
        with big.open('xb') as handle:
            handle.truncate(4_000_000_000_000)
        mkntfs = ROOT / '.workbench/ntfs-3g-2026.9.28/ntfsprogs/mkntfs'
        subprocess.run([str(mkntfs), '-F', '-Q', '-s', '512', '-c', '4096', str(big)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
        mark_dirty(big)
        io = BoundedImage(big, short_bitmap=True)
        items, err = C.c_longlong(), C.create_string_buffer(256)
        rc = lib.nk_clear_check_marker(C.byref(io.io), C.byref(items), err, len(err))
        results.append(dict(name='短读拒绝且不清除检查标记', passed=rc == -1 and io.writes == 0,
                            rc=rc, writes=io.writes, reason=err.value.decode()))
        io.close()
        io = BoundedImage(big)
        rc = lib.nk_clear_check_marker(C.byref(io.io), C.byref(items), err, len(err))
        results.append(dict(name='4TB位图通过64MiB限制回调', passed=rc == 0 and not io.rejected,
                            rc=rc, rejected=io.rejected, largest_read=io.largest_read, reason=err.value.decode()))
        io.close()
        # Reserved record 12 is allocated but not reached from a folder. A torn
        # sector in it must be rejected by the allocation scan, even mid-batch.
        mark_dirty(big)
        with big.open('r+b') as handle:
            boot = handle.read(512)
            cluster = int.from_bytes(boot[11:13], 'little') * boot[13]
            record_code = int.from_bytes(boot[64:65], 'little', signed=True)
            record_size = 1 << -record_code if record_code < 0 else record_code * cluster
            at = int.from_bytes(boot[48:56], 'little') * cluster + 12 * record_size
            handle.seek(at)
            record = handle.read(record_size)
            assert record[:4] == b'FILE' and int.from_bytes(record[22:24], 'little') & 1
            handle.seek(at + 510)
            handle.write(bytes([record[510] ^ 0xff]))
        io = BoundedImage(big)
        rc = lib.nk_clear_check_marker(C.byref(io.io), C.byref(items), err, len(err))
        results.append(dict(name='批次中在用记录MST损坏必须拒绝', passed=rc == -1 and io.writes == 0,
                            rc=rc, writes=io.writes, reason=err.value.decode()))
        io.close()
        small = folder / 'unclean.img'
        shutil.copyfile(ROOT / '.workbench/log-fixtures/unclean.img', small)
        io = BoundedImage(small)
        before, items, err = WindowsLog(), C.c_longlong(), C.create_string_buffer(256)
        rc = lib.nk_windows_log_recover(C.byref(io.io), C.byref(before), C.byref(items), err, len(err))
        clean = lib.nk_inspect(C.byref(io.io))
        results.append(dict(name='完整核验保持9982项且减少原始读取',
                            passed=rc == 0 and clean == 0 and items.value == 9982 and io.reads < 16000,
                            rc=rc, items=items.value, reads=io.reads, reason=err.value.decode()))
        io.close()
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0 if all(item['passed'] for item in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
