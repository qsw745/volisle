#!/usr/bin/env python3
""""Check on This Mac" against a volume Windows 11 formatted and filled with the
structures real Windows disks carry (scripts/check-fixtures/fetch-rich-ntfs.sh):
hard links, junctions, symbolic links, compressed, sparse and WOF files,
alternate data streams, object IDs, a USN journal, a case-sensitive folder,
explicit ACLs, the recycle bin, 8.3 names, EFS, deep paths, a shadow copy.
None of it is damage: the check must pass and clear only the dirty flag.
Works on a copy; the fixture is never written."""
import ctypes as C
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

FIXTURE = ROOT / '.workbench/check-fixtures/rich.img'
TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_clear_check_marker.argtypes = [C.c_void_p, C.POINTER(C.c_longlong), C.c_char_p, C.c_size_t]
ELIB.nk_clear_check_marker.restype = C.c_int
VOLUME_IS_DIRTY = 0x0001


def volume_flags(image):
    """$Volume's flags through ntfsinfo (independent of the bridge)."""
    out = subprocess.run([TOOLS / 'ntfsinfo', '-f', '-m', str(image)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if 'Volume Flags' in line or 'Volume flags' in line:
            return line.strip()
    return out[-400:]


def tree(image):
    """Every path and its type as ntfsls sees it, hidden and system files included."""
    out = subprocess.run([TOOLS / 'ntfsls', '-f', '-a', '-R', '-l', str(image)], capture_output=True)
    return out.returncode, hashlib.sha256(out.stdout).hexdigest(), len(out.stdout.splitlines())


def main():
    if not FIXTURE.is_file():
        sys.exit(f'缺少 {FIXTURE}：先运行 scripts/check-fixtures/fetch-rich-ntfs.sh')
    report = {'fixture_sha256': hashlib.sha256(FIXTURE.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix='volisle-check-win-', dir=ROOT / '.workbench') as tmp:
        image = Path(tmp) / 'rich.img'
        shutil.copyfile(FIXTURE, image)
        before_tree = tree(image)
        report['flags_before'] = volume_flags(image)
        io = ImageIO(image)
        assert io.inspect() == 1, '测试盘应带“需要检查”标记'
        items = C.c_longlong(0)
        errbuf = C.create_string_buffer(256)
        rc = ELIB.nk_clear_check_marker(C.byref(io.io), C.byref(items), errbuf, len(errbuf))
        error = C.get_errno()
        report['result'] = {'rc': rc, 'errno': error, 'reason': errbuf.value.decode(), 'items': items.value}
        print(json.dumps(report['result'], ensure_ascii=False), flush=True)
        assert rc == 0, ('Windows 正常写出的结构被判为有问题', errbuf.value.decode(), error)
        assert items.value > 8000, items.value
        assert io.inspect() == 0, '清除后应为干净'
        io.close()
        report['flags_after'] = volume_flags(image)
        after_tree = tree(image)
        assert before_tree == after_tree, '除卷标志外不应有任何改动'
        assert subprocess.run([TOOLS / 'ntfsfix', '-n', str(image)], capture_output=True).returncode == 0
        report['checked_items'] = items.value
        report['success'] = True
    (ROOT / 'docs/testing/check-marker-windows-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('PASS Windows 11 写出的常见结构全部通过“在 Mac 上检查”，只清除了需要检查标记')


if __name__ == '__main__':
    main()
