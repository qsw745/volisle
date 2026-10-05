#!/usr/bin/env python3
"""Write journal on BitLocker volumes: the FSKit extension's journal sources and
the real engine (scripts/fixtures/write_journal_driver.swift with BDE_KEY) on
copies of the images Windows 11 encrypted (.workbench/bitlocker-fixtures). The
journal works on ciphertext; every interruption must roll back to a clean
volume whose Windows files are intact, keep BitLocker's own regions and the
volume flags as Windows left them, and allow the next session. Recovery
without the key must refuse without writing."""
import ctypes as C
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, IO

SRC = ROOT / '.workbench/ntfs-3g-2026.7.7'
OUT = ROOT / '.workbench/write-journal-20260925'
FIXTURES = ROOT / '.workbench/bitlocker-fixtures'
SOURCES = ['MetadataBlocks', 'MetadataWritePipeline', 'WriteJournalStore', 'WriteJournal', 'WriteJournalRecovery']
PASSWORD = 1
LIB.nk_bde_open.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_bde_open.restype = C.c_void_p
LIB.nk_bde_io.argtypes = [C.c_void_p]
LIB.nk_bde_io.restype = IO
LIB.nk_bde_close.argtypes = [C.c_void_p]
LIB.nk_bde_derive_key.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_bde_derive_key.restype = C.c_int
LIB.nk_volume_state.argtypes = [C.POINTER(IO), C.POINTER(C.c_uint16), C.POINTER(C.c_longlong), C.POINTER(C.c_longlong)]
LIB.nk_volume_state.restype = C.c_int
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['zsh', 'scripts/build-ntfs-bridge.sh'], cwd=ROOT, check=True)
    subprocess.run(['clang', '-target', 'arm64-apple-macos26.4', '-c', '-fPIC', '-DHAVE_CONFIG_H', '-I', SRC, '-I', SRC / 'include',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.c', '-o', OUT / 'ntfs_bridge.o'], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_WRITE_JOURNAL_TESTING', '-import-objc-header',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.h', *[f'apps/extension/Sources/{n}.swift' for n in SOURCES],
                    'scripts/fixtures/write_journal_driver.swift', OUT / 'ntfs_bridge.o', SRC / 'libntfs-3g/.libs/libntfs-3g.a',
                    '-framework', 'CoreFoundation', '-o', OUT / 'driver'], cwd=ROOT, check=True)


def driver(*args, env=None, expect=None):
    p = subprocess.run([OUT / 'driver', *map(str, args)], capture_output=True, timeout=900, env={**os.environ, **(env or {})})
    if expect is not None:
        assert p.returncode == expect, (args, p.returncode, p.stderr.decode()[-800:])
    return p


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pattern(index):
    """Same bytes as the driver's pattern(_:)."""
    return bytes(((j * 31) ^ (index * 131) ^ (j >> 12)) & 0xff for j in range(1 << 20))


def reserved(raw):
    metas = [struct.unpack_from('<Q', raw, 176 + 8 * i)[0] for i in range(3)]
    sector = struct.unpack_from('<H', raw, 11)[0]
    block = raw[metas[0]:metas[0] + 64]
    store = struct.unpack_from('<Q', block, 56)[0], struct.unpack_from('<I', block, 28)[0] * sector
    return [(m, 65536) for m in metas] + [store]


def derive(image, password):
    device = ImageIO(image, readonly=True)
    out, err = C.create_string_buffer(65), C.create_string_buffer(96)
    assert LIB.nk_bde_derive_key(C.byref(device.io), PASSWORD, password.encode(), out, err, 96) == 0, err.value
    device.close()
    return out.value.decode()


class Decrypted:
    """Read-only decrypted view of an image."""
    def __init__(self, image, password):
        self.device = ImageIO(image, readonly=True)
        self.handle = LIB.nk_bde_open(C.byref(self.device.io), PASSWORD, password.encode(), None, 0)
        assert self.handle
        self.io = LIB.nk_bde_io(self.handle)

    def flags(self):
        value, a, b = C.c_uint16(), C.c_longlong(), C.c_longlong()
        assert LIB.nk_volume_state(C.byref(self.io), C.byref(value), C.byref(a), C.byref(b)) == 0
        return value.value

    def files(self, paths):
        v = LIB.nk_mount_io(C.byref(self.io), None, 0)
        assert v
        found = {}
        for path, size in paths:
            buf = C.create_string_buffer(max(1, size))
            n = LIB.nk_read(v, path.encode(), 0, size, buf)
            found[path] = sha(buf.raw[:size]) if n == size else None
        assert LIB.nk_umount(v) == 0
        return found

    def close(self):
        LIB.nk_bde_close(self.handle)
        self.device.close()


def healthy(image, meta, initial_flags, raw_before, new=()):
    view = Decrypted(image, meta['password'])
    assert LIB.nk_inspect(C.byref(view.io)) == 0, '卷是干净的'
    assert view.flags() == initial_flags, hex(view.flags())
    expected = {'/' + f['path']: f['sha256'] for f in meta['files']}
    got = view.files([('/' + f['path'], f['size']) for f in meta['files']] + [(p, s) for p, s, _ in new])
    view.close()
    for path, digest in expected.items():
        assert got[path] == digest, ('Windows 写的文件', path)
    for path, _, digest in new:
        assert got[path] == digest, ('新文件', path)
    raw = image.read_bytes()
    for start, length in reserved(raw_before):
        assert raw[start:start + length] == raw_before[start:start + length], 'BitLocker 保留区域不变'
    assert raw[:512] == raw_before[:512], 'BitLocker 卷头不变'


