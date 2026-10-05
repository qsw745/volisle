#!/usr/bin/env python3
"""Real FSKit overwrite lifecycle test, restricted to a fresh, exactly bound 64/512 MiB image."""
import argparse
from datetime import datetime
import errno
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
from bundle_manifest import sha256
from fskit_fixture import validate_fixture, WORK

spec = importlib.util.spec_from_file_location('fskit_write', Path(__file__).with_name('test-fskit-write.py'))
fskit = importlib.util.module_from_spec(spec); spec.loader.exec_module(fskit)



def private_mode_rejection(root):
    checks = []
    for name, mode, directory in [('private-mode-file', 0o600, False), ('private-mode-directory', 0o700, True)]:
        target = root / name
        assert not target.exists(), '私有权限测试不能覆盖已有节点'
        try:
            if directory:
                target.mkdir(mode=mode)
            else:
                fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
                os.close(fd)
        except OSError as error:
            assert error.errno == errno.ENOTSUP, (name, error)
        else:
            raise AssertionError('未实现的私有权限不能伪称成功')
        assert not target.exists(), '拒绝权限后不能残留放宽权限的节点'
        checks.append('private-' + ('directory-0700' if directory else 'file-0600') + '-rejected-without-node')
    return checks

def private_mode_success(root):
    folder = root / 'mac-private'
    folder.mkdir(mode=0o700)
    target = folder / 'secret.txt'
    fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        assert os.write(fd, b'owner-private') == 13
        os.fsync(fd)
    finally: os.close(fd)
    assert folder.stat().st_mode & 0o7777 == 0o700
    assert target.stat().st_mode & 0o7777 == 0o600
    os.chmod(target, 0o400)
    assert target.stat().st_mode & 0o7777 == 0o400
    try:
        fd = os.open(target, os.O_WRONLY)
    except PermissionError: pass
    else:
        os.close(fd); raise AssertionError('私有只读文件仍允许写入')
    os.chmod(target, 0o600)
    assert target.read_bytes() == b'owner-private'
    assert not any(name.upper().startswith('$VOLISLE') for name in fskit.run(['/usr/bin/xattr', target]).stdout.decode().splitlines())
    return ['mac-private-file-and-directory-modes', 'mac-private-readonly-and-unlock']


