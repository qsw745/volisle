#!/usr/bin/env python3
"""Upload the Mac App Store screenshots of one language to the version being prepared.

  python3 scripts/store/asc-screenshots.py zh-Hans docs/store/screenshots/zh-Hans/*.png

Files go up in the order given and replace whatever screenshots that language had.
Only the version in PREPARE_FOR_SUBMISSION is touched; nothing is submitted.
Uses the key named in config/release.local.env (see asc-status.py).
"""
import hashlib
import importlib.util
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('asc_status', HERE / 'asc-status.py')
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

DISPLAY = 'APP_DESKTOP'
SIZES = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}


def call(method, path, bearer, body=None):
    request = urllib.request.Request(asc.API + path, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={'Authorization': 'Bearer ' + bearer, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = json.loads(error.read() or b'{}').get('errors', [{}])[0]
        sys.exit(f'接口拒绝（{error.code}，{method} {path}）：{detail.get("title", "")} {detail.get("detail", "")}')


def png_size(data):
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        return None, None, None
    return int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big'), data[25]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    locale, files = sys.argv[1], [pathlib.Path(f) for f in sys.argv[2:]]
    if len(files) > 10:
        sys.exit('一种语言最多 10 张')
    blobs = []
    for f in files:
        data = f.read_bytes()
        width, height, color = png_size(data)
        if (width, height) not in SIZES:
            sys.exit(f'{f}: {width}×{height} 不是 Mac App Store 接受的尺寸')
        if color in (4, 6):
            sys.exit(f'{f}: 带透明通道，商店不接受')
        blobs.append((f, data))

    bearer = asc.token(asc.config())
    app = call('GET', f'/v1/apps?filter[bundleId]={asc.BUNDLE}', bearer)['data'][0]['id']
    versions = [v for v in call('GET', f'/v1/apps/{app}/appStoreVersions?filter[platform]=MAC_OS', bearer)['data']
                if v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION']
    if len(versions) != 1:
        sys.exit('没有唯一一个“准备提交”的版本')
    version = versions[0]
    localization = next((l for l in call('GET', f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", bearer)['data']
                         if l['attributes']['locale'] == locale), None)
    if localization is None:
        sys.exit(f'版本 {version["attributes"]["versionString"]} 还没有 {locale} 这种语言：先在 App Store Connect 里加上')

    sets = call('GET', f"/v1/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets", bearer)['data']
    shots = next((s for s in sets if s['attributes']['screenshotDisplayType'] == DISPLAY), None)
    if shots is None:
        shots = call('POST', '/v1/appScreenshotSets', bearer, {'data': {'type': 'appScreenshotSets',
            'attributes': {'screenshotDisplayType': DISPLAY},
            'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': localization['id']}}}}})['data']
    for old in call('GET', f"/v1/appScreenshotSets/{shots['id']}/appScreenshots", bearer)['data']:
        call('DELETE', f"/v1/appScreenshots/{old['id']}", bearer)
        print(f"删掉原有截图 {old['attributes'].get('fileName')}")

    for f, data in blobs:
        reserved = call('POST', '/v1/appScreenshots', bearer, {'data': {'type': 'appScreenshots',
            'attributes': {'fileName': f.name, 'fileSize': len(data)},
            'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': shots['id']}}}}})['data']
        for part in reserved['attributes']['uploadOperations']:
            chunk = data[part['offset']:part['offset'] + part['length']]
            request = urllib.request.Request(part['url'], method=part['method'], data=chunk,
                                             headers={h['name']: h['value'] for h in part['requestHeaders']})
            urllib.request.urlopen(request, timeout=300).read()
        call('PATCH', f"/v1/appScreenshots/{reserved['id']}", bearer, {'data': {'type': 'appScreenshots', 'id': reserved['id'],
            'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
        print(f'已上传 {f.name}')

    # Apple processes each file after the upload; report what it ends up as.
    for _ in range(30):
        states = [(s['attributes']['fileName'], (s['attributes'].get('assetDeliveryState') or {}).get('state'))
                  for s in call('GET', f"/v1/appScreenshotSets/{shots['id']}/appScreenshots", bearer)['data']]
        if all(state in ('COMPLETE', 'FAILED') for _, state in states):
            break
        time.sleep(5)
    for name, state in states:
        print(f'{name}：{state}')
    return 0 if all(state == 'COMPLETE' for _, state in states) else 1


if __name__ == '__main__':
    sys.exit(main())
