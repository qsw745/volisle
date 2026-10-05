#!/usr/bin/env python3
"""BitLocker read-only unlock (nk_bde_*) on images Windows 11 created (see
.workbench/bitlocker-fixtures: XTS/CBC, 128/256, password + recovery password).
Read-only: the images are opened O_RDONLY and hashed before and after."""
import ctypes as C
import errno
import hashlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, IO

ELIB = C.CDLL(LIB._name, use_errno=True)
ELIB.nk_bde_probe.argtypes = [C.POINTER(IO)]
ELIB.nk_bde_probe.restype = C.c_int
ELIB.nk_bde_open.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_size_t]
ELIB.nk_bde_open.restype = C.c_void_p
ELIB.nk_bde_io.argtypes = [C.c_void_p]
ELIB.nk_bde_io.restype = IO
ELIB.nk_bde_close.argtypes = [C.c_void_p]
ELIB.nk_bde_derive_key.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t]
ELIB.nk_bde_derive_key.restype = C.c_int
LIB.nk_format.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_char_p, C.c_size_t]
LIB.nk_format.restype = C.c_int
FIXTURES = ROOT / '.workbench/bitlocker-fixtures'
PASSWORD, RECOVERY, KEY = 1, 2, 3
checks = []


def passed(name):
    checks.append({'name': name, 'passed': True})
    print('PASS', name, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unlock(device, kind, secret):
    err = C.create_string_buffer(96)
    C.set_errno(0)
    handle = ELIB.nk_bde_open(C.byref(device.io), kind, secret.encode(), err, 96)
    return handle, (0 if handle else C.get_errno()), err.value.decode()


def read_file(v, path, size):
    out = C.create_string_buffer(size)
    assert LIB.nk_read(v, path.encode(), 0, size, out) == size, path
    return hashlib.sha256(out.raw).hexdigest()


def verify(name, kind, secret, files):
    device = ImageIO(FIXTURES / f'{name}.img', readonly=True)
    handle, error, reason = unlock(device, kind, secret)
    assert handle, (name, error, reason)
    plain = ELIB.nk_bde_io(handle)
    assert plain.readonly == 1 and not plain.pwrite and plain.size == device.io.size
    assert LIB.nk_inspect(C.byref(plain)) in (0, 3), '解密后是可识别的 NTFS'
    v = LIB.nk_mount_io(C.byref(plain), None, 0)
    assert v, name
    for f in files:
        assert read_file(v, '/' + f['path'], f['size']) == f['sha256'], (name, f['path'])
    assert LIB.nk_umount(v) == 0
    ELIB.nk_bde_close(handle)
    assert device.writes == 0
    device.close()


names = ['xts128', 'xts256', 'cbc128', 'cbc256']
metas = {n: json.loads((FIXTURES / f'{n}.json').read_text(encoding='utf-8-sig')) for n in names}
before = {n: digest(FIXTURES / f'{n}.img') for n in names}

for n in names:
    started = time.time()
    verify(n, PASSWORD, metas[n]['password'], metas[n]['files'])
    print(f'  {n}：{metas[n]["method"]}，{time.time() - started:.1f}s', flush=True)
passed('XTS-AES 128/256 与 AES-CBC 128/256：用密码解锁后只读挂载，中文路径文件与 3 MiB 文件的 SHA-256 与 Windows 一致')

for n in names:
    verify(n, RECOVERY, metas[n]['recovery'], metas[n]['files'])
passed('四块盘都能用 48 位恢复密钥解锁并读出一致的内容')

def derive(device, kind, secret):
    out, err = C.create_string_buffer(65), C.create_string_buffer(96)
    C.set_errno(0)
    status = ELIB.nk_bde_derive_key(C.byref(device.io), kind, secret.encode(), out, err, 96)
    return (out.value.decode() if status == 0 else None), C.get_errno()


for n in names:
    device = ImageIO(FIXTURES / f'{n}.img', readonly=True)
    key, _ = derive(device, PASSWORD, metas[n]['password'])
    assert key and len(key) == 64 and key == key.lower()
    assert derive(device, RECOVERY, metas[n]['recovery'])[0] == key, '两种保护方式解出同一把主密钥'
    assert derive(device, PASSWORD, 'wrong-password') == (None, errno.EACCES)
    assert derive(device, KEY, key)[1] == errno.EINVAL, '不能由主密钥再导出'
    device.close()
    verify(n, KEY, key, metas[n]['files'])
    device = ImageIO(FIXTURES / f'{n}.img', readonly=True)
    flipped = key[:-1] + ('0' if key[-1] != '0' else '1')
    assert unlock(device, KEY, flipped)[1] == errno.EACCES
    for malformed in (key.upper(), key[:-2], key + '00', 'g' * 64, ''):
        assert unlock(device, KEY, malformed)[1] == errno.EINVAL, malformed
    assert device.writes == 0
    device.close()
passed('密码与恢复密钥导出同一把卷主密钥；用主密钥可只读挂载且内容一致；错一位拒绝访问，格式不对参数无效')

device = ImageIO(FIXTURES / 'xts128.img', readonly=True)
assert ELIB.nk_bde_probe(C.byref(device.io)) == 1
assert unlock(device, PASSWORD, 'wrong-password')[1] == errno.EACCES
recovery = metas['xts128']['recovery']
wrong_digit = recovery[:-1] + ('0' if recovery[-1] != '0' else '1')
assert unlock(device, RECOVERY, wrong_digit)[1] == errno.EACCES, '最后一组不能被 11 整除'
valid_but_wrong = '-'.join(['000000'] * 8)
assert unlock(device, RECOVERY, valid_but_wrong)[1] == errno.EACCES
assert unlock(device, RECOVERY, recovery[:-7])[1] == errno.EACCES, '少一组'
assert unlock(device, 9, 'x')[1] == errno.EINVAL
assert device.writes == 0
device.close()
passed('错误密码、校验不通过或组数不对的恢复密钥都返回“拒绝访问”，未知方式返回“参数无效”，全程零写入')

import tempfile
with tempfile.TemporaryDirectory(prefix='volisle-bde-', dir=ROOT / '.workbench') as tmp:
    plain_path = Path(tmp) / 'plain.img'
    with plain_path.open('xb') as f:
        f.truncate(16 << 20)
    plain = ImageIO(plain_path)
    err = C.create_string_buffer(256)
    assert LIB.nk_format(C.byref(plain.io), b'PLAIN', 0, err, 256) == 0
    assert ELIB.nk_bde_probe(C.byref(plain.io)) == 0
    assert unlock(plain, PASSWORD, 'x')[1] == errno.EINVAL
    plain.close()
passed('普通 NTFS 盘不被识别为 BitLocker，解锁请求被拒绝')

assert all(digest(FIXTURES / f'{n}.img') == before[n] for n in names)
passed('四块加密镜像在全部测试前后逐字节不变')

report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'checks': checks,
          'fixtures': {n: metas[n]['method'] for n in names},
          'scope': 'Windows 11 专业版生成的 BitLocker 镜像（160 MB，完全加密）；只读；不涉及 FSKit 或实盘'}
(ROOT / 'docs/testing/bitlocker-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} 项通过')
