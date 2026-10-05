#!/usr/bin/env python3
"""Regression checks on disposable ordinary files; never mounts a device."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from physical_test_files import populate, verify

class PhysicalFilesTests(unittest.TestCase):
    def test_roundtrip_and_tampering(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'fresh'
            expected=populate(base, large_bytes=65536)
            self.assertEqual(len(expected),20)
            self.assertEqual((base/'large-64KiB.bin').stat().st_size,65536)
            self.assertEqual((base/'nested/移动.bin').read_bytes(), hashlib.shake_256(b'0').digest(513))
            verify(base,expected)
            with (base/'large-64KiB.bin').open('r+b') as stream:stream.write(b'corruption')
            with self.assertRaises(ValueError):verify(base,expected)

    def test_never_reuse_existing_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'existing';base.mkdir();(base/'keep').write_bytes(b'original')
            with self.assertRaises(FileExistsError):populate(base,large_bytes=65536)
            self.assertEqual((base/'keep').read_bytes(),b'original')

    def test_reject_symlinks_and_escape_before_read(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);base=root/'fresh';base.mkdir()
            outside=root/'outside';outside.write_bytes(b'private')
            (base/'link').symlink_to(outside)
            sha=hashlib.sha256(b'private').hexdigest()
            for name in ['../outside','/outside','link','a/../outside']:
                with self.subTest(name=name),self.assertRaises(ValueError):verify(base,{name:sha})
            linked=root/'linked';linked.symlink_to(base,target_is_directory=True)
            with self.assertRaises(FileExistsError):populate(linked,large_bytes=65536)

    def test_fail_before_creation_on_invalid_size(self):
        with tempfile.TemporaryDirectory() as folder:
            for size in [0,-1,65535,64*1024*1024+1]:
                target=Path(folder)/str(size)
                with self.assertRaises(ValueError):populate(target,large_bytes=size)
                self.assertFalse(target.exists())

if __name__=='__main__':unittest.main()
