#!/usr/bin/env python3
"""File names between macOS and NTFS, on newly created disposable images only.

- Names Windows cannot use are stored with the SFM private-use mapping and
  listed, opened, renamed and deleted under their Mac spelling.
- Entries stored decomposed (NFD) or with CJK compatibility ideographs by other
  systems list and open (they used to list but fail every lookup).
- "$" names are reserved at the root only; dot files are hidden from Windows;
  a folder or rename differing only in case from another entry is refused;
  a file is not (the kernel retries open(O_CREAT) on EEXIST for ever).
"""
import ctypes as C
import errno
import json
import subprocess
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO

TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'


class Dirent(C.Structure):
    _fields_ = [('name', C.c_char_p), ('is_dir', C.c_int), ('size', C.c_longlong),
                ('inode', C.c_uint64), ('is_symlink', C.c_int), ('reference', C.c_uint64)]


class Stat(C.Structure):
    _fields_ = [('is_dir', C.c_int), ('size', C.c_longlong), ('alloc_size', C.c_longlong), ('inode', C.c_uint64),
                ('atime', C.c_longlong), ('mtime', C.c_longlong), ('ctime', C.c_longlong), ('btime', C.c_longlong),
                ('is_symlink', C.c_int), ('koio_ok', C.c_int), ('is_resident', C.c_int),
                ('atime_nsec', C.c_int), ('mtime_nsec', C.c_int), ('ctime_nsec', C.c_int), ('btime_nsec', C.c_int),
                ('mac_mode', C.c_uint32), ('file_flags', C.c_uint32)]


DIR_CB = C.CFUNCTYPE(C.c_int, C.c_void_p, C.POINTER(Dirent))
LIB.nk_list.argtypes = [C.c_void_p, C.c_char_p, DIR_CB, C.c_void_p]; LIB.nk_list.restype = C.c_int
LIB.nk_stat_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(Stat)]; LIB.nk_stat_path.restype = C.c_int
LIB.nk_reference_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_uint64)]; LIB.nk_reference_path.restype = C.c_int
# Raw libntfs-3g, to put names on disk exactly as another system would.
LIB.ntfs_pathname_to_inode.argtypes = [C.c_void_p, C.c_void_p, C.c_char_p]; LIB.ntfs_pathname_to_inode.restype = C.c_void_p
LIB.ntfs_create.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p, C.c_uint8, C.c_uint32]; LIB.ntfs_create.restype = C.c_void_p
LIB.ntfs_inode_close.argtypes = [C.c_void_p]; LIB.ntfs_inode_close.restype = C.c_int

checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def listing(v, path):
    found = {}

    @DIR_CB
    def collect(_, entry):
        e = entry.contents
        found[e.name.decode()] = e.reference
        return 0
    assert LIB.nk_list(v, path.encode(), collect, None) == 0, path
    return found


def stat(v, path):
    st = Stat()
    C.set_errno(0)
    rc = LIB.nk_stat_path(v, path.encode(), C.byref(st))
    return (st if rc == 0 else None), C.get_errno()


def call(function, *args):
    C.set_errno(0)
    rc = function(*args)
    return rc, (C.get_errno() if rc else 0)


def write(v, path, data):
    buf = C.create_string_buffer(data)
    return LIB.nk_write(v, path.encode(), 0, len(data), buf)


def read(v, path, size):
    buf = C.create_string_buffer(size)
    n = LIB.nk_read(v, path.encode(), 0, size, buf)
    return buf.raw[:n] if n >= 0 else None


