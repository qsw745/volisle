#!/usr/bin/env python3
"""Compile the pinned update framework locally; never use a hosted build."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '2.10.0'
SHA = '0d596e9b4af1402868e8a40a552883e1fee295db26af11845999a163a043354f'
ARCHIVE = ROOT / f'.workbench/Sparkle-{VERSION}-source.tar.gz'
SOURCE = ROOT / '.workbench/sparkle-source'
PROJECT = SOURCE / 'sparkle-project-Sparkle-eef1a53'
PRODUCTS = ROOT / '.workbench/sparkle-build/Build/Products/Release'

def prepare():
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        temporary = ARCHIVE.with_suffix('.download')
        request = urllib.request.Request(f'https://api.github.com/repos/sparkle-project/Sparkle/tarball/{VERSION}', headers={'User-Agent': 'Volisle-local-build'})
        with urllib.request.urlopen(request, timeout=60) as response:
            temporary.write_bytes(response.read())
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA:
            raise ValueError('Sparkle 源码摘要不匹配')
        temporary.rename(ARCHIVE)
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA:
        raise ValueError('Sparkle 源码归档已变化')
    SOURCE.mkdir(parents=True, exist_ok=True)
    with tarfile.open(ARCHIVE) as archive:
        members = archive.getmembers()
        for member in members:
            target = SOURCE / member.name
            if not target.resolve().is_relative_to(PROJECT) or member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                raise ValueError('Sparkle 源码归档路径无效')
        if not PROJECT.exists():
            archive.extractall(SOURCE, filter='data')
        for member in members:
            if member.isfile():
                target = SOURCE / member.name
                if target.is_symlink() or not target.is_file() or target.read_bytes() != archive.extractfile(member).read():
                    raise ValueError('实际编译的 Sparkle 源码已变化：' + member.name)
    # The framework ships inside the app: Apple silicon and Intel. The signing tools below only run here.
    subprocess.run(['xcodebuild', '-project', str(PROJECT / 'Sparkle.xcodeproj'), '-scheme', 'Sparkle',
                    '-configuration', 'Release', '-derivedDataPath', str(ROOT / '.workbench/sparkle-build'),
                    'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'build'], check=True)
    # The update-feed signing tools come from the same verified source.
    for scheme in ['sign_update', 'generate_keys']:
        subprocess.run(['xcodebuild', '-project', str(PROJECT / 'Sparkle.xcodeproj'), '-scheme', scheme,
                        '-configuration', 'Release', '-derivedDataPath', str(ROOT / '.workbench/sparkle-build'),
                        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'build'], check=True)
    if not (PRODUCTS / 'Sparkle.framework/Versions/B/Sparkle').is_file() or not (PRODUCTS / 'sign_update').is_file() \
            or not (PRODUCTS / 'generate_keys').is_file():
        raise ValueError('Sparkle 本地构建没有产物')

if __name__ == '__main__': prepare()
