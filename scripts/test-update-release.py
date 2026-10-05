#!/usr/bin/env python3
"""Check release/source pairing without signing, publishing or using a disk."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('release',Path(__file__).with_name('prepare-update-release.py'))
release=importlib.util.module_from_spec(spec);spec.loader.exec_module(release)

class UpdateReleaseTests(unittest.TestCase):
    def test_unresolved_file_system_failures_block_release(self):
        ready={'schema':1,'build':4,'status':'ready','blockers':[],'source_provenance_sha256':'a'*64}
        release.verify_readiness(ready,4,'a'*64)
        for changes in [{'status':'blocked'}, {'blockers':['metadata-mirror-interruption']},
                        {'build':3}, {'source_provenance_sha256':'b'*64}, {'schema':2},
                        {'blockers':None}, {'status':'candidate'}]:
            with self.assertRaises(ValueError): release.verify_readiness(dict(ready,**changes),4,'a'*64)
        for field in ready:
            missing=dict(ready);del missing[field]
            with self.assertRaises(ValueError):release.verify_readiness(missing,4,'a'*64)

    def test_source_must_match_candidate_exactly(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);app=root/'Fixture.app';resources=app/'Contents/Resources';resources.mkdir(parents=True)
            data=b'fixture source'
            (resources/'SourceProvenance.json').write_text(json.dumps({'schema':1,'files':{'README.md':{'sha256':hashlib.sha256(data).hexdigest(),'mode':420}}}))
            archive=root/'source.tar.gz'
            def write(payload=data,name='Volisle/README.md',mode=420,duplicate=False,link=False):
                with tarfile.open(archive,'w:gz') as t:
                    m=tarfile.TarInfo(name);m.mode=mode;m.size=len(payload)
                    if link:m.type=tarfile.SYMTYPE;m.linkname='/etc/hosts';m.size=0
                    t.addfile(m,io.BytesIO(payload))
                    if duplicate:t.addfile(m,io.BytesIO(payload))
            write();release.verify_source(app,archive)
            for args in [{'payload':b'wrong'},{'name':'../README.md'},{'mode':493},{'duplicate':True},{'link':True}]:
                write(**args)
                with self.assertRaises(ValueError):release.verify_source(app,archive)

if __name__=='__main__':unittest.main()
