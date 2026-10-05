#!/usr/bin/env python3
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
from bundle_manifest import inventory
spec=importlib.util.spec_from_file_location('updates',Path(__file__).with_name('configure-updates.py'))
updates=importlib.util.module_from_spec(spec);spec.loader.exec_module(updates)

class UpdatePackagingTests(unittest.TestCase):
    def test_feed_configuration_fails_closed(self):
        disabled=dict(schema=1,channel='unconfigured',feed_url=None,public_ed25519_key=None,version='0.2.0',build=3)
        self.assertNotIn('SUFeedURL',updates.configure({'SUFeedURL':'stale'},disabled))
        good=dict(disabled,channel='website',feed_url='https://example.com/appcast.xml',public_ed25519_key=base64.b64encode(b'x'*32).decode())
        self.assertTrue(updates.configure({},good)['SURequireSignedFeed'])
        for url in ['http://example.com/feed','https://user:pass@example.com/feed','file:///tmp/feed','https://example.com/feed?secret=x']:
            with self.assertRaises(ValueError):updates.configure({},dict(good,feed_url=url))
        for key in ['bad',base64.b64encode(b'x'*31).decode()]:
            with self.assertRaises(ValueError):updates.configure({},dict(good,public_ed25519_key=key))
        with self.assertRaises(ValueError):updates.configure({},dict(disabled,feed_url=good['feed_url']))

    def test_versioned_framework_links_preserved_and_bounded(self):
        with tempfile.TemporaryDirectory() as d:
            app=Path(d)/'Fixture.app'; f=app/'Contents/Frameworks/Sparkle.framework'
            (f/'Versions/B').mkdir(parents=True)
            (f/'Versions/B/Sparkle').write_text('fixture')
            (f/'Versions/Current').symlink_to('B');(f/'Sparkle').symlink_to('Versions/Current/Sparkle')
            original=inventory(app)
            self.assertEqual(original['Contents/Frameworks/Sparkle.framework/Sparkle'],{'symlink':'Versions/Current/Sparkle'})
            for target in ['/etc/hosts','../../../../outside','missing','Sparkle']:
                (f/'Sparkle').unlink();(f/'Sparkle').symlink_to(target)
                with self.assertRaises(ValueError):inventory(app)
            (f/'Sparkle').unlink();(f/'Sparkle').symlink_to('Versions/B/Sparkle')
            self.assertNotEqual(inventory(app),original)
            (app/'outside').symlink_to('Contents/Frameworks/Sparkle.framework/Sparkle')
            with self.assertRaises(ValueError):inventory(app)
            (app/'outside').unlink()
            import shutil
            shutil.rmtree(f)
            f.symlink_to(Path(d))
            with self.assertRaises(ValueError):inventory(app)

if __name__=='__main__':unittest.main()
