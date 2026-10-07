#!/usr/bin/env python3
"""R1/R3 matrix: the FSKit extension's journal sources + real NTFS engine on
disposable images. Every interruption point must recover to a clean,
mountable volume whose existing data is intact, and allow the next session."""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
SRC = ROOT / '.workbench/ntfs-3g-2026.7.7'
OUT = ROOT / '.workbench/write-journal-20260925'
SENTINEL = b'unchanged-existing-data' * 128
SOURCES = ['MetadataBlocks', 'MetadataWritePipeline', 'WriteJournalStore', 'WriteJournal', 'WriteJournalRecovery']


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['zsh', 'scripts/build-ntfs-bridge.sh'], cwd=ROOT, check=True)
    subprocess.run(['clang', '-target', 'arm64-apple-macos26.4', '-c', '-fPIC', '-DHAVE_CONFIG_H', '-I', SRC, '-I', SRC / 'include',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.c', '-o', OUT / 'ntfs_bridge.o'], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_WRITE_JOURNAL_TESTING', '-import-objc-header',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.h', *[f'apps/extension/Sources/{n}.swift' for n in SOURCES],
                    'scripts/fixtures/write_journal_driver.swift', OUT / 'ntfs_bridge.o', SRC / 'libntfs-3g/.libs/libntfs-3g.a',
                    '-framework', 'CoreFoundation', '-o', OUT / 'driver'], cwd=ROOT, check=True)


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def make_base(path, size=64 * 1024 * 1024):
    with path.open('xb') as f:
        f.truncate(size)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', path], check=True, capture_output=True)
    io = ImageIO(path); v = io.mount(); assert v
    assert LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0; io.close()


def driver(*args, env=None, expect=None):
    p = subprocess.run([OUT / 'driver', *map(str, args)], capture_output=True, timeout=600,
                       env={**os.environ, **(env or {})})
    if expect is not None:
        assert p.returncode == expect, (args, p.returncode, p.stderr.decode())
    return p


def listing(image):
    p = subprocess.run([BIN / 'ntfsls', '-f', image], capture_output=True)
    assert p.returncode == 0, p.stderr.decode()
    return set(p.stdout.decode().split())


def healthy(image, expect_new, kind='file'):
    names = listing(image)
    marker = {'file': 'new-node', 'directory': 'new-node', 'many': 'many-0', 'big': 'big', 'write': None}[kind]
    if marker:
        assert (marker in names) == expect_new, (kind, names)
    data = subprocess.run([BIN / 'ntfscat', '-f', image, '/sentinel'], capture_output=True, check=True).stdout
    if kind == 'write' and expect_new:
        assert data == SENTINEL + bytes(4096 - len(SENTINEL)) + b'\x5a' * (3 * 1024 * 1024 + 123)
    else:
        assert data == SENTINEL, 'sentinel changed'
    io = ImageIO(image, readonly=True)
    try:
        assert io.inspect() == 0, 'not clean'
    finally:
        io.close()


def records(journal):
    return sorted(p.name for p in journal.iterdir() if p.name not in ('key.bin', 'superseded') and not p.name.endswith('.lock'))


