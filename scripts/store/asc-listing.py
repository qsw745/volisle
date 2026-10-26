#!/usr/bin/env python3
"""Fill one language of the store page from docs/store/listing/<locale>.json.

  python3 scripts/store/asc-listing.py zh-Hans

Keys in the file: subtitle and privacyPolicyUrl (app information), and description, promotionalText,
keywords, supportUrl, marketingUrl (the version in PREPARE_FOR_SUBMISSION).
Only keys present in the file are written; nothing is submitted.
Uses the key named in config/release.local.env (see asc-status.py).
"""
import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('asc_screenshots', HERE / 'asc-screenshots.py')
shots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shots)
asc, call = shots.asc, shots.call

VERSION_KEYS = ('description', 'promotionalText', 'keywords', 'supportUrl', 'marketingUrl')
LIMITS = {'subtitle': 30, 'promotionalText': 170, 'description': 4000, 'keywords': 100}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    locale = sys.argv[1]
    listing = json.loads((HERE.parents[1] / f'docs/store/listing/{locale}.json').read_text())
    for key, limit in LIMITS.items():
        if len(listing.get(key, '')) > limit:
            sys.exit(f'{key} 超过 {limit} 字')
    bearer = asc.token(asc.config())
    app = call('GET', f'/v1/apps?filter[bundleId]={asc.BUNDLE}', bearer)['data'][0]['id']

    info_fields = {k: listing[k] for k in ('subtitle', 'privacyPolicyUrl') if k in listing}
    if info_fields:
        # The app information still being edited: the one not yet live.
        infos = call('GET', f'/v1/apps/{app}/appInfos', bearer)['data']
        info = next(i for i in infos if i['attributes'].get('appStoreState') != 'READY_FOR_SALE')
        local = next((l for l in call('GET', f"/v1/appInfos/{info['id']}/appInfoLocalizations", bearer)['data']
                      if l['attributes']['locale'] == locale), None)
        if local is None:
            sys.exit(f'App 信息里还没有 {locale}')
        call('PATCH', f"/v1/appInfoLocalizations/{local['id']}", bearer, {'data': {'type': 'appInfoLocalizations', 'id': local['id'],
            'attributes': info_fields}})
        for key, value in info_fields.items():
            print(f'{key}：{value}')

    fields = {k: listing[k] for k in VERSION_KEYS if k in listing}
    if fields:
        versions = [v for v in call('GET', f'/v1/apps/{app}/appStoreVersions?filter[platform]=MAC_OS', bearer)['data']
                    if v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION']
        if len(versions) != 1:
            sys.exit('没有唯一一个“准备提交”的版本')
        local = next((l for l in call('GET', f"/v1/appStoreVersions/{versions[0]['id']}/appStoreVersionLocalizations", bearer)['data']
                      if l['attributes']['locale'] == locale), None)
        if local is None:
            sys.exit(f'版本里还没有 {locale}')
        saved = call('PATCH', f"/v1/appStoreVersionLocalizations/{local['id']}", bearer, {'data': {'type': 'appStoreVersionLocalizations',
            'id': local['id'], 'attributes': fields}})['data']['attributes']
        for key in fields:
            assert saved.get(key) == fields[key], key
            print(f'{key}：已填（{len(fields[key])} 字）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
