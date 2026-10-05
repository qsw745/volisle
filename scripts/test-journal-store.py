#!/usr/bin/env python3
"""Bounded completion archive and interrupted host-log retirement, no disks."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / '.workbench/test-journal-store'
POINTS = ['archive-renamed', 'archive-committed', 'retired-renamed', 'retired-committed',
          'retired-pruned-1', 'retired-pruned-6', 'retired-removed']


def run(mode, path, *args):
    return subprocess.run([DRIVER, mode, path, *map(str, args)], check=True, capture_output=True, text=True).stdout.strip()


def digest(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file()}


def main():
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_JOURNAL_TESTING',
                    ROOT / 'packages/VolisleCore/Sources/VolisleCore/ReplacementJournal.swift',
                    ROOT / 'scripts/test-journal-store.swift', '-o', DRIVER], check=True)
    cases = []
    with tempfile.TemporaryDirectory(prefix='journal-store-', dir=ROOT / '.workbench') as temp:
        root = Path(temp)
        baseline = root / 'baseline'; baseline.mkdir(mode=0o700)
        run('seed', baseline, 300)
        incomplete = baseline / run('unfinished', baseline)
        damaged = baseline / run('unfinished', baseline)
        (damaged / '000003.json').write_text('{')
        originals = {p.name: digest(p) for p in [incomplete, damaged]}
        audit = json.loads(run('audit', baseline))
        assert audit == {'completed': 300, 'unresolved': 2, 'blocksWriting': True}, audit
        assert len(list((baseline / '.completed').iterdir())) == 64
        assert not list((baseline / '.retiring').iterdir())
        for name, files in originals.items(): assert digest(baseline / name) == files
        again = json.loads(run('audit', baseline))
        assert again == {'completed': 64, 'unresolved': 2, 'blocksWriting': True}
        other = json.loads(run('audit-other', baseline))
        assert other == {'completed': 0, 'unresolved': 0, 'blocksWriting': False}
        run('retire', baseline)
        assert len(list((baseline / '.completed').iterdir())) == 64
        cases.append({'case': '300-legacy-completed-plus-unfinished-and-corrupt', 'retained_completed': 64,
                      'unfinished_unchanged': True, 'writes_blocked': True})
        # Real process termination and throwing IO errors in every durable
        # move/deletion stage. A new process completes host-only maintenance.
        clean = root / 'clean'; clean.mkdir(mode=0o700); run('seed', clean, 65)
        for point in POINTS:
            for action in ['crash', 'failure']:
                folder = root / f'{point}-{action}'; shutil.copytree(clean, folder)
                child = subprocess.run([DRIVER, point, folder, action], capture_output=True, text=True)
                assert child.returncode == (86 if action == 'crash' else 0), (point, child.stderr)
                result = json.loads(run('audit', folder))
                assert not result['blocksWriting'] and result['unresolved'] == 0
                assert len(list((folder / '.completed').iterdir())) == 64
                assert not list((folder / '.retiring').iterdir())
                assert len(list(folder.iterdir())) == 2
                cases.append({'boundary': point, 'action': action, 'recovered_in_new_process': True})
        # Unsafe archive objects are never followed or recursively removed.
        for kind in ['symlink', 'unknown', 'corrupt-completed', 'unfinished-completed']:
            folder = root / kind; shutil.copytree(clean, folder)
            run('audit', folder)
            outside = root / f'outside-{kind}'; outside.write_bytes(b'preserve')
            archive = folder / '.completed'; entry = next(archive.iterdir())
            if kind == 'symlink':
                (entry / '000006.json').unlink(); (entry / '000006.json').symlink_to(outside)
            elif kind == 'unknown': (entry / 'do-not-delete').write_bytes(b'preserve')
            elif kind == 'corrupt-completed': (entry / '000006.json').write_text('{')
            else:
                # A valid unfinished chain placed in completed storage is
                # still unresolved. Folder location cannot confer completion.
                (entry / '000004.json').unlink(); (entry / '000005.json').unlink(); (entry / '000006.json').unlink()
            before = {p.name for p in archive.iterdir()}
            result = json.loads(run('audit', folder))
            assert result['blocksWriting'] and result['unresolved'] == 1
            assert {p.name for p in archive.iterdir()} == before and outside.read_bytes() == b'preserve'
            cases.append({'case': kind, 'preserved_and_blocked': True})
        # Neither archive-name collisions nor a replaced archive root may
        # overwrite evidence or redirect pruning outside the host store.
        for kind in ['archive-collision', 'archive-root-symlink']:
            folder = root / kind; folder.mkdir(mode=0o700); run('seed', folder, 1)
            outside = root / f'outside-dir-{kind}'; outside.mkdir(mode=0o700)
            (outside / 'keep').write_text('preserve')
            archive = folder / '.completed'
            if kind == 'archive-root-symlink': archive.symlink_to(outside, target_is_directory=True)
            else:
                archive.mkdir(mode=0o700)
                journal = next(p for p in folder.iterdir() if not p.name.startswith('.'))
                shutil.copytree(journal, archive / journal.name)
            before = digest(folder)
            child = subprocess.run([DRIVER, 'audit', folder], capture_output=True, text=True)
            assert child.returncode != 0 and digest(folder) == before
            assert (outside / 'keep').read_text() == 'preserve'
            cases.append({'case': kind, 'refused_without_overwrite': True})
    report = {'success': True, 'verified_at': datetime.now(timezone.utc).isoformat(), 'cases': cases,
              'scope': 'host application recovery metadata only; no NTFS operations'}
    (ROOT / 'docs/testing/journal-store-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'归档测试通过：{len(cases)} 项；300 份迁移、64 份保留、中断恢复、未完成/损坏记录保留。')


if __name__ == '__main__': main()
