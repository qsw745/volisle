"""Disposable NTFS images carrying the inconsistency a user reported on
2026-10-10 ("listed as a folder, record is a file"), built the way it most
likely happened on their disk: a folder is deleted and its file record reused
by a new file, while the parent folder's index on disk keeps its old content
(the index write lost when the disk was pulled). Regular image files only;
never a device.

The parent's index is put back by rewriting the parent's file record (its
INDEX_ROOT) and, for a large folder, its index blocks, from copies taken
before the delete: every byte written is one NTFS itself wrote earlier."""
import ctypes as C
import struct

from ntfs_bridge_test_support import LIB, ImageIO

MIB = 1 << 20
FILE_ATTR_I30_INDEX_PRESENT = 0x10000000
AT_FILE_NAME, AT_INDEX_ROOT, AT_INDEX_ALLOCATION, AT_BITMAP, AT_END = 0x30, 0x90, 0xA0, 0xB0, 0xFFFFFFFF
INDEX_ENTRY_NODE, INDEX_ENTRY_END = 0x01, 0x02

LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int


class Dirent(C.Structure):
    _fields_ = [('name', C.c_char_p), ('is_dir', C.c_int), ('size', C.c_longlong),
                ('inode', C.c_uint64), ('is_symlink', C.c_int), ('reference', C.c_uint64)]


DIR_CB = C.CFUNCTYPE(C.c_int, C.c_void_p, C.POINTER(Dirent))
LIB.nk_list.argtypes = [C.c_void_p, C.c_char_p, DIR_CB, C.c_void_p]
LIB.nk_list.restype = C.c_int


def mft(ref):
    return ref & ((1 << 48) - 1)


def seq(ref):
    return ref >> 48


def geometry(path):
    """(sector, cluster, record size, $MFT LCN, $MFTMirr LCN)."""
    with path.open('rb') as f:
        boot = f.read(512)
    sector = struct.unpack_from('<H', boot, 11)[0]
    cluster = sector * boot[13]
    cpr = struct.unpack_from('b', boot, 64)[0]
    record = (1 << -cpr) if cpr < 0 else cpr * cluster
    return sector, cluster, record, struct.unpack_from('<Q', boot, 48)[0], struct.unpack_from('<Q', boot, 56)[0]


def record_offset(path, number, mirror=False):
    """$MFT of a freshly formatted small image is one run from its start."""
    _, cluster, record, mft_lcn, mirror_lcn = geometry(path)
    return (mirror_lcn if mirror else mft_lcn) * cluster + number * record, record


def read_record(path, number):
    """The record as stored (multi-sector protected)."""
    at, size = record_offset(path, number)
    with path.open('rb') as f:
        f.seek(at)
        raw = f.read(size)
    assert raw[:4] == b'FILE', number
    return raw


def write_record(path, number, raw, mirror=False):
    at, size = record_offset(path, number, mirror)
    assert len(raw) == size and raw[:4] == b'FILE'
    with path.open('r+b') as f:
        f.seek(at)
        f.write(raw)


def read_at(path, offset, length):
    with path.open('rb') as f:
        f.seek(offset)
        return f.read(length)


def write_at(path, offset, data):
    with path.open('r+b') as f:
        f.seek(offset)
        f.write(data)


def unprotect(raw, sector):
    """Undo the update sequence: the real last two bytes of every sector."""
    data = bytearray(raw)
    usa_ofs, usa_count = struct.unpack_from('<HH', data, 4)
    usn = data[usa_ofs:usa_ofs + 2]
    for i in range(1, usa_count):
        end = i * sector - 2
        assert data[end:end + 2] == usn, 'torn record'
        data[end:end + 2] = data[usa_ofs + 2 * i:usa_ofs + 2 * i + 2]
    return data


def protect(data, sector):
    """Store again: save each sector's last two bytes and put the USN there."""
    data = bytearray(data)
    usa_ofs, usa_count = struct.unpack_from('<HH', data, 4)
    usn = data[usa_ofs:usa_ofs + 2]
    for i in range(1, usa_count):
        end = i * sector - 2
        data[usa_ofs + 2 * i:usa_ofs + 2 * i + 2] = data[end:end + 2]
        data[end:end + 2] = usn
    return bytes(data)


def attributes(data):
    at = struct.unpack_from('<H', data, 20)[0]
    while True:
        kind = struct.unpack_from('<I', data, at)[0]
        if kind == AT_END:
            return
        length = struct.unpack_from('<I', data, at + 4)[0]
        yield kind, at, length
        at += length


