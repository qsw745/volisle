#!/usr/bin/env python3
"""Per-operation crash tests on new, detached 64 MiB regular images only."""
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from ntfs_bridge_test_support import ROOT, LIB, ImageIO, PWRITE
from fixture_operation_journal import OperationJournal, recover_session
import fixture_operation_journal as module
from test_workdir import finish_workdir, make_workdir

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
OLD = b'previously acknowledged data\n' * 256
NEW = b'next acknowledged version\n' * 256


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class SessionIO(ImageIO):
    def __init__(self, image):
        super().__init__(image)
        self.journal = OperationJournal(image, image.with_suffix('.journal'))
        original = self.callbacks[1]
        @PWRITE
        def write(ctx, buf, count, offset):
            try:
                self.journal.before_write(offset, C.string_at(buf, count))
            except Exception:
                return -1
            return original(ctx, buf, count, offset)
        self.protected_write = write
        self.io.pwrite = write

    def operation(self, label, function):
        self.journal.begin(label)
        result = function()
        assert result >= 0, (label, result)
        assert LIB.nk_sync(self.volume) == 0
        self.journal.commit()
        return result

    def setup(self):
        self.journal.begin('mount')
        self.volume = self.mount()
        assert self.volume
        self.journal.commit()
        self.operation('create-stable', lambda: LIB.nk_create(self.volume, b'/', b'stable'))
        self.operation('write-stable', lambda: LIB.nk_write(self.volume, b'/stable', 0, len(OLD), OLD))
        self.operation('create-other', lambda: LIB.nk_create(self.volume, b'/', b'other'))
        self.operation('write-other', lambda: LIB.nk_write(self.volume, b'/other', 0, len(NEW), NEW))

    def close(self):
        self.journal.close()
        super().close()


def action(io, name):
    v = io.volume
    return {
        'create': lambda: LIB.nk_create(v, b'/', b'pending'),
        'mkdir': lambda: LIB.nk_mkdir(v, b'/', b'pending-dir'),
        'overwrite': lambda: LIB.nk_write(v, b'/stable', 3, len(NEW), NEW),
        'truncate': lambda: LIB.nk_truncate(v, b'/stable', 5),
        'rename': lambda: LIB.nk_rename(v, b'/stable', b'/', b'renamed'),
        'delete': lambda: LIB.nk_delete(v, b'/stable'),
    }[name]()


def worker(image, name, fault, point):
    io = SessionIO(image)
    io.setup()
    checkpoint = digest(image)
    image.with_suffix('.checkpoint').write_text(checkpoint)
    if fault == 'between':
        os._exit(86)
    io.journal.begin(name)
    start = io.writes
    if fault == 'crash':
        io.crash_after_write_at = start + point
    if fault == 'write':
        io.fail_write_at = start + point
    if fault == 'sync':
        io.fail_sync_at = io.syncs + 1
    result = action(io, name)
    if fault in ['write', 'sync']:
        synced = LIB.nk_sync(io.volume)
        assert result < 0 or synced < 0
        # Do not run normal unmount writes in a different transaction after a
        # failed operation. This child deliberately terminates the live engine.
        os._exit(86)
    assert result >= 0
    assert LIB.nk_sync(io.volume) == 0
    if fault == 'before-commit':
        os._exit(86)
    if fault == 'commit':
        def fail(*args):
            raise OSError('injected commit marker persistence failure')
        module.append = fail
        try:
            io.journal.commit()
        except OSError:
            os._exit(86)
        raise AssertionError('commit failure not reached')
    io.journal.commit()
    if fault == 'after-commit':
        image.with_suffix('.committed').write_text(digest(image))
        os._exit(86)
    writes = io.writes - start
    # This is one live mount across all operations; unmount gets its own
    # transaction so its dirty-marker clearing also has an explicit boundary.
    io.journal.begin('unmount')
    assert LIB.nk_umount(io.volume) == 0
    io.journal.commit()
    io.close()
    print(json.dumps({'writes': writes}))


def main():
    folder = make_workdir('block-journal-')
    base = folder / 'base.img'
    with base.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
    checks = []
    counts = {}
    complete = False

    def child(name, fault, point=0):
        image = folder / f'{name}-{fault}-{point}.img'
        shutil.copyfile(base, image)
        p = subprocess.run([sys.executable, __file__, '--worker', str(image), name, fault, str(point)],
                           capture_output=True, timeout=60)
        assert p.returncode == (0 if fault == 'none' else 86), (name, fault, point, p.stderr.decode())
        return image, p

    def verify_rollback(image):
        result = recover_session(image, image.with_suffix('.journal'))
        assert result['state'] == 'rolled-back'
        assert digest(image) == image.with_suffix('.checkpoint').read_text()
        assert recover_session(image, image.with_suffix('.journal'))['writes'] == 0
        # A mounted-session checkpoint remains DIRTY: independent forced
        # read-only extraction is evidence of contents, not a clean mount.
        for path, expected in [('/stable', OLD), ('/other', NEW)]:
            assert subprocess.check_output([BIN / 'ntfscat', '-f', image, path], stderr=subprocess.DEVNULL) == expected
        io = ImageIO(image)
        assert io.inspect() == 1
        assert not io.mount()
        io.close()
        image.unlink()

    try:
        for name in ['create', 'mkdir', 'overwrite', 'truncate', 'rename', 'delete']:
            image, p = child(name, 'none')
            counts[name] = json.loads(p.stdout)['writes']
            assert counts[name] > 0
            assert recover_session(image, image.with_suffix('.journal'))['state'] == 'committed'
            io = ImageIO(image)
            assert io.inspect() == 0
            io.close()
            image.unlink()
            checks.append(name + '-continuous-session-clean-close')
            for fault in ['write', 'crash']:
                for point in range(1, counts[name] + 1):
                    image, _ = child(name, fault, point)
                    verify_rollback(image)
                    checks.append(f'{name}-{fault}-{point}-preserves-earlier-commits')
            for fault in ['sync', 'before-commit', 'commit']:
                image, _ = child(name, fault)
                verify_rollback(image)
                checks.append(f'{name}-{fault}-preserves-earlier-commits')
        image, _ = child('create', 'between')
        assert recover_session(image, image.with_suffix('.journal')) == {'state': 'committed', 'writes': 0, 'commits': 5}
        assert digest(image) == image.with_suffix('.checkpoint').read_text()
        checks.append('crash-between-operations-keeps-five-commits')
        image.unlink()
        image, _ = child('overwrite', 'after-commit')
        assert recover_session(image, image.with_suffix('.journal'))['state'] == 'committed'
        assert digest(image) == image.with_suffix('.committed').read_text()
        expected = bytearray(OLD)
        expected[3:3 + len(NEW)] = NEW
        assert subprocess.check_output([BIN / 'ntfscat', '-f', image, '/stable'], stderr=subprocess.DEVNULL) == expected
        checks.append('crash-after-durable-commit-keeps-new-version')
        image.unlink()
        complete = True
    finally:
        report = {'success': complete, 'checks': checks, 'writeCounts': counts,
                  'fixture': str(folder), 'productionIntegrated': False, 'clearsDirtyMarker': False}
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)
        finish_workdir(folder, complete)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        worker(Path(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        main()
