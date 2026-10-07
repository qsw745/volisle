#!/usr/bin/env python3
"""A raw disk image for the test VM, to plug in as a USB drive: one Windows data
partition (GPT, or MBR with --mbr) holding NTFS and a few known files. Built
without mounting it on the host, so neither Finder nor Volisle there touch it.

  make-ntfs-disk.py <out.img> [--size-gb 8] [--label NTFSTEST] [--mbr]

Needs the NTFS tools and bridge the write-journal tests build:
  make -C .workbench/ntfs-3g-2026.7.7/ntfsprogs mkntfs && zsh scripts/build-ntfs-bridge.sh
"""
import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from ntfs_bridge_test_support import LIB, ImageIO  # noqa: E402

MKNTFS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs'
SECTOR = 512
START = 2048  # 1 MiB, as Windows and Disk Utility align
BASIC_DATA = uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7')
CHUNK = 1 << 20


def gpt_layout(size):
    """(partition end LBA, writes) for a GPT disk with one Basic Data partition."""
    last = size // SECTOR - 1
    end = (last - 33 + 1) // START * START - 1
    entry = (BASIC_DATA.bytes_le + uuid.uuid4().bytes_le + struct.pack('<QQQ', START, end, 0)
             + 'Basic data partition'.encode('utf-16-le').ljust(72, b'\0'))
    entries = entry.ljust(128 * 128, b'\0')
    entries_crc = zlib.crc32(entries) & 0xffffffff
    disk = uuid.uuid4()

    def header(current, backup, entries_lba):
        fields = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x00010000, 92, 0, 0, current, backup,
                             34, last - 33, disk.bytes_le, entries_lba, 128, 128, entries_crc)
        crc = zlib.crc32(fields) & 0xffffffff
        return (fields[:16] + struct.pack('<I', crc) + fields[20:]).ljust(SECTOR, b'\0')

    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\x00\x02\x00', 0xEE, b'\xff\xff\xff', 1, min(last, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'
    return end, [(0, bytes(mbr)), (SECTOR, header(1, last, 2)), (2 * SECTOR, entries),
                 ((last - 32) * SECTOR, entries), (last * SECTOR, header(last, 1, last - 32))]


def mbr_layout(size):
    """(partition end LBA, writes) for an MBR disk with one NTFS (0x07) partition."""
    sectors = min(size // SECTOR, 0xffffffff)
    end = sectors // START * START - 1
    mbr = bytearray(SECTOR)
    mbr[440:444] = os.urandom(4)  # disk signature
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0x07, b'\xfe\xff\xff', START, end - START + 1)
    mbr[510:512] = b'\x55\xaa'
    return end, [(0, bytes(mbr))]


def pattern(index):
    """Each MiB distinct, so a damaged or misplaced block shows."""
    seed = hashlib.sha256(index.to_bytes(8, 'little')).digest()
    return (seed * (CHUNK // len(seed)))[:CHUNK]


def populate(volume_path, label):
    io = ImageIO(volume_path)
    try:
        v = io.mount()
        assert v, '无法挂载新建的 NTFS'
        files = {
            b'/read-me.txt': f'盘屿测试盘 {label}：这些文件用来核对读写是否正确。\n'.encode(),
            b'/sentinel.txt': b'unchanged-existing-data\n' * 64,
        }
        assert LIB.nk_mkdir(v, b'/', '照片'.encode()) == 0
        for index in range(3):
            files[f'/照片/样张-{index}.jpg'.encode()] = os.urandom(200_000 + index * 1000)
        for path, data in files.items():
            parent, name = path.rsplit(b'/', 1)
            assert LIB.nk_create(v, parent or b'/', name) == 0, path
            assert LIB.nk_write(v, path, 0, len(data), data) == len(data), path
        assert LIB.nk_create(v, b'/', '大文件.bin'.encode()) == 0
        for index in range(64):
            chunk = pattern(index)
            assert LIB.nk_write(v, '/大文件.bin'.encode(), index * CHUNK, CHUNK, chunk) == CHUNK
        assert LIB.nk_umount(v) == 0
        return {p.decode(): hashlib.sha256(d).hexdigest() for p, d in files.items()} | {
            '/大文件.bin': hashlib.sha256(b''.join(pattern(i) for i in range(64))).hexdigest()}
    finally:
        io.close()


def copy_sparse(source, target, offset):
    """Copies only the chunks that hold data, so the disk image stays sparse."""
    with open(source, 'rb') as src, open(target, 'r+b') as dst:
        position = 0
        while True:
            data = src.read(CHUNK)
            if not data:
                break
            if data.count(0) != len(data):
                dst.seek(offset + position)
                dst.write(data)
            position += len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('out', type=Path)
    parser.add_argument('--size-gb', type=int, default=8)
    parser.add_argument('--label', default='NTFSTEST')
    parser.add_argument('--mbr', action='store_true')
    args = parser.parse_args()
    if args.out.exists():
        parser.error(f'已存在：{args.out}')
    size = args.size_gb << 30
    end, writes = (mbr_layout if args.mbr else gpt_layout)(size)
    with tempfile.TemporaryDirectory(prefix='ntfs-disk-') as temp:
        volume = Path(temp) / 'volume.img'
        with volume.open('xb') as f:
            f.truncate((end - START + 1) * SECTOR)
        subprocess.run([MKNTFS, '-F', '-Q', '-L', args.label, '-p', str(START), volume], check=True, capture_output=True)
        digests = populate(volume, args.label)
        with args.out.open('xb') as f:
            f.truncate(size)
        with args.out.open('r+b') as f:
            for offset, data in writes:
                f.seek(offset)
                f.write(data)
        copy_sparse(volume, args.out, START * SECTOR)
    manifest = args.out.with_suffix('.sha256.txt')
    manifest.write_text(''.join(f'{digest}  {path}\n' for path, digest in sorted(digests.items())), encoding='utf-8')
    print(f'{args.out}：{"MBR" if args.mbr else "GPT"}，{args.size_gb} GB，NTFS 卷“{args.label}”；文件校验值见 {manifest.name}')


if __name__ == '__main__':
    main()
