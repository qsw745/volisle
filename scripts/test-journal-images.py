#!/usr/bin/env python3
"""Drive the actual native journal and NTFS bridge through process exits."""
import ctypes as C
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from journal_image_recovery import export_checkpoints

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
DRIVER = ROOT / '.workbench/test-journal-image'
OLD = b'old-version' + b'A' * 16384
NEW = b'new-version' + b'B' * 32768
OLD_EDIT = b'OLD-edited!' + b'A' * 16384
NEW_EDIT = b'NEW-edited!' + b'B' * 32768
STAGES = ['prepared', 'replace-intent', 'replace-data', 'published', 'old-intent', 'old-data',
          'old-complete', 'new-intent', 'new-data', 'new-complete', 'reclaimed', 'cleanup-intent',
          'cleanup-deleted', 'cleaned']
EXPECTED = {
    'normal': ('cleaned', 10), 'identity-mismatch': ('published', 8),
    'identity-after-intent': ('cleaning', 9),
    'intent-failure': ('prepared', 1), 'completion-failure': ('writing', 4),
    'cleanup-completion-failure': ('cleaning', 9),
    'prepared': ('prepared', 1), 'replace-intent': ('replacing', 2), 'replace-data': ('replacing', 2),
    'published': ('published', 3), 'old-intent': ('writing', 4), 'old-data': ('writing', 4),
    'old-complete': ('published', 5), 'new-intent': ('writing', 6), 'new-data': ('writing', 6),
    'new-complete': ('published', 7), 'reclaimed': ('published', 8), 'cleanup-intent': ('cleaning', 9),
    'cleanup-deleted': ('cleaning', 9), 'cleaned': ('cleaned', 10)
}


def read(image, path):
    result = subprocess.run([BIN / 'ntfscat', '-f', image, path], capture_output=True, timeout=15)
    return result.stdout if result.returncode == 0 else None


