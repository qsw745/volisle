#!/usr/bin/env python3
"""Read-only: compares the first four $MFT records with their $MFTMirr copies
and prints what differs ($Volume, record 3, holds the volume flags, including
the "needs a check" bit this host sets for a write session).

Opens the image or device read-only and writes nothing to it. A device needs
--serial (the volume serial as the extension logs it), so the wrong disk is
refused; reading a raw device needs root, which this script never asks for.

    python3 scripts/ntfs_mirror_records.py image.img
    sudo python3 -I scripts/ntfs_mirror_records.py /dev/diskNsM --serial ce9ebe7ff726b67f [--save folder]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys

RECORDS = ['$MFT', '$MFTMirr', '$LogFile', '$Volume']
DIRTY = 0x0001
ALIGN = 4096


def pread_aligned(fd, count, offset):
    """Raw devices only take whole sectors: read the covering aligned span."""
    start = offset // ALIGN * ALIGN
    end = (offset + count + ALIGN - 1) // ALIGN * ALIGN
    data = os.pread(fd, end - start, start)
    if len(data) < offset - start + count:
        raise OSError(f'short read at {offset}')
    return data[offset - start:offset - start + count]


def layout(boot):
    if boot[3:11] != b'NTFS    ':
        raise ValueError('not an NTFS boot sector')
    sector = struct.unpack_from('<H', boot, 0x0b)[0]
    per_cluster = boot[0x0d]
    # Above 128 the field is a negative power of two (clusters over 64 KiB).
    cluster = sector * (per_cluster if per_cluster <= 0x80 else 1 << (256 - per_cluster))
    mft, mirror = struct.unpack_from('<QQ', boot, 0x30)
    size = struct.unpack_from('<b', boot, 0x40)[0]
    record = size * cluster if size > 0 else 1 << -size
    if sector not in (512, 1024, 2048, 4096) or not 512 <= record <= 4096:
        raise ValueError('implausible NTFS geometry')
    return {'serial': boot[0x48:0x50].hex(), 'cluster': cluster, 'record': record,
            'mft': mft * cluster, 'mirror': mirror * cluster}


def describe(raw):
    """Facts of one on-disk record; `raw` keeps its update sequence fixups."""
    if raw[:4] != b'FILE':
        return {'valid': False, 'magic': raw[:4].hex()}
    usa_offset, usa_count = struct.unpack_from('<HH', raw, 4)
    lsn = struct.unpack_from('<Q', raw, 8)[0]
    attributes, _, in_use = struct.unpack_from('<HHI', raw, 0x14)
    if usa_count < 2 or usa_offset + 2 * usa_count > len(raw) or in_use > len(raw):
        return {'valid': False, 'magic': 'FILE', 'reason': 'header'}
    number = raw[usa_offset:usa_offset + 2]
    fixed, torn = bytearray(raw), []
    for index in range(1, usa_count):
        end = index * 512
        if end > len(raw):
            break
        if raw[end - 2:end] != number:
            torn.append(index - 1)
        fixed[end - 2:end] = raw[usa_offset + 2 * index:usa_offset + 2 * index + 2]
    facts = {'valid': True, 'lsn': lsn, 'updateSequence': struct.unpack('<H', number)[0], 'bytesInUse': in_use,
             'tornSectors': torn, 'sha256': hashlib.sha256(bytes(fixed[:in_use])).hexdigest()}
    at = attributes
    while at + 16 <= in_use:
        kind, length = struct.unpack_from('<II', fixed, at)
        if kind == 0xffffffff or length < 16 or at + length > in_use:
            break
        if kind == 0x70 and fixed[at + 8] == 0:  # resident $VOLUME_INFORMATION
            value = at + struct.unpack_from('<H', fixed, at + 0x14)[0]
            flags = struct.unpack_from('<H', fixed, value + 10)[0]
            facts.update(volumeFlags=f'0x{flags:04x}', dirty=bool(flags & DIRTY), flagsOffset=value + 10)
        at += length
    return facts


def compare(read):
    """`read(count, offset)` → bytes. Returns the report as a dict."""
    geometry = layout(read(512, 0))
    size, report = geometry['record'], {'geometry': geometry, 'records': []}
    for index, name in enumerate(RECORDS):
        entry = {'record': index, 'name': name}
        raws = {}
        for copy in ('mft', 'mirror'):
            offset = geometry[copy] + index * size
            raws[copy] = read(size, offset)
            entry[copy] = {'offset': offset, **describe(raws[copy])}
        length = entry['mft'].get('bytesInUse', size)
        entry['same'] = raws['mft'][:length] == raws['mirror'][:length]
        if not entry['same']:
            entry['differingBytes'] = [i for i in range(size) if raws['mft'][i] != raws['mirror'][i]]
        entry['raw'] = raws
        report['records'].append(entry)
    return report


def verdict(report):
    volume = report['records'][3]
    others = [r['name'] for r in report['records'][:3] if not r['same']]
    if volume['same'] and not others:
        return '四条记录与镜像一致'
    lines = []
    if others:
        lines.append('记录不一致：' + '、'.join(others))
    if not volume['same']:
        a, b = volume['mft'], volume['mirror']
        if a.get('dirty') is not None and a.get('dirty') != b.get('dirty'):
            stale = '$MFTMirr 那份' if b['dirty'] else '$MFT 那份'
            lines.append(f'$Volume（记录 3）两份不一致：{stale}仍带“需要检查”标记，是没写上的旧版本；'
                         f'更新序号 $MFT={a.get("updateSequence")} $MFTMirr={b.get("updateSequence")}')
        else:
            lines.append('$Volume（记录 3）两份不一致，但“需要检查”标记相同；见差异字节')
    return '；'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('target', type=Path)
    parser.add_argument('--serial', help='卷序列号（扩展日志里的写法），读设备时必填')
    parser.add_argument('--save', type=Path, help='把两份记录的原始内容各存一个文件到这个文件夹')
    args = parser.parse_args()
    mode = os.stat(args.target).st_mode
    if not (stat.S_ISREG(mode) or stat.S_ISBLK(mode) or stat.S_ISCHR(mode)):
        sys.exit('只接受普通文件或磁盘设备')
    if not stat.S_ISREG(mode) and not args.serial:
        sys.exit('读设备必须给出 --serial，以免读错盘')
    fd = os.open(args.target, os.O_RDONLY)
    try:
        report = compare(lambda count, offset: pread_aligned(fd, count, offset))
    finally:
        os.close(fd)
    serial = report['geometry']['serial']
    if args.serial and args.serial.lower() not in (serial, bytes.fromhex(serial)[::-1].hex()):
        sys.exit(f'卷序列号不符：盘上 {serial}，期望 {args.serial}；未输出内容')
    for entry in report['records']:
        raws = entry.pop('raw')
        if args.save:
            args.save.mkdir(parents=True, exist_ok=True)
            for copy, data in raws.items():
                (args.save / f'record{entry["record"]}-{copy}.bin').write_bytes(data)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(verdict(report))


if __name__ == '__main__':
    main()
