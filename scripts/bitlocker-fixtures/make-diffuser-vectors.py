#!/usr/bin/env python3
"""Generate independent vectors using pinned Dislocker code + OpenSSL.

Development only; requires OpenSSL headers/libs (brew) and cryptography in the
selected Python. Reference sources stay in .workbench, never in the product.
The checked-in JSON is sufficient to run tests without these dependencies.
"""
import base64
import ctypes as C
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.workbench/bitlocker-diffuser-reference'
COMMIT = '21ef6e58deb400502121e80fc0dfc7d9974e364f'
SOURCES = {
    'diffuser.c': 'd522d104a6f00374e48e0d3c7b16b0aa5b96831b07e672957f33bb7f2301e0e7',
    'encrypt.c': '186ab1507e2710a5ea878c8547ebaddf436059add2d21019c3f29e372c7b2d5e',
    'decrypt.c': '3e957ee63d70b3e0110040a27cba147e93455040d0bb2b30d014b65b6d440399',
}


def function(source, name):
    """Keep the upstream function body verbatim; adapt only its AES bindings."""
    start = source.index('void ' + name + '(')
    pos = source.index('{', start)
    depth = 1
    end = pos + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def reference_library():
    WORK.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name, digest in SOURCES.items():
        path = WORK / name
        if not path.exists():
            path.write_bytes(urllib.request.urlopen(
                f'https://raw.githubusercontent.com/Aorimn/dislocker/{COMMIT}/src/encryption/{name}', timeout=30).read())
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, name
        sources[name] = data.decode()
    prefix = r'''
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <openssl/aes.h>
typedef struct { AES_KEY FVEK_E_ctx, FVEK_D_ctx, TWEAK_E_ctx; } dis_aes_contexts_t;
#define AES_ECB_ENC(ctx,mode,in,out) AES_ecb_encrypt(in,out,ctx,mode)
#define AES_CBC(ctx,mode,n,iv,in,out) AES_cbc_encrypt(in,out,n,ctx,iv,mode)
'''
    # diffuser.c keeps its copyright/license header. Only unavailable include
    # directives are removed; its algorithm is not rewritten by the generator.
    diffuser = re.sub(r'^#include .*$', '', sources['diffuser.c'], flags=re.M)
    functions = '\n'.join(function(sources[file], name) for file, name in [
        ('encrypt.c', 'encrypt_cbc_without_diffuser'), ('encrypt.c', 'encrypt_cbc_with_diffuser'),
        ('decrypt.c', 'decrypt_cbc_without_diffuser'), ('decrypt.c', 'decrypt_cbc_with_diffuser')])
    suffix = r'''
void reference_sector(int bits, int size, const uint8_t key[64], uint64_t offset,
                      int encrypt, const uint8_t *input, uint8_t *output) {
    dis_aes_contexts_t ctx;
    AES_set_encrypt_key(key,bits,&ctx.FVEK_E_ctx);
    AES_set_decrypt_key(key,bits,&ctx.FVEK_D_ctx);
    AES_set_encrypt_key(key+32,bits,&ctx.TWEAK_E_ctx);
    if (encrypt) encrypt_cbc_with_diffuser(&ctx,size,(uint8_t*)input,offset,output);
    else decrypt_cbc_with_diffuser(&ctx,size,(uint8_t*)input,offset,output);
}
void reference_convert_cbc(int bits, int size, const uint8_t *old_key, const uint8_t key[64],
                           uint8_t *data, size_t length) {
    dis_aes_contexts_t old, next;
    AES_set_encrypt_key(old_key,bits,&old.FVEK_E_ctx);
    AES_set_decrypt_key(old_key,bits,&old.FVEK_D_ctx);
    AES_set_encrypt_key(key,bits,&next.FVEK_E_ctx);
    AES_set_encrypt_key(key+32,bits,&next.TWEAK_E_ctx);
    for (size_t at=0; at<length; at+=size) {
        decrypt_cbc_without_diffuser(&old,size,data+at,at,data+at);
        encrypt_cbc_with_diffuser(&next,size,data+at,at,data+at);
    }
}
'''
    (WORK / 'reference.c').write_text(prefix + diffuser + functions + suffix)
    openssl = Path(subprocess.check_output(['brew', '--prefix', 'openssl@3'], text=True).strip())
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-shared', '-fPIC',
                    '-I', str(openssl / 'include'), '-L', str(openssl / 'lib'), '-lcrypto',
                    str(WORK / 'reference.c'), '-o', str(WORK / 'reference.dylib')], check=True)
    lib = C.CDLL(str(WORK / 'reference.dylib'))
    lib.reference_sector.argtypes = [C.c_int, C.c_int, C.c_void_p, C.c_uint64, C.c_int, C.c_void_p, C.c_void_p]
    lib.reference_sector.restype = None
    lib.reference_convert_cbc.argtypes = [C.c_int, C.c_int, C.c_void_p, C.c_void_p, C.c_void_p, C.c_size_t]
    lib.reference_convert_cbc.restype = None
    return lib


def crypt(lib, bits, key, offset, data, encrypt=True):
    out = C.create_string_buffer(len(data))
    lib.reference_sector(bits, len(data), key, offset, encrypt, data, out)
    return out.raw


