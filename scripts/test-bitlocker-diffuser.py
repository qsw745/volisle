#!/usr/bin/env python3
"""Exact independent ciphertext/decryption tests of the production BDE layer.

No physical devices. Tests use checked-in Dislocker/OpenSSL vectors; neither
Dislocker nor OpenSSL is needed at test runtime. Use --sanitize for ASan/UBSan.
"""
import base64
import ctypes as C
import errno
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.workbench/bitlocker-diffuser-tests'
OUT.mkdir(parents=True, exist_ok=True)
SANITIZE = '--sanitize' in sys.argv
if SANITIZE:
    sys.argv.remove('--sanitize')
DYLIB = OUT / 'driver.dylib'
subprocess.run(['clang', '-g', '-O1', '-Wno-deprecated-declarations', '-shared', '-fPIC',
                str(ROOT / 'scripts/fixtures/bitlocker-diffuser-driver.c'), '-o', str(DYLIB)], check=True)
if SANITIZE:
    subprocess.run(['clang', '-g', '-O1', '-Wno-deprecated-declarations', '-fsanitize=address,undefined',
                    '-fno-omit-frame-pointer', '-DNK_DIFFUSER_TEST_MAIN=1',
                    str(ROOT / 'scripts/fixtures/bitlocker-diffuser-driver.c'),
                    '-o', str(OUT / 'driver-sanitized')], check=True)
LIB = C.CDLL(str(DYLIB), use_errno=True)
LIB.test_bde_sector.argtypes = [C.c_uint32, C.c_void_p, C.c_size_t, C.c_int, C.c_int64, C.c_int, C.c_void_p]
LIB.test_bde_sector.restype = C.c_int
VECTORS = json.loads((ROOT / 'scripts/fixtures/bitlocker-diffuser-vectors.json').read_text())['vectors']
FIXTURES = json.loads((ROOT / 'scripts/fixtures/bitlocker-diffuser-unlock.json').read_text())['fixtures']
PREAD = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_void_p, C.c_longlong, C.c_longlong)
PWRITE = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_void_p, C.c_longlong, C.c_longlong)
SYNC = C.CFUNCTYPE(C.c_int, C.c_void_p)


class IO(C.Structure):
    _fields_ = [('ctx', C.c_void_p), ('pread', PREAD), ('pwrite', PWRITE),
                ('size', C.c_longlong), ('readonly', C.c_int), ('sync', SYNC)]


LIB.nk_bde_open.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_bde_open.restype = C.c_void_p
LIB.nk_bde_io.argtypes = [C.c_void_p]
LIB.nk_bde_io.restype = IO
LIB.nk_bde_close.argtypes = [C.c_void_p]
LIB.nk_bde_derive_key.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_bde_derive_key.restype = C.c_int


class MemoryDisk:
    def __init__(self, fixture, readonly=False):
        self.raw = bytearray(fixture['size'])
        for segment in fixture['segments']:
            data = base64.b64decode(segment['data'])
            self.raw[segment['offset']:segment['offset'] + len(data)] = data
        self.writes = 0
        self.fail_read = self.fail_write = self.fail_sync = False

        @PREAD
        def read(_, buf, count, offset):
            if self.fail_read or offset < 0 or offset + count > len(self.raw):
                return -1
            C.memmove(buf, bytes(self.raw[offset:offset + count]), count)
            return count

        @PWRITE
        def write(_, buf, count, offset):
            self.writes += 1
            if self.fail_write or offset < 0 or offset + count > len(self.raw):
                return -1
            self.raw[offset:offset + count] = C.string_at(buf, count)
            return count

        @SYNC
        def sync(_):
            return -1 if self.fail_sync else 0

        self.callbacks = read, write, sync
        self.io = IO(None, read, write, len(self.raw), readonly, sync)

    def open(self, secret, kind=3):
        err = C.create_string_buffer(128)
        C.set_errno(0)
        handle = LIB.nk_bde_open(C.byref(self.io), kind, secret.encode(), err, len(err))
        return handle, C.get_errno(), err.value.decode()


def read_view(io, offset, count):
    buf = C.create_string_buffer(count)
    result = io.pread(io.ctx, buf, count, offset)
    return result, buf.raw


