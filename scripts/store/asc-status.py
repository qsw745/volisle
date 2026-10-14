#!/usr/bin/env python3
"""Read-only App Store Connect status of the store build: recent builds and TestFlight.

Uses the App Store Connect API key named in config/release.local.env
(VOLISLE_NOTARY_KEY_ID, VOLISLE_NOTARY_KEY, VOLISLE_NOTARY_ISSUER); the key is never printed.

  python3 scripts/store/asc-status.py            # last five builds
  python3 scripts/store/asc-status.py --build 3  # one build with its TestFlight state; exit 2 while processing
"""
import argparse
import base64
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = 'top.qisw.volisle.mas'
API = 'https://api.appstoreconnect.apple.com'


def config():
    # A worktree keeps its own release.local.env (store profiles); the key lives in the main checkout's.
    bases = [ROOT.parents[2], ROOT] if ROOT.parent.name == 'worktrees' else [ROOT]
    values = {}
    for base in bases:
        path = base / 'config/release.local.env'
        if path.exists():
            values.update(re.findall(r'^([A-Z_]+)=(.*)$', path.read_text(), re.M))
    missing = [k for k in ('VOLISLE_NOTARY_KEY_ID', 'VOLISLE_NOTARY_KEY', 'VOLISLE_NOTARY_ISSUER') if k not in values]
    if missing:
        sys.exit('config/release.local.env 里缺少：' + '、'.join(missing))
    return {k: os.path.expandvars(v.strip('"\'')) for k, v in values.items()}


def token(env):
    b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
    now = int(time.time())
    head = b64(json.dumps({'alg': 'ES256', 'kid': env['VOLISLE_NOTARY_KEY_ID'], 'typ': 'JWT'}).encode())
    body = b64(json.dumps({'iss': env['VOLISLE_NOTARY_ISSUER'], 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    key = pathlib.Path(env['VOLISLE_NOTARY_KEY']).expanduser()
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=f'{head}.{body}'.encode(),
                         capture_output=True, check=True).stdout
    # DER ECDSA signature → the raw r‖s that JWT wants.
    i, parts = (2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)), []
    for _ in range(2):
        length = der[i + 1]
        parts.append(int.from_bytes(der[i + 2:i + 2 + length], 'big'))
        i += 2 + length
    return f'{head}.{body}.{b64(b"".join(p.to_bytes(32, "big") for p in parts))}'


def get(path, bearer):
    request = urllib.request.Request(API + path, headers={'Authorization': 'Bearer ' + bearer})
    try:
        return json.load(urllib.request.urlopen(request, timeout=60))
    except urllib.error.HTTPError as error:
        detail = json.loads(error.read() or b'{}').get('errors', [{}])[0]
        sys.exit(f'接口拒绝（{error.code}）：{detail.get("title", "")} {detail.get("detail", "")}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build')
    args = parser.parse_args()
    bearer = token(config())
    app = get(f'/v1/apps?filter[bundleId]={BUNDLE}', bearer)['data'][0]['id']
    query = f'/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=5'
    if args.build:
        query += f'&filter[version]={args.build}'
    builds = get(query, bearer)['data']
    if args.build and not builds:
        print(f'构建 {args.build}：还没出现（苹果仍在接收）')
        return 2
    for build in builds:
        a = build['attributes']
        line = f"构建 {a['version']}：{a['processingState']}，上传于 {a['uploadedDate']}"
        if args.build:
            beta = get(f"/v1/builds/{build['id']}/buildBetaDetail", bearer)['data']['attributes']
            line += f"，内部测试 {beta.get('internalBuildState')}"
        print(line)
    if args.build and builds[0]['attributes']['processingState'] == 'PROCESSING':
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
