#!/usr/bin/env python3
"""Prepare the version in PREPARE_FOR_SUBMISSION for review, without submitting it.

  python3 scripts/store/asc-review.py <build number>

- picks that build for the version;
- writes the review notes (the English block in docs/store/审核备注草稿.md) and
  "no sign-in required";
- attaches docs/store/Volisle-NTFS-Test.zip, replacing earlier attachments.
Contact details are left as they are: the owner fills them in.
Uses the key named in config/release.local.env (see asc-status.py).
"""
import hashlib
import importlib.util
import pathlib
import re
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('asc_screenshots', HERE / 'asc-screenshots.py')
shots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shots)
asc, call = shots.asc, shots.call
DOCS = HERE.parents[1] / 'docs/store'


def upload(reserved, data):
    for part in reserved['attributes']['uploadOperations']:
        request = urllib.request.Request(part['url'], method=part['method'], data=data[part['offset']:part['offset'] + part['length']],
                                         headers={h['name']: h['value'] for h in part['requestHeaders']})
        urllib.request.urlopen(request, timeout=300).read()


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        sys.exit(__doc__)
    number = sys.argv[1]
    notes = re.search(r'```text\n(.*?)```', (DOCS / '审核备注草稿.md').read_text(), re.S).group(1).strip()
    if len(notes) > 4000:
        sys.exit(f'审核备注 {len(notes)} 字，超过 4000')
    if f'store-1.0-build{number}' not in notes:
        sys.exit(f'审核备注里的源码标签不是构建 {number} 的')
    attachment = DOCS / 'Volisle-NTFS-Test.zip'
    data = attachment.read_bytes()

    bearer = asc.token(asc.config())
    app = call('GET', f'/v1/apps?filter[bundleId]={asc.BUNDLE}', bearer)['data'][0]['id']
    versions = [v for v in call('GET', f'/v1/apps/{app}/appStoreVersions?filter[platform]=MAC_OS', bearer)['data']
                if v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION']
    if len(versions) != 1:
        sys.exit('没有唯一一个“准备提交”的版本')
    version = versions[0]

    builds = call('GET', f'/v1/builds?filter[app]={app}&filter[version]={number}&filter[processingState]=VALID', bearer)['data']
    if len(builds) != 1:
        sys.exit(f'找不到处理完成的构建 {number}')
    call('PATCH', f"/v1/appStoreVersions/{version['id']}/relationships/build", bearer, {'data': {'type': 'builds', 'id': builds[0]['id']}})
    print(f"版本 {version['attributes']['versionString']} 选用构建 {number}")

    detail = call('GET', f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail", bearer).get('data')
    attributes = {'notes': notes, 'demoAccountRequired': False}
    if detail:
        call('PATCH', f"/v1/appStoreReviewDetails/{detail['id']}", bearer, {'data': {'type': 'appStoreReviewDetails', 'id': detail['id'], 'attributes': attributes}})
    else:
        detail = call('POST', '/v1/appStoreReviewDetails', bearer, {'data': {'type': 'appStoreReviewDetails', 'attributes': attributes,
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version['id']}}}}})['data']
    print(f'审核备注：已填（{len(notes)} 字），不需要登录')

    for old in call('GET', f"/v1/appStoreReviewDetails/{detail['id']}/appStoreReviewAttachments", bearer)['data']:
        call('DELETE', f"/v1/appStoreReviewAttachments/{old['id']}", bearer)
        print(f"删掉原有附件 {old['attributes'].get('fileName')}")
    reserved = call('POST', '/v1/appStoreReviewAttachments', bearer, {'data': {'type': 'appStoreReviewAttachments',
        'attributes': {'fileName': attachment.name, 'fileSize': len(data)},
        'relationships': {'appStoreReviewDetail': {'data': {'type': 'appStoreReviewDetails', 'id': detail['id']}}}}})['data']
    upload(reserved, data)
    call('PATCH', f"/v1/appStoreReviewAttachments/{reserved['id']}", bearer, {'data': {'type': 'appStoreReviewAttachments', 'id': reserved['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    state = call('GET', f"/v1/appStoreReviewAttachments/{reserved['id']}", bearer)['data']['attributes'].get('assetDeliveryState')
    print(f'附件 {attachment.name}：{(state or {}).get("state")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
