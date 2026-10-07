#!/usr/bin/env python3
"""Checks stale artifact rejection using disposable ordinary files only."""
from copy import deepcopy
import json
import os
from pathlib import Path
import tempfile
from bundle_manifest import inventory, sha256, verify_manifest

with tempfile.TemporaryDirectory(prefix='volisle-bundle-fixture-') as temporary:
    parent = Path(temporary)
    bundle = parent / 'fixture.app'
    binary = bundle / 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b'fixture-binary')
    binary.chmod(0o755)
    receipt = parent / 'build-manifest.json'
    original = {
        'schema_version': 1, 'bundle_id': 'test.fixture', 'extension_bundle_id': 'test.fixture.filesystem',
        'extension_build': {'experimental_writes': False, 'target': 'arm64-apple-macos' + os.environ.get('VOLISLE_MIN_MACOS', '15.4'), 'binary_sha256': sha256(binary)},
        'files': inventory(bundle),
    }
    receipt.write_text(json.dumps(original))
    def verify():
        return verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem')
    def rejected():
        try: verify()
        except ValueError: return
        raise AssertionError('accepted changed candidate')
    verify()
    for path, value in [
        (['schema_version'], 2), (['bundle_id'], 'other.fixture'),
        (['extension_bundle_id'], 'other.fixture.filesystem'),
        (['extension_build', 'experimental_writes'], True),
        (['extension_build', 'experimental_replacement'], True),
        (['extension_build', 'experimental_private_permissions'], True),
        (['extension_build', 'binary_sha256'], '0' * 64),
        (['extension_build', 'target'], 'other-target'),
    ]:
        document = deepcopy(original); node = document
        for key in path[:-1]: node = node[key]
        node[path[-1]] = value
        receipt.write_text(json.dumps(document)); rejected()
    receipt.write_text(json.dumps(original))
    binary.write_bytes(b'substituted-binary'); rejected()
    binary.write_bytes(b'fixture-binary')
    binary.chmod(0o644); rejected(); binary.chmod(0o755)
    extra = bundle / 'extra'; extra.write_text('unreviewed'); rejected(); extra.unlink()
    extra.symlink_to(binary); rejected(); extra.unlink()
    binary.unlink(); rejected()
    binary.write_bytes(b'fixture-binary'); binary.chmod(0o755)
    fixture = {'serial_hex': '0102030405060708', 'size': 67108864, 'image_sha256': 'a' * 64}
    experimental = deepcopy(original)
    experimental['extension_build'].update(experimental_writes=True, fixture=fixture)
    receipt.write_text(json.dumps(experimental))
    rejected()  # Normal signing must still reject experimental artifacts.
    verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', fixture)
    wrong_fixture = dict(fixture, serial_hex='0807060504030201')
    try: verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', wrong_fixture)
    except ValueError: pass
    else: raise AssertionError('accepted other fixture binding')
    experimental['extension_build']['experimental_replacement'] = True
    receipt.write_text(json.dumps(experimental))
    try: verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', fixture)
    except ValueError: pass
    else: raise AssertionError('覆盖实验未单独授权仍被接受')
    verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', fixture, replacement=True)
    experimental['extension_build']['experimental_private_permissions'] = True
    receipt.write_text(json.dumps(experimental))
    for arguments in [dict(fixture=fixture,replacement=True),dict(fixture=fixture,replacement=True,private_permissions=True,daily=True)]:
        try: verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', **arguments)
        except ValueError: pass
        else: raise AssertionError('私有权限实验未被单独隔离')
    verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', fixture, replacement=True, private_permissions=True)
    physical = {'bsd_name': 'disk999s1', 'root': '/Volisle-Test-fixture', 'expires_at': 123}
    physical_build = deepcopy(original)
    physical_build['extension_build'].update(experimental_writes=True, physical_test=physical)
    receipt.write_text(json.dumps(physical_build))
    rejected()
    verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', physical=physical)
    for arguments in [dict(physical=dict(physical, bsd_name='disk998s1')),
                      dict(physical=physical, fixture=fixture), dict(physical=physical, replacement=True)]:
        try: verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', **arguments)
        except ValueError: pass
        else: raise AssertionError('实盘候选接受了其他设备、镜像或覆盖保存范围')
    daily = deepcopy(original)
    daily['extension_build']['daily_writes'] = True
    receipt.write_text(json.dumps(daily))
    rejected()
    verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', daily=True)
    for arguments in [dict(daily=True, fixture=fixture), dict(daily=True, physical=physical), dict(daily=True, replacement=True)]:
        try: verify_manifest(bundle, receipt, 'test.fixture', 'test.fixture.filesystem', **arguments)
        except ValueError: pass
        else: raise AssertionError('日常写入与测试绑定混用')
print('构建记录验证通过：文件完整性、普通写入与覆盖实验的独立门禁。')
print('实验候选：准确绑定通过；默认签名及其他镜像绑定均被拒绝。')