def main():
    report = {'success': False, 'cases': []}
    with tempfile.TemporaryDirectory(prefix='volisle-journal-', dir=ROOT / '.workbench') as tmp:
        root = Path(tmp); base = root / 'base.img'
        with base.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
        subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True, timeout=45)
        io = ImageIO(base); volume = io.mount(); assert volume
        for name, value in [(b'document', OLD), (b'draft', NEW), (b'sentinel', b'untouched')]:
            assert LIB.nk_create(volume, b'/', name) == 0
            assert LIB.nk_write(volume, b'/' + name, 0, len(value), C.create_string_buffer(value)) == len(value)
        assert LIB.nk_umount(volume) == 0; io.close()
        modes = ['normal', 'identity-mismatch', 'identity-after-intent', 'intent-failure', 'completion-failure',
                 'cleanup-completion-failure', *STAGES]
        for mode in modes:
            folder = root / mode; folder.mkdir(); image = folder / 'fixture.img'; shutil.copyfile(base, image)
            child = subprocess.run([DRIVER, mode, folder], capture_output=True, text=True, timeout=30)
            cleanup_fault = mode.startswith('cleanup-write-')
            assert child.returncode == (86 if mode in STAGES or mode.startswith('cleanup-write-crash-') else 0), (mode, child.stderr[-2000:])
            if mode == 'normal':
                count = json.loads(child.stdout)['cleanup_writes']
                assert 0 < count <= 128
                modes.extend(f'cleanup-write-{kind}-{point}' for kind in ['failure', 'crash'] for point in range(1, count + 1))
                report['cleanup_write_points'] = count
                with tempfile.TemporaryDirectory(prefix='fskit-readonly-', dir=ROOT / '.workbench') as scan:
                    shutil.copyfile(image, Path(scan) / 'fixture.img')
                    checked = subprocess.run(['python3', ROOT / 'scripts/verify-fixture-allocation.py', scan],
                                             check=True, capture_output=True, text=True, timeout=45)
                    report['allocation_check'] = json.loads(checked.stdout)
                    assert report['allocation_check']['success']
            before = hashlib.sha256(image.read_bytes()).hexdigest()
            observed = subprocess.run([DRIVER, 'inspect', folder], check=True, capture_output=True, text=True, timeout=15)
            journal = json.loads(observed.stdout)
            assert not journal['cleanupAuthorized']
            assert journal['valid'] == (not mode.endswith('failure')), (mode, journal)
            phase, records = ('cleaning', 9) if cleanup_fault else EXPECTED[mode]
            assert (journal['state']['phase'], journal['records']) == (phase, records), (mode, journal)
            assert journal['state']['reclaimed'] == (records >= 8)
            if phase == 'writing':
                assert journal['state']['pendingRole'] == ('old' if records == 4 else 'new')
            for field, updated, threshold in [('before', OLD_EDIT, 5), ('after', NEW_EDIT, 7)]:
                initial = OLD if field == 'before' else NEW
                assert journal['state'][field]['sha256'] == hashlib.sha256(updated if records >= threshold else initial).hexdigest()
            assert hashlib.sha256(image.read_bytes()).hexdigest() == before
            assert read(image, '/sentinel') == b'untouched'
            io = ImageIO(image)
            dirty = mode in STAGES or mode.endswith('failure') or mode == 'identity-after-intent' or cleanup_fault
            assert io.inspect() == int(dirty)
            if dirty: assert not io.mount() and io.writes == 0
            io.close()
            paths = {p: read(image, p) for p in ['/document', '/draft', '/.old', '/.kept-old']}
            # Verify each durable prefix against literal independently chosen
            # content, not fingerprints produced by the native journal itself.
            if mode in ['prepared', 'replace-intent', 'intent-failure']:
                assert paths['/document'] == OLD and paths['/draft'] == NEW
            else:
                old_edited = mode not in ['replace-data', 'published', 'old-intent']
                new_edited = mode not in ['replace-data', 'published', 'old-intent', 'old-data', 'old-complete', 'new-intent', 'completion-failure']
                assert paths['/document'] == (NEW_EDIT if new_edited else NEW), mode
                if mode in ['normal', 'cleanup-deleted', 'cleaned', 'cleanup-completion-failure']:
                    assert paths['/.old'] is None
                elif mode in ['identity-mismatch', 'identity-after-intent']:
                    assert paths['/.old'] == b'unrelated-backup-name' and paths['/.kept-old'] == OLD_EDIT
                elif cleanup_fault:
                    assert paths['/.old'] in (None, OLD_EDIT)
                else:
                    assert paths['/.old'] == (OLD_EDIT if old_edited else OLD), mode
            if journal['valid']:
                exported = export_checkpoints(folder)
                assert exported['image_unchanged'] and exported['write_callbacks'] == 0
                assert not exported['cleanup_authorized']
                for role, result in exported['versions'].items():
                    output = folder / 'exports' / (role + '.bin')
                    if result['status'] == 'checkpoint-match':
                        expected = (OLD_EDIT if records >= 5 else OLD) if role == 'old' else (
                            NEW_EDIT if records >= 7 else NEW)
                        assert output.read_bytes() == expected
                    else:
                        assert not output.exists()
                assert exported['versions']['old']['status'] == ('checkpoint-mismatch' if mode == 'old-data' else
                    'unavailable' if mode in ['normal', 'identity-mismatch', 'identity-after-intent', 'cleanup-deleted', 'cleaned'] or
                    (cleanup_fault and paths['/.old'] is None) else 'checkpoint-match')
                assert exported['versions']['new']['status'] == ('checkpoint-mismatch' if mode == 'new-data' else 'checkpoint-match')
            else:
                try:
                    export_checkpoints(folder)
                    raise AssertionError('损坏记录被用于导出')
                except ValueError:
                    pass
                assert not (folder / 'exports').exists()
            assert hashlib.sha256(image.read_bytes()).hexdigest() == before
            report['cases'].append({'mode': mode, 'journal_valid': journal['valid'],
                                    'records': journal['records'], 'phase': journal['state']['phase'],
                                    'dirty': dirty, 'readonly_replay_unchanged': True,
                                    'checkpoint_export': exported['versions'] if journal['valid'] else 'refused-invalid-journal'})
    report['success'] = True
    report['verified_at'] = datetime.now(timezone.utc).isoformat()
    report['not_covered'] = ['hardware power loss', 'torn NTFS sectors', 'FSKit replacement callbacks', 'restart cleanup']
    (ROOT / 'docs/testing/replacement-journal-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
