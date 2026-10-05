#!/usr/bin/env python3
"""Local host-journal crash matrix. No device mounts or NTFS mutations."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.workbench'
DRIVER = WORK / 'test-journal-lifecycle'
BOUNDARIES = ['checkpoint-created', 'checkpoint-written', 'checkpoint-synced',
              'checkpoint-renamed', 'checkpoint-committed',
              'checkpoint-pruned-1', 'checkpoint-pruned-64', 'checkpoint-pruned-128',
              'checkpoint-prune-committed']


def main():
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_JOURNAL_TESTING',
                    ROOT / 'packages/VolisleCore/Sources/VolisleCore/ReplacementJournal.swift',
                    ROOT / 'scripts/test-journal-lifecycle.swift', '-o', DRIVER], check=True)
    cases = []
    with tempfile.TemporaryDirectory(prefix='journal-lifecycle-', dir=WORK) as tmp:
        root = Path(tmp)
        for generation in [1, 2]:
            for mode in ['normal', *BOUNDARIES]:
                for action in (['normal'] if mode == 'normal' else ['crash', 'failure']):
                    folder = root / f'{generation}-{mode}-{action}'; folder.mkdir()
                    child = subprocess.run([DRIVER, mode, folder, str(generation), action], capture_output=True, text=True)
                    assert child.returncode == (86 if action == 'crash' else 0), (mode, generation, child.stderr)
                    result = json.loads(subprocess.run([DRIVER, 'inspect', folder], check=True, capture_output=True, text=True).stdout)
                    pending = mode in BOUNDARIES[:3]
                    assert result['valid'] == (not pending), (mode, generation, result)
                    assert not result['cleanupAuthorized']
                    # A process exit or failure before the next intent cannot
                    # advance file contents. Prior durable fingerprint survives.
                    edits = 63 if generation == 1 else 127
                    expected = b'new' if mode == 'normal' else f'edit-{edits - 1}'.encode()
                    assert result['state']['after']['sha256'] == hashlib.sha256(expected).hexdigest()
                    assert result['state']['phase'] == 'published'
                    assert result['records'] == (129 if generation == 1 else 257) + (2 if mode == 'normal' else 0)
                    cases.append({'generation': generation, 'boundary': mode, 'action': action,
                                  'valid': result['valid'], 'records': result['records']})
        # A checkpoint must itself be protected; a good tail never hides a
        # truncated, substituted, or corrupt checkpoint. No cleanup on replay.
        import shutil
        baseline = root / '2-normal-normal'
        for kind in ['truncated', 'symlink', 'hardlink', 'tampered', 'missing-tail', 'unknown-file']:
            folder = root / kind; shutil.copytree(baseline, folder)
            checkpoint = folder / 'journal/checkpoint.json'
            if kind == 'truncated': checkpoint.write_bytes(b'{')
            if kind == 'tampered':
                data = bytearray(checkpoint.read_bytes()); data[len(data)//2] ^= 1; checkpoint.write_bytes(data)
            if kind == 'symlink': checkpoint.unlink(); checkpoint.symlink_to(baseline / 'journal/checkpoint.json')
            if kind == 'hardlink': (root / 'extra-hardlink').hardlink_to(checkpoint)
            if kind == 'missing-tail': (folder / 'journal/000258.json').unlink()
            if kind == 'unknown-file': (folder / 'journal/injected').write_text('x')
            result = json.loads(subprocess.run([DRIVER, 'inspect', folder], check=True, capture_output=True, text=True).stdout)
            assert not result['valid'] and not result['cleanupAuthorized'], (kind, result)
            cases.append({'corruption': kind, 'refused': True})
    report = {'success': True, 'verified_at': datetime.now(timezone.utc).isoformat(), 'cases': cases,
              'not_covered': ['hardware power loss', 'torn sectors', 'NTFS writes at checkpoint boundaries']}
    (ROOT / 'docs/testing/journal-lifecycle-result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'检查点测试通过：{len(cases)} 项；双代切换、持久化边界退出/失败、损坏拒绝。')


if __name__ == '__main__': main()
