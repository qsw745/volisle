#!/usr/bin/env python3
"""Authenticated native transaction + real NTFS on detached 64 MiB fixtures."""
import json
import base64
import struct
import ctypes as C
from pathlib import Path
import shutil
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO
from fixture_block_journal import sha

OUT = ROOT / '.workbench/device-recovery-20260925'
UPSTREAM = ROOT / '.workbench/ntfs-3g-2026.7.7'
BIN = UPSTREAM / 'ntfsprogs'
SENTINEL = b'authenticated-native-transaction-sentinel\n' * 256


def main():
    OUT.mkdir(exist_ok=True, parents=True)
    subprocess.run(['clang', '-target', 'arm64-apple-macos26.4', '-c', '-fPIC', '-DHAVE_CONFIG_H',
                    '-I', str(UPSTREAM), '-I', str(UPSTREAM / 'include'),
                    'packages/VolisleNTFS/bridge/ntfs_bridge.c', '-o', str(OUT / 'ntfs_bridge.o')], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_BLOCK_JOURNAL_TESTING', '-import-objc-header', 'packages/VolisleNTFS/bridge/ntfs_bridge.h',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalStore.swift',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalTransaction.swift',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalAuthority.swift',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalRollback.swift',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalDeviceSession.swift',
                    'packages/VolisleCore/Sources/VolisleCore/BlockJournalDeviceRecovery.swift',
                    'scripts/fixtures/detached_recovery_device.swift',
                    'apps/extension/Sources/MetadataWritePipeline.swift',
                    'apps/extension/Sources/NTFSReadOnlyInspection.swift',
                    'scripts/fixtures/block_transaction_engine_driver.swift', str(OUT / 'ntfs_bridge.o'),
                    str(UPSTREAM / 'libntfs-3g/.libs/libntfs-3g.a'), '-framework', 'CoreFoundation',
                    '-o', str(OUT / 'engine-driver')], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOLISLE_BLOCK_JOURNAL_TESTING',
                    '-import-objc-header', 'packages/VolisleNTFS/bridge/ntfs_bridge.h',
                    'apps/extension/Sources/NTFSReadOnlyInspection.swift', 'scripts/test-readonly-inspection.swift',
                    str(OUT / 'ntfs_bridge.o'), str(UPSTREAM / 'libntfs-3g/.libs/libntfs-3g.a'),
                    '-framework', 'CoreFoundation', '-o', str(OUT / 'inspection')], cwd=ROOT, check=True)
    folder = Path(tempfile.mkdtemp(prefix='block-journal-', dir=ROOT / '.workbench'))
    base = folder / 'base.img'
    with base.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], capture_output=True, check=True)
    io = ImageIO(base)
    v = io.mount()
    assert v and LIB.nk_create(v, b'/', b'sentinel') == 0
    assert LIB.nk_write(v, b'/sentinel', 0, len(SENTINEL), SENTINEL) == len(SENTINEL)
    assert LIB.nk_umount(v) == 0
    io.close()
    original = sha(base.read_bytes())
    checks, counts = [], {}
    success = False

    def invoke(image, mode, fault, point, block, expected):
        p = subprocess.run([OUT / 'engine-driver', image, mode, fault, str(point), str(block)],
                           cwd=ROOT, capture_output=True, timeout=30)
        assert p.returncode == expected, (mode, fault, point, block, p.returncode, p.stderr.decode())
        return json.loads(p.stdout) if p.stdout else {}

    def case(kind, fault, point, block):
        image = folder / f'{kind}-{fault}-{point}-{block}.img'
        shutil.copyfile(base, image)
        result = invoke(image, kind, fault, point, block, 86 if fault in ['crash', 'partial', 'committed-crash', 'authority-written', 'authority-durable'] else 0)
        before = sha(image.read_bytes())
        needs_reconcile = fault in ['anchor-before', 'authority-written', 'authority-durable']
        snapshot = invoke(image, 'inspect', 'none', 0, block, 3 if needs_reconcile else 0)
        if needs_reconcile:
            assert snapshot == {'rejected': True}
            assert sha(image.read_bytes()) == before
            checks.append(f'{kind}-{block}-{fault}-{point}-ambiguous-tail-refused-without-write')
            snapshot = invoke(image, 'reconcile', 'none', 0, block, 0)
            assert invoke(image, 'inspect', 'none', 0, block, 0) == snapshot
            assert sha(image.read_bytes()) == before
        if fault in ['none', 'committed-crash']:
            assert snapshot['committed'] and sha(image.read_bytes()) == before
            assert subprocess.check_output([BIN / 'ntfscat', image, '/sentinel']) == SENTINEL
            if kind == 'file':
                assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
            checks.append(f'{kind}-{block}-{fault}-commit-retained')
        else:
            assert not snapshot['committed']
            assert all(w['offset'] % block == 0 for w in snapshot['writes'])
            # Swift now plans AND executes rollback while retaining both leases.
            # Python supplies the independently captured fixture baseline only.
            interrupted = kind == 'file' and block == 4096 and fault == 'crash' and point == 6
            if interrupted:
                invoke(image, 'restore', original, 1, block, 86)
                invoke(image, 'restore', original, -1, block, 86)
                checks.append('native-rollback-full-and-half-write-process-exits')
            restored = invoke(image, 'restore', original, 0, block, 0)
            assert restored['restoredBlocks'] >= 0 and sha(image.read_bytes()) == original
            if interrupted:
                assert invoke(image, 'restore', original, 0, block, 0) == {'restoredBlocks': 0, 'alreadyCompleted': True}
                assert sha(image.read_bytes()) == original
                checks.append('native-rollback-restart-completes-and-terminal-receipt-skips-repeat')
            assert subprocess.check_output([BIN / 'ntfscat', image, '/sentinel']) == SENTINEL
            io = ImageIO(image)
            assert io.inspect() == 0
            v = io.mount()
            assert v and LIB.nk_umount(v) == 0
            io.close()
            checks.append(f'{kind}-{block}-{fault}-{point}-exact-recovery-and-clean-reopen')
        image.unlink()  # Newly created fixture only; original failed images are untouched.
        return result

    try:
        for block in [4096, 16384]:
            for kind in ['file', 'directory']:
                count = case(kind, 'none', 0, block)['writes']
                assert count > 0
                counts[f'{kind}-{block}'] = count
                for fault in ['fail', 'crash', 'partial', 'anchor-before', 'anchor-after', 'authority-written', 'authority-durable']:
                    for point in range(1, count+1):
                        case(kind, fault, point, block)
        case('file', 'committed-crash', 0, 4096)
        for stage in [1001, 1002, 1003, 1004]:
            image = folder / f'completion-{stage}.img'
            shutil.copyfile(base, image)
            invoke(image, 'file', 'crash', 6, 4096, 86)
            invoke(image, 'restore', original, stage, 4096, 86)
            assert sha(image.read_bytes()) == original
            saved = invoke(image, 'restore', original, 0, 4096, 0)
            assert saved == {'restoredBlocks': 0, 'alreadyCompleted': True}
            assert sha(image.read_bytes()) == original
            checks.append(f'completion-publication-crash-{stage}-revalidated-without-repeat-rollback')
            invoke(image, 'file', 'none', 0, 4096, 0)
            changed = sha(image.read_bytes())
            assert changed != original
            assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
            assert invoke(image, 'restore-old', original, 0, 4096, 0) == {'restoredBlocks': 0, 'alreadyCompleted': True}
            assert sha(image.read_bytes()) == changed
            checks.append(f'completed-old-transaction-{stage}-cannot-revert-later-committed-create')
            image.unlink()
        for stage in [0, 1001, 1002, 1003, 1004]:
            image = folder / f'commit-finalization-{stage}.img'
            shutil.copyfile(base, image)
            invoke(image, 'file', 'none', 0, 4096, 0)
            first = sha(image.read_bytes())
            assert first != original
            invoke(image, 'finalize', first, stage, 4096, 86 if stage else 0)
            assert sha(image.read_bytes()) == first
            assert invoke(image, 'finalize', first, 0, 4096, 0) == {'alreadyCompleted': True}
            assert invoke(image, 'restore', original, 0, 4096, 3) == {'rejected': True}
            assert sha(image.read_bytes()) == first
            checks.append(f'committed-finalization-{stage}-durable-and-never-rollback')
            # A second failed transaction rolls back only its own writes.
            if stage == 0:
                invoke(image, 'file-2', 'crash', 6, 4096, 86)
                invoke(image, 'restore', first, 0, 4096, 0)
                assert sha(image.read_bytes()) == first
                assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
                checks.append('second-transaction-recovery-preserves-first-committed-file')
            else:
                invoke(image, 'file-2', 'none', 0, 4096, 0)
                second = sha(image.read_bytes())
                invoke(image, 'finalize', second, 0, 4096, 0)
                assert second != first and sha(image.read_bytes()) == second
                for name in ['/new-node', '/new-node-2']:
                    assert subprocess.check_output([BIN / 'ntfscat', image, name]) == b''
                assert invoke(image, 'restore', original, 0, 4096, 3) == {'rejected': True}
                assert sha(image.read_bytes()) == second
                checks.append(f'two-committed-sessions-{stage}-retain-both-files')
            image.unlink()
        for kind in ['committed', 'recovered']:
            for stage in range(5):
                image = folder / f'retirement-{kind}-{stage}.img'
                shutil.copyfile(base, image)
                invoke(image, 'file', 'none' if kind == 'committed' else 'crash', 0 if kind == 'committed' else 6, 4096, 0 if kind == 'committed' else 86)
                if kind == 'committed':
                    expected = sha(image.read_bytes())
                    invoke(image, 'finalize', expected, 0, 4096, 0)
                else:
                    expected = original
                    invoke(image, 'restore', expected, 0, 4096, 0)
                state = image.with_suffix('.state') / 'authority' / 'anchors.json'
                before = state.read_bytes()
                entry = json.loads(base64.b64decode(json.loads(before)['payload']))['entries'][0]
                transaction = entry['binding']['transactionID']
                log = image.with_suffix('.state') / 'logs' / (transaction.lower()+'.blocklog')
                assert log.is_file()
                invoke(image, 'retire', transaction, stage, 4096, 86 if stage else 0)
                assert invoke(image, 'retire', transaction, 0, 4096, 0) == {'removed': stage == 1}
                assert not log.exists() and state.read_bytes() == before and sha(image.read_bytes()) == expected
                checks.append(f'{kind}-retirement-{stage}-restart-preserves-device-and-terminal')
                invoke(image, 'file-2' if kind == 'committed' else 'file', 'none', 0, 4096, 0)
                latest = sha(image.read_bytes())
                assert invoke(image, 'retire', transaction, 0, 4096, 0) == {'removed': False}
                assert sha(image.read_bytes()) == latest
                assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
                if kind == 'committed':
                    assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node-2']) == b''
                checks.append(f'{kind}-retirement-{stage}-later-write-survives-repeated-retirement')
                image.unlink()
        for stage in [0, 1001, 1002, 1003, 1004]:
            image = folder / f'epoch-{stage}.img'
            shutil.copyfile(base, image)
            old_requests = []
            for cycle in [1, 2]:
                invoke(image, 'file' if cycle == 1 else 'file-2', 'none', 0, 4096, 0)
                expected = sha(image.read_bytes())
                invoke(image, 'finalize', expected, 0, 4096, 0)
                state = image.with_suffix('.state') / 'authority' / 'anchors.json'
                payload = json.loads(base64.b64decode(json.loads(state.read_bytes())['payload']))
                entry = payload['entries'][0]
                request = base64.b64encode(json.dumps(entry['binding']).encode()).decode()
                old_requests.append(request)
                invoke(image, 'retire', entry['binding']['transactionID'], 0, 4096, 0)
                cut = stage if cycle == 1 else 0
                invoke(image, 'epoch', 'none', cut, 4096, 86 if cut else 0)
                assert invoke(image, 'epoch', 'none', 0, 4096, 0) == {'empty': True}
                current = json.loads(base64.b64decode(json.loads(state.read_bytes())['payload']))
                assert current['generation'] == cycle and current['entries'] == []
                for old in old_requests:
                    assert invoke(image, 'old-request', old, 0, 4096, 3) == {'rejected': True}
                assert sha(image.read_bytes()) == expected
                checks.append(f'epoch-{stage}-cycle-{cycle}-cleared-receipts-still-reject-old-requests')
            invoke(image, 'file-3', 'none', 0, 4096, 0)
            for name in ['/new-node', '/new-node-2', '/new-node-3']:
                assert subprocess.check_output([BIN / 'ntfscat', image, name]) == b''
            checks.append(f'epoch-{stage}-third-session-keeps-all-three-files')
            image.unlink()
        for outcome in ['committed', 'recovered']:
            for stage in range(9):
                image = folder / f'managed-{outcome}-{stage}.img'
                shutil.copyfile(base, image)
                invoke(image, 'file', 'none' if outcome == 'committed' else 'crash', 0 if outcome == 'committed' else 6, 4096, 0 if outcome == 'committed' else 86)
                baseline = sha(image.read_bytes()) if outcome == 'committed' else original
                invoke(image, 'finalize' if outcome == 'committed' else 'restore', baseline, 0, 4096, 0)
                state = image.with_suffix('.state') / 'authority' / 'anchors.json'
                entry = json.loads(base64.b64decode(json.loads(state.read_bytes())['payload']))['entries'][0]
                old = base64.b64encode(json.dumps(entry['binding']).encode()).decode()
                old_log = image.with_suffix('.state') / 'logs' / (entry['binding']['transactionID'].lower()+'.blocklog')
                mode = 'auto-file-2' if outcome == 'committed' else 'auto-file'
                if stage:
                    invoke(image, mode, 'maintenance', stage, 4096, 86)
                    assert sha(image.read_bytes()) == baseline
                invoke(image, mode, 'none', 0, 4096, 0)
                current = json.loads(base64.b64decode(json.loads(state.read_bytes())['payload']))
                assert current['generation'] == 1 and len(current['entries']) == 1 and not old_log.exists()
                assert invoke(image, 'old-request', old, 0, 4096, 3) == {'rejected': True}
                expected = sha(image.read_bytes())
                invoke(image, 'finalize', expected, 0, 4096, 0)
                checks.append(f'managed-{outcome}-{stage}-automatic-reclaim-and-new-generation')
                # No explicit retire or epoch call between subsequent real writes.
                invoke(image, 'auto-file-3', 'none', 0, 4096, 0)
                for name in ['/sentinel', '/new-node', '/new-node-3'] + (['/new-node-2'] if outcome == 'committed' else []):
                    assert subprocess.check_output([BIN / 'ntfscat', image, name]) == (SENTINEL if name == '/sentinel' else b'')
                checks.append(f'managed-{outcome}-{stage}-following-session-preserves-earlier-files')
                image.unlink()
        for outcome in ['active', 'committed-unvalidated']:
            image = folder / f'managed-refuse-{outcome}.img'
            shutil.copyfile(base, image)
            invoke(image, 'file', 'crash' if outcome == 'active' else 'none', 6 if outcome == 'active' else 0, 4096, 86 if outcome == 'active' else 0)
            before = sha(image.read_bytes())
            state = image.with_suffix('.state') / 'authority' / 'anchors.json'
            authority_before = state.read_bytes()
            assert invoke(image, 'auto-file-2', 'none', 0, 4096, 3) == {'rejected': True}
            assert sha(image.read_bytes()) == before and state.read_bytes() == authority_before
            checks.append(f'managed-{outcome}-refused-without-device-or-authority-change')
            image.unlink()
        for cut in [0, 1, -1, 1001, 1002, 1003, 1004]:
            image = folder / f'stored-baseline-{cut}.img'
            shutil.copyfile(base, image)
            invoke(image, 'file', 'partial', 4, 4096, 86)
            state = image.with_suffix('.state') / 'authority' / 'anchors.json'
            payload = json.loads(base64.b64decode(json.loads(state.read_bytes())['payload']))
            assert payload['version'] == 6 and payload['entries'][0]['binding']['recoveryBaselineSHA256'] == original
            # No baseline is supplied to either recovery process.
            if cut:
                invoke(image, 'restore-stored', 'none', cut, 4096, 86)
            invoke(image, 'restore-stored', 'none', 0, 4096, 0)
            assert sha(image.read_bytes()) == original
            checks.append(f'stored-baseline-{cut}-restart-recovery-without-external-digest')
            invoke(image, 'auto-file', 'none', 0, 4096, 0)
            first = sha(image.read_bytes())
            invoke(image, 'finalize', first, 0, 4096, 0)
            invoke(image, 'auto-file-2', 'partial', 4, 4096, 86)
            invoke(image, 'restore-stored', 'none', 0, 4096, 0)
            assert sha(image.read_bytes()) == first
            assert subprocess.check_output([BIN / 'ntfscat', image, '/new-node']) == b''
            checks.append(f'stored-baseline-{cut}-new-session-keeps-prior-success')
            image.unlink()
        for fault in ['unlock', 'rename', 'close']:
            image = folder / f'device-fence-{fault}.img'
            shutil.copyfile(base, image)
            invoke(image, 'file', 'crash', 3, 4096, 86)
            before = sha(image.read_bytes())
            state = image.with_suffix('.state')
            authority_before = {str(p.relative_to(state)): sha(p.read_bytes()) for p in state.rglob('*') if p.is_file()}
            assert invoke(image, 'restore-device-fault', fault, 0, 4096, 3) == {'rejected': True}
            assert sha(image.read_bytes()) == before
            assert {str(p.relative_to(state)): sha(p.read_bytes()) for p in state.rglob('*') if p.is_file()} == authority_before
            checks.append(f'device-fence-{fault}-refused-without-write-or-completion')
            if fault == 'rename':
                held = Path(str(image) + '.detached')
                assert sha(held.read_bytes()) == before
                image.unlink()  # New injected replacement only.
                held.rename(image)
            assert invoke(image, 'restore-stored', 'none', 0, 4096, 0)['restoredBlocks'] > 0
            assert sha(image.read_bytes()) == original
            assert subprocess.check_output([BIN / 'ntfscat', image, '/sentinel']) == SENTINEL
            checks.append(f'device-fence-{fault}-fresh-session-recovers-original')
            image.unlink()

        probe = subprocess.run([OUT / 'inspection', base], cwd=ROOT, capture_output=True, check=True, timeout=30)
        observed = json.loads(probe.stdout)
        assert observed['passed'] == 8 and sha(base.read_bytes()) == original
        checks.extend([f'real-readonly-adapter-{i}' for i in range(observed['passed'])])
        (OUT / 'real-inspection.json').write_text(json.dumps(observed, indent=2)+'\n')
        for kind in ['dirty', 'hibernated', 'mirror-corrupt']:
            image = folder / f'health-{kind}.img'
            shutil.copyfile(base, image)
            if kind == 'hibernated':
                device = ImageIO(image)
                volume = device.mount()
                assert volume and LIB.nk_create(volume, b'/', b'hiberfil.sys') == 0
                hiber = C.create_string_buffer(b'hibr'+bytes(4092))
                assert LIB.nk_write(volume, b'/hiberfil.sys', 0, 4096, hiber) == 4096
                assert LIB.nk_umount(volume) == 0
                device.close()
            else:
                with image.open('r+b') as stream:
                    boot = stream.read(512)
                    cluster = struct.unpack_from('<H', boot, 11)[0] * boot[13]
                    cpr = struct.unpack_from('b', boot, 64)[0]
                    record = (1 << -cpr) if cpr < 0 else cpr * cluster
                    if kind == 'mirror-corrupt':
                        stream.seek(struct.unpack_from('<Q', boot, 56)[0]*cluster)
                        stream.write(b'BAD!')
                    else:
                        for location in [48, 56]:
                            pos = struct.unpack_from('<Q', boot, location)[0]*cluster+3*record
                            stream.seek(pos)
                            data = stream.read(record)
                            attr = struct.unpack_from('<H', data, 20)[0]
                            while struct.unpack_from('<I', data, attr)[0] != 0xffffffff:
                                tag, length = struct.unpack_from('<II', data, attr)
                                assert length >= 24 and attr+length <= record
                                if tag == 0x70:
                                    at = pos+attr+struct.unpack_from('<H', data, attr+20)[0]+10
                                    stream.seek(at)
                                    flags = struct.unpack('<H', stream.read(2))[0]
                                    stream.seek(at)
                                    stream.write(struct.pack('<H', flags|1))
                                    break
                                attr += length
                            else: raise AssertionError('missing volume flags')
            before = sha(image.read_bytes())
            assert invoke(image, 'auto-file', 'none', 0, 4096, 3) == {'rejected': True}
            assert not image.with_suffix('.state').exists() and sha(image.read_bytes()) == before
            checks.append(f'{kind}-baseline-capture-refused-before-journal-state')
            # Test-only injection proves matching bytes are not a health certificate.
            invoke(image, 'seed-unsafe-baseline', 'none', 0, 4096, 0)
            state = image.with_suffix('.state') / 'authority' / 'anchors.json'
            saved = state.read_bytes()
            assert invoke(image, 'restore-stored', 'none', 0, 4096, 3) == {'rejected': True}
            assert state.read_bytes() == saved and sha(image.read_bytes()) == before
            checks.append(f'{kind}-matching-baseline-refused-without-restore-or-completion')
            image.unlink()
        success = True
    finally:
        report = {'success': success, 'passed': len(checks), 'checks': checks, 'physicalBlockWrites': counts,
                  'anchorImplementation': 'BlockJournalAuthority', 'rootServiceInstalled': False, 'actualFSKitRuntime': False,
                  'recoveryExecutor': 'native-Swift-with-fixture-baseline', 'durableRecoveryCompletion': True, 'durableCommitCompletion': True, 'explicitTerminalLogRetirement': True, 'generationFenceCompaction': True, 'managedAdmissionAndMaintenance': True, 'durableIndependentBaseline': True, 'readonlyHealthBeforeCaptureAndDuringRestore': True, 'transactionScope': 'clean-mount-to-clean-unmount',
                  'fixture': str(folder)}
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'success': success, 'passed': len(checks), 'report': str(folder / 'result.json')}), flush=True)


if __name__ == '__main__':
    main()
