#!/usr/bin/env python3
"""Durable metadata barrier tests using new, unmounted 64 MiB images only."""
import ctypes as C
import json
from pathlib import Path
import shutil
import subprocess
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from test_workdir import finish_workdir, make_workdir

UPSTREAM = ROOT / '.workbench/ntfs-3g-2026.7.7'
BINARY = ROOT / '.workbench/volume-sync-20260924/probe.dylib'
STAMP = 1701234567


def main():
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['clang', '-shared', '-fPIC', '-DHAVE_CONFIG_H',
                    '-I', str(UPSTREAM), '-I', str(UPSTREAM / 'include'),
                    str(ROOT / 'scripts/fixtures/volume_sync_probe.c'),
                    str(UPSTREAM / 'libntfs-3g/.libs/libntfs-3g.a'),
                    '-framework', 'CoreFoundation', '-o', str(BINARY)], check=True)
    lib = C.CDLL(str(BINARY), use_errno=True)
    for name in ['nk_mount_io', 'nk_sync', 'nk_umount', 'nk_create', 'nk_inspect']:
        getattr(lib, name).argtypes = getattr(LIB, name).argtypes
        getattr(lib, name).restype = getattr(LIB, name).restype
    for name in ['probe_dirty', 'probe_time']:
        getattr(lib, name).argtypes = [C.c_void_p, C.c_int]
        getattr(lib, name).restype = C.c_longlong if name == 'probe_time' else C.c_int
    lib.probe_stage.argtypes = [C.c_void_p, C.c_int, C.c_longlong]
    lib.probe_stage.restype = C.c_int
    lib.probe_pending_security_index.argtypes = [C.c_void_p, C.c_int, C.c_int]
    lib.probe_pending_security_index.restype = C.c_int
    lib.probe_close_security.argtypes = [C.c_void_p]
    lib.probe_close_security.restype = C.c_int
    folder = make_workdir('volume-sync-')
    base = folder / 'base.img'
    with base.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    subprocess.run([UPSTREAM / 'ntfsprogs/mkntfs', '-F', '-Q', base], capture_output=True, check=True)
    checks = []
    counts = {}
    success = False

    def opened(name, readonly=False):
        image = folder / (name + '.img')
        shutil.copyfile(base, image)
        io = ImageIO(image, readonly=readonly)
        v = lib.nk_mount_io(C.byref(io.io), None, 0)
        assert v
        return image, io, v

    def verify_snapshot(image, kind, expected):
        clone = folder / 'readback.img'
        shutil.copyfile(image, clone)
        io = ImageIO(clone, readonly=True)
        v = lib.nk_mount_io(C.byref(io.io), None, 0)
        assert v, 'independent read-only reopen failed'
        assert lib.probe_time(v, kind) == expected, (kind, 'durable timestamp missing')
        assert lib.nk_umount(v) == 0
        assert io.writes == 0
        io.close()
        clone.unlink()

    try:
        for kind, label in enumerate(['volume', 'bitmap', 'mft', 'mft-mirror', 'security']):
            image, io, v = opened(label)
            assert lib.probe_stage(v, kind, STAMP + kind) == 0
            assert lib.probe_dirty(v, kind) == 1
            writes, syncs = io.writes, io.syncs
            assert lib.nk_sync(v) == 0
            assert lib.probe_dirty(v, kind) == 0, label + ': sync reported success with dirty metadata in memory'
            counts[label] = io.writes - writes
            assert counts[label] > 0 and io.syncs > syncs
            verify_snapshot(image, kind, STAMP + kind)
            assert lib.nk_inspect(C.byref(io.io)) == 1, 'sync must not clear owned dirty marker'
            writes = io.writes
            assert lib.nk_sync(v) == 0 and io.writes == writes
            assert lib.nk_create(v, b'/', b'after-sync') == 0
            assert lib.nk_umount(v) == 0
            assert lib.nk_inspect(C.byref(io.io)) == 0
            io.close()
            image.unlink()
            checks.append(label + '-flush-durable-readback-marker-retained-and-reuse')
            for point in range(1, counts[label] + 1):
                image, io, v = opened(label + '-fail-' + str(point))
                assert lib.probe_stage(v, kind, STAMP + kind) == 0
                io.fail_write_at = io.writes + point
                assert lib.nk_sync(v) == -1
                writes = io.writes
                io.fail_write_at = None
                assert lib.nk_sync(v) == -1
                assert lib.nk_create(v, b'/', b'must-not-create') == -1
                assert io.writes == writes
                assert lib.nk_umount(v) == -1
                io.close()
                checks.append(label + f'-write-{point}-failure-locks-session')
            image, io, v = opened(label + '-flush-fail')
            assert lib.probe_stage(v, kind, STAMP + kind) == 0
            io.fail_sync_at = io.syncs + 1
            assert lib.nk_sync(v) == -1
            io.fail_sync_at = None
            writes = io.writes
            assert lib.nk_sync(v) == -1
            assert lib.nk_create(v, b'/', b'must-not-create') == -1
            assert io.writes == writes
            assert lib.nk_umount(v) == -1
            io.close()
            checks.append(label + '-device-flush-failure-locks-session')
        for index in [0, 1]:
            image, io, v = opened('pending-security-' + str(index))
            assert lib.probe_pending_security_index(v, index, 1) == 0
            writes = io.writes
            assert lib.nk_sync(v) == -1
            assert io.writes == writes
            # Remove the synthetic pending flag before releasing its context;
            # the sticky write failure must survive that state change.
            assert lib.probe_pending_security_index(v, index, 0) == 0
            assert lib.nk_sync(v) == -1
            assert lib.nk_create(v, b'/', b'must-not-create') == -1
            assert lib.nk_umount(v) == -1
            io.close()
            checks.append(f'pending-security-index-{index}-refuses-and-locks-session')
        image, io, v = opened('closed-security')
        assert lib.probe_close_security(v) == 0
        # Upstream leaves index pointers stale when secure_ni becomes NULL.
        writes = io.writes
        assert lib.nk_sync(v) == 0 and io.writes == writes
        assert lib.nk_create(v, b'/', b'after-security-close') == 0
        assert lib.nk_umount(v) == 0
        io.close()
        checks.append('closed-security-context-is-not-dereferenced')
        image, io, v = opened('all-held-inodes')
        for kind in range(5):
            assert lib.probe_stage(v, kind, STAMP + kind) == 0
        assert lib.nk_sync(v) == 0
        for kind in range(5):
            assert lib.probe_dirty(v, kind) == 0
            verify_snapshot(image, kind, STAMP + kind)
        assert lib.nk_umount(v) == 0
        io.close()
        checks.append('all-held-system-inodes-share-one-durable-barrier')
        image, io, v = opened('creation-held-metadata')
        assert lib.probe_stage(v, 1, STAMP) == 0
        assert lib.nk_create(v, b'/', b'creation-barrier') == 0
        assert lib.probe_dirty(v, 1) == 0, 'creation left held bitmap metadata unflushed'
        verify_snapshot(image, 1, STAMP)
        assert lib.nk_umount(v) == 0
        io.close()
        checks.append('creation-uses-complete-metadata-barrier')
        image, io, v = opened('readonly', readonly=True)
        assert lib.nk_sync(v) == 0
        assert io.writes == 0 and io.syncs == 0
        assert lib.nk_umount(v) == 0
        io.close()
        checks.append('readonly-sync-never-calls-writable-callback')
        assert lib.nk_sync(None) == -1
        checks.append('null-volume-refused')
        success = True
    finally:
        report = {'success': success, 'checks': checks, 'metadataWriteCounts': counts, 'fixture': str(folder)}
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)
        finish_workdir(folder, success)


if __name__ == '__main__':
    main()
