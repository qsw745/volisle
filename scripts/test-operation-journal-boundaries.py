#!/usr/bin/env python3
"""Protocol/failure boundaries on detached fixture files, no user media."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from ntfs_bridge_test_support import ROOT
import fixture_operation_journal as module
from fixture_operation_journal import OperationJournal, recover_session, parse
from fixture_block_journal import canonical, sha

BIN = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'


def digest(image):
    return sha(image.read_bytes())


def main():
    folder = Path(tempfile.mkdtemp(prefix='block-journal-', dir=ROOT / '.workbench'))
    base = folder / 'base.img'
    with base.open('xb') as stream:
        stream.truncate(64 * 1024 * 1024)
    subprocess.run([BIN / 'mkntfs', '-F', '-Q', base], check=True, capture_output=True)
    checks = []
    complete = False

    def fixture(name, pending=True):
        image = folder / (name + '.img')
        log = image.with_suffix('.journal')
        shutil.copyfile(base, image)
        record = OperationJournal(image, log)
        for number, (offset, data) in enumerate([(100000, b'A' * 40), (200000, b'B' * 40)]):
            record.begin('acknowledged-' + str(number))
            record.before_write(offset, data)
            assert os.pwrite(record.image, data, offset) == len(data)
            record.commit()
        checkpoint = digest(image)
        if pending:
            record.begin('pending')
            for offset, data in [(100010, b'X' * 60), (100025, b'Y' * 60), (200020, b'Z' * 40)]:
                record.before_write(offset, data)
                assert os.pwrite(record.image, data, offset) == len(data)
            os.fsync(record.image)
        return image, log, record, checkpoint

    def refused(image, log):
        before = digest(image)
        try:
            recover_session(image, log)
            raise AssertionError('invalid input accepted')
        except (ValueError, KeyError):
            pass
        assert digest(image) == before

    def rewrite(log, edit):
        events = [json.loads(line)['payload'] for line in log.read_bytes().splitlines()]
        edit(events)
        previous = '0' * 64
        lines = []
        # Recompute the chain to exercise protocol validation, not just hashes.
        for index, value in enumerate(events):
            value.update(sequence=index, previous=previous)
            previous = sha(canonical(value))
            lines.append(canonical({'payload': value, 'sha256': previous}))
        log.write_bytes(b'\n'.join(lines) + b'\n')

    try:
        for name, edit in [
            ('missing-prior-commit', lambda e: e.pop(3)),
            ('wrong-operation-number', lambda e: e[4].update(operation=9)),
            ('wrong-checkpoint', lambda e: e[4].update(originalSHA256='0' * 64)),
            ('wrong-historical-commit-hash', lambda e: e[3].update(imageSHA256='0' * 64)),
            ('wrong-historical-before-image', lambda e: e[2].update(before='Qw==' * 1)),
            ('write-outside-operation', lambda e: e.insert(4, dict(e[2]))),
            ('duplicate-commit', lambda e: e.insert(4, dict(e[3]))),
            ('boolean-operation-number', lambda e: e[1].update(operation=True)),
            ('recovery-before-commit', lambda e: e.insert(3, {'kind': 'recovered'})),
        ]:
            image, log, record, _ = fixture(name)
            record.close()
            rewrite(log, edit)
            refused(image, log)
            checks.append(name + '-refused-without-image-write')
            image.unlink()
        for name in ['truncated-log', 'unexpected-range', 'unlogged-range', 'wrong-image']:
            image, log, record, _ = fixture(name)
            record.close()
            if name == 'truncated-log':
                log.write_bytes(log.read_bytes()[:-7])
            elif name == 'wrong-image':
                other = folder / 'copied.img'
                shutil.copyfile(image, other)
                image = other
            else:
                with image.open('r+b') as stream:
                    stream.seek(100010 if name == 'unexpected-range' else 300000)
                    stream.write(b'\xfe')
            refused(image, log)
            checks.append(name + '-refused-without-image-write')
            image.unlink()
        for name in ['nested-begin', 'write-without-begin', 'double-commit', 'external-boundary-change']:
            image, log, record, checkpoint = fixture(name, pending=False)
            before = digest(image)
            try:
                if name == 'nested-begin':
                    record.begin('pending')
                    record.begin('nested')
                elif name == 'write-without-begin':
                    record.before_write(100000, b'bad')
                elif name == 'double-commit':
                    record.commit()
                else:
                    os.pwrite(record.image, b'external', 400000)
                    before = digest(image)
                    record.begin('pending')
                raise AssertionError('protocol misuse accepted')
            except ValueError:
                pass
            assert record.failed
            try:
                record.emit({'kind': 'write'})
                raise AssertionError('failed session reused')
            except ValueError:
                pass
            assert digest(image) == before
            record.close()
            checks.append(name + '-latches-failure')
            image.unlink()
        image, log, record, checkpoint = fixture('recovery-crash')
        record.close()
        command = ('import os,sys; from fixture_operation_journal import recover_session; '
                   'recover_session(sys.argv[1],sys.argv[2],after_write=lambda _:os._exit(87))')
        p = subprocess.run([sys.executable, '-c', command, str(image), str(log)], cwd=ROOT / 'scripts', timeout=60)
        assert p.returncode == 87
        assert recover_session(image, log) == {'state': 'rolled-back', 'writes': 2, 'commits': 2}
        assert digest(image) == checkpoint
        assert recover_session(image, log)['writes'] == 0
        checks.append('overlapping-rollback-process-crash-resumes-preserving-two-commits')
        image.unlink()
        image, log, record, checkpoint = fixture('partial-rollback')
        record.close()
        original = module.os.pwrite
        def torn(fd, data, offset):
            original(fd, data[:len(data) // 2], offset)
            os.fsync(fd)
            raise OSError('partial recovery write')
        module.os.pwrite = torn
        try:
            try:
                recover_session(image, log)
                raise AssertionError('fault not reached')
            except OSError:
                pass
        finally:
            module.os.pwrite = original
        assert recover_session(image, log)['state'] == 'rolled-back'
        assert digest(image) == checkpoint
        checks.append('partial-rollback-resumes-preserving-two-commits')
        image.unlink()
        image, log, record, checkpoint = fixture('ambiguous-commit')
        original = module.append
        def appended_then_failed(fd, value):
            original(fd, value)
            raise OSError('response lost after durable commit')
        module.append = appended_then_failed
        try:
            try:
                record.commit()
                raise AssertionError('fault not reached')
            except OSError:
                pass
        finally:
            module.append = original
            record.close()
        before = digest(image)
        assert recover_session(image, log) == {'state': 'committed', 'writes': 0, 'commits': 3}
        assert digest(image) == before
        checks.append('durable-commit-with-lost-response-kept-as-indeterminate-result')
        image.unlink()
        image, log, record, checkpoint = fixture('locking')
        try:
            recover_session(image, log)
            raise AssertionError('active session lock bypassed')
        except BlockingIOError:
            pass
        record.close()
        assert recover_session(image, log)['state'] == 'rolled-back'
        assert digest(image) == checkpoint
        checks.append('live-session-excludes-recovery')
        image.unlink()
        complete = True
    finally:
        report = {'success': complete, 'checks': checks, 'fixture': str(folder), 'productionIntegrated': False}
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))


if __name__ == '__main__':
    main()
