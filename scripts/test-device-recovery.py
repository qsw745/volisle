#!/usr/bin/env python3
"""Local authenticated recovery orchestration tests; no disk devices are opened."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.workbench/device-recovery-20260925'
SOURCES = ['BlockJournalStore', 'BlockJournalTransaction', 'BlockJournalAuthority',
           'BlockJournalRollback', 'BlockJournalDeviceSession', 'BlockJournalDeviceRecovery']


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    executable = OUT / 'test-device-recovery'
    command = ['swiftc', '-swift-version', '6', '-D', 'VOLISLE_BLOCK_JOURNAL_TESTING']
    command += [str(ROOT / f'packages/VolisleCore/Sources/VolisleCore/{name}.swift') for name in SOURCES]
    command += [str(ROOT / 'scripts/test-device-recovery.swift'), '-o', str(executable)]
    with (OUT / 'build-final.log').open('w') as log:
        subprocess.run(command, cwd=ROOT, check=True, timeout=60, stdout=log, stderr=subprocess.STDOUT)
    result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, timeout=60)
    (OUT / 'tests-final.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    match = re.fullmatch(r'passed (\d+): (.+/result.json)\n', result.stdout)
    assert match, result.stdout
    report_path = Path(match[2])
    assert report_path.parent.parent == ROOT / '.workbench'
    assert report_path.parent.name.startswith('device-recovery-')
    report = json.loads(report_path.read_text())
    assert int(match[1]) == report['passed'] == len(report['checks']) == 15
    assert report['physicalDiskTouched'] is False
    (OUT / 'orchestration-result.json').write_text(json.dumps({'report': str(report_path), **report}, indent=2)+'\n')
    print(result.stdout, end='')


if __name__ == '__main__':
    main()
