#!/usr/bin/env python3
"""Verify durable withdrawal over the installed signed root XPC service.

Uses only nonexistent device envelopes; no disks are mounted, opened or written.
Unregister/register deliberately restarts the idle helper to test persistence.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

APP = Path.home() / 'Applications/Volisle Test.app'
CLI = APP / 'Contents/MacOS/Volisle'


def call(*args, rejected=False):
    result = subprocess.run([str(CLI), *args], capture_output=True, text=True, timeout=45)
    if rejected:
        if result.returncode != 1 or '磁盘检查请求无效' not in result.stderr:
            raise RuntimeError(f'请求没有被固定协议明确拒绝：{result.returncode} {result.stderr}')
        return {'exit_code': result.returncode, 'error': result.stderr.strip()}
    if result.returncode:
        raise RuntimeError(f'{args[0]} 失败：{result.returncode} {result.stdout.strip()} {result.stderr.strip()}')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('拒绝覆盖已有验收结果')
    for name in ['disk99999', 'disk99999s1']:
        if Path('/dev', name).exists():
            raise ValueError('占位设备实际存在，停止')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True, capture_output=True)
    status = call('--helper-status')
    if status.get('state') != 'connected' or not status.get('packageVerified'):
        raise ValueError('必须先安装并连接可信后台')
    latest = call('--helper-cycle-latest')
    if latest is not None and latest['phase'] != 'finished':
        raise ValueError('存在未完成磁盘操作，停止')
    result = {'success': False, 'previous_operation': latest, 'checks': [], 'disk_operations': False}
    removed = False
    try:
        envelopes = [('cycle', 'disk99999s1', '4096'), ('write', 'disk99999', '67108864')]
        requests = []
        for mode, disk, size in envelopes:
            tail = [disk, '1', size, str(uuid.uuid4()).upper()]
            requests.append((mode, tail))
            assert call(f'--helper-{mode}-resolve', *tail) is None
            assert call(f'--helper-{mode}-resolve', *tail) is None
            result['checks'].append({'mode': mode, 'request_id': tail[-1], 'withdrawal_retry': True,
                                     'late_start': call(f'--helper-{mode}-start', *tail, rejected=True)})
        assert call('--helper-cycle-latest') == latest
        removed = True
        call('--helper-unregister')
        # SMAppService.unregister returns before all launchd/BTM teardown
        # callbacks settle. Do not immediately register over a terminating job.
        deadline = time.monotonic() + 15
        while subprocess.run(['launchctl', 'print', 'system/top.qisw.volisle.mount-helper'], capture_output=True).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError('后台注销未完成，未重复注册')
            time.sleep(0.5)
        time.sleep(2)
        registered = call('--helper-register')
        if registered.get('state') != 'connected':
            raise RuntimeError('后台重启后未连接')
        removed = False
        for mode, tail in requests:
            assert call(f'--helper-{mode}-resolve', *tail) is None
            call(f'--helper-{mode}-start', *tail, rejected=True)
        assert call('--helper-cycle-latest') == latest
        result['restart_retains_fences'] = True
        result['current_operation_unchanged'] = True
        result['success'] = True
    except BaseException as error:
        result['error'] = str(error)
        raise
    finally:
        if removed:
            try:
                result['restore_service'] = call('--helper-register')
            except BaseException as error:
                result['restore_error'] = str(error)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
