#!/usr/bin/env python3
"""Check the app's interface translations against the strings the compiler sees.

Keys are the Chinese source strings. The compiler records every
LocalizedStringKey literal and String(localized:) call (with %@/%lld
placeholders); this script builds the app and core with that output enabled,
then checks:

  * en, zh-Hans and zh-Hant Localizable.strings cover every key;
  * English keeps the same placeholders in the same order;
  * the Chinese tables map each key to itself (they must exist: the development
    region is en, so a Chinese system without its own table falls back to English);
  * no stale keys remain;
  * the app's interface sources have no Chinese literal that would be shown
    verbatim (log lines and file names are excluded).

  python3 scripts/check-localization.py          # check
  python3 scripts/check-localization.py --write  # regenerate the Chinese tables
"""
import argparse
import glob
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / 'assets/brand/Localization/app'
APP_SOURCES = ROOT / 'apps/macos/Sources/Volisle'
CJK = re.compile('[\u4e00-\u9fff]')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:@|lld|ld|d|lf|f|s)')
LOG_LINE = re.compile(r'\b(Logger|log|Log)\b.*\.(notice|error|info|debug|fault)\(|preconditionFailure')


def literals(line):
    """Yield (start, end) of top-level Swift string literals, honoring \\( ) nesting."""
    i, n = 0, len(line)
    while i < n:
        if line.startswith('//', i):
            return
        if line[i] != '"':
            i += 1
            continue
        start, i, depth = i, i + 1, 0
        while i < n:
            c = line[i]
            if c == '\\' and i + 1 < n and line[i + 1] == '(':
                depth, i = depth + 1, i + 2
                continue
            if c == '\\':
                i += 2
                continue
            if depth:
                if c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                elif c == '"':
                    j = i + 1
                    while j < n and line[j] != '"':
                        j += 2 if line[j] == '\\' else 1
                    i = j
                i += 1
                continue
            if c == '"':
                yield start, i + 1
                i += 1
                break
            i += 1


def build(package, scratch, extra):
    command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(scratch),
               '-Xswiftc', '-emit-localized-strings', '-Xswiftc', '-emit-localized-strings-path',
               '-Xswiftc', str(scratch / 'strings')] + extra
    (scratch / 'strings').mkdir(parents=True, exist_ok=True)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit('编译失败：\n' + result.stdout[-2000:] + result.stderr[-2000:])


def collect(scratch_dirs):
    keys, lines = {}, {}
    for scratch in scratch_dirs:
        for path in glob.glob(str(scratch) + '/**/*.stringsdata', recursive=True):
            data = json.load(open(path))
            source = os.path.realpath(data['source'])
            for entries in data.get('tables', {}).values():
                for entry in entries:
                    if entry['key']:
                        keys.setdefault(entry['key'], source)
                    lines.setdefault(source, set()).add(entry['location']['startingLine'])
    return keys, lines


def read_table(path):
    if not path.exists():
        return None
    out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def uncaptured(lines):
    found = []
    for source in sorted(APP_SOURCES.glob('*.swift')):
        seen = lines.get(os.path.realpath(source), set())
        for number, line in enumerate(source.read_text(encoding='utf-8').splitlines(), 1):
            if LOG_LINE.search(line) or 'String(localized:' in line or number in seen:
                continue
            chinese = [line[s:e] for s, e in literals(line) if CJK.search(line[s:e])]
            if chinese:
                found.append(f'{source.name}:{number}: {" | ".join(chinese)[:120]}')
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--write', action='store_true', help='regenerate the zh-Hans and zh-Hant tables from the keys')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='volisle-l10n-') as temp:
        app, core = Path(temp) / 'app', Path(temp) / 'core'
        build(ROOT / 'apps/macos', app, ['--product', 'Volisle'])
        build(ROOT / 'packages/VolisleCore', core, [])
        keys, lines = collect([app, core])
    if not keys:
        sys.exit('没有收集到任何本地化键，请检查编译器输出')
    if args.write:
        for language in ['zh-Hans', 'zh-Hant']:
            body = ['/* 中文界面：键即原文。必须存在，否则开发区域为 en 时中文系统会回退到英文表。 */', '']
            body += [f'"{escape(key)}" = "{escape(key)}";' for key in keys]
            (TABLES / f'{language}.lproj/Localizable.strings').write_text('\n'.join(body) + '\n', encoding='utf-8')
    problems = []
    english = read_table(TABLES / 'en.lproj/Localizable.strings') or {}
    for language in ['zh-Hans', 'zh-Hant']:
        table = read_table(TABLES / f'{language}.lproj/Localizable.strings')
        if table is None:
            problems.append(f'{language} 缺少 Localizable.strings')
            continue
        problems += [f'{language} 缺少或改动了：{key}' for key in keys if table.get(key) != key]
        problems += [f'{language} 多余：{key}' for key in table if key not in keys]
    for key in keys:
        if key not in english:
            problems.append(f'en 缺少：{key}')
        elif PLACEHOLDER.findall(key) != PLACEHOLDER.findall(english[key]):
            problems.append(f'en 占位符不一致：{key} → {english[key]}')
        elif CJK.search(english[key]):
            problems.append(f'en 仍含中文：{key} → {english[key]}')
    problems += [f'en 多余：{key}' for key in english if key not in keys]
    problems += [f'界面未本地化：{item}' for item in uncaptured(lines)]
    for problem in problems:
        print(problem)
    print(f'本地化键 {len(keys)} 个；问题 {len(problems)} 个')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
