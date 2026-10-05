#!/usr/bin/env python3
"""Pure fixtures: does not read keychain, issue certificates, or sign code."""
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
from copy import deepcopy

spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('sign-extension-bundle.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
now = datetime.now(timezone.utc)
cert = b'fixture-public-certificate'
fingerprint = hashlib.sha1(cert).hexdigest()
profile = {
    'ExpirationDate': now + timedelta(days=1), 'TeamIdentifier': ['TESTTEAM00'],
    'Platform': ['OSX'], 'ProvisionsAllDevices': True, 'DeveloperCertificates': [cert],
    'Entitlements': {'com.apple.application-identifier': 'TESTTEAM00.test.fixture.filesystem',
                     'com.apple.developer.team-identifier': 'TESTTEAM00',
                     'com.apple.developer.fskit.fsmodule': True},
}
assert signing.validate_profile(profile, 'TESTTEAM00', 'test.fixture.filesystem', fingerprint, now)['com.apple.security.app-sandbox']
changes = [
    (['ExpirationDate'], now - timedelta(seconds=1)),
    (['TeamIdentifier'], ['OTHERTEAM0']),
    (['Entitlements', 'com.apple.application-identifier'], 'TESTTEAM00.*'),
    (['Entitlements', 'com.apple.application-identifier'], 'TESTTEAM00.other.filesystem'),
    (['Entitlements', 'com.apple.developer.team-identifier'], 'OTHERTEAM0'),
    (['Entitlements', 'com.apple.developer.fskit.fsmodule'], False),
    (['Entitlements', 'get-task-allow'], True),
    (['ProvisionsAllDevices'], False),
    (['Platform'], ['iOS']),
    (['DeveloperCertificates'], [b'other-certificate']),
]
for path, value in changes:
    bad = deepcopy(profile); node = bad
    for key in path[:-1]: node = node[key]
    node[path[-1]] = value
    try: signing.validate_profile(bad, 'TESTTEAM00', 'test.fixture.filesystem', fingerprint, now)
    except ValueError: pass
    else: raise AssertionError('accepted invalid profile: ' + str(path))
print('签名描述文件验证：1 个正常夹具、10 个拒绝场景通过；未执行签名。')
