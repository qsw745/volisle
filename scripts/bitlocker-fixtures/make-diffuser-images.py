#!/usr/bin/env python3
"""Disposable NTFS integration fixtures, NOT images created by Windows 7.

Convert copies of the existing Windows 11 full-volume CBC fixtures with pinned
Dislocker sector encryption. Rewrap the FVEK and refresh metadata checksums;
retain the original NTFS files, allocation and password/recovery protectors.
Requires the same development dependencies as make-diffuser-vectors.py.
"""
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import zlib

from cryptography.hazmat.primitives.ciphers.aead import AESCCM

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('diffuser_reference', Path(__file__).with_name('make-diffuser-vectors.py'))
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)
import sys
sys.path.insert(0, str(ROOT / 'scripts'))
from ntfs_bridge_test_support import LIB, IO, ImageIO

LIB.nk_bde_derive_key.argtypes = [C.POINTER(IO), C.c_int, C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t]
LIB.nk_bde_derive_key.restype = C.c_int
SOURCE = ROOT / '.workbench/bitlocker-fixtures'
TARGET = ROOT / '.workbench/bitlocker-diffuser-fixtures'


def open_ccm(key, data):
    return AESCCM(key).decrypt(data[:12], data[28:] + data[12:28], None)


def seal_ccm(key, nonce, plain):
    sealed = AESCCM(key).encrypt(nonce, plain, None)
    return nonce + sealed[-16:] + sealed[:-16]


def main():
    lib = reference.reference_library()
    TARGET.mkdir(parents=True, exist_ok=True)
    for bits in (128, 256):
        source_name, name = f'cbc{bits}', f'diffuser{bits}'
        metadata = json.loads((SOURCE / f'{source_name}.json').read_text(encoding='utf-8-sig'))
        image = ImageIO(SOURCE / f'{source_name}.img', readonly=True)
        vmk_text, error = C.create_string_buffer(65), C.create_string_buffer(128)
        try:
            assert LIB.nk_bde_derive_key(C.byref(image.io), 1, metadata['password'].encode(), vmk_text, error, 128) == 0, error.value
        finally:
            image.close()
        vmk = bytes.fromhex(vmk_text.value.decode())
        original = (SOURCE / f'{source_name}.img').read_bytes()
        raw = bytearray(original)
        sector = struct.unpack_from('<H', raw, 11)[0]
        blocks = [struct.unpack_from('<Q', raw, 176 + 8 * i)[0] for i in range(3)]
        first = original[blocks[0]:blocks[0] + 65536]
        end = 64 + struct.unpack_from('<I', first, 64)[0]
        pos, old_fvek = 112, None
        while pos < end:
            size, kind, typ, _ = struct.unpack_from('<HHHH', first, pos)
            if (kind, typ) == (3, 5):
                old_fvek = open_ccm(vmk, first[pos + 8:pos + size])[12:]
                break
            pos += size
        assert old_fvek and len(old_fvek) == bits // 8
        new_fvek = bytes(range(64))
        # Native independent conversion avoids Python callbacks per sector.
        buf = (C.c_ubyte * len(raw)).from_buffer(raw)
        lib.reference_convert_cbc(bits, sector, old_fvek, new_fvek, buf, len(raw))
        header_bytes = struct.unpack_from('<I', first, 28)[0] * sector
        raw[:header_bytes] = original[:header_bytes]
        for offset in blocks:
            block = bytearray(original[offset:offset + 65536])
            old_end = 64 + struct.unpack_from('<I', block, 64)[0]
            pos, entries = 112, b''
            while pos < old_end:
                size, kind, typ, version = struct.unpack_from('<HHHH', block, pos)
                entry = bytes(block[pos:pos + size])
                if (kind, typ) == (3, 5):
                    payload = struct.pack('<IHHI', 76, 1, 0, 0x8000 + (bits == 256)) + new_fvek
                    # Preserve Windows' FILETIME/counter nonce layout and its
                    # relation to the metadata nonce counter. These are public
                    # disposable test keys; this generator is not a rekey API.
                    nonce = entry[8:20]
                    sealed = seal_ccm(vmk, nonce, payload)
                    entry = struct.pack('<HHHH', len(sealed) + 8, kind, typ, version) + sealed
                entries += entry
                pos += size
            new_end = 112 + len(entries)
            assert new_end % 16 == 0
            block[112:new_end] = entries
            struct.pack_into('<H', block, 8, new_end // 16)
            struct.pack_into('<II', block, 64, new_end - 64, 1)
            struct.pack_into('<I', block, 76, new_end - 64)
            # Preserve the two identical 16-bit method values emitted by
            # Windows, rather than changing only the reader's low word.
            old_method = struct.unpack_from('<I', block, 100)[0]
            assert old_method >> 16 == old_method & 0xffff
            method = 0x8000 + (bits == 256)
            struct.pack_into('<I', block, 100, method | method << 16)
            validation = bytearray(original[offset + old_end:offset + old_end + 88])
            struct.pack_into('<I', validation, 4, zlib.crc32(block[:new_end]))
            # The validation datum contains the SHA256 of the metadata, wrapped
            # with VMK. Assert the original interpretation before replacing it.
            old_hash = open_ccm(vmk, bytes(validation[16:88]))
            assert old_hash[12:] == hashlib.sha256(original[offset:offset + old_end]).digest()
            nonce = bytes(validation[16:28])
            validation[16:88] = seal_ccm(vmk, nonce, old_hash[:12] + hashlib.sha256(block[:new_end]).digest())
            block[new_end:new_end + len(validation)] = validation
            raw[offset:offset + 65536] = block
        (TARGET / f'{name}.img').write_bytes(raw)
        # Preserve the container's original MBR and fixed-VHD footer.
        vhd = bytearray((SOURCE / f'{source_name}.vhd').read_bytes())
        start = struct.unpack_from('<I', vhd, 454)[0] * 512
        vhd[start:start + len(raw)] = raw
        (TARGET / f'{name}.vhd').write_bytes(vhd)
        metadata.update({'method': f'AES-CBC {bits} with Elephant Diffuser',
                         'provenance': 'Converted Windows 11 CBC fixture using pinned Dislocker; NOT Windows 7-created',
                         'source_image_sha256': hashlib.sha256(original).hexdigest(),
                         'image_sha256': hashlib.sha256(raw).hexdigest()})
        (TARGET / f'{name}.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
        print(f'{name}: {len(raw)} bytes, reference-encrypted NTFS fixture', flush=True)


if __name__ == '__main__':
    main()