def unlock_fixture(lib, bits, size):
    """Synthetic v2 metadata, independently wrapped with cryptography AESCCM.

    These fixtures exercise the public unlock/I/O API, not Windows provenance.
    All keys/passwords below are public test values for disposable buffers.
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESCCM
    password = '盘屿测试 Diffuser🔐'
    recovery = '-'.join(['000011'] * 8)
    vmk, fvek = bytes(range(32)), bytes(range(64))
    method = 0x8000 if bits == 128 else 0x8001
    total, store, data_offset = 1 << 20, 256 << 10, 320 << 10

    def entry(etype, vtype, data):
        return struct.pack('<HHHH', len(data) + 8, etype, vtype, 1) + data

    def wrap(key, payload, nonce):
        sealed = AESCCM(key).encrypt(nonce, payload, None)
        return nonce + sealed[-16:] + sealed[:-16]

    def key_payload(key, kind):
        return struct.pack('<IHHI', 12 + len(key), 1, 0, kind) + key

    protectors = b''
    for kind, initial in [(0x2000, hashlib.sha256(hashlib.sha256(password.encode('utf-16le')).digest()).digest()),
                          (0x0800, hashlib.sha256(b'\x01\x00' * 8).digest())]:
        salt = bytes(range(16))
        stretched = bytes(32)
        for count in range(0x100000):
            stretched = hashlib.sha256(stretched + initial + salt + struct.pack('<Q', count)).digest()
        props = bytearray(28)
        struct.pack_into('<H', props, 26, kind)
        props += entry(0, 3, struct.pack('<I', 0x1000) + salt)
        nonce = bytes([kind >> 8]) * 12
        props += entry(0, 5, wrap(stretched, key_payload(vmk, 0x2000), nonce))
        protectors += entry(2, 8, props)

    def metadata(key=fvek, key_method=method):
        entries = protectors + entry(3, 5, wrap(vmk, key_payload(key, key_method), bytes([33]) * 12))
        block = bytearray(112)
        block[:8] = b'-FVE-FS-'
        struct.pack_into('<H', block, 10, 2)
        struct.pack_into('<Q', block, 16, total)
        struct.pack_into('<I', block, 28, 8192 // size)
        struct.pack_into('<Q', block, 56, store)
        struct.pack_into('<III', block, 64, 48 + len(entries), 1, 48)
        struct.pack_into('<I', block, 100, method)
        return bytes(block) + entries

    boot = bytearray(512)
    boot[3:11] = b'-FVE-FS-'
    struct.pack_into('<H', boot, 11, size)
    for i in range(3):
        struct.pack_into('<Q', boot, 176 + 8 * i, (i + 1) * 65536)
    segments = [(0, bytes(boot))]
    block = metadata()
    segments += [((i + 1) * 65536, block) for i in range(3)]
    for offset, length in [(store, 8192), (data_offset, size * 3)]:
        for at in range(offset, offset + length, size):
            plain = bytes((i * 37 + (i >> 3) + 19) & 255 for i in range(size))
            segments.append((at, crypt(lib, bits, fvek, at, plain)))
    updated = bytearray(plain * 3)
    updated[13:13 + size + 100] = (b'VOLISLE' * ((size + 106) // 7))[:size + 100]
    written = b''.join(crypt(lib, bits, fvek, data_offset + at, bytes(updated[at:at + size]))
                       for at in range(0, size * 3, size))
    return {'bits': bits, 'sector_size': size, 'size': total, 'vmk': vmk.hex(),
            'password': password, 'recovery': recovery, 'data_offset': data_offset,
            'written_ciphertext': base64.b64encode(written).decode(),
            'segments': [{'offset': at, 'data': base64.b64encode(data).decode()} for at, data in segments],
            'malformed_metadata': {label: base64.b64encode(data).decode() for label, data in [
                ('short_key', metadata(fvek[:32])), ('long_key', metadata(fvek + b'!')),
                ('mismatched_method', metadata(key_method=0x8002))]}}


def main():
    lib = reference_library()
    vectors = []
    # Nonzero padding catches an incorrect AES-128 tweak split at byte 16.
    key = bytes(range(64))
    for bits in (128, 256):
        for size in (512, 4096):
            for offset in (0, size, 0x123456789000):
                plain = bytes((i * 37 + (i >> 3) + 19) & 255 for i in range(size))
                encrypted = crypt(lib, bits, key, offset, plain)
                assert crypt(lib, bits, key, offset, encrypted, False) == plain
                vectors.append({'bits': bits, 'sector_size': size, 'offset': offset,
                                'key': key.hex(), 'ciphertext': base64.b64encode(encrypted).decode()})
    target = ROOT / 'scripts/fixtures/bitlocker-diffuser-vectors.json'
    target.write_text(json.dumps({'source': f'https://github.com/Aorimn/dislocker/tree/{COMMIT}',
                                 'source_sha256': SOURCES, 'vectors': vectors}, indent=2) + '\n')
    target = ROOT / 'scripts/fixtures/bitlocker-diffuser-unlock.json'
    target.write_text(json.dumps({'provenance': 'Synthetic v2 metadata; cryptography AESCCM + pinned Dislocker sector encryption; not Windows-created',
                                 'fixtures': [unlock_fixture(lib, bits, size) for bits in (128, 256) for size in (512, 4096)]}, indent=2) + '\n')
    print(f'{len(vectors)} independent vectors and 4 synthetic unlock fixtures generated')


if __name__ == '__main__':
    main()