def runs(data, at):
    """(LCN, clusters) of a non-resident attribute's mapping pairs."""
    pos = at + struct.unpack_from('<H', data, at + 32)[0]
    lcn, found = 0, []
    while data[pos]:
        nlen, olen = data[pos] & 0x0F, data[pos] >> 4
        length = int.from_bytes(data[pos + 1:pos + 1 + nlen], 'little')
        delta = int.from_bytes(data[pos + 1 + nlen:pos + 1 + nlen + olen], 'little', signed=True)
        lcn += delta
        found.append((lcn, length))
        pos += 1 + nlen + olen
    return found


def index_root_entries(data):
    """(offset in the record, MFT reference, flags) of every INDEX_ROOT entry."""
    for kind, at, _ in attributes(data):
        if kind != AT_INDEX_ROOT:
            continue
        assert data[at + 8] == 0, 'INDEX_ROOT is resident'
        value = at + struct.unpack_from('<H', data, at + 20)[0]
        header = value + 16
        entry = header + struct.unpack_from('<I', data, header)[0]
        while True:
            ref, length, _, flags = struct.unpack_from('<QHHH', data, entry)
            if flags & INDEX_ENTRY_END:
                return
            yield entry, ref, flags
            entry += length
    raise AssertionError('no INDEX_ROOT')


def has_index_allocation(data):
    return any(kind == AT_INDEX_ALLOCATION for kind, _, _ in attributes(data))


def folder_extents(path, folder):
    """Byte ranges holding a folder's index: its record and its index blocks."""
    sector, cluster, *_ = geometry(path)
    at, size = record_offset(path, folder)
    extents = [(at, size)]
    data = unprotect(read_record(path, folder), sector)
    for kind, offset, _ in attributes(data):
        if kind == AT_INDEX_ALLOCATION:
            extents += [(lcn * cluster, length * cluster) for lcn, length in runs(data, offset)]
    return extents


def snapshot(path, extents):
    return [(offset, read_at(path, offset, length)) for offset, length in extents]


def put_back(path, saved):
    for offset, data in saved:
        write_at(path, offset, data)


def mark_dirty(path):
    """VOLUME_IS_DIRTY in $Volume (record 3) of $MFT and $MFTMirr, as
    "Check on This Mac" requires (same as test-ntfs-check-marker.py)."""
    _, cluster, record, mft_lcn, mirror_lcn = geometry(path)
    with path.open('r+b') as f:
        for lcn in (mft_lcn, mirror_lcn):
            pos = lcn * cluster + 3 * record
            f.seek(pos)
            data = f.read(record)
            a = struct.unpack_from('<H', data, 20)[0]
            while struct.unpack_from('<I', data, a)[0] != AT_END:
                kind, length = struct.unpack_from('<II', data, a)
                if kind == 0x70:
                    at = pos + a + struct.unpack_from('<H', data, a + 20)[0] + 10
                    f.seek(at)
                    flags = struct.unpack('<H', f.read(2))[0]
                    f.seek(at)
                    f.write(struct.pack('<H', flags | 1))
                    break
                a += length
            else:
                raise AssertionError('$Volume information missing')


