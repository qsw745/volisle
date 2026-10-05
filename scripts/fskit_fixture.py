"""Validate a disposable, detached ordinary image before experimental builds."""
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
from bundle_manifest import sha256

WORK = Path(__file__).resolve().parents[1] / '.workbench'
SIZE = 64 * 1024 * 1024
ALLOWED_SIZES = (SIZE, 512 * 1024 * 1024)


def validate_fixture(folder):
    folder = Path(folder).absolute()
    if folder.is_symlink() or folder.resolve().parent != WORK.resolve() or not re.fullmatch(r'fskit-readonly-[a-z0-9_]+', folder.name):
        raise ValueError('实验写入只接受本项目新建镜像目录')
    image = folder / 'fixture.img'
    receipt = folder / 'fixture.json'
    for path in [image, receipt]:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('镜像与记录必须是非链接普通文件')
    document = json.loads(receipt.read_text())
    size = document.get('size')
    if type(size) is not int or size not in ALLOWED_SIZES or image.stat().st_size != size or document.get('schema') != 1 or sha256(image) != document.get('image_sha256'):
        raise ValueError('镜像容量或校验记录不匹配')
    attachments = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))
    if any(Path(x.get('image-path', '')).resolve() == image.resolve() for x in attachments.get('images', [])):
        raise ValueError('实验镜像已连接，不能构建或签名')
    with image.open('rb') as stream:
        boot = stream.read(512)
    serial = boot[0x48:0x50]
    if boot[3:11] != b'NTFS    ' or boot[510:] != b'\x55\xaa' or not any(serial):
        raise ValueError('镜像 NTFS 引导记录无效')
    return {'serial_hex': serial.hex(), 'size': size, 'image_sha256': document['image_sha256']}


if __name__ == '__main__':
    import sys
    fixture = validate_fixture(sys.argv[1])
    output = Path(sys.argv[2])
    output.write_text('enum ExperimentalFixture { static let serial: [UInt8] = ' + str(list(bytes.fromhex(fixture['serial_hex']))) + '; static let byteCount: UInt64 = ' + str(fixture['size']) + ' }\n')
    output.with_suffix('.json').write_text(json.dumps(fixture, indent=2) + '\n')
