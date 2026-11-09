#!/usr/bin/env python3
"""Signing policy fixtures; never requests Photos access or touches a library."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('sign-extension-bundle.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
key = 'com.apple.security.personal-information.photos-library'
expected = {key: True}
assert signing.application_entitlements({'NSPhotoLibraryUsageDescription': 'Export selected originals'}) == expected
for info in [{}, {'NSPhotoLibraryUsageDescription': ''}, {'NSPhotoLibraryUsageDescription': 1}]:
    try: signing.application_entitlements(info)
    except ValueError: pass
    else: raise AssertionError('accepted missing/invalid Photos purpose')

signing.validate_photo_entitlement_scope(expected, {}, {})
for app, extension, helper in [({}, {}, {}), ({key: False}, {}, {}),
                               ({**expected, 'com.apple.security.app-sandbox': True}, {}, {}),
                               (expected, expected, {}), (expected, {}, expected)]:
    try: signing.validate_photo_entitlement_scope(app, extension, helper)
    except ValueError: pass
    else: raise AssertionError('accepted missing, excessive or misplaced Photos entitlement')
print('照片签名策略：2 个正常场景、8 个拒绝场景通过；未访问图库或执行签名。')
