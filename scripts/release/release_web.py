#!/usr/bin/env python3
"""Release-time edits the release script (release.sh) makes, kept in one place.

  release_web.py check-notes <notes.txt>
      The update notes: a title line, then "· " lines, Chinese first, then English.
  release_web.py readiness <candidate.app> <build> <version>
      config/release-readiness.json for this build (status stays as it is).
  release_web.py website <dmg> <source.tar.gz> <notes.txt>
      Moves the current release into apps/web/lib/history.ts, points
      apps/web/lib/release.ts at the new files, and adds the notes to both
      changelog pages.
  release_web.py history-files <stage/downloads>
      Makes sure every earlier version listed in history.ts is in the stage:
      copies it from an earlier dist/ stage or downloads it from the live site,
      and checks its SHA-256 against history.ts either way.
"""
import hashlib
import html
import json
import os
import re
import shutil
import sys
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_TS = ROOT / 'apps/web/lib/release.ts'
HISTORY_TS = ROOT / 'apps/web/lib/history.ts'
CHANGELOG = {'zh': ROOT / 'apps/web/app/(zh)/changelog/page.tsx', 'en': ROOT / 'apps/web/app/(en)/en/changelog/page.tsx'}
SITE = 'https://qisw.top/volisle'
CJK = re.compile(r'[一-鿿]')


def fail(message):
    sys.exit(f'错误：{message}')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def notes(path):
    lines = [l.strip() for l in Path(path).read_text(encoding='utf-8').splitlines() if l.strip()]
    if len(lines) < 3 or not lines[0].startswith('盘屿 '):
        fail('更新说明第一行应为“盘屿 x.y.z · Volisle x.y.z”，后面每条以“· ”开头')
    items = [l[1:].strip() for l in lines[1:] if l.startswith('·')]
    if len(items) != len(lines) - 1:
        fail('更新说明除第一行外，每行都要以“· ”开头')
    zh = [i for i in items if CJK.search(i)]
    en = [i for i in items if not CJK.search(i)]
    if not zh or not en or items != zh + en:
        fail('更新说明要先写中文条目、再写英文条目，两种都不能少')
    return zh, en


def jsx_text(text):
    """A note as JSX text: entities for < > & " ' (lint rejects bare quotes) and
    for braces, which JSX would read as code."""
    return html.escape(text, quote=True).replace('{', '&#123;').replace('}', '&#125;')


def field(text, key):
    m = re.search(rf"\n  {key}: '([^']*)'", text)
    if not m:
        fail(f'release.ts 里找不到 {key}')
    return m.group(1)


def readiness(candidate, build, version):
    provenance = sha256(Path(candidate) / 'Contents/Resources/SourceProvenance.json')
    path = ROOT / 'config/release-readiness.json'
    d = json.loads(path.read_text())
    d['build'] = int(build)
    d['source_provenance_sha256'] = provenance
    d['decided'] = f'{date.today().isoformat()}：所有者用 scripts/release/release.sh 发布 {version}（构建 {build}）。'
    path.write_text(json.dumps(d, ensure_ascii=False, indent=2) + '\n')


