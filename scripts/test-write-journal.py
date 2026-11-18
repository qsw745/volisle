#!/usr/bin/env python3
"""R1/R3 matrix: the FSKit extension's journal sources + real NTFS engine on
disposable images. Every interruption point must recover to a clean,
mountable volume whose existing data is intact, and allow the next session.

The images folder is removed when the run passes; --keep keeps it anyway."""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from ntfs_mirror_records import compare, verdict
from test_workdir import finish_workdir, make_workdir

BIN = ROOT / '.workbench/ntfs-3g-2026.9.28/ntfsprogs'
SRC = ROOT / '.workbench/ntfs-3g-2026.9.28'
OUT = ROOT / '.workbench/write-journal-20260925'
SENTINEL = b'unchanged-existing-data' * 128
SOURCES = ['MetadataBlocks', 'MetadataWritePipeline', 'WriteJournalStore', 'WriteJournal', 'WriteJournalRecovery']


# VOLISLE_TEST_ARCH=x86_64: the journal and engine under test run as Intel code
# (under Rosetta on Apple silicon); the checks around them stay native.
ARCH = os.environ.get('VOLISLE_TEST_ARCH', 'arm64')


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['zsh', 'scripts/build-ntfs-bridge.sh'], cwd=ROOT, check=True)
    subprocess.run(['clang', '-target', f'{ARCH}-apple-macos26.4', '-c', '-fPIC', '-DHAVE_CONFIG_H', '-I', SRC, '-I', SRC / 'include',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.c', '-o', OUT / 'ntfs_bridge.o'], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-target', f'{ARCH}-apple-macos26.4', '-D', 'VOLISLE_WRITE_JOURNAL_TESTING', '-import-objc-header',
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


def driver(*args, env=None, expect=None, binary='driver'):
    # SINCE_END: by default each run sees the disk again long after the last
    # session ended, past the retention window; '0' is "used again at once".
    p = subprocess.run([OUT / binary, *map(str, args)], capture_output=True, timeout=600,
                       env={**os.environ, 'SINCE_END': '3600', **(env or {})})
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


def ended(journal):
    """A cleanly ended session: its finished record and the epochs it keeps."""
    names = records(journal)
    return (sum(n.endswith('.finished') for n in names) == 1 and any(n.endswith('.epoch') for n in names)
            and all(n.endswith(('.finished', '.epoch')) for n in names))


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
        # "Next insertion still works": a new journaled session on the same image,
        # begun as a write activation does (recovery first).
        out = json.loads(driver('op', image, journal, 'next', 'none', 0, env={**env, 'ACTIVATE': '1'}, expect=0).stdout)
        assert not out['failed'] and ended(journal), records(journal)
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
        assert not out['failed'] and ended(journal), records(journal)
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
    assert not out['failed'] and ended(journal), out
    assert out['skipped'] >= 299 * 1024 * 1024, out
    m.timings['write_300mib_free_space_s'] = round(time.monotonic() - start, 2)
    m.timings['free_space_skipped_mib'] = round(out['skipped'] / 1048576, 1)
    data = subprocess.run([BIN / 'ntfscat', '-f', image, '/big'], capture_output=True, check=True).stdout
    assert data == b'\xa5' * (300 * 1024 * 1024), len(data)
    # Its records name 300 MiB of blocks written into free space: the next
    # connection reads back the newest of them, in device order, within seconds.
    start = time.monotonic()
    m.recover_ok(image, journal, expect='none', env=env)
    m.timings['landing_300mib_free_space_s'] = round(time.monotonic() - start, 2)
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
    assert not out['failed'] and ended(journal), records(journal)
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
    assert not out['failed'] and out['unreadableReads'] == 0 and ended(journal), (out, p.stderr.decode()[-500:])
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


def mirror_report(image):
    with image.open('rb') as f:
        return compare(lambda count, offset: os.pread(f.fileno(), count, offset))


def inspect(image):
    io = ImageIO(image, readonly=True)
    try:
        return io.inspect()
    finally:
        io.close()


def consistent(image):
    """Every listed name of the tests can be read, and ntfsfix finds nothing."""
    unreadable = [n for n in sorted(listing(image)) if n.startswith(('many-', 'new-node', 'next-session', 'sentinel')) and
                  subprocess.run([BIN / 'ntfscat', '-f', image, '/' + n], capture_output=True).returncode != 0]
    return not unreadable and subprocess.run([BIN / 'ntfsfix', '-n', image], capture_output=True).returncode == 0


def finish_cache_loss(m, base):
    # A clean session end, then the cable is pulled while the drive still holds
    # the last writes in its own cache (a real USB disk, 2026-10-11: unplugged
    # 1.1 s after "session ended", $Volume no longer matched its mirror copy and
    # the volume could not be opened at all). The records kept past the end roll
    # the session back to its oldest retained checkpoint, whichever writes were lost.
    block = 4096
    env = {'BLOCK': str(block)}
    geometry = mirror_report(base)['geometry']
    # The cache blocks holding $Volume and its mirror copy: the marker release.
    marker = ','.join(str((geometry[copy] + 3 * geometry['record']) // block * block) for copy in ('mft', 'mirror'))
    cases = [(kind, loss, {}) for kind in ['file', 'many'] for loss in ['last:1', 'first:1', 'window', 'recent']]
    # Unmounted right after the operation, as the real session was. One lost
    # directory block, or the marker release landing while half of the rest does
    # not, left a volume that looked clean and was not.
    cases += [('many', 'last:1', {'UNCHECKPOINTED_END': '1'}), ('many', f'others:{marker}', {'UNCHECKPOINTED_END': '1'})]
    for kind, loss, extra in cases:
        label = loss.split(':')[0] + ('-uncheckpointed' if extra else '') + (loss.split(':')[1][:1] if loss[-2:] == ':1' else '')
        image, journal = m.fresh(base, f'finish-loss-{kind}-{label}')
        p = driver('op', image, journal, kind, 'finish-loss', 0, env={**env, **extra, 'FINISH_LOSS': loss}, expect=86)
        assert b'LOST ' in p.stderr and ended(journal), (p.stderr, records(journal))
        out = m.recover_ok(image, journal, expect='recovered-after-end')
        assert out['writes'] > 0, out
        assert all(r['same'] for r in mirror_report(image)['records']) and inspect(image) == 0 and consistent(image), (kind, loss)
        healthy(image, expect_new=False, kind=kind)   # everything was inside the retention window
        m.next_session(image, journal, env)
        m.checks.append(f'finish-loss-{kind}-{label}')
        image.unlink(); shutil.rmtree(journal)
    # The rollback itself interrupted at every device write, then run again.
    image, journal = m.fresh(base, 'finish-loss-reinterrupt-probe')
    lossy = {**env, 'UNCHECKPOINTED_END': '1', 'FINISH_LOSS': 'last:1'}
    driver('op', image, journal, 'many', 'finish-loss', 0, env=lossy, expect=86)
    total = json.loads(driver('recover', image, journal, expect=0).stdout)['writes']
    for n in range(1, total + 1):
        for fault in ['crash', 'partial']:
            image, journal = m.fresh(base, f'finish-loss-reinterrupt-{fault}-{n}')
            driver('op', image, journal, 'many', 'finish-loss', 0, env=lossy, expect=86)
            driver('recover', image, journal, fault, n, expect=86)
            assert any(x.endswith('.session') for x in records(journal)) and not any(x.endswith('.finished') for x in records(journal))
            m.recover_ok(image, journal, expect='recovered')
            assert inspect(image) == 0 and consistent(image)
            healthy(image, expect_new=False, kind='many')
            m.next_session(image, journal, env)
            image.unlink(); shutil.rmtree(journal)
    m.checks.append(f'finish-loss-rollback-reinterrupted-{total}-points')


def clean_end_records(m, base):
    # What a clean end leaves on record, and every way the next connection
    # disposes of it without touching the device.
    env = {'BLOCK': '4096'}
    again = {**env, 'SINCE_END': '0', 'ACTIVATE': '1'}   # used again inside the retention window

    def ended_session(name, kind='file'):
        image, journal = m.fresh(base, name)
        out = json.loads(driver('op', image, journal, kind, 'none', 0, env=env, expect=0).stdout)
        assert not out['failed'] and ended(journal), records(journal)
        return image, journal

    def untouched(image, journal, expect_records_gone=True, **extra):
        before = sha(image)
        out = json.loads(driver('recover', image, journal, env=extra or None, expect=0).stdout)
        assert out == {'outcome': 'none', 'writes': 0} and sha(image) == before, out
        assert (records(journal) == []) if expect_records_gone else ended(journal), records(journal)

    # Everything reached the device and the window is over: the records go.
    image, journal = ended_session('end-settled')
    untouched(image, journal); healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('clean-end-settled-records-removed')
    # Still inside the window: they stay, across any number of connections.
    image, journal = ended_session('end-in-window')
    untouched(image, journal, expect_records_gone=False, SINCE_END='0')
    untouched(image, journal, expect_records_gone=False, SINCE_END='19')
    # A write session that did not go through this activation's recovery never takes them over.
    before = sha(image)
    p = driver('op', image, journal, 'next', 'none', 0, env={**env, 'SINCE_END': '0'})
    assert p.returncode != 0 and sha(image) == before and ended(journal), (p.returncode, p.stdout)
    m.checks.append('clean-end-in-window-records-kept')
    # Written again inside the window: the session is continued, not restarted.
    out = json.loads(driver('op', image, journal, 'next', 'none', 0, env=again, expect=0).stdout)
    assert not out['failed'] and out['firstEpoch'] > 1 and ended(journal), (out, records(journal))
    assert {'new-node', 'next-session'} <= listing(image)
    healthy(image, expect_new=True); m.recover_ok(image, journal, expect='none')
    m.checks.append('clean-end-in-window-session-continued')
    # A continuation that never gets to write leaves the records as they were:
    # nothing is rolled back for it, in the window or after.
    image, journal = ended_session('continued-never-wrote')
    driver('op', image, journal, 'next', 'none', 0, env={**again, 'STOP_AFTER_BEGIN': '1'}, expect=86)
    assert ended(journal), records(journal)
    untouched(image, journal, expect_records_gone=False, SINCE_END='0')
    untouched(image, journal); healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('continued-session-never-wrote-not-rolled-back')
    # After the window a new session starts from epoch 1.
    image, journal = ended_session('end-then-fresh')
    out = json.loads(driver('op', image, journal, 'next', 'none', 0, env={**env, 'ACTIVATE': '1'}, expect=0).stdout)
    assert not out['failed'] and out['firstEpoch'] == 1 and ended(journal), out
    m.checks.append('clean-end-after-window-fresh-session')
    # The continued session interrupted at every device write: rolled back over
    # the earlier mount's epochs too, since they are still inside the window.
    image, journal = ended_session('continued-probe')
    points = json.loads(driver('op', image, journal, 'next', 'none', 0, env=again, expect=0).stdout)['deviceWrites']
    for n in range(1, points + 1):
        for fault in ['crash', 'partial']:
            image, journal = ended_session(f'continued-{fault}-{n}')
            driver('op', image, journal, 'next', fault, n, env=again, expect=86)
            m.recover_ok(image, journal, expect='recovered')
            assert 'next-session' not in listing(image) and inspect(image) == 0 and consistent(image)
            healthy(image, expect_new=False)
            m.next_session(image, journal, env)
            image.unlink(); shutil.rmtree(journal)
    m.checks.append(f'continued-session-interrupted-{points}-points')
    # The earlier mount's epochs aged out before the interruption: only the
    # continued part is rolled back.
    image, journal = ended_session('continued-aged')
    driver('op', image, journal, 'next', 'crash', 2, env={**again, 'RETENTION': '0'}, expect=86)
    m.recover_ok(image, journal, expect='recovered')
    assert 'next-session' not in listing(image)
    healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('continued-session-aged-epochs-stay')
    # The end interrupted between writing the finished record and removing the
    # session's: it is the finished session.
    image, journal = m.fresh(base, 'finish-interrupted')
    p = driver('op', image, journal, 'file', 'finish-crash', 0, env=env)
    assert p.returncode == 86 and b'COMMITTED' in p.stderr, (p.returncode, p.stderr.decode())
    assert {n.rsplit('.', 1)[1] for n in records(journal)} == {'session', 'finished', 'epoch'}, records(journal)
    untouched(image, journal); healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('end-interrupted-between-records')
    # Removal interrupted once the records' head is gone: nothing is replayed,
    # and the next session removes the orphan epochs.
    image, journal = ended_session('removal-interrupted')
    driver('recover', image, journal, env={'REMOVE_CRASH': '1'}, expect=86)
    assert records(journal) and all(n.endswith('.epoch') for n in records(journal)), records(journal)
    out = json.loads(driver('recover', image, journal, expect=0).stdout)
    assert out == {'outcome': 'none', 'writes': 0}, out
    healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('cleanup-interrupted-after-records-head-removed')

    # Used elsewhere since the clean end: never rolled back, whatever is missing.
    def finished_record(journal):
        return json.loads(next(journal.glob('*.finished')).read_bytes()[:-32])
    image, journal = ended_session('elsewhere-logfile')
    with image.open('r+b') as f:
        f.seek(finished_record(journal)['record']['logfileOffset'] + 100); f.write(b'\x01\x02\x03\x04')
    untouched(image, journal); m.checks.append('clean-end-logfile-changed-records-dropped')
    image, journal = ended_session('elsewhere-boot')
    with image.open('r+b') as f:
        f.seek(0x48); f.write(b'\xff' * 8)
    untouched(image, journal); m.checks.append('clean-end-boot-changed-records-dropped')
    # Another Mac's Volisle wrote to it (its own records folder), both inside and after the window.
    for since in ['0', '3600']:
        image, journal = ended_session(f'elsewhere-other-host-{since}')
        other = journal.with_name(journal.name + '-other')
        if other.exists():
            shutil.rmtree(other)
        out = json.loads(driver('op', image, other, 'next', 'none', 0, env=env, expect=0).stdout)
        assert not out['failed']
        untouched(image, journal, SINCE_END=since)
        assert {'new-node', 'next-session'} <= listing(image) and inspect(image) == 0
        m.checks.append(f'clean-end-other-host-wrote-records-dropped-{since}')
    # Its own writes missing AND someone else's change: still not rolled back.
    lossy = {**env, 'FINISH_LOSS': 'last:1'}
    image, journal = m.fresh(base, 'lost-and-foreign')
    driver('op', image, journal, 'many', 'finish-loss', 0, env=lossy, expect=86)
    offset = next(o for epoch in sorted(journal.glob('*.epoch')) for g in epoch_groups(epoch.read_bytes()) for o in g[0])
    with image.open('r+b') as f:
        f.seek(offset + 2048); f.write(os.urandom(64))
    untouched(image, journal); m.checks.append('clean-end-lost-and-foreign-not-rolled-back')
    # Not every retained epoch is there, or one is cut short: no partial rollback.
    for damage in ['missing', 'truncated']:
        image, journal = m.fresh(base, f'incomplete-{damage}')
        driver('op', image, journal, 'many', 'finish-loss', 0, env=lossy, expect=86)
        epochs = sorted(journal.glob('*.epoch'))
        assert len(epochs) >= 2, epochs
        if damage == 'missing':
            epochs[0].unlink()
        else:
            epochs[-1].write_bytes(epochs[-1].read_bytes()[:-45])   # its checkpoint frame
        untouched(image, journal); m.checks.append(f'clean-end-epochs-{damage}-not-rolled-back')
    # An unreadable finished record vouches for nothing.
    image, journal = ended_session('finished-damaged')
    record = next(journal.glob('*.finished'))
    data = bytearray(record.read_bytes()); data[10] ^= 0xff; record.write_bytes(data)
    untouched(image, journal); m.next_session(image, journal, env)
    m.checks.append('clean-end-finished-record-damaged-dropped')
    # Kept for 30 days.
    image, journal = ended_session('expiry')
    driver('expire', image, journal, 29, expect=0); assert ended(journal), records(journal)
    driver('expire', image, journal, 31, expect=0); assert records(journal) == [], records(journal)
    m.checks.append('clean-end-records-expire')


# The last version that removed every record at a clean end.
BEFORE_FINISHED_RECORDS = '4847f3d6e70098aa5cd893e0039323e0f6791775'


def build_previous():
    """The driver from the sources before finished records; False without that commit (a snapshot without history)."""
    def show(path):
        return subprocess.run(['git', 'show', f'{BEFORE_FINISHED_RECORDS}:{path}'], cwd=ROOT, capture_output=True)
    if show('apps/extension/Sources/WriteJournal.swift').returncode != 0:
        return False
    folder = OUT / 'previous-sources'
    folder.mkdir(exist_ok=True)
    sources = [f'apps/extension/Sources/{n}.swift' for n in SOURCES] + ['scripts/fixtures/write_journal_driver.swift']
    for path in sources:
        (folder / Path(path).name).write_bytes(show(path).stdout)
    subprocess.run(['swiftc', '-swift-version', '6', '-target', f'{ARCH}-apple-macos26.4', '-D', 'VOLISLE_WRITE_JOURNAL_TESTING',
                    '-import-objc-header', 'packages/VolisleNTFS/bridge/ntfs_bridge.h', *[folder / Path(x).name for x in sources],
                    OUT / 'ntfs_bridge.o', SRC / 'libntfs-3g/.libs/libntfs-3g.a', '-framework', 'CoreFoundation',
                    '-o', OUT / 'driver-previous'], cwd=ROOT, check=True)
    return True


def downgrade(m, base):
    # A version from before finished records never reads them: it behaves as it
    # always did, and what it leaves is not mistaken for anything afterwards.
    if not build_previous():
        print('跳过降级用例：仓库里没有引入已结束记录之前的提交', file=sys.stderr)
        return
    env = {'BLOCK': '4096'}
    previous = dict(binary='driver-previous')
    # The old version starts its own session; the stale finished record then vouches for nothing.
    image, journal = m.fresh(base, 'downgrade-clean')
    assert not json.loads(driver('op', image, journal, 'file', 'none', 0, env=env, expect=0).stdout)['failed'] and ended(journal)
    assert json.loads(driver('recover', image, journal, expect=0, **previous).stdout) == {'outcome': 'none', 'writes': 0}
    out = json.loads(driver('op', image, journal, 'next', 'none', 0, env=env, expect=0, **previous).stdout)
    assert not out['failed'] and records(journal) == ['0123456789abcdef.finished'], records(journal)
    before = sha(image)
    out = json.loads(driver('recover', image, journal, expect=0).stdout)
    assert out == {'outcome': 'none', 'writes': 0} and sha(image) == before and records(journal) == [], (out, records(journal))
    assert {'new-node', 'next-session'} <= listing(image)
    healthy(image, expect_new=True)
    m.checks.append('downgrade-old-version-unaffected-stale-record-dropped')
    # The old version's own interrupted session is recovered; the earlier clean session stays.
    image, journal = m.fresh(base, 'downgrade-interrupted')
    assert not json.loads(driver('op', image, journal, 'file', 'none', 0, env=env, expect=0).stdout)['failed']
    driver('op', image, journal, 'next', 'crash', 2, env=env, expect=86, **previous)
    assert {n.rsplit('.', 1)[1] for n in records(journal)} == {'session', 'finished', 'epoch'}, records(journal)
    m.recover_ok(image, journal, expect='recovered')
    assert 'next-session' not in listing(image)
    healthy(image, expect_new=True); m.next_session(image, journal, env)
    m.checks.append('downgrade-old-version-interrupted-session-recovered')


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


def durability_report(m, base):
    # The app confirms a copy once the extension reports it durable: an unplug
    # before that rolls it back, one after it keeps it.
    for when, kept in [('before', False), ('after', True)]:
        image, journal = m.fresh(base, f'durability-{when}')
        p = driver('durability', image, journal, when, env={'BLOCK': '4096'})
        assert p.returncode == 86, (when, p.returncode, p.stderr.decode())
        assert json.loads(p.stdout)['durable'] == kept, p.stdout
        m.recover_ok(image, journal)
        assert ('copied' in listing(image)) == kept, (when, listing(image))
        healthy(image, expect_new=False, kind='write')
        m.checks.append(f'durability-report-{when}-unplug')
        image.unlink(); shutil.rmtree(journal)


def archive_per_volume(m, base):
    # Superseded records are kept per volume: a second disk archiving often
    # must not push out the first disk's last records.
    image, journal = m.fresh(base, 'archive-keep')  # the driver's store creates the folder (0700)
    a, b = '00000000000000aa', '00000000000000bb'
    kept = json.loads(driver('archive-keep', image, journal, a, b, b, b, b, expect=0).stdout)
    assert sum(k.endswith('-' + a) for k in kept) == 1 and sum(k.endswith('-' + b) for k in kept) == 3, kept
    m.checks.append('superseded-records-kept-per-volume')
    image.unlink(); shutil.rmtree(journal)


def records_gone(m, base):
    # The records directory goes away while a session runs (2026-10-15: emptying
    # a Trash holding an app copy with the same identifier deleted the
    # extension's container). The session makes it again and an unplug after
    # that is still recovered, dirty marker released. Moved away (into the
    # Trash) is the same. Before this, the records were gone and the volume
    # stayed marked as needing a check.
    env = {'BLOCK': '4096'}
    for how in ['deleted', 'moved']:
        for when in ['idle', 'change', 'open']:
            image, journal = m.fresh(base, f'records-{how}-{when}')
            p = driver('records-gone', image, journal, how, when, expect=86)
            out = json.loads(p.stdout)
            assert not out['failed'] and not out['missing'], out
            assert '0123456789abcdef.session' in out['records'].split(), out
            # idle: nothing was retained any more. change, open: the last epoch
            # (in the remade directory, or gone with the old one) is not reported
            # safe to unplug before its retention window ends.
            assert out['durableNow'] == (when == 'idle') and out['durableLater'], out
            m.recover_ok(image, journal)
            names = listing(image)
            assert 'copied' in names and 'after' not in names, names
            # The change before the unplug was past its retention window by then
            # (open: it went with the old directory; change: pruned in the new one).
            assert ('late' in names) == (when != 'idle'), (when, names)
            if when == 'open':
                data = subprocess.run([BIN / 'ntfscat', '-f', image, '/late'], capture_output=True, check=True).stdout
                assert data == b'\x4d' * (9 * 1024 * 1024), len(data)
            healthy(image, expect_new=False)
            m.next_session(image, journal, env)
            m.checks.append(f'records-dir-{how}-{when}-remade-and-recovered')
            image.unlink(); shutil.rmtree(journal)
            shutil.rmtree(Path(str(journal) + '.moved'), ignore_errors=True)
    # Nothing can be made where the directory was: the session stops and every
    # change is refused; with no records the volume stays marked as needing a check.
    image, journal = m.fresh(base, 'records-blocked')
    out = json.loads(driver('records-gone', image, journal, 'blocked', 'change', expect=86).stdout)
    assert out['failed'] and out['refused'], out
    journal.unlink(); journal.mkdir(mode=0o700)
    assert json.loads(driver('recover', image, journal, expect=0).stdout)['outcome'] == 'none'
    assert inspect(image) == 1
    m.checks.append('records-dir-blocked-stops-session')
    image.unlink(); shutil.rmtree(journal)


def store_locations(m, base):
    # The store build keeps its records in the app group container; an earlier
    # version left them in the extension's own. Activation recovers both, the
    # older place first, and a refusal there keeps the volume read-only.
    env = {'BLOCK': '4096'}
    image, older = m.fresh(base, 'older-place')
    newer = m.folder / 'older-place.group'
    driver('op', image, older, 'file', 'crash', 3, env=env, expect=86)
    out = json.loads(driver('recover-both', image, newer, older, expect=0).stdout)
    assert out['outcomes'] == ['recovered', 'none'], out
    assert records(older) == [] and records(newer) == [], (records(older), records(newer))
    healthy(image, expect_new=False)
    m.next_session(image, newer, env)
    m.checks.append('store-older-place-recovered')
    image.unlink(); shutil.rmtree(older); shutil.rmtree(newer)
    # Recovered before the kernel mount (no device barrier yet): the older place
    # keeps its records as recovered. The next write session, which begins in
    # the newer place, must clean them up; left there they are refused at the
    # next connection once the volume changed, and the disk stays read-only.
    image, older = m.fresh(base, 'older-recovered')
    newer = m.folder / 'older-recovered.group'
    driver('op', image, older, 'file', 'crash', 3, env=env, expect=86)
    out = json.loads(driver('recover-both', image, newer, older, env={'NOT_DURABLE': '1'}, expect=0).stdout)
    assert out['outcomes'] == ['recovered', 'none'] and records(older), (out, records(older))
    out = json.loads(driver('op', image, newer, 'next', 'none', 0, env={**env, 'RETIRE': str(older)}, expect=0).stdout)
    assert not out['failed'] and records(older) == [], (out, records(older))
    out = json.loads(driver('recover-both', image, newer, older, expect=0).stdout)
    assert out['outcomes'] == ['none', 'none'], out
    assert 'next-session' in listing(image) and 'new-node' not in listing(image)
    healthy(image, expect_new=False)
    m.checks.append('store-older-place-recovered-records-retired')
    image.unlink(); shutil.rmtree(older); shutil.rmtree(newer)
    # An interrupted session still on record in the older place is not dropped: writing is refused.
    image, older = m.fresh(base, 'older-active')
    newer = m.folder / 'older-active.group'
    driver('op', image, older, 'file', 'crash', 3, env=env, expect=86)
    p = driver('op', image, newer, 'next', 'none', 0, env={**env, 'RETIRE': str(older)})
    assert p.returncode != 0 and records(older), (p.returncode, records(older))
    m.checks.append('store-older-place-active-blocks-writes')
    image.unlink(); shutil.rmtree(older); shutil.rmtree(newer)
    # Only the newer place has records; a missing older one is not made.
    image, newer = m.fresh(base, 'newer-place')
    older = m.folder / 'newer-place.container'
    driver('op', image, newer, 'file', 'crash', 3, env=env, expect=86)
    out = json.loads(driver('recover-both', image, newer, older, expect=0).stdout)
    assert out['outcomes'] == ['recovered'] and not older.exists(), out
    healthy(image, expect_new=False)
    m.checks.append('store-newer-place-recovered')
    image.unlink(); shutil.rmtree(newer)
    # Damaged records in the older place: refused, the newer place not consulted, nothing written.
    image, older = m.fresh(base, 'older-refused')
    newer = m.folder / 'older-refused.group'
    driver('op', image, older, 'file', 'crash', 5, env=env, expect=86)
    epoch = sorted(older.glob('*.epoch'))[-1]
    data = bytearray(epoch.read_bytes()); data[len(data) // 2] ^= 0xff; epoch.write_bytes(data)
    before = sha(image)
    out = json.loads(driver('recover-both', image, newer, older, expect=0).stdout)
    assert out == {'outcomes': ['refused-corrupt'], 'writes': 0} and sha(image) == before and records(newer) == [], out
    assert records(older), 'a refusal keeps the records'
    m.checks.append('store-older-place-refusal-stops')
    image.unlink(); shutil.rmtree(older); shutil.rmtree(newer)


def full_matrix(m, base, folder):
    archive_per_volume(m, base)
    durability_report(m, base)
    records_gone(m, base)
    store_locations(m, base)
    # Retained (as shipped) and without retention (the checkpoint logic alone).
    for retention in [{}, {'RETENTION': '0'}]:
        for block in ['4096', '16384', '65536']:
            for kind in ['file', 'directory', 'write', 'many']:
                m.run_kind(base, kind, {'BLOCK': block, **retention})
    recovery_interruption(m, base)
    finish_cache_loss(m, base)
    clean_end_records(m, base)
    downgrade(m, base)
    refusals(m, base)
    capacity(m, folder)
    if '--large' in sys.argv:
        large_volume(m, folder)


def main():
    build()
    folder = make_workdir('write-journal-')
    m = Matrix(folder)
    result = {'completed': False, 'success': False}
    try:
        base = folder / 'base.img'; make_base(base)
        # --quick: only the cases that need no long runs (archive, durability report, records directory gone, store record places).
        if '--quick' in sys.argv:
            archive_per_volume(m, base)
            durability_report(m, base)
            records_gone(m, base)
            store_locations(m, base)
        elif '--finish-loss' in sys.argv:
            finish_cache_loss(m, base)
            clean_end_records(m, base)
            downgrade(m, base)
        else:
            unreadable_free_space(m, base)
        if not {'--unreadable-only', '--quick', '--finish-loss'} & set(sys.argv):
            full_matrix(m, base, folder)
        result.update(completed=True, success=True)
    finally:
        result.update(checks=len(m.checks), counts=m.counts, timings=m.timings, folder=str(folder))
        (OUT / 'result.json').write_text(json.dumps({**result, 'names': m.checks}, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finish_workdir(folder, result['success'], keep='--keep' in sys.argv)


if __name__ == '__main__':
    main()
