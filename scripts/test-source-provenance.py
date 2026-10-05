#!/usr/bin/env python3
"""Reject stale, incomplete or linked corresponding source before packaging."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('packager',Path(__file__).with_name('package-local-candidate.py'))
packager=importlib.util.module_from_spec(spec);spec.loader.exec_module(packager)

class SourceProvenanceTests(unittest.TestCase):
    def test_packaging_requires_signed_source_receipt(self):
        self.assertTrue(callable(getattr(packager,'validate_corresponding_source',None)), '候选打包缺少源码对应门禁')
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                packager.validate_corresponding_source(Path(d),Path(d))

    def test_sources_and_license_scope_cannot_change_after_build(self):
        self.assertTrue(Path(__file__).with_name('source_provenance.py').is_file(), '缺少构建时源码清单')
        from source_provenance import source_inventory, validate_receipt
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for name in ['LICENSE','LICENSE_SCOPE.md','README.md','config/signing.json','config/updates.json','.workbench/Sparkle-2.10.0-source.tar.gz','apps/macos/Package.swift','docs/release/自己发布新版本.md','docs/release/自动更新.md','apps/macos/Sources/Main.swift','scripts/build.sh','.workbench/ntfs-3g.tgz']:
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
            original={'schema':1,'files':source_inventory(root)}
            validate_receipt(root,original)
            self.assertIn('LICENSE_SCOPE.md',original['files'])
            for name in ['LICENSE_SCOPE.md','apps/macos/Sources/Main.swift']:
                p=root/name;p.write_text('changed')
                with self.assertRaises(ValueError):validate_receipt(root,original)
                p.write_text('fixture')
            added=root/'apps/macos/Sources/Extra.swift';added.write_text('unbuilt source')
            with self.assertRaises(ValueError):validate_receipt(root,original)
            added.unlink()
            p=root/'scripts/build.sh';p.chmod(0o755)
            with self.assertRaises(ValueError):validate_receipt(root,original)
            p.chmod(0o644)
            p.unlink();p.symlink_to(root/'README.md')
            with self.assertRaises(ValueError):validate_receipt(root,original)
            p.unlink();p.write_text('fixture')
            bad=copy.deepcopy(original);bad['files']['../outside']={'sha256':'a'*64,'mode':420}
            with self.assertRaises(ValueError):validate_receipt(root,bad)
            bad=copy.deepcopy(original);bad['schema']=2
            with self.assertRaises(ValueError):validate_receipt(root,bad)

if __name__=='__main__':unittest.main()
