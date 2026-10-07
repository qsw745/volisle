#!/usr/bin/env python3
"""Export the public snapshot of this private repository.

  scripts/publish-public.py export <git ref> [--out DIR]
      Writes the files allowed in the public repository, as of <ref> (a tag
      such as v0.6.2), to DIR (default dist/public/<ref>), with local paths
      and server details replaced, then scans the result and fails on any hit.
  scripts/publish-public.py sync <snapshot DIR> <public clone DIR> <message>
      Replaces the clone's working tree with the snapshot (its .git is kept)
      and commits. Pushing is left to you: git -C <clone> push.

What is public and why: docs/product/公开仓库方案.md. Owner-specific values
to replace or refuse live in config/publish-public.local.json (not in git):
  {"scrub": [["regex", "replacement"], ...], "forbidden": ["regex", ...]}
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Never public: internal decisions, drafts, third parties' names, the store probe.
EXCLUDE = [
    r'^docs/(handoff|marketing|product|superpowers|design)/',
    r'^docs/feasibility/商业SDK',
    r'^docs/release/(0\.3\.0-部署方案|签名账户核对|当前交付清单|正式发布状态|0\.2\.0-集中验收指南)\.md$',
    r'^scripts/mas-poc/',
]

# Replaced in every text file. Owner-specific values (server, key IDs, names)
# come from config/publish-public.local.json, which is not in git: listing them
# here would publish exactly what the scrub hides.
SCRUB = [(r'~/\s"\']+/', '~/'), (r'~/\s"\']+\b', '~')]

# Must not survive into the snapshot.
FORBIDDEN = [r'BEGIN [A-Z ]*PRIVATE KEY', r'\bghp_[A-Za-z0-9]{20}', r'\bsk-[A-Za-z0-9]{20}', r'\bAKIA[0-9A-Z]{16}\b',
             r'\bxox[bap]-[A-Za-z0-9-]{10}', r'~]']
LOCAL = ROOT / 'config/publish-public.local.json'


def load_local():
    if not LOCAL.is_file():
        sys.exit(f'缺少 {LOCAL}：个人信息替换与禁止清单（不入库），格式见 scripts/publish-public.py 开头说明')
    data = json.loads(LOCAL.read_text())
    SCRUB.extend((p, r) for p, r in data.get('scrub', []))
    FORBIDDEN.extend(data.get('forbidden', []))
SECRET_SUFFIXES = ('.p8', '.p12', '.pem', '.key', '.mobileprovision', '.provisionprofile')


def git(*args, binary=False):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, check=True)
    return result.stdout if binary else result.stdout.decode()


def export(ref, out):
    load_local()
    names = [n for n in git('-c', 'core.quotepath=off', 'ls-tree', '-r', '--name-only', ref).splitlines() if n]
    keep = [n for n in names if not any(re.search(p, n) for p in EXCLUDE)]
    if out.exists():
        sys.exit(f'{out} 已存在；先检查再删掉')
    scrubbed, hits = 0, []
    for name in keep:
        if name.endswith(SECRET_SUFFIXES) or Path(name).name.startswith(('.env', 'release.local')) and not name.endswith('.example'):
            sys.exit(f'疑似密钥或个人配置文件：{name}')
        data = git('show', f'{ref}:{name}', binary=True)
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            text = None
        if text is not None:
            new = text
            for pattern, replacement in SCRUB:
                new = re.sub(pattern, replacement, new)
            if new != text:
                scrubbed += 1
            for pattern in FORBIDDEN:
                if re.search(pattern, new):
                    hits.append(f'{name}: {pattern}')
            data = new.encode('utf-8')
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        mode = git('ls-tree', ref, '--', name).split()[0]
        if mode == '100755':
            target.chmod(0o755)
    if hits:
        shutil.rmtree(out)
        sys.exit('扫描命中，已删除导出目录：\n  ' + '\n  '.join(hits))
    excluded = len(names) - len(keep)
    print(f'已导出 {ref}：{len(keep)} 个文件（排除 {excluded} 个，替换个人信息 {scrubbed} 个）→ {out}')
    print('扫描：没有密钥、服务器信息、本机路径或第三方昵称')


# Public commits never carry a personal address (the local git config may).
PUBLIC_AUTHOR = ['-c', 'user.name=qsw745', '-c', 'user.email=92699806+qsw745@users.noreply.github.com']


def sync(snapshot, clone, message):
    if not (clone / '.git').is_dir():
        sys.exit(f'{clone} 不是 git 仓库')
    # Everything but .git is deleted below: never this private repository, a
    # folder inside it, or one that contains it.
    root = ROOT.resolve()
    if clone == root or root in clone.parents or clone in root.parents:
        sys.exit(f'{clone} 是私有仓库本身、在它里面或包含它，拒绝同步')
    remote = subprocess.run(['git', '-C', str(clone), 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
    if not remote.rstrip('/').removesuffix('.git').lower().endswith('github.com/qsw745/volisle'):
        sys.exit(f'{clone} 的 origin 不是公开仓库 qsw745/volisle：{remote or "无"}')
    for child in clone.iterdir():
        if child.name == '.git':
            continue
        shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
    shutil.copytree(snapshot, clone, dirs_exist_ok=True)
    subprocess.run(['git', '-C', str(clone), 'add', '-A'], check=True)
    if subprocess.run(['git', '-C', str(clone), 'diff', '--cached', '--quiet']).returncode == 0:
        print('没有变化，未提交'); return
    subprocess.run(['git', '-C', str(clone), *PUBLIC_AUTHOR, 'commit', '-q', '-m', message], check=True)
    print(subprocess.run(['git', '-C', str(clone), 'show', '--stat', '--format=%h %s', 'HEAD'],
                         capture_output=True, text=True).stdout.splitlines()[0])
    print(f'已提交到 {clone}，确认后运行：git -C {clone} push')


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) in (2, 4) and a[0] == 'export' and (len(a) == 2 or a[2] == '--out'):
        export(a[1], Path(a[3]).resolve() if len(a) == 4 else ROOT / 'dist/public' / a[1])
    elif len(a) == 4 and a[0] == 'sync':
        sync(Path(a[1]).resolve(), Path(a[2]).resolve(), a[3])
    else:
        sys.exit(__doc__)
