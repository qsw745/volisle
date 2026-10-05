#!/usr/bin/env python3
"""Mac side of the Windows round trip (R5) and the USB throughput sample (R2).
Only writes inside <mount>/Volisle-Roundtrip-<tag>; never elsewhere."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def extension_rss_mib():
    out = subprocess.run(['ps', '-axo', 'rss=,comm='], capture_output=True, text=True).stdout
    values = [int(l.split()[0]) for l in out.splitlines() if l.strip().endswith('/VolisleFS')]
    return round(max(values) / 1024, 1) if values else None


def write_file(path, data):
    with open(path, 'xb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())


def phase_write(root, big_mib):
    root.mkdir()
    files = {}
    (root / 'mac-edit.txt').write_text('Mac 原始内容\n', encoding='utf-8')
    write_file(root / '中文 名称 🌊.txt', ('盘屿 Mac 写入\n' * 2000).encode())
    batch = root / 'batch'; batch.mkdir()
    start = time.monotonic()
    for index in range(300):
        write_file(batch / f'small-{index:03d}.bin', os.urandom(4096 + index))
    small_s = time.monotonic() - start
    chunk = os.urandom(1 << 20)
    peak = 0
    start = time.monotonic()
    with open(root / 'large.bin', 'xb') as f:
        for index in range(big_mib):
            f.write(chunk)
            if index % 64 == 0:
                peak = max(peak, extension_rss_mib() or 0)
        f.flush(); os.fsync(f.fileno())
    write_s = time.monotonic() - start
    for p in sorted(root.rglob('*')):
        if p.is_file():
            files[str(p.relative_to(root)).replace('/', '\\')] = sha(p)
    start = time.monotonic()
    assert sha(root / 'large.bin') == files['large.bin']
    read_s = time.monotonic() - start
    (root / 'mac-manifest.json').write_text(json.dumps({'files': files}, ensure_ascii=False, indent=1), encoding='utf-8')
    return {'files': len(files), 'small_files_300_s': round(small_s, 2),
            'large_mib': big_mib, 'write_mib_s': round(big_mib / write_s, 1), 'read_mib_s': round(big_mib / read_s, 1),
            'extension_rss_peak_mib': peak}


def phase_mac_edit(root):
    """After Windows: verify its files, edit a Windows-ACL file, add one."""
    manifest = json.loads((root / 'windows-manifest.json').read_text(encoding='utf-8-sig'))
    for name, digest in manifest['files'].items():
        assert sha(root / name.replace('\\', '/')) == digest, name
    inherited = root / 'Win-ACL' / 'inherited.txt'
    # Ordinary overwrite save in place (what simple editors do).
    with open(inherited, 'r+b') as f:
        f.seek(0); f.write('Mac 覆盖保存\n'.encode()); f.truncate(); f.flush(); os.fsync(f.fileno())
    write_file(root / 'Win-ACL' / 'mac-created.txt', 'Mac 在 Windows 权限目录中新建\n'.encode())
    with open(root / 'win-new.txt', 'ab') as f:
        f.write('Mac 追加\n'.encode()); f.flush(); os.fsync(f.fileno())
    files = {}
    for name in ['Win-ACL\\inherited.txt', 'Win-ACL\\mac-created.txt', 'win-new.txt', 'mac-edit.txt']:
        files[name] = sha(root / name.replace('\\', '/'))
    (root / 'mac-manifest-2.json').write_text(json.dumps({'files': files}, ensure_ascii=False, indent=1), encoding='utf-8')
    return {'windows_files_verified': len(manifest['files']), 'mac_edits': len(files)}


def phase_acl2(root):
    """Inheritance on create, and a safe-save style replace from another folder."""
    acl = root / 'Win-ACL'
    write_file(acl / 'mac-created-2.txt', 'Mac 新建（应继承目录权限）\n'.encode())
    (acl / 'mac-dir').mkdir()
    write_file(acl / 'mac-dir' / 'nested.txt', b'nested\n')
    temp = root / '.save-temp-inherited.txt'
    write_file(temp, 'Mac 替换保存\n'.encode())
    os.replace(temp, acl / 'inherited.txt')
    return {'created': 3, 'replaced': 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mount', type=Path)
    parser.add_argument('tag')
    parser.add_argument('phase', choices=['write', 'mac-edit', 'acl2', 'verify'])
    parser.add_argument('--big-mib', type=int, default=1024)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9A-Za-z-]+', args.tag):
        parser.error('tag')
    root = args.mount / f'Volisle-Roundtrip-{args.tag}'
    if args.phase == 'write':
        result = phase_write(root, args.big_mib)
    elif args.phase == 'mac-edit':
        result = phase_mac_edit(root)
    elif args.phase == 'acl2':
        result = phase_acl2(root)
    else:
        manifest = json.loads((root / 'mac-manifest-2.json').read_text(encoding='utf-8'))
        for name, digest in manifest['files'].items():
            assert sha(root / name.replace('\\', '/')) == digest, name
        result = {'verified': len(manifest['files'])}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
