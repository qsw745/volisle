#!/usr/bin/env python3
"""Real signed XPC integration in a temporary GUI LaunchAgent, never root.
Build VolisleHelperProbe locally first. Does not register the product daemon.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(args, check=True):
    return subprocess.run([str(x) for x in args], check=check, capture_output=True, text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    args = parser.parse_args()
    probe = args.probe.resolve(strict=True)
    if os.geteuid() == 0 or not probe.is_relative_to(ROOT / 'apps/macos/.build') or probe.name != 'VolisleHelperProbe':
        raise ValueError('仅接受普通用户运行的本地开发验收程序')
    config = json.loads((ROOT / 'config/signing.json').read_text())
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']).stdout
    matches = re.findall(r'\b([A-F0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(config['team_id']) + r'\)"', identities)
    if len(matches) != 1:
        raise ValueError('需唯一匹配当前配置的 Developer ID 证书')
    identity = matches[0]
    stage = Path(tempfile.mkdtemp(prefix='volisle-xpc-', dir='/private/tmp'))
    result = {'stage': str(stage), 'tests': [], 'cleanup': [], 'root_service_registered': False}
    failure = None
    jobs = []
    try:
        clients = {}
        for name, identifier, mode in [
            ('server', config['bundle_id'] + '.mount-helper', 'signed'),
            ('client', config['bundle_id'], 'signed'),
            ('wrong-client', config['bundle_id'] + '.unrelated', 'signed'),
            ('adhoc-client', config['bundle_id'], 'adhoc'),
            ('debug-client', config['bundle_id'], 'debug'),
            ('wrong-server', config['bundle_id'] + '.unrelated-helper', 'signed'),
        ]:
            target = stage / name
            shutil.copy2(probe, target)
            command = ['/usr/bin/codesign', '--force', '--options', 'runtime', '--identifier', identifier,
                       '--sign', '-' if mode == 'adhoc' else identity]
            if mode != 'adhoc':
                command.append('--timestamp')
            if mode == 'debug':
                entitlements = stage / 'debug.entitlements'
                entitlements.write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
                command.extend(['--entitlements', str(entitlements)])
            run(command + [target])
            run(['/usr/bin/codesign', '--verify', '--strict', target])
            clients[name] = target
        for server, cases in [('server', [('client', 'accepted'), ('wrong-client', 'rejected'),
                                          ('adhoc-client', 'rejected'), ('debug-client', 'rejected'), ('client', 'accepted')]),
                              ('wrong-server', [('client', 'rejected')])]:
            name = 'top.qisw.volisle.integration.' + str(uuid.uuid4())
            target = f'gui/{os.getuid()}/{name}'
            plist = stage / (name + '.plist')
            plist.write_bytes(plistlib.dumps({'Label': name, 'ProgramArguments': [str(clients[server]), '--serve', name],
                                             'MachServices': {name: True}, 'RunAtLoad': True,
                                             'StandardErrorPath': str(stage / (server + '.stderr'))}))
            # Register only this random, nonprivileged job. Track even a failed
            # bootstrap so cleanup can verify no late registration remains.
            jobs.append(target)
            run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', plist])
            for client, expected in cases:
                completed = run([clients[client], '--client', name, expected])
                result['tests'].append({'server': server, 'client': client, 'expected': expected,
                                        'passed': completed.returncode == 0, 'output': completed.stdout.strip()})
            if server == 'server':
                completed = run([clients['client'], '--inspect', name, 'disk999999999s1', '1', '512', 'unavailable'])
                result['tests'].append({'server': server, 'client': 'client', 'operation': 'inspectDisk',
                                        'expected': 'unavailable', 'passed': True, 'output': completed.stdout.strip()})
            run(['/bin/launchctl', 'bootout', target])
            gone = run(['/bin/launchctl', 'print', target], check=False).returncode != 0
            result['cleanup'].append({'job': name, 'removed': gone})
            if not gone:
                raise RuntimeError('临时服务仍在注册')
            jobs.remove(target)
    except Exception as error:
        failure = error
        result['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result['stderr'] = error.stderr[-4000:]
    finally:
        for target in jobs:
            run(['/bin/launchctl', 'bootout', target], check=False)
            gone = run(['/bin/launchctl', 'print', target], check=False).returncode != 0
            result['cleanup'].append({'job': target.split('/')[-1], 'removed': gone})
        result['passed'] = failure is None and len(result['tests']) == 7 and all(x['removed'] for x in result['cleanup'])
        (stage / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result['passed']:
        raise RuntimeError('XPC 验收未全部通过；保留现场记录') from failure


if __name__ == '__main__':
    main()