class DiffuserTests(unittest.TestCase):
    def crypt(self, method, key, size, offset, encrypt, source):
        if SANITIZE:
            p = subprocess.run([str(OUT / 'driver-sanitized'), str(method), key.hex(), str(size),
                                str(offset), str(encrypt)], input=source, capture_output=True,
                               env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(p.stderr, b'', p.stderr.decode(errors='replace'))
            return p.returncode, p.stdout
        buf = C.create_string_buffer(b'!' + source)
        result = LIB.test_bde_sector(method, key, len(key), size, offset, encrypt, C.byref(buf, 1))
        return result, buf.raw[1:1 + size]

    def test_independent_ciphertext_and_plaintext(self):
        # Catches wrong key split, diffuser ordering, rotations, arithmetic and
        # sector address derivation; encrypt/decrypt are checked independently.
        for v in VECTORS:
            with self.subTest(bits=v['bits'], size=v['sector_size'], offset=v['offset']):
                method = 0x8000 if v['bits'] == 128 else 0x8001
                key = bytes.fromhex(v['key'])
                plain = bytes((i * 37 + (i >> 3) + 19) & 255 for i in range(v['sector_size']))
                cipher = base64.b64decode(v['ciphertext'])
                for encrypt, source, expected in [(1, plain, cipher), (0, cipher, plain)]:
                    # Intentionally unaligned: production must not cast byte
                    # buffers to potentially misaligned uint32_t pointers.
                    result, output = self.crypt(method, key, v['sector_size'], v['offset'], encrypt, source)
                    self.assertEqual(result, 0)
                    self.assertEqual(output, expected)

    @unittest.skipUnless(SANITIZE, '使用 --sanitize 运行原生公开解锁及 I/O 检查')
    def test_public_io_under_sanitizer(self):
        for f in FIXTURES:
            with self.subTest(bits=f['bits'], sector=f['sector_size']):
                disk = MemoryDisk(f)
                p = subprocess.run([str(OUT / 'driver-sanitized'), '--io', f['vmk'], str(f['size']),
                                    str(f['sector_size']), str(f['data_offset'])],
                                   input=bytes(disk.raw) + base64.b64decode(f['written_ciphertext']),
                                   capture_output=True, env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
                self.assertEqual(p.returncode, 0, p.stderr.decode(errors='replace'))
                self.assertEqual(p.stderr, b'')

    def test_diffuser_requires_full_64_byte_key_material(self):
        # A truncated FVEK/TWEAK must not become a wrong-key writable view.
        for method in (0x8000, 0x8001):
            for length in (0, 16, 32, 48, 63, 65):
                with self.subTest(method=method, length=length):
                    result, _ = self.crypt(method, bytes(length), 512, 0, 0, bytes(512))
                    self.assertNotEqual(result, 0)

    def test_public_unlock_password_recovery_and_master_key(self):
        for f in FIXTURES:
            for kind, secret in [(1, f['password']), (2, f['recovery']), (3, f['vmk'])]:
                with self.subTest(bits=f['bits'], sector=f['sector_size'], kind=kind):
                    disk = MemoryDisk(f, readonly=True)
                    before = bytes(disk.raw)
                    handle, error, message = disk.open(secret, kind)
                    self.assertTrue(handle, (error, message))
                    self.addCleanup(LIB.nk_bde_close, handle)
                    view = LIB.nk_bde_io(handle)
                    size = f['sector_size']
                    plain = bytes((i * 37 + (i >> 3) + 19) & 255 for i in range(size))
                    self.assertEqual(read_view(view, f['data_offset'], size * 3), (size * 3, plain * 3))
                    # The logical header must use the physical store's address
                    # for BOTH its sector key and CBC IV.
                    self.assertEqual(read_view(view, 0, 8192), (8192, plain * (8192 // size)))
                    self.assertEqual(read_view(view, 65536, size), (size, bytes(size)))
                    self.assertEqual(view.readonly, 1)
                    self.assertFalse(view.pwrite)
                    self.assertFalse(view.sync)
                    self.assertEqual(bytes(disk.raw), before)
                    self.assertEqual(disk.writes, 0)
                    if kind != 3:
                        out = C.create_string_buffer(65)
                        self.assertEqual(LIB.nk_bde_derive_key(C.byref(disk.io), kind, secret.encode(), out, None, 0), 0)
                        self.assertEqual(out.value.decode(), f['vmk'])

    def test_unaligned_write_matches_independent_ciphertext(self):
        for f in FIXTURES:
            with self.subTest(bits=f['bits'], sector=f['sector_size']):
                disk = MemoryDisk(f)
                handle, error, message = disk.open(f['vmk'])
                self.assertTrue(handle, (error, message))
                try:
                    view = LIB.nk_bde_io(handle)
                    self.assertEqual(view.readonly, 0)
                    size, offset = f['sector_size'], f['data_offset']
                    before = bytes(disk.raw)
                    data = (b'VOLISLE' * ((size + 106) // 7))[:size + 100]
                    self.assertEqual(view.pwrite(view.ctx, data, len(data), offset + 13), len(data))
                    self.assertEqual(disk.raw[offset:offset + size * 3], base64.b64decode(f['written_ciphertext']))
                    self.assertEqual(disk.raw[:offset], before[:offset])
                    self.assertEqual(disk.raw[offset + size * 3:], before[offset + size * 3:])
                    self.assertEqual(view.sync(view.ctx), 0)
                finally:
                    LIB.nk_bde_close(handle)
                handle, _, _ = disk.open(f['vmk'])
                self.assertTrue(handle)
                try:
                    self.assertEqual(read_view(LIB.nk_bde_io(handle), offset + 13, len(data)), (len(data), data))
                finally:
                    LIB.nk_bde_close(handle)

    def test_reserved_regions_and_io_failure_propagation(self):
        for f in FIXTURES:
            disk = MemoryDisk(f)
            handle, _, message = disk.open(f['vmk'])
            self.assertTrue(handle, message)
            try:
                view = LIB.nk_bde_io(handle)
                before = bytes(disk.raw)
                for offset in (65536, 65536 - 10, (256 << 10) - 10, 256 << 10):
                    self.assertEqual(view.pwrite(view.ctx, b'!' * 20, 20, offset), -1)
                self.assertEqual(disk.writes, 0)
                self.assertEqual(bytes(disk.raw), before)
                disk.fail_read = True
                self.assertEqual(view.pwrite(view.ctx, b'!', 1, f['data_offset'] + 1), -1)
                self.assertEqual(disk.writes, 0)
                self.assertEqual(read_view(view, f['data_offset'], 1)[0], -1)
                disk.fail_read = False
                disk.fail_write = True
                self.assertEqual(view.pwrite(view.ctx, bytes(f['sector_size']), f['sector_size'], f['data_offset']), -1)
                disk.fail_sync = True
                self.assertEqual(view.sync(view.ctx), -1)
                self.assertEqual(bytes(disk.raw), before)
            finally:
                LIB.nk_bde_close(handle)

    def test_bad_credentials_or_metadata_never_write(self):
        for f in FIXTURES:
            disk = MemoryDisk(f)
            for kind, secret in [(1, 'wrong'), (2, '-'.join(['000022'] * 8)), (3, 'ff' * 32)]:
                handle, error, _ = disk.open(secret, kind)
                self.assertFalse(handle)
                self.assertEqual(error, errno.EACCES)
            for label, block in f['malformed_metadata'].items():
                bad = MemoryDisk(f)
                data = base64.b64decode(block)
                for offset in (65536, 131072, 196608):
                    bad.raw[offset:offset + len(data)] = data
                self.assertFalse(bad.open(f['vmk'])[0], label)
                self.assertEqual(bad.writes, 0)
            for field, value, fmt in [(100, 0x8006, '<I'), (16, f['size'] - f['sector_size'], '<Q'), (10, 1, '<H')]:
                bad = MemoryDisk(f)
                for offset in (65536, 131072, 196608):
                    struct.pack_into(fmt, bad.raw, offset + field, value)
                self.assertFalse(bad.open(f['vmk'])[0])
                self.assertEqual(bad.writes, 0)
            self.assertEqual(disk.writes, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