def raw_create(v, directory, name):
    """A file named exactly `name` (UTF-16), bypassing Volisle's name handling."""
    vol = C.cast(v, C.POINTER(C.c_void_p))[0]  # nk_volume.vol
    dir_ni = LIB.ntfs_pathname_to_inode(vol, None, directory.encode())
    assert dir_ni, directory
    units = name.encode('utf-16-le')
    buf = C.create_string_buffer(units)
    ni = LIB.ntfs_create(dir_ni, 0, buf, len(units) // 2, 0o100000)
    assert ni, name
    assert LIB.ntfs_inode_close(ni) == 0 and LIB.ntfs_inode_close(dir_ni) == 0
    assert LIB.nk_sync(v) == 0


def on_disk(image, path):
    """Names as NTFS-3G's own tool lists them (exact UTF-16 converted to UTF-8)."""
    out = subprocess.run([TOOLS / 'ntfsls', '-f', '-a', '-p', path, image], capture_output=True, check=True).stdout
    return set(unicodedata.normalize('NFC', n) for n in out.decode('utf-8', 'surrogateescape').split('\n') if n)


def main():
    with tempfile.TemporaryDirectory(prefix='volisle-names-', dir=ROOT / '.workbench') as tmp:
        image = Path(tmp) / 'names.img'
        with image.open('xb') as f:
            f.truncate(64 * 1024 * 1024)
        subprocess.run([TOOLS / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True, timeout=60)
        device = ImageIO(image)
        v = device.mount(); assert v
        assert LIB.nk_mkdir(v, b'/', b'mac') == 0

        # 1. Windows-forbidden characters: stored mapped, used under the Mac name.
        mac_names = ['a?b.txt', 'x|y', '"q"', '<a>', 'star*', 'back\\slash', 'c:d', 'name.', 'name ', 'Icon\r', 'ctl\x01x']
        for name in mac_names:
            path = '/mac/' + name
            assert call(LIB.nk_create, v, b'/mac', name.encode()) == (0, 0), name
            assert write(v, path, name.encode() * 3) == len(name) * 3, name
        listed = listing(v, '/mac')
        assert set(mac_names) <= set(listed), sorted(listed)
        for name in mac_names:
            st, _ = stat(v, '/mac/' + name)
            assert st and st.size == len(name) * 3, name
            assert read(v, '/mac/' + name, 100) == name.encode() * 3, name
        passed('Windows 不允许的字符：以 Mac 名字新建、列出、读写一致')
        stored = {unicodedata.normalize('NFC', n) for n in on_disk(image, '/mac')}
        expect = {'ab.txt', 'xy', 'q', 'a', 'star', 'backslash',
                  'cd', 'name', 'name', 'Icon', 'ctlx'}
        assert expect <= stored, sorted(stored - expect)
        assert not any(c in n for n in stored for c in '?|"<>*\\:' + '\r\x01'), sorted(stored)
        passed('盘上按 SFM 映射存储（Windows 可打开），不含 Windows 禁用字符')
        assert call(LIB.nk_rename, v, b'/mac/a?b.txt', b'/mac', b'renamed?.txt') == (0, 0)
        assert 'renamed?.txt' in listing(v, '/mac') and 'a?b.txt' not in listing(v, '/mac')
        assert read(v, '/mac/renamed?.txt', 100) == b'a?b.txt' * 3
        for name in ['renamed?.txt', 'x|y', 'name.', 'Icon\r']:
            assert call(LIB.nk_delete, v, ('/mac/' + name).encode()) == (0, 0), name
        assert not {'renamed?.txt', 'x|y', 'name.', 'Icon\r'} & set(listing(v, '/mac'))
        passed('映射过的名字可改名、删除')

        # 2. Names stored by older versions without mapping still work.
        raw_create(v, '/mac', 'legacy?.txt')
        assert 'legacy?.txt' in listing(v, '/mac')
        assert stat(v, '/mac/legacy?.txt')[0] is not None
        assert call(LIB.nk_create, v, b'/mac', b'legacy?.txt') == (-1, errno.EEXIST)
        assert call(LIB.nk_delete, v, b'/mac/legacy?.txt') == (0, 0)
        passed('旧版未映射存储的名字仍可打开、防重名、删除')

        # 3. Decomposed and compatibility-ideograph names written by other systems.
        assert LIB.nk_mkdir(v, b'/', b'foreign') == 0
        nfd = unicodedata.normalize('NFD', 'café-한글-が.txt')
        compat = '山﨑.txt'  # 﨑: NFC turns it into 崎, a different name
        raw_create(v, '/foreign', nfd)
        raw_create(v, '/foreign', compat)
        raw_create(v, '/foreign', 'plain.txt')
        listed = listing(v, '/foreign')
        assert nfd in listed and compat in listed and 'plain.txt' in listed, [n.encode() for n in listed]
        for name in [nfd, compat]:
            assert stat(v, '/foreign/' + name)[0] is not None, name.encode()
            ref = C.c_uint64()
            assert LIB.nk_reference_path(v, ('/foreign/' + name).encode(), C.byref(ref)) == 0 and ref.value == listed[name]
        # The composed spelling an app may pass finds the decomposed entry.
        assert stat(v, '/foreign/' + unicodedata.normalize('NFC', nfd))[0] is not None
        assert call(LIB.nk_create, v, b'/foreign', unicodedata.normalize('NFC', nfd).encode()) == (-1, errno.EEXIST)
        for name in [nfd, compat]:
            assert call(LIB.nk_delete, v, ('/foreign/' + name).encode()) == (0, 0), name.encode()
        assert set(listing(v, '/foreign')) == {'plain.txt'}
        passed('其他系统存的 NFD 名与兼容汉字：可列出、打开、删除，NFC 拼写也能找到')

        # 4. Names this Mac creates are stored composed.
        assert call(LIB.nk_create, v, b'/foreign', unicodedata.normalize('NFD', 'résumé.txt').encode()) == (0, 0)
        assert call(LIB.nk_umount, v) == (0, 0); device.close()
        device = ImageIO(image); v = device.mount(); assert v
        raw = listing(v, '/foreign')
        assert 'résumé.txt' in raw and unicodedata.normalize('NFD', 'résumé.txt') not in raw, [n.encode() for n in raw]
        passed('Mac 新建的名字按 NFC 存储（与 Windows 一致）')

        # 5. "$" names: only the root's are NTFS metadata.
        assert call(LIB.nk_create, v, b'/mac', b'$5.pdf') == (0, 0)
        assert '$5.pdf' in listing(v, '/mac')
        assert call(LIB.nk_create, v, b'/', b'$Volisle')[1] == errno.EINVAL
        assert call(LIB.nk_rename, v, b'/mac/$5.pdf', b'/', b'$5.pdf')[1] == errno.EINVAL
        passed('“$”开头的名字只在根目录保留，子目录可用')

        # 6. Dot files are hidden from Windows Explorer; others are not.
        for name in ['.DS_Store', 'visible.txt']:
            assert LIB.nk_create(v, b'/mac', name.encode()) == 0
        assert stat(v, '/mac/.DS_Store')[0].file_flags & 0x2
        assert not stat(v, '/mac/visible.txt')[0].file_flags & 0x2
        passed('点文件新建时带 Windows 隐藏属性')

        # 7. Case. A folder, or a rename onto another entry's case variant, is
        #    refused. A file is not: open(O_CREAT) answers EEXIST by looking the
        #    name up again, which never finds it, so the kernel retried for ever.
        #    A case-only rename of the same file works.
        assert LIB.nk_create(v, b'/mac', b'Readme.md') == 0
        assert call(LIB.nk_create, v, b'/mac', b'README.md') == (0, 0)
        assert call(LIB.nk_delete, v, b'/mac/README.md') == (0, 0)
        assert LIB.nk_mkdir(v, b'/mac', b'Docs') == 0
        assert call(LIB.nk_mkdir, v, b'/mac', b'DOCS') == (-1, errno.EEXIST)
        assert LIB.nk_create(v, b'/mac', b'other.md') == 0
        assert call(LIB.nk_rename, v, b'/mac/other.md', b'/mac', b'readme.MD') == (-1, errno.EEXIST)
        assert call(LIB.nk_rename, v, b'/mac/Readme.md', b'/mac', b'README.md') == (0, 0)
        names = listing(v, '/mac')
        assert 'README.md' in names and 'Readme.md' not in names
        passed('只差大小写：文件夹与改名被拒绝，新建文件不拒绝（防内核死循环）；同一文件只改大小写正常')

        # 8. Errors keep their meaning.
        assert LIB.nk_mkdir(v, b'/mac', b'full') == 0 and LIB.nk_create(v, b'/mac/full', b'x') == 0
        assert call(LIB.nk_delete, v, b'/mac/full') == (-1, errno.ENOTEMPTY)
        assert call(LIB.nk_delete, v, b'/mac/missing') == (-1, errno.ENOENT)
        assert call(LIB.nk_create, v, b'/mac', ('n' * 256).encode()) == (-1, errno.ENAMETOOLONG)
        assert LIB.nk_create(v, b'/mac', b'after-errors') == 0  # the session was not locked
        passed('非空目录、不存在、名字过长返回各自的错误码，且不锁会话')

        assert LIB.nk_umount(v) == 0; device.close()
        assert subprocess.run([TOOLS / 'ntfsfix', '-n', image], capture_output=True).returncode == 0
        passed('卸载干净，ntfsfix -n 无错误')

    result = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks, 'success': True}
    (ROOT / 'docs/testing/ntfs-names-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'checks': len(checks), 'success': True}))


if __name__ == '__main__':
    main()
