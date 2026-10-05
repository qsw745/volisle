#!/usr/bin/env python3
"""Reject unsafe image inputs using only temporary ordinary files."""
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
from bundle_manifest import sha256
from fskit_fixture import WORK, SIZE, validate_fixture

with tempfile.TemporaryDirectory(prefix='fskit-readonly-', dir=WORK) as temporary:
    folder = Path(temporary)
    image = folder / 'fixture.img'
    boot = bytearray(512)
    boot[3:11] = b'NTFS    '; boot[510:] = b'\x55\xaa'
    boot[0x48:0x50] = bytes.fromhex('0102030405060708')
    with image.open('xb') as stream:
        stream.write(boot); stream.truncate(SIZE)
    document = {'schema': 1, 'size': SIZE, 'image_sha256': sha256(image)}
    receipt = folder / 'fixture.json'
    receipt.write_text(json.dumps(document))
    assert validate_fixture(folder)['serial_hex'] == '0102030405060708'
    def rejects():
        try: validate_fixture(folder)
        except (ValueError, OSError): return
        raise AssertionError('unsafe fixture accepted')
    receipt.write_text(json.dumps(dict(document, image_sha256='0' * 64))); rejects()
    receipt.write_text(json.dumps(dict(document, size=2000000000000))); rejects()
    receipt.write_text(json.dumps(dict(document, schema=2))); rejects()
    receipt.write_text(json.dumps(document))
    extra = folder / 'hard-link'; os.link(image, extra); rejects(); extra.unlink()
    renamed = folder / 'original'; image.rename(renamed)
    image.symlink_to(renamed); rejects(); image.unlink(); renamed.rename(image)
    with image.open('r+b') as stream: stream.truncate(512)
    rejects()
with tempfile.TemporaryDirectory(prefix='fskit-readonly-', dir=WORK) as temporary:
    folder = Path(temporary); image = folder / 'fixture.img'
    with image.open('xb') as stream:
        stream.write(boot); stream.truncate(512 * 1024 * 1024)
    receipt = folder / 'fixture.json'
    receipt.write_text(json.dumps({'schema': 1, 'size': 512 * 1024 * 1024, 'image_sha256': sha256(image)}))
    assert validate_fixture(folder)['size'] == 512 * 1024 * 1024, '大文件夹具应保留精确容量绑定'
    scripts = Path(__file__).resolve().parent
    for script, options in [
        ('prepare-extension-bundle.py', ['--bundle-id', 'top.qisw.volisle']),
        ('sign-extension-bundle.py', ['--profile', str(folder / 'unused-profile')]),
    ]:
        output = folder / ('rejected-' + script)
        result = subprocess.run([sys.executable, str(scripts / script), *options,
                                 '--write-fixture', str(folder), '--write-service-fixture',
                                 '--output-dir', str(output)], capture_output=True, text=True)
        assert result.returncode == 2 and '后台镜像事务目前仅支持 64 MiB' in result.stderr, result.stderr
        assert not output.exists(), '不支持的后台模式不能生成候选'

    with image.open('r+b') as stream: stream.truncate(128 * 1024 * 1024)
    receipt.write_text(json.dumps({'schema': 1, 'size': 128 * 1024 * 1024, 'image_sha256': sha256(image)}))
    rejects()
print('镜像输入验证：64/512 MiB 正常夹具与 7 个输入拒绝及 2 个后台模式拒绝场景通过；未连接镜像。')
