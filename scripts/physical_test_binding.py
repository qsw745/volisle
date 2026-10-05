"""Validate an explicitly authorized physical-test record; never open a device."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]

def validate_binding(path):
    path = Path(path).absolute()
    if path.is_symlink() or path.parent.is_symlink() or path.resolve().parent.parent != (ROOT / '.workbench').resolve():
        raise ValueError('实盘绑定只接受本项目独立测试记录')
    document = json.loads(path.read_text())
    if document.get('schema') != 1 or document.get('backup_confirmed') is not True:
        raise ValueError('缺少已备份的明确记录')
    if not 0 < document['expires_at'] - time.time() <= 7200:
        raise ValueError('实盘测试绑定已过期或有效期过长')
    if not re.fullmatch(r'disk[0-9]+s[0-9]+', document['bsd_name']):
        raise ValueError('必须指定单个分区')
    if not re.fullmatch(r'/Volisle-Test-[0-9]{8}-[0-9a-f]{32}', document['root']):
        raise ValueError('测试目录无效')
    if document['option'] != 'volisle-test-' + document['root'].rsplit('-', 1)[1]:
        raise ValueError('测试选项与目录不匹配')
    boot = (path.parent / 'boot-sector.bin').read_bytes()
    if len(boot) != 512 or boot[3:11] != b'NTFS    ' or boot[510:] != b'\x55\xaa' or not any(boot[72:80]):
        raise ValueError('只读引导记录无效')
    if hashlib.sha256(boot).hexdigest() != document['boot_sha256'] or boot[72:80].hex() != document['serial_hex']:
        raise ValueError('引导记录与绑定不一致')
    previous = json.loads((path.parent / 'privileged-readonly-result.json').read_text())
    if previous.get('success') is not True or previous.get('original_restored') is not True or previous.get('writes_attempted') is not False:
        raise ValueError('必须先完成只读实盘检查和恢复')
    disk = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', document['bsd_name']]))
    if (disk.get('VolumeUUID') != document['volume_uuid'] or disk.get('Size') != document['size'] or
        disk.get('ParentWholeDisk') != document['parent_disk'] or disk.get('Internal') is not False or
        disk.get('BusProtocol') != 'USB' or disk.get('PartitionMapPartitionOffset') != document['offset'] or
        disk.get('FilesystemType') != 'ntfs' or disk.get('WritableVolume') is not False):
        raise ValueError('当前设备身份或只读挂载状态与绑定不符')
    return document

if __name__ == '__main__':
    import sys
    document = validate_binding(sys.argv[1])
    out = Path(sys.argv[2])
    out.write_text('enum PhysicalTestTarget { static let policy = PhysicalTestPolicy(bsdName: ' +
        json.dumps(document['bsd_name']) + ', serial: ' + str(list(bytes.fromhex(document['serial_hex']))) +
        ', byteCount: ' + str(document['size']) + ', option: ' + json.dumps(document['option']) +
        ', root: ' + json.dumps(document['root']) + ', expiresAt: ' + str(document['expires_at']) + ') }\n')
    out.with_suffix('.json').write_text(json.dumps(document, indent=2) + '\n')
