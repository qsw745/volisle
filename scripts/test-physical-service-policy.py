#!/usr/bin/env python3
"""Offline registry parsing and build-option rejection checks; no disk access."""
import subprocess
import unittest
from physical_service_policy import media_registry_id

class PhysicalServicePolicyTests(unittest.TestCase):
    def test_exact_nested_media(self):
        entries = [{'IORegistryEntryChildren': [{'BSD Name': 'disk8s1', 'IORegistryEntryID': 123},
                                               {'BSD Name': 'disk9s1', 'IORegistryEntryID': 456}]}]
        self.assertEqual(media_registry_id(entries, 'disk8s1'), 123)
    def test_missing_duplicate_and_invalid_id(self):
        for entries in [[], [{'BSD Name': 'disk8s1'}], [{'BSD Name': 'disk8s1', 'IORegistryEntryID': True}],
                        [{'BSD Name': 'disk8s1', 'IORegistryEntryID': 0}],
                        [{'BSD Name': 'disk8s1', 'IORegistryEntryID': 1}] * 2]:
            with self.assertRaises(ValueError): media_registry_id(entries, 'disk8s1')
    def test_scope_requires_explicit_physical_binding_before_any_build(self):
        commands = [(['python3', 'scripts/prepare-extension-bundle.py', '--bundle-id', 'top.qisw.volisle'], []),
                    (['python3', 'scripts/sign-extension-bundle.py', '--profile', '/nonexistent'], [])]
        for command, _ in commands:
            result = subprocess.run(command + ['--write-service-physical'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('后台实盘事务需要独立的 --physical-test', result.stderr)

if __name__ == '__main__': unittest.main()