def main(folder, signed, ui_review=False, lifecycle_stress=False, app_review=False, app_rejection_review=False, permission_review=False):
    fixture = validate_fixture(folder)
    folder = folder.resolve()
    image = folder / 'fixture.img'
    receipt = json.loads((signed / 'signing-result.json').read_text())
    assert receipt['fixture'] == fixture and receipt['write_mode'] == 'fixture-only'
    assert not (folder / 'replacement-result.json').exists()
    relative = 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'
    assert sha256(fskit.INSTALLED / relative) == sha256(signed / 'top.qisw.volisle.app' / relative)
    fskit.run(['codesign', '--verify', '--deep', '--strict', fskit.INSTALLED])
    modules = json.loads(fskit.run([WORK / 'probe-fskit']).stdout)['modules']
    assert len(modules) == 1 and modules[0]['enabled']
    assert Path(modules[0]['path']).resolve() == (fskit.INSTALLED / 'Contents/Extensions/VolisleFS.appex').resolve()
    started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    result = {'sessions': [], 'checks': [], 'success': False, 'fixture': fixture}
    large_fixture = fixture['size'] == 512 * 1024 * 1024
    old_data, new_data = b'OLD!' + b'a' * 16384, b'NEW!' + b'b' * 32768
    try:
        with fskit.mounted(image, False, result) as root:
            closed_source, closed_target = root / 'closed-draft.bin', root / 'closed-document.bin'
            closed_source.write_bytes(b'closed-new'); closed_target.write_bytes(b'closed-old')
            os.replace(closed_source, closed_target)
            assert not closed_source.exists() and closed_target.read_bytes() == b'closed-new'
            result['checks'].append('replace-closed-target')
            # A temporary save in a different directory, including the same
            # basename, must keep the old open object independent.
            other = root / 'other'; other.mkdir()
            cross = other / 'closed-document.bin'; cross.write_bytes(b'cross-directory-source')
            with closed_target.open('rb', buffering=0) as old:
                os.replace(cross, closed_target)
                assert old.read() == b'closed-new'
                assert not cross.exists() and closed_target.read_bytes() == b'cross-directory-source'
            result['checks'].append('cross-directory-same-name-open-target')
            closed_cross = other / 'closed-final.bin'
            with closed_cross.open('xb') as stream:
                stream.write(b'closed-cross-directory'); stream.flush(); os.fsync(stream.fileno())
            os.replace(closed_cross, closed_target)
            assert not closed_cross.exists() and closed_target.read_bytes() == b'closed-cross-directory'
            result['checks'].append('cross-directory-closed-target')
            # Larger than the former 8 MiB ceiling, with a partial final chunk.
            # Keep both versions open through replacement and verify independent
            # file handles. The 512 MiB fixture exercises 80/96/72 MiB contents.
            large_source, large_target = root / 'large-draft.bin', root / 'large-document.bin'
            old_large = b'OLD-LARGE' + bytes(range(256)) * (327680 if large_fixture else 65536)
            new_large = b'NEW-LARGE' + bytes(reversed(range(256))) * (393216 if large_fixture else 81920) + b'end'
            large_target.write_bytes(old_large); large_source.write_bytes(new_large)
            assert large_source.stat().st_size == len(new_large)
            assert large_target.stat().st_size == len(old_large)
            with large_target.open('r+b', buffering=0) as old:
                os.fsync(old.fileno())
                os.replace(large_source, large_target)
                assert not large_source.exists() and large_target.read_bytes() == new_large
                assert old.read() == old_large
                old.seek(len(old_large) - 7); old.write(b'changed'); os.fsync(old.fileno())
                old.seek(0); assert old.read() == old_large[:-7] + b'changed'
                assert large_target.read_bytes() == new_large
            result['checks'].append('96MiB-replacement-and-80MiB-old-handle-write' if large_fixture else '20MiB-streamed-replacement-and-16MiB-old-handle-write')
            closed_large = root / 'closed-large-final.bin'
            new_large = b'FINAL-LARGE' + bytes(range(256)) * (294912 if large_fixture else 36864) + b'partial-end'
            with closed_large.open('xb') as stream:
                stream.write(new_large); stream.flush(); os.fsync(stream.fileno())
            os.replace(closed_large, large_target)
            assert not closed_large.exists() and large_target.read_bytes() == new_large
            result['checks'].append('96MiB-target-replaced-by-72MiB-closed-source' if large_fixture else '20MiB-target-replaced-by-9MiB-closed-source')
            target, source = root / 'document.bin', root / 'draft.bin'
            target.write_bytes(old_data); source.write_bytes(new_data)
            with target.open('r+b', buffering=0) as old:
                os.fsync(old.fileno())
                os.replace(source, target)
                assert not source.exists() and target.read_bytes() == new_data
                old.seek(0); assert old.read() == old_data
                old.seek(0); old.write(b'EDIT'); os.fsync(old.fileno())
                old.seek(0); assert old.read() == b'EDIT' + old_data[4:]
                assert target.read_bytes() == new_data
                result['checks'].append('replace-open-old-descriptor-isolated')
                with target.open('r+b', buffering=0) as new:
                    new.seek(0); new.write(b'NEXT'); os.fsync(new.fileno())
                    new.truncate(8193); os.fsync(new.fileno())
                new_data = (b'NEXT' + new_data[4:])[:8193]
                assert target.read_bytes() == new_data
                old.seek(0); assert old.read() == b'EDIT' + old_data[4:]
                result['checks'].append('new-descriptor-write-truncate-isolated')
                assert not any(p.name.startswith('.volisle-replaced-') for p in root.iterdir())
                result['checks'].append('private-backup-not-enumerated')
            # close is deliberately not treated as final vnode reclamation.
            assert target.read_bytes() == new_data
            result['checks'].append('new-data-survives-old-close')
            if lifecycle_stress:
                # Closed sources/targets force the extension replacement path.
                # Exceed archive retention in one mount, not just unit fixtures.
                stress_target = root / 'sustained-save.txt'
                stress_target.write_bytes(b'original')
                for n in range(70):
                    draft = root / 'sustained-draft.txt'
                    value = f'save-{n:03d}'.encode()
                    with draft.open('xb') as stream:
                        stream.write(value); stream.flush(); os.fsync(stream.fileno())
                    os.replace(draft, stress_target)
                    assert not draft.exists() and stress_target.read_bytes() == value
                result['checks'].append('70-closed-replacements-in-one-mount')
            if app_review or app_rejection_review:
                result['checks'].extend(private_mode_success(root) if receipt.get('experimental_private_permissions') else private_mode_rejection(root))
                if permission_review:
                    assert receipt.get('experimental_private_permissions')
                    for name,mode,value in [('nonowner-control.txt',0o644,b'public-control'),('nonowner-private.txt',0o600,b'private-control')]:
                        fd=os.open(root/name,os.O_CREAT|os.O_EXCL|os.O_WRONLY,mode)
                        try: os.write(fd,value);os.fsync(fd)
                        finally: os.close(fd)
                    (folder/'nonowner-ready.json').write_text(json.dumps({'root':str(root)})+'\n')
                    print('非所有者验收已就绪：'+str(root),flush=True)
                    deadline=time.monotonic()+900
                    evidence=folder/'nonowner-result.json'
                    while not evidence.exists() and time.monotonic()<deadline:time.sleep(1)
                    proof=json.loads(evidence.read_text())
                    if not proof.get('success'): raise RuntimeError('非所有者访问验收未完成；'+proof.get('not_covered','独立检查失败'))
                    assert proof['success'] and proof['root']==str(root) and proof['uid']!=proof['owner_uid']
                    assert proof['checks']==['public-control-readable-as-nonowner','private-read-denied','private-write-denied','private-directory-traversal-denied']
                    result['nonowner_access']=proof
                    result['checks'].append('independent-nonowner-file-and-directory-denied')
                document = root / 'Volisle-应用保存测试.txt'
                document.write_text('Volisle original text.\n', encoding='utf-8')
                first = 'Volisle first save 中文 20260924.\n'
                second = 'Volisle second save 中文 20260924.\n'
                deadline = time.monotonic() + 900
                for step, expected in ([(1, 'Volisle original text.\n')] if app_rejection_review else [(1, first), (2, second)]):
                    (folder / 'application-save-ready.json').write_text(json.dumps({
                        'path': str(document), 'step': step, 'expected': expected}, ensure_ascii=False) + '\n')
                    print('应用保存检查已就绪：' + str(document) + ' 阶段=' + str(step), flush=True)
                    done = folder / ('application-save-' + str(step))
                    while not done.exists() and time.monotonic() < deadline:
                        time.sleep(1)
                    assert done.exists(), '应用保存操作未在限定时间内完成'
                    assert document.read_text(encoding='utf-8') == expected, '实际文件与应用保存内容不符'
                    result['checks'].append('textedit-rejected-save-preserves-original' if app_rejection_review else 'textedit-save-' + str(step) + '-content-verified')
                result['application_save_supported'] = not app_rejection_review
            if ui_review:
                incoming = root / 'Finder 来源'; incoming.mkdir()
                destination = root / 'Finder 目标'; destination.mkdir()
                (incoming / 'Finder 覆盖.txt').write_bytes('Finder 新版本内容\n'.encode())
                (destination / 'Finder 覆盖.txt').write_bytes('Finder 原版本内容\n'.encode())
                (folder / 'replacement-ui-ready.json').write_text(json.dumps({'source': str(incoming), 'destination': str(destination)}, ensure_ascii=False) + '\n')
                print('Finder 覆盖核验已就绪：' + str(root), flush=True)
                deadline = time.monotonic() + 180
                while not (folder / 'replacement-ui-finished').exists() and time.monotonic() < deadline:
                    time.sleep(1)
                assert (destination / 'Finder 覆盖.txt').read_bytes() == 'Finder 新版本内容\n'.encode()
                result['checks'].append('finder-overwrite-content-verified')
        observed = fskit.run([WORK / 'ntfs-3g-2026.7.7/ntfsprogs/ntfscat', image, '/document.bin']).stdout
        assert observed == new_data
        observed_large = fskit.run([WORK / 'ntfs-3g-2026.7.7/ntfsprogs/ntfscat', image, '/large-document.bin']).stdout
        assert observed_large == new_large
        from ntfs_bridge_test_support import ImageIO
        device = ImageIO(image, readonly=True)
        try: assert device.inspect() == 0 and device.writes == 0
        finally: device.close()
        with fskit.mounted(image, True, result) as root:
            assert (root / 'document.bin').read_bytes() == new_data
            assert (root / 'large-document.bin').read_bytes() == new_large
            if lifecycle_stress: assert (root / 'sustained-save.txt').read_bytes() == b'save-069'
            if (app_review or app_rejection_review) and receipt.get('experimental_private_permissions'):
                assert (root / 'mac-private').stat().st_mode & 0o7777 == 0o700
                assert (root / 'mac-private/secret.txt').stat().st_mode & 0o7777 == 0o600
                assert (root / 'mac-private/secret.txt').read_bytes() == b'owner-private'
                result['checks'].append('mac-private-modes-after-readonly-remount')
            if app_review or app_rejection_review:
                assert (root / 'Volisle-应用保存测试.txt').read_text(encoding='utf-8') == ('Volisle original text.\n' if app_rejection_review else second)
                result['checks'].append('textedit-original-survives-rejected-save-and-remount' if app_rejection_review else 'textedit-content-survives-readonly-remount')
            if ui_review:
                assert (root / 'Finder 目标/Finder 覆盖.txt').read_bytes() == 'Finder 新版本内容\n'.encode()
            assert not (root / 'draft.bin').exists()
            assert not any(p.name.startswith('.volisle-replaced-') for p in root.iterdir()), '旧副本在最终回收后仍残留'
        result['checks'].append('offline-clean-readonly-remount-no-backup')
        result['allocation_check'] = json.loads(fskit.run([sys.executable, Path(__file__).with_name('verify-fixture-allocation.py'), folder]).stdout)
        assert result['allocation_check']['success']
        logs = fskit.run(['/usr/bin/log', 'show', '--start', started, '--style', 'json',
            '--predicate', 'subsystem == "Volisle.NTFSModule"']).stdout
        events = json.loads(logs)
        (folder / 'replacement-events.json').write_text(json.dumps(events, ensure_ascii=False, indent=2) + '\n')
        publications = [e for e in events if '覆盖实验已发布' in e.get('eventMessage', '')]
        assert any('跨目录=true' in e.get('eventMessage', '') for e in publications), '没有观察到原生跨目录发布'
        import re
        large_publications = [e for e in publications if (m := re.search(r'旧字节=(\d+) 新字节=(\d+)', e.get('eventMessage', ''))) and min(int(m[1]), int(m[2])) > (64 if large_fixture else 8) * 1024 * 1024]
        assert large_publications, '没有观察到原生大文件发布'
        # Finder may delete/copy instead of using rename-over; count observed
        # publications, never infer one journal from every UI replacement.
        if lifecycle_stress: assert len(publications) >= 65, '连续保存没有覆盖原生归档上限'
        expected_audit = '恢复记录只读复核：卷=' + fixture['serial_hex'] + ' 已完成=' + str(min(64, len(publications))) + ' 未完成=0'
        audits = [e for e in events if expected_audit in e.get('eventMessage', '')]
        assert audits and publications, '缺少原生发布或持久化重读证据'
        assert any(a['processID'] != p['processID'] for a in audits for p in publications), '尚未验证跨进程持久化'
        result['checks'].append('sandbox-journal-replayed-by-new-readonly-process')
        result['observed_publications'] = [e['eventMessage'] for e in publications]
        result['journal_audit'] = [{'processID': e['processID'], 'eventMessage': e['eventMessage']} for e in audits]
        result['success'] = True
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        result['final_image_sha256'] = sha256(image)
        (folder / 'replacement-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--signed-dir', type=Path, required=True)
    parser.add_argument('--ui-review', action='store_true')
    parser.add_argument('--lifecycle-stress', action='store_true')
    parser.add_argument('--app-review', action='store_true', help='等待实际文本编辑连续保存并核对内容；仅操作新建测试文件')
    parser.add_argument('--app-rejection-review', action='store_true', help='已知不兼容保存的保护性检查；不表示应用保存已支持')
    parser.add_argument('--permission-review', action='store_true', help='等待独立非所有者进程验证，只适用于私有权限实验')
    args = parser.parse_args()
    if args.permission_review and not args.app_review: parser.error('非所有者检查必须配合应用保存验收')
    if args.app_review and args.app_rejection_review: parser.error('保存成功验收与拒绝验收不能混用')
    main(args.fixture, args.signed_dir, args.ui_review, args.lifecycle_stress, args.app_review, args.app_rejection_review, args.permission_review)
