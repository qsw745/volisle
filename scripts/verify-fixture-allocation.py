#!/usr/bin/env python3
"""Read-only allocation cross-check for detached Volisle 64/512 MiB fixtures.

Uses upstream ntfsinfo/ntfscat; checks allocated runs against each other and
$Bitmap. This is a focused regression check, not a replacement for chkdsk.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
from bundle_manifest import sha256
from fskit_fixture import WORK, ALLOWED_SIZES


def verify(folder):
    folder = Path(folder).absolute()
    if folder.is_symlink() or folder.resolve().parent != WORK.resolve() or not re.fullmatch(r'fskit-readonly-[a-z0-9_]+', folder.name):
        raise ValueError('仅接受本项目的一次性镜像')
    image = folder / 'fixture.img'
    st = image.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size not in ALLOWED_SIZES:
        raise ValueError('镜像不是允许容量的非链接普通文件')
    attached = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))
    if any(Path(x.get('image-path', '')).resolve() == image.resolve() for x in attached.get('images', [])):
        raise ValueError('必须正常卸载并断开镜像后再检查')
    before = sha256(image)
    with image.open('rb') as stream:
        boot = stream.read(512)
    if boot[3:11] != b'NTFS    ' or boot[510:] != b'\x55\xaa':
        raise ValueError('NTFS 引导记录无效')
    cluster_size = struct.unpack_from('<H', boot, 11)[0] * boot[13]
    record_unit = struct.unpack_from('b', boot, 64)[0]
    record_size = 2 ** -record_unit if record_unit < 0 else cluster_size * record_unit
    if record_size != 1024 or cluster_size != 4096:
        raise ValueError('尚未覆盖的镜像几何参数')
    binary = WORK / 'ntfs-3g-2026.7.7/ntfsprogs'

    def run(name, *args):
        return subprocess.check_output([binary / name, *map(str, args)], timeout=15)

    mft = run('ntfscat', image, '/$MFT')
    bitmap = run('ntfscat', image, '/$Bitmap')
    if len(mft) % record_size or not 0 < len(mft) <= 512 * record_size:
        raise ValueError('超出小镜像 MFT 检查范围')
    owners = {}
    errors = []
    used_records = 0
    for index in range(len(mft) // record_size):
        record = mft[index * record_size:(index + 1) * record_size]
        if record[:4] != b'FILE' or not struct.unpack_from('<H', record, 22)[0] & 1:
            continue
        used_records += 1
        info = run('ntfsinfo', '-v', '-i', index, image).decode()
        runs = re.findall(r'^\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+|<HOLE>)\s+(0x[0-9a-f]+)\s*$', info, re.M)
        totals = re.findall(r'^Total runs: (\d+)', info, re.M)
        if len(totals) != 1 or int(totals[0]) != len(runs):
            raise ValueError(f'记录 {index} 的区段未被完整解析')
        for _, lcn, length in runs:
            if lcn == '<HOLE>':
                continue
            start, count = int(lcn, 16), int(length, 16)
            if count <= 0 or start + count > st.st_size // cluster_size:
                raise ValueError(f'记录 {index} 的区段越界')
            for cluster in range(start, start + count):
                if cluster in owners:
                    errors.append({'cluster': cluster, 'records': [owners[cluster], index], 'error': 'cross-linked'})
                owners[cluster] = index
                if cluster // 8 >= len(bitmap) or not bitmap[cluster // 8] & (1 << (cluster % 8)):
                    errors.append({'cluster': cluster, 'record': index, 'error': 'allocated-run-marked-free'})
    if sha256(image) != before:
        raise ValueError('只读检查前后镜像发生变化')
    return {'success': not errors, 'image_sha256': before, 'records_checked': used_records,
            'owned_clusters_checked': len(owners), 'errors': errors,
            'scope': 'run overlap and allocated-run bitmap consistency; not full filesystem validation'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    args = parser.parse_args()
    result = verify(args.fixture)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['success'] else 1)
