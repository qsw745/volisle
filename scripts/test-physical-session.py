#!/usr/bin/env python3
"""Identity checks only; no sudo, raw devices or mount calls."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('session',Path(__file__).with_name('run-physical-acceptance.py'))
session=importlib.util.module_from_spec(spec);spec.loader.exec_module(session)

class SessionIdentityTests(unittest.TestCase):
    def setUp(self):
        self.binding=dict(bsd_name='disk999s1',size=2000396321280,parent_disk='disk999',offset=32768,volume_uuid=None)
        self.disk=dict(DeviceIdentifier='disk999s1',Size=2000396321280,ParentWholeDisk='disk999',PartitionMapPartitionOffset=32768,Internal=False,BusProtocol='USB',FilesystemType='ntfs')
    def test_uuid_absent_still_requires_full_partition_binding(self):
        session.check_disk(self.binding,self.disk,native=True)
    def test_reject_changed_or_missing_device_fields(self):
        for key,value in [('DeviceIdentifier','disk1s1'),('Size',67108864),('ParentWholeDisk','disk1'),('PartitionMapPartitionOffset',0),('Internal',True),('BusProtocol','PCI')]:
            for missing in [False,True]:
                disk=deepcopy(self.disk)
                if missing:disk.pop(key)
                else:disk[key]=value
                with self.subTest(key=key,missing=missing),self.assertRaises(ValueError):session.check_disk(self.binding,disk)
    def test_reject_native_uuid_or_filesystem_change(self):
        for key,value in [('VolumeUUID','unexpected'),('FilesystemType','apfs')]:
            disk=dict(self.disk);disk[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):session.check_disk(self.binding,disk,native=True)
    def test_reject_whole_disk_and_injected_device(self):
        for device in ['disk999','/dev/disk999s1','disk999s1;echo','disk999s1/../disk1']:
            binding=dict(self.binding,bsd_name=device);disk=dict(self.disk,DeviceIdentifier=device)
            with self.subTest(device=device),self.assertRaises(ValueError):session.check_disk(binding,disk)

if __name__=='__main__':unittest.main()
