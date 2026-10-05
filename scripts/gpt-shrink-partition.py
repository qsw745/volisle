#!/usr/bin/env python3
"""Shrink one GPT partition in place: keep its start, set its size in 512-byte
sectors. Updates the primary and backup tables and their CRCs. Only shrinks,
only 512-byte sectors, and checks both headers before writing anything.
(macOS's own gpt tool no longer modifies partition tables.)
  gpt-shrink-partition.py /dev/rdiskN START_LBA SECTORS"""
import os
import struct
import sys
import zlib

SECTOR = 512


def read(fd, lba, count):
    os.lseek(fd, lba * SECTOR, os.SEEK_SET)
    data = os.read(fd, count * SECTOR)
    if len(data) != count * SECTOR:
        sys.exit('读取失败')
    return data


def write(fd, lba, data):
    os.lseek(fd, lba * SECTOR, os.SEEK_SET)
    if os.write(fd, data) != len(data):
        sys.exit('写入失败')


def header(fd, lba):
    raw = bytearray(read(fd, lba, 1))
    size = struct.unpack_from('<I', raw, 12)[0]
    if raw[:8] != b'EFI PART' or not 92 <= size <= SECTOR:
        sys.exit(f'LBA {lba} 不是 GPT 头')
    crc = struct.unpack_from('<I', raw, 16)[0]
    struct.pack_into('<I', raw, 16, 0)
    if zlib.crc32(bytes(raw[:size])) != crc:
        sys.exit(f'LBA {lba} 的 GPT 头校验不符')
    entries_lba, count, entry_size, entries_crc = struct.unpack_from('<QIII', raw, 72)
    if entry_size != 128 or not 1 <= count <= 1024:
        sys.exit('不支持的分区表项格式')
    entries = bytearray(read(fd, entries_lba, (count * entry_size + SECTOR - 1) // SECTOR))
    if zlib.crc32(bytes(entries[:count * entry_size])) != entries_crc:
        sys.exit(f'LBA {lba} 的分区表校验不符')
    return raw, size, entries_lba, count, entries


def main():
    device, start, sectors = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if not device.startswith('/dev/rdisk') or 's' in device[len('/dev/rdisk'):] or sectors <= 0:
        sys.exit('用法：gpt-shrink-partition.py /dev/rdiskN START_LBA SECTORS（整盘设备）')
    fd = os.open(device, os.O_RDWR)
    try:
        primary = header(fd, 1)
        backup_lba = struct.unpack_from('<Q', primary[0], 32)[0]
        backup = header(fd, backup_lba)
        if primary[4][:primary[3] * 128] != backup[4][:backup[3] * 128]:
            sys.exit('主表与备份表不一致')
        entries = primary[4]
        matches = [i for i in range(primary[3]) if struct.unpack_from('<Q', entries, i * 128 + 32)[0] == start
                   and any(entries[i * 128:i * 128 + 16])]
        if len(matches) != 1:
            sys.exit(f'没有唯一从 LBA {start} 开始的分区')
        i = matches[0]
        last = struct.unpack_from('<Q', entries, i * 128 + 40)[0]
        new_last = start + sectors - 1
        if new_last > last:
            sys.exit('只允许缩小分区')
        struct.pack_into('<Q', entries, i * 128 + 40, new_last)
        entries_crc = zlib.crc32(bytes(entries[:primary[3] * 128]))
        for raw, size, entries_lba, _, _ in (primary, backup):
            write(fd, entries_lba, bytes(entries))
            struct.pack_into('<I', raw, 88, entries_crc)
            struct.pack_into('<I', raw, 16, 0)
            struct.pack_into('<I', raw, 16, zlib.crc32(bytes(raw[:size])))
            write(fd, struct.unpack_from('<Q', raw, 24)[0], bytes(raw))
        os.fsync(fd)
        print(f'分区 {i + 1}：LBA {start}–{new_last}（原结束 {last}）')
    finally:
        os.close(fd)


main()
