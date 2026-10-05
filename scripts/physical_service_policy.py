"""Bind a signed backend test scope to one live USB media instance and boot."""
import os
import plistlib
import subprocess
import uuid


def media_registry_id(entries, bsd_name):
    matches = []
    def visit(node):
        if isinstance(node, dict):
            if node.get('BSD Name') == bsd_name:
                matches.append(node.get('IORegistryEntryID'))
            for child in node.get('IORegistryEntryChildren', []):
                visit(child)
    for node in entries:
        visit(node)
    if len(matches) != 1 or type(matches[0]) is not int or matches[0] <= 0:
        raise ValueError('无法唯一绑定当前 IOMedia 实例')
    return matches[0]


def capture_service_scope(document):
    # This reads registry metadata only. It never opens or unmounts a disk.
    entries = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg', '-a', '-r', '-c', 'IOMedia']))
    registry = media_registry_id(entries, document['bsd_name'])
    boot = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip()
    uuid.UUID(boot)
    if os.getuid() == 0:
        raise ValueError('必须由登录用户构建测试范围')
    return {'schema': 1, 'ownerUID': os.getuid(), 'bsdName': document['bsd_name'],
            'registryID': registry, 'byteCount': document['size'], 'bootSession': boot,
            'bootSHA256': document['boot_sha256'], 'option': document['option'],
            'root': document['root'], 'expiresAt': document['expires_at']}
