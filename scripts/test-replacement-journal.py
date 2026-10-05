#!/usr/bin/env python3
"""Build and test native replacement recovery, locally and without mounting."""
import json
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.workbench'
SOURCE = ROOT / 'packages/VolisleCore/Sources/VolisleCore/ReplacementJournal.swift'
(ROOT / 'docs/testing').mkdir(parents=True, exist_ok=True)


def run(*args):
    subprocess.run([str(x) for x in args], check=True, cwd=ROOT)


run(ROOT / 'scripts/build-ntfs-bridge.sh')
run('swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos26.4', SOURCE,
    ROOT / 'scripts/test-replacement-journal.swift', '-o', WORK / 'test-replacement-journal')
with tempfile.TemporaryDirectory(prefix='journal-unit-', dir=WORK) as tmp:
    run(WORK / 'test-replacement-journal', tmp)
# Match the host deployment target of the ordinary-file test dylib. The
# actual extension is built independently with its macOS 26.4 target.
run('swiftc', '-swift-version', '6', '-D', 'VOLISLE_JOURNAL_TESTING', '-import-objc-header', ROOT / 'packages/VolisleNTFS/bridge/ntfs_bridge.h',
    SOURCE, ROOT / 'scripts/test-journal-image.swift', WORK / 'libVolisleNTFS.dylib', '-o', WORK / 'test-journal-image')
run('python3', ROOT / 'scripts/test-ntfs-abort.py')
run('python3', ROOT / 'scripts/test-journal-images.py')
run('python3', ROOT / 'scripts/test-journal-lifecycle.py')
run('python3', ROOT / 'scripts/test-journal-store.py')
run('python3', ROOT / 'scripts/test-journal-checkpoint-images.py')
report = {'success': True, 'verified_at': datetime.now(timezone.utc).isoformat(),
          'native_state_and_storage_checks': 'passed', 'host_abort_checks': 'passed',
          'image_result': 'replacement-journal-result.json'}
(ROOT / 'docs/testing/replacement-journal-suite.json').write_text(json.dumps(report, indent=2) + '\n')