class Matrix:
    def __init__(self, folder):
        self.folder, self.checks, self.counts, self.timings = folder, [], {}, {}

    def fresh(self, base, name):
        image = self.folder / f'{name}.img'; journal = self.folder / f'{name}.journal'
        shutil.copyfile(base, image)
        if journal.exists():
            shutil.rmtree(journal)
        return image, journal

    def recover_ok(self, image, journal, expect='recovered', env=None):
        start = time.monotonic()
        out = json.loads(driver('recover', image, journal, env=env, expect=0).stdout)
        self.timings.setdefault('recover_max_s', 0)
        self.timings['recover_max_s'] = max(self.timings['recover_max_s'], time.monotonic() - start)
        assert out['outcome'] == expect, out
        assert records(journal) == [], records(journal)
        return out

    def next_session(self, image, journal, env):
        # "Next insertion still works": a new journaled session on the same image.
        out = json.loads(driver('op', image, journal, 'next', 'none', 0, env=env, expect=0).stdout)
        assert not out['failed'] and records(journal) == []
        assert 'next-session' in listing(image)

    def case(self, base, kind, fault, n, env, crash):
        name = f'{kind}-{fault}-{n}-{env["BLOCK"]}' + ('-r0' if env.get('RETENTION') == '0' else '')
        image, journal = self.fresh(base, name)
        p = driver('op', image, journal, kind, fault, n, env=env)
        assert p.returncode == (86 if crash else 0), (name, p.returncode, p.stderr.decode())
        if not crash:
            assert json.loads(p.stdout)['failed'], name
        self.recover_ok(image, journal, env=env)
        # A fault after checkpoint B (during unmount) keeps the committed operation
        # only without retention; retained, it is rolled back with its window.
        healthy(image, expect_new=b'COMMITTED' in p.stderr and env.get('RETENTION') == '0', kind=kind)
        self.next_session(image, journal, env)
        self.checks.append(name)
        image.unlink(); shutil.rmtree(journal)

    def run_kind(self, base, kind, env):
        image, journal = self.fresh(base, f'{kind}-none-{env["BLOCK"]}' + ('-r0' if env.get('RETENTION') == '0' else ''))
        out = json.loads(driver('op', image, journal, kind, 'none', 0, env=env, expect=0).stdout)
        assert not out['failed'] and records(journal) == []
        healthy(image, expect_new=True, kind=kind)
        self.recover_ok(image, journal, expect='none', env=env)
        dw, ew = out['deviceWrites'], out['engineWrites']
        self.counts[f'{kind}-{env["BLOCK"]}'] = {'deviceWrites': dw, 'engineWrites': ew}
        self.checks.append(f'{kind}-none-{env["BLOCK"]}' + ('-r0' if env.get('RETENTION') == '0' else ''))
        points = range(1, dw + 1) if dw <= 40 else sorted({1, 2, 3, dw // 2, dw - 1, dw})
        epoints = range(1, ew + 1) if ew <= 40 else sorted({1, 2, 3, 4, ew // 2, ew})
        for fault in ['fail', 'crash', 'partial', 'short']:
            for n in points:
                self.case(base, kind, fault, n, env, crash=fault in ('crash', 'partial'))
        for fault in ['engine-fail', 'engine-crash']:
            for n in epoints:
                self.case(base, kind, fault, n, env, crash=fault == 'engine-crash')
        for n in [1, 2]:
            self.case(base, kind, 'journal-fail', n, env, crash=False)
            self.case(base, kind, 'flush-fail', n, env, crash=False)
        self.case(base, kind, 'journal-crash', 1, env, crash=True)
        self.case(base, kind, 'checkpoint-crash', 1, env, crash=True)


def epoch_frames(data):
    """[(before [(offset, bytes)], after offsets)] per group frame; type 4 also
    carries each written block's sector hashes."""
    at, groups = 0, []
    while at + 5 <= len(data):
        kind, length = data[at], int.from_bytes(data[at + 1:at + 5], 'big')
        payload = data[at + 5:at + 5 + length]
        if kind in (2, 4):
            count, i, before = int.from_bytes(payload[:4], 'big'), 4, []
            for _ in range(count):
                offset, size = int.from_bytes(payload[i:i + 8], 'big'), int.from_bytes(payload[i + 8:i + 12], 'big')
                before.append((offset, payload[i + 12:i + 12 + size])); i += 12 + size
            afters, i, after = int.from_bytes(payload[i:i + 4], 'big'), i + 4, []
            for _ in range(afters):
                after.append(int.from_bytes(payload[i:i + 8], 'big')); i += 40
                if kind == 4:
                    i += 4 + 8 * int.from_bytes(payload[i:i + 4], 'big')
            assert i == len(payload), (kind, i, len(payload))
            groups.append((before, after))
        at += 5 + length + 32
    return groups


def epoch_groups(data):
    """[(before offsets, after offsets)] per group frame."""
    return [([o for o, _ in before], after) for before, after in epoch_frames(data)]


def epoch_befores(data):
    """[[(offset, before bytes)]] per group frame."""
    return [before for before, _ in epoch_frames(data)]


def recovery_interruption(m, base):
    env = {'BLOCK': '4096'}
    image, journal = m.fresh(base, 'reinterrupt-probe')
    driver('op', image, journal, 'file', 'crash', 3, env=env, expect=86)
    probe = json.loads(driver('recover', image, journal, expect=0).stdout)
    total = probe['writes']
    for n in range(1, total + 1):
        for fault in ['crash', 'partial']:
            image, journal = m.fresh(base, f'reinterrupt-{fault}-{n}')
            driver('op', image, journal, 'file', 'crash', 3, env=env, expect=86)
            driver('recover', image, journal, fault, n, expect=86)          # recovery itself interrupted
            driver('recover', image, journal, 'crash', total + 100, expect=0)  # second attempt, no fault hit
            assert records(journal) == [], records(journal)
            healthy(image, expect_new=False)
            m.next_session(image, journal, env)
            m.checks.append(f'recovery-{fault}-{n}')
    # A second recovery attempt after an interrupted one with no retry fault.
    m.checks.append(f'recovery-points-{total}')


def refusals(m, base):
    env = {'BLOCK': '4096'}
    def crashed(name):
        image, journal = m.fresh(base, name)
        driver('op', image, journal, 'file', 'crash', 5, env=env, expect=86)
        return image, journal
    def refused(image, journal, reason):
        before = sha(image)
        out = json.loads(driver('recover', image, journal, expect=0).stdout)
        assert out['outcome'] == f'refused-{reason}' and out['writes'] == 0, out
        assert sha(image) == before and records(journal), 'refusal changed state'
    def superseded(image, journal):
        # Used elsewhere since: never rolled back (zero writes), records archived
        # so they no longer block, and our unreleased dirty marker keeps it read-only.
        before = sha(image)
        out = json.loads(driver('recover', image, journal, expect=0).stdout)
        assert out['outcome'] == 'superseded' and out['writes'] == 0, out
        assert sha(image) == before and records(journal) == [], records(journal)
        archived = list((journal / 'superseded').glob('*/*'))
        assert any(p.name.endswith('.session') for p in archived) and any(p.name.endswith('.epoch') for p in archived), archived
        io = ImageIO(image, readonly=True)
        try:
            assert io.inspect() == 1, 'the interrupted session must leave the volume marked as needing a check'
        finally:
            io.close()
        p = driver('op', image, journal, 'next', 'none', 0, env=env)
        assert p.returncode != 0 or json.loads(p.stdout)['failed'], 'a dirty volume must not start a write session'
        assert sha(image) == before
        # Second time: nothing left to apply.
        assert json.loads(driver('recover', image, journal, expect=0).stdout)['outcome'] == 'none'
    # Windows-style use after the interruption rewrites the $LogFile restart page.
    image, journal = crashed('foreign-logfile')
    record = json.loads((journal / '0123456789abcdef.session').read_bytes()[:-32])
    with image.open('r+b') as f:
        f.seek(record['logfileOffset'] + 100); f.write(b'\x01\x02\x03\x04')
    superseded(image, journal); m.checks.append('supersede-logfile-changed')
    image, journal = crashed('foreign-boot')
    with image.open('r+b') as f:
        f.seek(0x48); f.write(b'\xff' * 8)  # volume serial
    superseded(image, journal); m.checks.append('supersede-boot-changed')
    # A block of a checkpointed, still retained epoch (its writes had completed),
    # changed by someone else. KEEP_ALL_BEFORE: every block has a before-image,
    # so a checkpoint falls every 32 MiB and the file spans two epochs.
    big = {**env, 'BIG_MIB': '40', 'OP_CHECKPOINTS': '1', 'KEEP_ALL_BEFORE': '1'}
    image, journal = m.fresh(base, 'foreign-block-probe')
    total = json.loads(driver('op', image, journal, 'big', 'none', 0, env=big, expect=0).stdout)['deviceWrites']
    image, journal = m.fresh(base, 'foreign-block')
    driver('op', image, journal, 'big', 'crash', total - 300, env=big, expect=86)
    epochs = sorted(journal.glob('*.epoch'))
    assert len(epochs) >= 2, epochs
    newest = {o for g in epoch_groups(epochs[-1].read_bytes()) for o in g[1]}
    offset = next(o for g in epoch_groups(epochs[-2].read_bytes()) for o in g[0] if o not in newest)
    with image.open('r+b') as f:
        f.seek(offset + 2048); f.write(os.urandom(64))
    refused(image, journal, 'foreignChange'); m.checks.append('refuse-block-changed')
    # A drive that loses power with writes in its cache can leave a block of a
    # checkpointed epoch half written: its earlier content with a run of empty
    # sectors (seen on a real USB disk, 2026-10-06), or new and old halves.
    # Those are this host's own writes: recognised sector by sector, rolled back.
    for damage in ['zeroed-run', 'new-and-old']:
        image, journal = m.fresh(base, f'partial-{damage}')
        driver('op', image, journal, 'big', 'crash', total - 300, env=big, expect=86)
        epochs = sorted(journal.glob('*.epoch'))
        newest = {o for g in epoch_groups(epochs[-1].read_bytes()) for o in g[1]}
        candidates = [(o, b) for g in epoch_befores(epochs[-2].read_bytes()) for o, b in g if o not in newest]
        with image.open('rb') as f:
            def suitable(o, b):
                # Zeroing must change the earlier content; new-and-old must mix two different halves.
                if damage == 'zeroed-run': return b[1024:3072] != bytes(2048)
                f.seek(o); now, half = f.read(len(b)), len(b) // 2
                return now[:half] != b[:half] and now[half:] != b[half:]
            offset, before = next((o, b) for o, b in candidates if suitable(o, b))
        with image.open('r+b') as f:
            if damage == 'zeroed-run':
                f.seek(offset); f.write(before)
                f.seek(offset + 1024); f.write(bytes(2048))
            else:
                f.seek(offset + len(before) // 2); f.write(before[len(before) // 2:])
        m.recover_ok(image, journal); healthy(image, expect_new=False, kind='big'); m.next_session(image, journal, env)
        m.checks.append(f'partial-write-{damage}-in-checkpointed-epoch-recovers')
    # Any block of the unfinished epoch may be torn, not only its last group's:
    # delayed writes reach the device whenever the system flushes them.
    image, journal = m.fresh(base, 'torn-early-group')
    driver('op', image, journal, 'big', 'crash', 2100, env={**env, 'BIG_MIB': '20'}, expect=86)
    groups = epoch_befores(sorted(journal.glob('*.epoch'))[-1].read_bytes())
    assert len(groups) >= 2, len(groups)
    final = {o for o, _ in groups[-1]}
    offset, before = next((o, b) for o, b in groups[0] if o not in final and len(b) == 4096)
    with image.open('r+b') as f:
        f.seek(offset + 2048); f.write(before[2048:])  # new first half, old second half
    m.recover_ok(image, journal); healthy(image, expect_new=False, kind='big'); m.next_session(image, journal, env)
    m.checks.append('torn-block-in-early-group-recovers')
    # An epoch whose header never became complete (host full, killed while
    # creating it) recorded no group: it is ignored, not a reason to refuse.
    for tail in [b'', b'\x01\x00\x00']:
        image, journal = crashed(f'headerless-epoch-{len(tail)}')
        newest = sorted(journal.glob('*.epoch'))[-1].name
        serial, number = newest[:-len('.epoch')].split('-')
        (journal / f'{serial}-{int(number, 16) + 1:016x}.epoch').write_bytes(tail)
        m.recover_ok(image, journal); healthy(image, expect_new=False); m.next_session(image, journal, env)
        m.checks.append(f'headerless-epoch-{len(tail)}-ignored')
    # Cleanup after a clean unmount interrupted once the session record is gone:
    # nothing is replayed, and the next session removes the orphan epochs.
    image, journal = m.fresh(base, 'finish-interrupted')
    p = driver('op', image, journal, 'file', 'finish-crash', 0, env=env)
    assert p.returncode == 86 and b'COMMITTED' in p.stderr, (p.returncode, p.stderr.decode())
    assert records(journal) and not any(n.endswith('.session') for n in records(journal)), records(journal)
    out = json.loads(driver('recover', image, journal, expect=0).stdout)
    assert out['outcome'] == 'none' and out['writes'] == 0, out
    healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('cleanup-interrupted-after-session-removed')
    image, journal = crashed('corrupt-frame')
    epoch = sorted(journal.glob('*.epoch'))[-1]
    data = bytearray(epoch.read_bytes()); data[len(data) // 2] ^= 0xff; epoch.write_bytes(data)
    refused(image, journal, 'corrupt'); m.checks.append('refuse-corrupt-frame')
    # Torn tail: a group record cut short never had device effects.
    image, journal = m.fresh(base, 'torn-tail')
    driver('op', image, journal, 'many', 'journal-crash', 1, env=env, expect=86)
    epoch = sorted(journal.glob('*.epoch'))[-1]
    epoch.write_bytes(epoch.read_bytes()[:-7])
    m.recover_ok(image, journal); healthy(image, expect_new=False, kind='many')
    m.checks.append('torn-tail-accepted')
    # Crash while mounted, after a checkpoint, with no operation in flight.
    image, journal = m.fresh(base, 'idle-crash')
    driver('session-crash', image, journal, env=env, expect=86)
    m.recover_ok(image, journal); healthy(image, expect_new=False); m.next_session(image, journal, env)
    m.checks.append('idle-mounted-crash')


def capacity(m, folder):
    base = folder / 'base-512m.img'; make_base(base, 512 * 1024 * 1024)
    # The cap bounds before-images; KEEP_ALL_BEFORE makes every block need one.
    env = {'BLOCK': '4096', 'BIG_MIB': '300', 'KEEP_ALL_BEFORE': '1'}
    image, journal = m.fresh(base, 'capacity')
    start = time.monotonic()
    out = json.loads(driver('op', image, journal, 'big', 'none', 0, env=env, expect=0).stdout)
    m.timings['capacity_stop_s'] = round(time.monotonic() - start, 2)
    assert out['failed'], 'epoch cap did not stop the session'
    journal_bytes = sum(p.stat().st_size for p in journal.glob('*.epoch'))
    assert journal_bytes <= 300 * 1024 * 1024, journal_bytes
    m.timings['capacity_journal_mib'] = round(journal_bytes / 1048576, 1)
    start = time.monotonic()
    m.recover_ok(image, journal)
    m.timings['capacity_recover_s'] = round(time.monotonic() - start, 2)
    healthy(image, expect_new=False, kind='big')
    m.next_session(image, journal, env)
    m.checks.append('epoch-cap-stops-and-recovers')
    # Free space needs no before-images: the same 300 MiB epoch commits and
    # the journal stays small.
    image, journal = m.fresh(base, 'free-space')
    env = {'BLOCK': '65536', 'BIG_MIB': '300'}
    start = time.monotonic()
    p = driver('op', image, journal, 'big', 'none', 0, env=env, expect=0)
    out = json.loads(p.stdout)
    assert not out['failed'] and records(journal) == [], out
    assert out['skipped'] >= 299 * 1024 * 1024, out
    m.timings['write_300mib_free_space_s'] = round(time.monotonic() - start, 2)
    m.timings['free_space_skipped_mib'] = round(out['skipped'] / 1048576, 1)
    data = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True, check=True).stdout
    assert data == b'\xa5' * (300 * 1024 * 1024), len(data)
    m.checks.append('300mib-free-space-no-before-images')
    # Interrupted in the middle of such a write: rolled back, existing data intact.
    for fault, n in [('crash', 40), ('partial', 700), ('crash', 2000)]:
        image, journal = m.fresh(base, f'free-space-{fault}-{n}')
        driver('op', image, journal, 'big', fault, n, env=env, expect=86)
        epoch_mib = sum(q.stat().st_size for q in journal.glob('*.epoch')) / 1048576
        assert epoch_mib < 8, epoch_mib
        m.recover_ok(image, journal, env=env)
        healthy(image, expect_new=False, kind='big')
        m.next_session(image, journal, env)
        m.checks.append(f'free-space-{fault}-{n}-rolls-back')
    # Throughput with a checkpoint, under the cap.
    image, journal = m.fresh(base, 'throughput')
    env = {'BLOCK': '4096', 'BIG_MIB': '200'}
    start = time.monotonic()
    out = json.loads(driver('op', image, journal, 'big', 'none', 0, env=env, expect=0).stdout)
    assert not out['failed']
    m.timings['write_200mib_s'] = round(time.monotonic() - start, 2)
    m.checks.append('200mib-single-epoch-commit')
    # Continuous copy far beyond one epoch: boundary checkpoints keep it bounded.
    image, journal = m.fresh(base, 'long-copy')
    env = {'BLOCK': '4096', 'BIG_MIB': '440', 'OP_CHECKPOINTS': '1'}
    start = time.monotonic()
    out = json.loads(driver('op', image, journal, 'big', 'none', 0, env=env, expect=0).stdout)
    assert not out['failed'] and records(journal) == []
    m.timings['write_440mib_checkpointed_s'] = round(time.monotonic() - start, 2)
    data = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True, check=True).stdout
    assert data == b'\xa5' * (440 * 1024 * 1024), len(data)
    m.checks.append('440mib-continuous-copy-bounded-epochs')
    # Crash after several mid-file checkpoints, over a volume whose free space
    # holds stale data: the surviving prefix must be the written data, never
    # stale content (free-space blocks carry no before-images).
    def pattern(i):
        return bytes(((j * 31) ^ (i * 131) ^ (j >> 12)) & 0xff for j in range(1048576))
    for block, n in [(65536, 16 * 300), (4096, 256 * 300)]:
        image, journal = m.fresh(base, f'stale-free-space-{block}')
        with image.open('wb') as f:
            for _ in range(600):
                f.write(os.urandom(1048576))
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True)
        env = {'BLOCK': str(block), 'BIG_MIB': '440', 'OP_CHECKPOINTS': '1', 'PATTERNED': '1', 'RETENTION': '0'}
        driver('op', image, journal, 'big', 'crash', n, env=env, expect=86)
        m.recover_ok(image, journal, env=env)
        data = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True, check=True).stdout
        assert len(data) >= 128 * 1048576, len(data)
        for i in range(0, len(data), 1048576):
            assert data[i:i + 1048576] == pattern(i // 1048576)[:len(data) - i], (block, i)
        m.checks.append(f'checkpointed-prefix-intact-over-stale-free-space-{block}')
    # A drive cache that loses power undoes part of what the last checkpoint
    # flushed. Without retention that leaves stale data inside the committed
    # file (seen on a real USB disk, 2026-10-04); with it, recovery rolls back
    # over the whole window and the volume is consistent.
    for loss in ['middle', 'scatter']:
        image, journal = m.fresh(base, f'cache-loss-{loss}')
        with image.open('wb') as f:
            for _ in range(600):
                f.write(os.urandom(1048576))
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True)
        env = {'BLOCK': '65536', 'BIG_MIB': '440', 'OP_CHECKPOINTS': '1', 'PATTERNED': '1', 'VOLATILE_LOSS': loss}
        p = driver('op', image, journal, 'big', 'crash', 16 * 300, env=env, expect=86)
        assert b'LOST ' in p.stderr, p.stderr
        m.recover_ok(image, journal, env=env)
        q = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True)
        for i in range(0, len(q.stdout) if q.returncode == 0 else 0, 1048576):
            assert q.stdout[i:i + 1048576] == pattern(i // 1048576)[:len(q.stdout) - i], (loss, i)
        assert subprocess.run([BIN / 'ntfsfix', '-n', image], capture_output=True).returncode == 0
        m.checks.append(f'drive-cache-loss-{loss}-rolls-back-retained-window')
    # A file older than the window, deleted inside it, its clusters reused:
    # those clusters keep before-images, so the old file comes back intact.
    for loss, n in [(None, 16 * 50), ('middle', 16 * 50), ('scatter', 16 * 40)]:
        image, journal = m.fresh(base, f'reuse-{loss}')
        with image.open('wb') as f:
            for _ in range(190):
                f.write(os.urandom(1048576))
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', image], check=True, capture_output=True)
        env = {'BLOCK': '65536', 'BIG_MIB': '150', 'RETENTION': '4', **({'VOLATILE_LOSS': loss} if loss else {})}
        driver('op', image, journal, 'reuse', 'crash', n, env=env, expect=86)
        m.recover_ok(image, journal, env=env)
        old = subprocess.run([BIN / 'ntfscat', '-f', image, '/old'], capture_output=True, check=True).stdout
        assert len(old) == 150 * 1048576, len(old)
        for i in range(0, len(old), 1048576):
            assert old[i:i + 1048576] == pattern(i // 1048576), (loss, i)
        assert subprocess.run([BIN / 'ntfscat', '-f', image, '/new'], capture_output=True).returncode != 0
        m.checks.append(f'reused-clusters-of-file-deleted-in-window-restored-{loss}')


def pattern_mib(i):
    return bytes(((j * 31) ^ (i * 131) ^ (j >> 12)) & 0xff for j in range(1048576))


def unreadable_free_space(m, base):
    # Unreadable sectors in free space (a real USB disk, 2026-10-07): a copy whose
    # pieces end inside cache blocks must not read the rest of such a block first.
    # The fixture fails every read of a block free at the session start until it
    # is written, so any such read fails the write.
    env = {'BLOCK': '65536', 'BIG_MIB': '24', 'PIECE': '200704', 'UNREADABLE_FREE': '1'}
    image, journal = m.fresh(base, 'unreadable-free-space')
    p = driver('op', image, journal, 'odd', 'none', 0, env=env, expect=0)
    out = json.loads(p.stdout)
    assert not out['failed'] and out['unreadableReads'] == 0 and records(journal) == [], (out, p.stderr.decode()[-500:])
    data = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True, check=True).stdout
    assert len(data) == 24 * 1048576, len(data)
    for i in range(0, len(data), 1048576):
        assert data[i:i + 1048576] == pattern_mib(i // 1048576), i
    healthy(image, expect_new=True, kind='big')
    m.next_session(image, journal, {'BLOCK': '65536'})
    m.checks.append('partial-writes-into-unreadable-free-space-read-nothing')
    # Interrupted there: rolled back like any other free-space write.
    for n in [40, 300]:
        image, journal = m.fresh(base, f'unreadable-free-space-crash-{n}')
        driver('op', image, journal, 'odd', 'crash', n, env=env, expect=86)
        m.recover_ok(image, journal, env={'BLOCK': '65536'})
        healthy(image, expect_new=False, kind='big')
        m.next_session(image, journal, {'BLOCK': '65536'})
        m.checks.append(f'partial-writes-into-unreadable-free-space-crash-{n}-rolls-back')


def large_volume(m, folder):
    # 2 TiB sparse image: session start and recovery must not scan the volume.
    base = folder / 'base-2t.img'
    with base.open('xb') as f:
        f.truncate(2 * 1024 ** 4)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', '-c', '4096', base], check=True, capture_output=True, timeout=600)
    io = ImageIO(base); v = io.mount(); assert v
    assert LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0; io.close()
    env = {'BLOCK': '4096'}
    journal = folder / '2t.journal'
    start = time.monotonic()
    out = json.loads(driver('op', base, journal, 'many', 'none', 0, env=env, expect=0).stdout)
    m.timings['2tib_session_total_s'] = round(time.monotonic() - start, 2)
    assert not out['failed']
    driver('op', base, journal, 'directory', 'crash', 3, env=env, expect=86)
    start = time.monotonic()
    m.recover_ok(base, journal)
    m.timings['2tib_recover_s'] = round(time.monotonic() - start, 2)
    healthy(base, expect_new=True, kind='many')      # the completed session stays
    assert 'new-node' not in listing(base)            # the interrupted one is rolled back
    m.checks.append('2tib-sparse-no-full-scan')
    base.unlink()


def full_matrix(m, base, folder):
    # Retained (as shipped) and without retention (the checkpoint logic alone).
    for retention in [{}, {'RETENTION': '0'}]:
        for block in ['4096', '16384', '65536']:
            for kind in ['file', 'directory', 'write', 'many']:
                m.run_kind(base, kind, {'BLOCK': block, **retention})
    recovery_interruption(m, base)
    refusals(m, base)
    capacity(m, folder)
    if '--large' in sys.argv:
        large_volume(m, folder)


def main():
    build()
    folder = Path(tempfile.mkdtemp(prefix='write-journal-', dir=ROOT / '.workbench'))
    m = Matrix(folder)
    result = {'completed': False, 'success': False}
    try:
        base = folder / 'base.img'; make_base(base)
        unreadable_free_space(m, base)
        if '--unreadable-only' not in sys.argv:
            full_matrix(m, base, folder)
        result.update(completed=True, success=True)
    finally:
        result.update(checks=len(m.checks), counts=m.counts, timings=m.timings, folder=str(folder))
        (OUT / 'result.json').write_text(json.dumps({**result, 'names': m.checks}, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    if result['success']:
        shutil.rmtree(folder)


if __name__ == '__main__':
    main()
