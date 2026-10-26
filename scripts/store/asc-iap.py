#!/usr/bin/env python3
"""Creates or completes the "盘屿 Pro" in-app purchase in App Store Connect. Safe to run again:
each step is done only when it is missing. Nothing is submitted for review here; the first
in-app purchase goes to review together with a new app version.
  python3 scripts/store/asc-iap.py                    # create / complete, then show the state
  python3 scripts/store/asc-iap.py --screenshot a.png # also the review screenshot (once)
  python3 scripts/store/asc-iap.py --show             # state only, changes nothing
Uses the key named in config/release.local.env (see asc-status.py).
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('asc_screenshots', HERE / 'asc-screenshots.py')
shots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shots)
asc, call = shots.asc, shots.call

PRODUCT_ID = 'top.qisw.volisle.mas.pro'
REFERENCE_NAME = '盘屿 Pro'
# Owner's decision 2026-10-15: US$3.99, ¥28 in mainland China (set now, used once the app is sold there).
PRICES = {'USA': '3.99', 'CHN': '28.0'}
BASE_TERRITORY = 'USA'
# Store limits: name 30, description 45 characters.
LOCALIZATIONS = {
    'zh-Hans': ('盘屿 Pro', '菜单栏、睡眠保护、每块盘单独设置'),
    'zh-Hant': ('盤嶼 Pro', '選單列、睡眠保護、每個磁碟單獨設定'),
    'en-US': ('Volisle Pro', 'Menu bar, sleep protection, per-disk settings'),
}
REVIEW_NOTE = (
    'A one-time, non-consumable unlock of the advanced features: a menu bar extra (disk status, eject all), '
    'keeping the Mac awake while a disk is being written and ejecting NTFS disks before sleep, and a per-disk '
    'read-only / read-write setting. Reading and writing NTFS disks stays free without it.\n'
    'Where: Settings (Command-comma) > Advanced (高级) tab > Buy (购买). Restore Purchase (恢复购买) is next to it.\n'
    'The per-disk setting appears in the main window under a mounted disk once unlocked; the attached test disk '
    'image from the app review notes can be used.'
)


def get_optional(path, bearer):
    """GET that reads 404 as "not set yet" (a new purchase has no price schedule or availability)."""
    request = urllib.request.Request(asc.API + path, headers={'Authorization': 'Bearer ' + bearer})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read() or b'{}')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {}
        raise


def find_iap(app, bearer):
    for item in call('GET', f'/v1/apps/{app}/inAppPurchasesV2?limit=200', bearer)['data']:
        if item['attributes']['productId'] == PRODUCT_ID:
            return item
    return None


def create_iap(app, bearer):
    return call('POST', '/v2/inAppPurchases', bearer, {'data': {'type': 'inAppPurchases',
        'attributes': {'name': REFERENCE_NAME, 'productId': PRODUCT_ID, 'inAppPurchaseType': 'NON_CONSUMABLE',
                       'reviewNote': REVIEW_NOTE, 'familySharable': False},
        'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']


def ensure_localizations(iap, bearer):
    present = {l['attributes']['locale']: l for l in call('GET', f'/v2/inAppPurchases/{iap}/inAppPurchaseLocalizations', bearer)['data']}
    for locale, (name, description) in LOCALIZATIONS.items():
        if len(name) > 30 or len(description) > 45:
            sys.exit(f'{locale} 的名称或描述超过长度限制')
        attributes = {'name': name, 'description': description}
        if locale in present:
            current = present[locale]['attributes']
            if current.get('name') != name or current.get('description') != description:
                call('PATCH', f"/v1/inAppPurchaseLocalizations/{present[locale]['id']}", bearer, {'data': {
                    'type': 'inAppPurchaseLocalizations', 'id': present[locale]['id'], 'attributes': attributes}})
                print(f'更新本地化 {locale}')
            continue
        call('POST', '/v1/inAppPurchaseLocalizations', bearer, {'data': {'type': 'inAppPurchaseLocalizations',
            'attributes': {'locale': locale, **attributes},
            'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iap}}}}})
        print(f'新增本地化 {locale}：{name} / {description}')


def price_point(iap, territory, price, bearer):
    path = f'/v2/inAppPurchases/{iap}/pricePoints?filter[territory]={territory}&limit=8000'
    for point in call('GET', path, bearer)['data']:
        if float(point['attributes']['customerPrice']) == float(price):
            return point['id']
    sys.exit(f'{territory} 没有 {price} 这个价格档')


def ensure_price(iap, bearer):
    schedule = get_optional(f'/v2/inAppPurchases/{iap}/iapPriceSchedule?include=manualPrices', bearer)
    if schedule.get('data') and schedule.get('included'):
        return
    included, refs = [], []
    for n, (territory, price) in enumerate(PRICES.items()):
        ref = f'${{price{n}}}'
        refs.append({'type': 'inAppPurchasePrices', 'id': ref})
        included.append({'type': 'inAppPurchasePrices', 'id': ref, 'attributes': {'startDate': None},
                         'relationships': {'inAppPurchasePricePoint': {'data': {'type': 'inAppPurchasePricePoints',
                                                                                'id': price_point(iap, territory, price, bearer)}}}})
    call('POST', '/v1/inAppPurchasePriceSchedules', bearer, {'data': {'type': 'inAppPurchasePriceSchedules',
        'relationships': {'inAppPurchase': {'data': {'type': 'inAppPurchases', 'id': iap}},
                          'baseTerritory': {'data': {'type': 'territories', 'id': BASE_TERRITORY}},
                          'manualPrices': {'data': refs}}}, 'included': included})
    print('价格：' + '，'.join(f'{t} {p}' for t, p in PRICES.items()) + f'（基准 {BASE_TERRITORY}）')


def app_territories(app, bearer):
    availability = call('GET', f'/v1/apps/{app}/appAvailabilityV2', bearer)['data']['id']
    territories, path = [], f'/v2/appAvailabilities/{availability}/territoryAvailabilities?include=territory&limit=200'
    while path:
        page = call('GET', path, bearer)
        territories += [t['relationships']['territory']['data']['id'] for t in page['data'] if t['attributes'].get('available')]
        path = page.get('links', {}).get('next', '').replace(asc.API, '') or None
    return territories


def ensure_availability(app, iap, bearer):
    existing = get_optional(f'/v2/inAppPurchases/{iap}/inAppPurchaseAvailability', bearer)
    if existing.get('data'):
        return
    territories = app_territories(app, bearer)
    if not territories:
        sys.exit('读不到应用的销售地区')
    call('POST', '/v1/inAppPurchaseAvailabilities', bearer, {'data': {'type': 'inAppPurchaseAvailabilities',
        'attributes': {'availableInNewTerritories': True},
        'relationships': {'inAppPurchase': {'data': {'type': 'inAppPurchases', 'id': iap}},
                          'availableTerritories': {'data': [{'type': 'territories', 'id': t} for t in territories]}}}})
    print(f'销售地区：与应用相同，共 {len(territories)} 个（含中国大陆：{"是" if "CHN" in territories else "否"}）')


def ensure_screenshot(iap, path, bearer):
    existing = get_optional(f'/v2/inAppPurchases/{iap}/appStoreReviewScreenshot', bearer)
    if existing.get('data'):
        print('审核截图已经有了，不重复上传')
        return
    data = path.read_bytes()
    width, height, color = shots.png_size(data)
    if width is None or color in (4, 6):
        sys.exit(f'{path}: 要不带透明通道的 PNG')
    reserved = call('POST', '/v1/inAppPurchaseAppStoreReviewScreenshots', bearer, {'data': {
        'type': 'inAppPurchaseAppStoreReviewScreenshots', 'attributes': {'fileName': path.name, 'fileSize': len(data)},
        'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iap}}}}})['data']
    for part in reserved['attributes']['uploadOperations']:
        request = urllib.request.Request(part['url'], method=part['method'], data=data[part['offset']:part['offset'] + part['length']],
                                         headers={h['name']: h['value'] for h in part['requestHeaders']})
        urllib.request.urlopen(request, timeout=300).read()
    call('PATCH', f"/v1/inAppPurchaseAppStoreReviewScreenshots/{reserved['id']}", bearer, {'data': {
        'type': 'inAppPurchaseAppStoreReviewScreenshots', 'id': reserved['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    print(f'已上传审核截图 {path.name}（{width}×{height}）')


def show(iap, bearer):
    item = call('GET', f'/v2/inAppPurchases/{iap}', bearer)['data']['attributes']
    print(f"{item['productId']}：{item['name']}，类型 {item['inAppPurchaseType']}，状态 {item['state']}，家人共享 {item.get('familySharable')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--screenshot', type=pathlib.Path)
    parser.add_argument('--show', action='store_true')
    args = parser.parse_args()
    bearer = asc.token(asc.config())
    app = call('GET', f'/v1/apps?filter[bundleId]={asc.BUNDLE}', bearer)['data'][0]['id']
    item = find_iap(app, bearer)
    if args.show:
        show(item['id'], bearer) if item else print('还没有建')
        return
    if item is None:
        item = create_iap(app, bearer)
        print(f'已创建内购 {PRODUCT_ID}')
    iap = item['id']
    ensure_localizations(iap, bearer)
    ensure_price(iap, bearer)
    ensure_availability(app, iap, bearer)
    if args.screenshot:
        ensure_screenshot(iap, args.screenshot, bearer)
    show(iap, bearer)


if __name__ == '__main__':
    main()
