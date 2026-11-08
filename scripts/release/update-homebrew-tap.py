#!/usr/bin/env python3
"""Keep the Homebrew cask (packaging/homebrew/Casks/volisle.rb) in step with releases.

  update-homebrew-tap.py set <version> <dmg>
      Writes the version and the DMG's SHA-256 into the cask in this repository.
  update-homebrew-tap.py push <message>
      Copies that cask and packaging/homebrew/README.md into a fresh clone of
      qsw745/homebrew-volisle and pushes it.
      Run only after the DMG is live on the website: the cask points users there.

The tap holds only those two files; this repository is their source of truth.
"""
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASK = ROOT / 'packaging/homebrew/Casks/volisle.rb'
README = ROOT / 'packaging/homebrew/README.md'
TAP = 'https://github.com/qsw745/homebrew-volisle.git'
PUBLIC_AUTHOR = ['-c', 'user.name=qsw745', '-c', 'user.email=92699806+qsw745@users.noreply.github.com']
VERSION = re.compile(r'^  version "[^"]*"$', re.M)
SHA256 = re.compile(r'^  sha256 "[0-9a-f]{64}"$', re.M)


def set_release(version: str, dmg: Path) -> None:
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        sys.exit(f'版本号格式不对：{version}')
    if dmg.name != f'Volisle-{version}-universal.dmg':
        sys.exit(f'安装包文件名与 cask 里的下载地址对不上：{dmg.name}')
    text = CASK.read_text()
    if len(VERSION.findall(text)) != 1 or len(SHA256.findall(text)) != 1:
        sys.exit(f'{CASK} 里找不到唯一的 version / sha256 行')
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    text = VERSION.sub(f'  version "{version}"', text)
    text = SHA256.sub(f'  sha256 "{digest}"', text)
    CASK.write_text(text)
    print(f'Homebrew cask 已改为 {version}（SHA-256 {digest}）')


def push(message: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        clone = Path(tmp) / 'homebrew-volisle'
        subprocess.run(['git', 'clone', '-q', TAP, str(clone)], check=True)
        (clone / 'Casks').mkdir(exist_ok=True)
        shutil.copyfile(CASK, clone / 'Casks/volisle.rb')
        shutil.copyfile(README, clone / 'README.md')
        subprocess.run(['git', '-C', str(clone), 'add', '-A'], check=True)
        if subprocess.run(['git', '-C', str(clone), 'diff', '--cached', '--quiet']).returncode == 0:
            print('Homebrew tap 已是最新，无需推送')
            return
        subprocess.run(['git', '-C', str(clone), *PUBLIC_AUTHOR, 'commit', '-q', '-m', message], check=True)
        subprocess.run(['git', '-C', str(clone), 'push', '-q', 'origin', 'HEAD'], check=True)
        print('Homebrew tap qsw745/homebrew-volisle 已推送')


if __name__ == '__main__':
    match sys.argv[1:]:
        case ['set', version, dmg]:
            set_release(version, Path(dmg))
        case ['push', message]:
            push(message)
        case _:
            sys.exit(__doc__)
