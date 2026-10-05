#!/usr/bin/env python3
"""Bounded acceptance payloads shared by the single-authorization test runner."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import time


def run(args):
    return subprocess.run([str(x) for x in args],check=True,capture_output=True,timeout=120)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def xattr(path):
    return bytes.fromhex(run(['/usr/bin/xattr','-px','com.volisle.test',path]).stdout.decode())


def verify(base,expected):
    base=Path(base)
    if base.is_symlink() or not base.is_dir() or not expected:
        raise ValueError('测试目录或校验清单无效')
    paths=[]
    for name,sha in expected.items():
        if (not isinstance(name,str) or name.startswith('/') or '\\' in name or ':' in name or
            any(p in ('','.','..') for p in name.split('/')) or
            not isinstance(sha,str) or not re.fullmatch('[0-9a-f]{64}',sha)):
            raise ValueError('校验清单包含无效路径或摘要')
        target=base
        for component in PurePosixPath(name).parts:
            target=target/component
            if target.is_symlink():raise ValueError('校验路径不能是符号链接')
        if not target.is_file():raise ValueError('缺少测试文件：'+name)
        paths.append((target,sha))
    for path,sha in paths:
        if digest(path)!=sha:raise ValueError('文件摘要不一致：'+path.name)
    if (base/'remove-me.txt').exists() or (base/'empty-dir').exists():
        raise ValueError('删除测试未完成')
    if xattr(base/'中文 空格.txt')!=b'ntfs-physical-test':
        raise ValueError('扩展属性不一致')


def populate(base,large_bytes=64*1024*1024,progress=lambda _:None):
    base=Path(base)
    if not isinstance(large_bytes,int) or not 65536<=large_bytes<=64*1024*1024:
        raise ValueError('本轮只允许 64 KiB 至 64 MiB 测试负载')
    script=Path(__file__).with_name('verify-windows.ps1').read_bytes()
    # Fail if any test directory already exists, even if empty or a symlink.
    base.mkdir()
    expected={}
    def create(name,data):
        with (base/name).open('xb') as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        expected[name]=hashlib.sha256(data).hexdigest()
        if digest(base/name)!=expected[name]:raise ValueError('新写入文件校验失败')
    create('中文 空格.txt','盘屿 Volisle 实盘测试：中文路径和读写校验。\n'.encode()*1024)
    progress('中文路径创建、同步与完整回读')
    name='large-64MiB.bin' if large_bytes==64*1024*1024 else f'large-{large_bytes//1024}KiB.bin'
    payload=bytearray(hashlib.shake_256(b'Volisle physical acceptance').digest(large_bytes))
    create(name,payload);progress('大文件写入与完整 SHA-256 回读')
    with (base/name).open('r+b') as stream:
        for offset in [123,large_bytes//2+17,large_bytes-4096]:
            patch=b'Volisle-random-update'*73
            stream.seek(offset);stream.write(patch);payload[offset:offset+len(patch)]=patch
        stream.flush();os.fsync(stream.fileno())
    expected[name]=hashlib.sha256(payload).hexdigest()
    if digest(base/name)!=expected[name]:raise ValueError('随机覆盖后摘要不一致')
    del payload
    progress('三处随机覆盖、同步与完整校验')
    (base/'nested').mkdir()
    for i in range(16):create(f'small-{i:02}.bin',hashlib.shake_256(str(i).encode()).digest(513+i*97))
    (base/'small-00.bin').rename(base/'nested/移动.bin')
    expected['nested/移动.bin']=expected.pop('small-00.bin')
    run(['/usr/bin/xattr','-wx','com.volisle.test',b'ntfs-physical-test'.hex(),base/'中文 空格.txt'])
    with (base/'remove-me.txt').open('xb') as stream:
        stream.write(b'disposable');stream.flush();os.fsync(stream.fileno())
    (base/'remove-me.txt').unlink();(base/'empty-dir').mkdir();(base/'empty-dir').rmdir()
    progress('小文件、跨目录改名、扩展属性与删除')
    create('Verify-Windows.ps1',script)
    create('checksums.json',(json.dumps({'files':expected.copy(),'created_at':time.time()},ensure_ascii=False,indent=2)+'\n').encode())
    verify(base,expected);progress('20 个文件与扩展属性完整校验')
    return expected