def set_mft_bitmap_bit(path, number):
    """Mark record `number` allocated in $MFT's own bitmap."""
    sector, cluster, *_ = geometry(path)
    data = unprotect(read_record(path, 0), sector)
    for kind, at, _ in attributes(data):
        if kind != AT_BITMAP:
            continue
        if data[at + 8]:
            lcn, _ = runs(data, at)[0]
            where = lcn * cluster + number // 8
            byte = read_at(path, where, 1)[0]
            write_at(path, where, bytes([byte | (1 << (number % 8))]))
        else:
            value = at + struct.unpack_from('<H', data, at + 20)[0]
            data[value + number // 8] |= 1 << (number % 8)
            raw = protect(data, sector)
            write_record(path, 0, raw)
            write_record(path, 0, raw, mirror=True)  # $MFTMirr holds records 0-3 too
        return
    raise AssertionError('$MFT has no bitmap')


def listing(v, path):
    found = {}

    @DIR_CB
    def collect(_, entry):
        found[entry.contents.name.decode()] = (entry.contents.reference, bool(entry.contents.is_dir))
        return 0
    assert LIB.nk_list(v, path.encode(), collect, None) == 0
    return found


def format_image(path, size=64 * MIB):
    with path.open('xb') as f:
        f.truncate(size)
    device = ImageIO(path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(device.io), b'STALE', 0, err, 256) == 0, err.value
    return device


def unmount(v):
    assert LIB.nk_sync(v) == 0 and LIB.nk_umount(v) == 0


def write_file(v, path, payload):
    buf = C.create_string_buffer(payload, len(payload))
    assert LIB.nk_write(v, path, 0, len(payload), buf) == len(payload)


def stale_folder_entry(path, reuse=True, new_in='a', crowd=0, child=False, payload=b'reused record\n' * 64):
    """Folder /b holds the entry of a deleted folder `old`.

    reuse: a new file /<new_in>/new.bin takes the freed record (else it stays
      free). /a is listed before /b in the root but walked after it (the check
      walks folders last-in first-out), so the stale entry is the first way the
      check reaches that record, as on the user's disk. new_in='c': the new
      file's own folder is walked first. new_in='b': its entry is lost with
      /b's index, so the record is reached only through the stale entry.
    crowd: that many files in /b before `old`, so /b's index has blocks.
    child: `old` had a file `c` whose record is put back in use afterwards,
      still naming `old` as its folder.

    Returns folder (MFT number of /b), record, entry_seq, record_seq (now),
    new_ref, payload, keep (/b's other names)."""
    device = format_image(path)
    v = device.mount()
    assert v
    for name in (b'a', b'b', b'c'):
        assert LIB.nk_mkdir(v, b'/', name) == 0
    keep = ['keep.txt'] + [f'entry-{i:03d}-' + 'x' * 40 for i in range(crowd)]
    for name in keep:
        assert LIB.nk_create(v, b'/b', name.encode()) == 0
    assert LIB.nk_mkdir(v, b'/b', b'old') == 0
    if child:
        assert LIB.nk_create(v, b'/b/old', b'c') == 0
    folder = mft(listing(v, '/')['b'][0])
    old_ref = listing(v, '/b')['old'][0]
    child_ref = listing(v, '/b/old')['c'][0] if child else None
    unmount(v)
    sector = geometry(path)[0]
    assert has_index_allocation(unprotect(read_record(path, folder), sector)) == bool(crowd), \
        '/b 的索引应当在记录里' if not crowd else '/b 的索引应当长出索引块'
    before = snapshot(path, folder_extents(path, folder))
    child_record = read_record(path, mft(child_ref)) if child else None

    v = device.mount()
    assert v
    if child:
        assert LIB.nk_delete(v, b'/b/old/c') == 0
    assert LIB.nk_delete(v, b'/b/old') == 0
    unmount(v)
    new_ref = None
    if reuse:
        # A fresh mount allocates the lowest free record: the one `old` had.
        v = device.mount()
        assert v and LIB.nk_create(v, b'/' + new_in.encode(), b'new.bin') == 0
        write_file(v, f'/{new_in}/new.bin'.encode(), payload)
        new_ref = listing(v, '/' + new_in)['new.bin'][0]
        unmount(v)
        assert mft(new_ref) == mft(old_ref), ('记录没有被重用，造不出这种不一致', hex(old_ref), hex(new_ref))
        assert seq(new_ref) != seq(old_ref), ('重用后序列号应当变化', hex(old_ref), hex(new_ref))
    device.close()

    # The index write that never reached the disk: /b's index as before the delete.
    put_back(path, before)
    if child:
        # `c` back in use, naming the deleted `old` as its folder.
        write_record(path, mft(child_ref), child_record)
        set_mft_bitmap_bit(path, mft(child_ref))
    now = unprotect(read_record(path, mft(old_ref)), sector)
    return {'folder': folder, 'record': mft(old_ref), 'entry_seq': seq(old_ref),
            'record_seq': struct.unpack_from('<H', now, 16)[0], 'old_ref': old_ref,
            'new_ref': new_ref, 'payload': payload, 'keep': keep, 'new_in': new_in}


def folder_flag_on_file(path):
    """Same symptom with nothing stale: /b's entry for keep.txt carries the
    "is a folder" duplicate flag while the record (same sequence) is a file.
    Not a stale entry: never to be repaired on the Mac."""
    device = format_image(path)
    v = device.mount()
    assert v
    assert LIB.nk_mkdir(v, b'/', b'b') == 0
    assert LIB.nk_create(v, b'/b', b'keep.txt') == 0
    folder = mft(listing(v, '/')['b'][0])
    ref = listing(v, '/b')['keep.txt'][0]
    unmount(v)
    device.close()
    sector = geometry(path)[0]
    data = unprotect(read_record(path, folder), sector)
    for entry, entry_ref, _ in index_root_entries(data):
        if entry_ref == ref:
            at = entry + 16 + 56  # INDEX_ENTRY header, then FILE_NAME_ATTR.file_attributes
            flags = struct.unpack_from('<I', data, at)[0]
            struct.pack_into('<I', data, at, flags | FILE_ATTR_I30_INDEX_PRESENT)
            break
    else:
        raise AssertionError('entry not found')
    write_record(path, folder, protect(data, sector))
    return {'folder': folder, 'record': mft(ref), 'entry_seq': seq(ref), 'record_seq': seq(ref)}