def records(journal):
    return sorted(p.name for p in journal.iterdir() if p.suffix in ('.session', '.epoch')) if journal.exists() else []


build()
names = ['xts128', 'xts256', 'cbc128', 'cbc256']
metas = {n: json.loads((FIXTURES / f'{n}.json').read_text(encoding='utf-8-sig')) for n in names}
originals = {n: (FIXTURES / f'{n}.img').read_bytes() for n in names}
cases = 0

with tempfile.TemporaryDirectory(prefix='volisle-bde-journal-', dir=ROOT / '.workbench') as tmp:
    tmp = Path(tmp)

    def fresh(n, label):
        image, journal = tmp / f'{n}-{label}.img', tmp / f'{n}-{label}-journal'
        image.write_bytes(originals[n])
        shutil.rmtree(journal, ignore_errors=True)  # the store creates its own directory
        return image, journal

    for n in names:
        meta, key = metas[n], derive(FIXTURES / f'{n}.img', metas[n]['password'])
        env = {'BDE_KEY': key, 'BLOCK': '4096', 'BIG_MIB': '6', 'PATTERNED': '1'}
        view = Decrypted(FIXTURES / f'{n}.img', meta['password'])
        initial = view.flags()
        view.close()

        # 1. A whole session: committed, finished, nothing left behind.
        image, journal = fresh(n, 'clean')
        out = json.loads(driver('op', image, journal, 'big', 'none', 0, env=env, expect=0).stdout)
        assert not out['failed'] and records(journal) == [] and out['skipped'] == 0, out
        big = b''.join(pattern(i) for i in range(6))
        healthy(image, meta, initial, originals[n], new=[('/big', len(big), sha(big))])
        assert json.loads(driver('recover', image, journal, env=env, expect=0).stdout)['outcome'] == 'none'
        writes = out['deviceWrites']
        cases += 1

        # 2. Interrupted anywhere: rolled back to the last retained checkpoint.
        points = sorted({1, 2, 3, writes // 4, writes // 2, writes - 1, writes})
        for kind in ('file', 'big'):
            for fault in ('crash', 'partial'):
                for point in points if kind == 'big' else (1, 2, 3):
                    image, journal = fresh(n, f'{kind}-{fault}-{point}')
                    p = driver('op', image, journal, kind, fault, point, env=env)
                    assert p.returncode in (0, 86), p.stderr.decode()[-400:]
                    out = json.loads(driver('recover', image, journal, env=env, expect=0).stdout)
                    assert out['outcome'] in ('recovered', 'none'), out
                    assert records(journal) == []
                    healthy(image, meta, initial, originals[n])
                    nxt = json.loads(driver('op', image, journal, 'next', 'none', 0, env=env, expect=0).stdout)
                    assert not nxt['failed'] and records(journal) == []
                    cases += 1
        for point in (2, 5, 20):
            image, journal = fresh(n, f'engine-{point}')
            p = driver('op', image, journal, 'big', 'engine-crash', point, env=env)
            assert p.returncode in (0, 86)
            assert json.loads(driver('recover', image, journal, env=env, expect=0).stdout)['outcome'] in ('recovered', 'none')
            healthy(image, meta, initial, originals[n])
            cases += 1

        # 3. A drive cache that loses part of what the last flush "made durable".
        for loss in ('middle', 'scatter'):
            image, journal = fresh(n, f'loss-{loss}')
            lossy = {**env, 'VOLATILE_LOSS': loss, 'OP_CHECKPOINTS': '1', 'BIG_MIB': '24'}
            p = driver('op', image, journal, 'big', 'crash', 400, env=lossy)
            assert p.returncode in (0, 86)
            assert json.loads(driver('recover', image, journal, env=env, expect=0).stdout)['outcome'] in ('recovered', 'none')
            healthy(image, meta, initial, originals[n])
            cases += 1

        # 4. Recovery needs the key to read the volume: without it, refuse and write nothing.
        image, journal = fresh(n, 'nokey')
        assert driver('op', image, journal, 'big', 'crash', writes // 2, env=env).returncode == 86
        before = image.read_bytes()
        out = json.loads(driver('recover', image, journal, env={'BLOCK': '4096'}, expect=0).stdout)
        assert out['outcome'].startswith('refused') and out['writes'] == 0, out
        assert image.read_bytes() == before and records(journal) != []
        assert json.loads(driver('recover', image, journal, env=env, expect=0).stdout)['outcome'] == 'recovered'
        healthy(image, meta, initial, originals[n])
        cases += 1
        print(f'  {n}：{meta["method"]} 通过（完整会话写入 {writes} 次）', flush=True)

passed('四种加密方式：完整会话提交并清除记录；新文件读回一致；BitLocker 保留区域、卷头与 Windows 的卷标志不变')
passed('新建与大文件写入在任意写入点崩溃或半写后，恢复到干净卷，Windows 写的文件完好，下一次会话正常')
passed('引擎写入中途崩溃、硬盘缓存丢失部分已刷盘数据后，恢复结果同样干净完整')
passed('没有密钥时恢复流程拒绝且零写入、记录保留；带上密钥后正常恢复')
assert all((FIXTURES / f'{n}.img').read_bytes() == originals[n] for n in names)
passed('四块原始加密镜像在全部测试前后逐字节不变')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks, 'cases': cases,
          'fixtures': {n: metas[n]['method'] for n in names},
          'scope': '扩展写入日志源码 + 真实引擎，Windows 11 生成的 BitLocker 镜像副本；块设备为测试替身；不涉及 FSKit 或实盘'}
(ROOT / 'docs/testing/bitlocker-journal-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过，{cases} 个场景')
