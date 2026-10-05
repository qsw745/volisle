#!/usr/bin/env python3
"""Native Swift aligned writer + real NTFS engine + detached image recovery."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from fixture_block_journal import recover, sha

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
OUT = ROOT / '.workbench/metadata-pipeline-20260924'
SENTINEL = b'previous-existing-content\n' * 256


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Compile current sources directly; never reuse a potentially stale C
    # object left by a previous extension build. No experimental C switches.
    upstream = ROOT / '.workbench/ntfs-3g-2026.7.7'
    subprocess.run(['clang', '-target', 'arm64-apple-macos26.4', '-c', '-fPIC', '-DHAVE_CONFIG_H',
                    '-I', str(upstream), '-I', str(upstream / 'include'),
                    'packages/VolisleNTFS/bridge/ntfs_bridge.c', '-o', str(OUT / 'ntfs_bridge.o')],
                   cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-import-objc-header',
                    'packages/VolisleNTFS/bridge/ntfs_bridge.h',
                    'apps/extension/Sources/MetadataWritePipeline.swift',
                    'scripts/fixtures/metadata_pipeline_driver.swift',
                    str(OUT / 'ntfs_bridge.o'),
                    '.workbench/ntfs-3g-2026.7.7/libntfs-3g/.libs/libntfs-3g.a',
                    '-framework', 'CoreFoundation', '-o', str(OUT / 'driver')], cwd=ROOT, check=True)
    folder = Path(tempfile.mkdtemp(prefix='block-journal-', dir=ROOT / '.workbench'))
    base = folder / 'base.img'
    with base.open('xb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
    io = ImageIO(base)
    v = io.mount()
    assert v
    assert LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0
    io.close()
    original = sha(base.read_bytes())
    checks = []
    counts = {}
    success = False

    def run(kind, fault, point, block):
        image = folder / f'{kind}-{fault}-{point}-{block}.img'
        log = image.with_suffix('.journal')
        shutil.copyfile(base, image)
        p = subprocess.run([OUT / 'driver', image, log, kind, fault, str(point), str(block)],
                           cwd=ROOT, capture_output=True, timeout=30)
        expected = 86 if fault in ['crash', 'partial', 'committed-crash'] else 0
        assert p.returncode == expected, (kind, fault, point, block, p.returncode, p.stderr.decode())
        return image, log, p

    try:
        for block in [4096, 16384]:
            for kind in ['file', 'directory']:
                image, log, p = run(kind, 'none', 0, block)
                count = json.loads(p.stdout)['writes']
                assert count > 0
                counts[f'{kind}-{block}'] = count
                after = sha(image.read_bytes())
                assert recover(image, log)['state'] == 'committed'
                assert sha(image.read_bytes()) == after
                records = [json.loads(line)['payload'] for line in log.read_text().splitlines()]
                writes = [r for r in records if r['kind'] == 'write']
                import base64
                assert all(r['offset'] % block == 0 and len(base64.b64decode(r['before'])) == block for r in writes)
                checks.append(f'{kind}-{block}-native-full-block-log-committed')
                image.unlink()
                for fault in ['fail', 'crash', 'partial', 'journal']:
                    for point in range(1, count + 1):
                        image, log, _ = run(kind, fault, point, block)
                        assert recover(image, log)['state'] == 'rolled-back'
                        assert sha(image.read_bytes()) == original
                        assert recover(image, log)['writes'] == 0
                        assert subprocess.check_output([BIN / 'ntfscat', image, '/sentinel']) == SENTINEL
                        io = ImageIO(image)
                        assert io.inspect() == 0
                        v = io.mount()
                        assert v
                        assert LIB.nk_umount(v) == 0
                        io.close()
                        checks.append(f'{kind}-{block}-{fault}-{point}-exact-recovery-and-reopen')
                        image.unlink()
        image, log, _ = run('file', 'committed-crash', 0, 4096)
        after = sha(image.read_bytes())
        assert recover(image, log)['state'] == 'committed'
        assert sha(image.read_bytes()) == after
        assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
        checks.append('native-committed-then-crash-keeps-created-file')
        image.unlink()
        success = True
    finally:
        report = {'success': success, 'checks': checks, 'physicalBlockWrites': counts,
                  'fixture': str(folder), 'pipelineInExtensionSource': True,
                  'journalInProduction': False, 'actualFSKitRuntime': False}
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
