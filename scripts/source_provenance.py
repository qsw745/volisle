"""Bind a candidate to the complete local source inputs, including licensing.

This is reproducible-input evidence, not a claim of bit-reproducible binaries.
The receipt is embedded before signing and checked again before packaging.
"""
import hashlib
import os
from pathlib import Path
import stat
import tarfile

UPSTREAM_SHA = 'd67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab'
REQUIRED = ['LICENSE', 'LICENSE_SCOPE.md', 'README.md', 'config/signing.json', 'config/updates.json', '.workbench/Sparkle-2.10.0-source.tar.gz',
            'apps/macos/Package.swift', 'docs/release/自己发布新版本.md', 'docs/release/自动更新.md', '.workbench/ntfs-3g.tgz']
FOLDERS = ['apps/macos/Sources', 'apps/macos/Helper', 'apps/extension', 'apps/web',
           'packages', 'scripts', 'assets/brand']
EXCLUDED = {'.build', 'build', 'node_modules', '.next', 'out', '__pycache__', '.swiftpm', '.git'}

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def source_inventory(root):
    root = Path(root).resolve()
    files = set(REQUIRED)
    for folder in FOLDERS:
        top = root / folder
        if not top.exists():
            continue
        if top.is_symlink():
            raise ValueError('源码目录不能是符号链接：' + folder)
        for directory, children, names in os.walk(top, followlinks=False):
            children[:] = [x for x in children if x not in EXCLUDED]
            for name in children + names:
                path = Path(directory) / name
                if path.is_symlink():
                    raise ValueError('源码不能含符号链接：' + str(path))
            for name in names:
                path = Path(directory) / name
                if name == '.DS_Store' or path.suffix in ('.pyc', '.tsbuildinfo'):
                    continue
                if name.startswith(('.env', 'release.local')) or path.suffix in ('.provisionprofile', '.p12', '.key', '.p8', '.pem'):
                    raise ValueError('源码范围包含需人工排除的敏感配置：' + str(path))
                files.add(path.relative_to(root).as_posix())
    result = {}
    for name in sorted(files):
        path = root / name
        if not path.is_file() or path.is_symlink() or path.resolve() != path:
            raise ValueError('源码输入缺失或经过链接：' + name)
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o7000:
            raise ValueError('源码文件含特殊权限：' + name)
        result[name] = {'sha256': digest(path), 'mode': mode}
    return result

def validate_receipt(root, receipt):
    if not isinstance(receipt, dict) or receipt.get('schema') != 1 or not isinstance(receipt.get('files'), dict):
        raise ValueError('缺少受支持的构建时源码记录')
    if receipt['files'] != source_inventory(root):
        raise ValueError('源码、许可证、构建脚本或文件权限在构建后变化，请重新构建候选')
    return receipt['files']

def verify_upstream(root):
    root = Path(root).resolve()
    archive = root / '.workbench/ntfs-3g.tgz'
    if digest(archive) != UPSTREAM_SHA:
        raise ValueError('上游源码归档摘要不匹配')
    work = root / '.workbench'
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            target = work / member.name
            if member.issym() or member.islnk() or not target.resolve().is_relative_to(work):
                raise ValueError('上游源码归档包含非预期路径')
            if member.isfile():
                if not target.is_file() or target.is_symlink() or digest(target) != hashlib.sha256(source.extractfile(member).read()).hexdigest():
                    raise ValueError('实际编译的上游源码已变化：' + member.name)
