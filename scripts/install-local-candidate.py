#!/usr/bin/env python3
"""Install a locally signed candidate with a retained rollback; no disk changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, **kwargs)


def registry_ids():
    import plistlib
    ids = set()
    def walk(node):
        if isinstance(node, dict):
            if 'IORegistryEntryID' in node: ids.add(node['IORegistryEntryID'])
            for child in node.get('IORegistryEntryChildren', []): walk(child)
        elif isinstance(node, list):
            for child in node: walk(child)
    walk(plistlib.loads(run('ioreg', '-a', '-r', '-c', 'IOMedia').stdout))
    return ids


def orphaned_write(record):
    """A write cycle interrupted by unplugging: its media is gone and nothing
    of Volisle is mounted. Older helpers could not close such a record; the
    replacement helper does. Anything else still blocks the update."""
    return (record.get('purpose') == 'readWrite' and record.get('phase') == 'needsRecovery'
            and record['disk']['registryID'] not in registry_ids()
            and not run('/sbin/mount', '-t', 'volisle').stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--label', required=True)
    # The copy macOS should use: one per Mac, or FSKit may pick either extension.
    parser.add_argument('--target', type=Path, default=Path.home() / 'Applications/Volisle Test.app')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9-]{1,60}', args.label): parser.error('备份标签格式错误')
    source = args.candidate.resolve(strict=True)
    target = args.target
    if target.suffix != '.app' or target.parent not in (Path('/Applications'), Path.home() / 'Applications'):
        parser.error('只能安装到 /Applications 或 ~/Applications 下的 .app')
    # Keep staging and rollback copies out of ~/Applications: two bundles with the
    # same extension ID there make FSKit discovery pick either one.
    spare = Path.home() / 'Volisle 测试回滚副本'
    spare.mkdir(exist_ok=True)
    stage = spare / (target.stem + '.' + args.label + '.staging')
    backup = spare / (target.stem + '.before-' + args.label + '.rollback')
    if backup.exists() or stage.exists() or target.is_symlink(): parser.error('目标或备份已有冲突')
    if subprocess.run(['pgrep', '-x', 'Volisle'], capture_output=True).returncode != 1: parser.error('请先退出盘屿')
    if run('/sbin/mount', '-t', 'volisle').stdout: parser.error('仍有使用中的盘屿挂载，停止更新')
    probe = Path(__file__).resolve().parents[1] / 'apps/macos/.build/out/Products/Release/VolisleHelperProbe'
    run('codesign', '--verify', '--deep', '--strict', source)
    run(probe, '--check-package', source)
    old = target / 'Contents/MacOS/Volisle'
    if target.exists():
        run(probe, '--check-package', target)
        state = json.loads(run(old, '--helper-status').stdout)
        if state['state'] == 'connected':
            latest = json.loads(run(old, '--helper-cycle-latest').stdout)
            if latest and latest['phase'] != 'finished' and not orphaned_write(latest):
                parser.error('后台事务尚未结束，停止更新')
            result = subprocess.run([str(old), '--helper-unregister'], capture_output=True)
            if json.loads(result.stdout).get('state') not in ['notRegistered', 'unavailable']: parser.error('后台组件未停止')
        elif state['state'] not in ['notRegistered', 'unavailable']:
            parser.error('无法确认后台组件已停止')
    if subprocess.run(['launchctl', 'print', 'system/top.qisw.volisle.mount-helper'], capture_output=True).returncode == 0:
        parser.error('后台服务仍在运行')
    shutil.copytree(source, stage, symlinks=True)
    run('codesign', '--verify', '--deep', '--strict', stage)
    # Only end our idle extension, never fskitd or another product's process.
    for pid in subprocess.run(['pgrep', '-x', 'VolisleFS'], capture_output=True, text=True).stdout.split():
        expected = str(target / 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS')
        if run('ps', '-p', pid, '-o', 'comm=', text=True).stdout.strip() != expected: parser.error('其他扩展副本正在运行')
        opened = subprocess.run(['lsof', '-p', pid, '-Fn'], capture_output=True, text=True).stdout
        if any(x.startswith('n/dev/') and x != 'n/dev/null' for x in opened.splitlines()): parser.error('扩展仍持有设备')
        if run('/sbin/mount', '-t', 'volisle').stdout: parser.error('挂载状态已变化')
        os.kill(int(pid), signal.SIGTERM)
        time.sleep(1)
        if subprocess.run(['ps', '-p', pid], capture_output=True).returncode == 0:
            if run('/sbin/mount', '-t', 'volisle').stdout: parser.error('挂载状态已变化')
            if run('ps', '-p', pid, '-o', 'comm=', text=True).stdout.strip() != expected: parser.error('进程身份变化')
            opened = subprocess.run(['lsof', '-p', pid, '-Fn'], capture_output=True, text=True).stdout
            if any(x.startswith('n/dev/') and x != 'n/dev/null' for x in opened.splitlines()): parser.error('扩展仍持有设备')
            os.kill(int(pid), signal.SIGKILL)
            time.sleep(1)
        if subprocess.run(['ps', '-p', pid], capture_output=True).returncode == 0: parser.error('扩展尚未退出')
    had_previous = target.exists()
    if had_previous: target.rename(backup)
    try:
        stage.rename(target)
        run('codesign', '--verify', '--deep', '--strict', target)
    except BaseException:
        if target.exists(): target.rename(stage)
        if had_previous: backup.rename(target)
        raise
    print(json.dumps({'installed': str(target), 'source': str(source), 'rollback': str(backup) if had_previous else None,
                      'full_disk_access_changed': False}, ensure_ascii=False))

if __name__ == '__main__': main()