def website(dmg, source, notes_path):
    zh, en = notes(notes_path)
    dmg, source = Path(dmg), Path(source)
    version = re.match(r'Volisle-(\d+\.\d+\.\d+)-(?:universal|arm64)\.dmg$', dmg.name)  # arm64: releases before 0.9
    if not version:
        fail(f'安装包文件名不对：{dmg.name}')
    version = version.group(1)
    t = RELEASE_TS.read_text()
    old = {k: field(t, k) for k in ['version', 'date', 'dateEn', 'dmg', 'dmgSize', 'dmgSha256', 'source', 'sourceSize', 'sourceSha256']}
    old_build = int(re.search(r'\n  build: (\d+),', t).group(1))
    if old['version'] == version:
        fail(f'release.ts 已经是 {version}，不要重复执行')
    build = json.loads((ROOT / 'config/updates.json').read_text())['build']
    today = date.today()
    zh_date = f'{today.year} 年 {today.month} 月 {today.day} 日'
    en_date = today.strftime('%B ') + str(today.day) + today.strftime(', %Y')
    mb = lambda p: f'{p.stat().st_size / 1e6:.1f} MB'
    new = {'version': version, 'date': zh_date, 'dateEn': en_date, 'dmg': f'/downloads/{dmg.name}', 'dmgSize': mb(dmg),
           'dmgSha256': sha256(dmg), 'source': f'/downloads/{source.name}', 'sourceSize': mb(source), 'sourceSha256': sha256(source)}
    for k, v in new.items():
        t, n = re.subn(rf"(\n  {k}: )'[^']*'", lambda m: m.group(1) + f"'{v}'", t, count=1)
        if n != 1:
            fail(f'无法更新 release.ts 的 {k}')
    t, n = re.subn(r'\n  build: \d+,', f'\n  build: {build},', t, count=1)
    if n != 1:
        fail('无法更新 release.ts 的 build')
    # The release just replaced becomes the newest earlier version.
    h = HISTORY_TS.read_text()
    anchor = 'export const history: PastRelease[] = [\n'
    if anchor not in h or f"version: '{old['version']}'" in h:
        fail('history.ts 格式不对，或上一版已在历史里')
    entry = (f"  {{ version: '{old['version']}', build: {old_build}, date: '{old['date']}', dateEn: '{old['dateEn']}',\n"
             f"    dmg: '{old['dmg']}', dmgSize: '{old['dmgSize']}', dmgSha256: '{old['dmgSha256']}',\n"
             f"    source: '{old['source']}', sourceSize: '{old['sourceSize']}', sourceSha256: '{old['sourceSha256']}' }},\n")
    HISTORY_TS.write_text(h.replace(anchor, anchor + entry, 1))
    RELEASE_TS.write_text(t)
    for locale, items, heading in (('zh', zh, f'{version} · {zh_date}'), ('en', en, f'{version} · {en_date}')):
        page = CHANGELOG[locale].read_text()
        first = page.find('<h2>')
        if first < 0:
            fail(f'{CHANGELOG[locale]} 里找不到版本标题')
        block = f'<h2>{heading}</h2><ul>\n' + ''.join(f'<li>{jsx_text(i)}</li>\n' for i in items) + '</ul>\n'
        CHANGELOG[locale].write_text(page[:first] + block + page[first:])
    print(f'官网：{old["version"]} 移入历史版本，当前版本改为 {version}（构建 {build}）')


def history_files(downloads):
    downloads = Path(downloads)
    wanted = re.findall(r"(?:dmg|source): '/downloads/([^']+)', (?:dmg|source)Size: '[^']*', (?:dmg|source)Sha256: '([0-9a-f]{64})'",
                        HISTORY_TS.read_text())
    earlier = sorted((ROOT / 'dist').glob('Volisle-*/site-stage/downloads'), key=os.path.getmtime, reverse=True)
    fetched = 0
    for name, digest in wanted:
        target = downloads / name
        if not target.exists():
            local = next((d / name for d in earlier if (d / name).is_file() and sha256(d / name) == digest), None)
            if local:
                shutil.copyfile(local, target)
            else:
                print(f'从官网下载 {name} …', flush=True)
                with urllib.request.urlopen(f'{SITE}/downloads/{name}', timeout=120) as r, open(target, 'wb') as f:
                    shutil.copyfileobj(r, f)
                fetched += 1
        if sha256(target) != digest:
            target.unlink()
            fail(f'{name} 的 SHA-256 与 history.ts 不符，已删除')
    print(f'历史版本文件 {len(wanted)} 个，全部核对通过（从官网下载 {fetched} 个）')


if __name__ == '__main__':
    command, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if command == 'check-notes' and len(args) == 1:
        zh, en = notes(args[0]); print(f'更新说明：中文 {len(zh)} 条，英文 {len(en)} 条')
    elif command == 'readiness' and len(args) == 3:
        readiness(*args)
    elif command == 'website' and len(args) == 3:
        website(*args)
    elif command == 'history-files' and len(args) == 1:
        history_files(args[0])
    else:
        sys.exit(__doc__)
