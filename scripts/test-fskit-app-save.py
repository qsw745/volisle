#!/usr/bin/env python3
"""R4 on the INSTALLED extension: application save paths on a new disposable
NTFS image mounted through FSKit (volisle-rw). Never touches another disk."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location('fskit_journal', Path(__file__).resolve().parent / 'test-fskit-journal.py')
_journal = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_journal)
Image, make_image, offline_check, volisle_mounts, ROOT = (_journal.Image, _journal.make_image,
    _journal.offline_check, _journal.volisle_mounts, _journal.ROOT)

SWIFT_REPLACE = r'''
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1])
let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
let temp = dir.appendingPathComponent(target.lastPathComponent)
try Data(CommandLine.arguments[2].utf8).write(to: temp)
_ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
try? FileManager.default.removeItem(at: dir)
'''


def osa(script):
    p = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise AssertionError('osascript: ' + p.stderr.strip())
    return p.stdout.strip()


def textedit_save(path, text):
    # TextEdit may auto-terminate after its last document closes; relaunch first.
    osa('tell application "TextEdit" to launch')
    time.sleep(2)
    osa(f'''tell application "TextEdit"
        set d to open POSIX file "{path}"
        delay 1
        set text of d to "{text}"
        save d
        delay 1
        close d saving no
    end tell''')


def main():
    folder = Path(tempfile.mkdtemp(prefix='fskit-appsave-', dir=ROOT / '.workbench'))
    result = {'folder': str(folder), 'checks': [], 'success': False}
    image = Image(folder)
    try:
        assert not volisle_mounts(), 'another Volisle mount exists; refusing'
        make_image(folder)
        image.attach(); root = image.mount()
        # 1. POSIX safe-save: private temp dir/file, then rename over.
        doc = root / 'posix 保存.txt'
        doc.write_bytes(b'v1\n')
        tmpdir = root / '.save-tmp'
        os.mkdir(tmpdir, 0o700)
        fd = os.open(tmpdir / 'new', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.write(fd, b'v2 posix\n'); os.fsync(fd); os.close(fd)
        os.replace(tmpdir / 'new', doc)
        os.rmdir(tmpdir)
        assert doc.read_bytes() == b'v2 posix\n'
        os.chmod(doc, 0o600)                          # accepted, stored as writable
        assert os.stat(doc).st_mode & 0o777 == 0o644
        os.chmod(doc, 0o444); assert os.stat(doc).st_mode & 0o777 == 0o444
        os.chmod(doc, 0o644)
        result['checks'].append('posix-private-temp-and-rename-over')
        # 2. NSFileManager replaceItemAt (NSDocument's path).
        fm = root / 'filemanager.txt'
        fm.write_text('original\n')
        for version in ['second', 'third']:
            subprocess.run(['swift', '-e', SWIFT_REPLACE, str(fm), version + '\n'], check=True, capture_output=True, timeout=300)
            assert fm.read_text() == version + '\n', fm.read_text()
        result['checks'].append('filemanager-replace-item-twice')
        # 3. TextEdit: two edit+save cycles, closing in between.
        te = root / '文本编辑.txt'
        te.write_text('初稿\n', encoding='utf-8')
        for version in ['第一次保存', '第二次保存']:
            textedit_save(te, version)
            time.sleep(1)
            assert te.read_text(encoding='utf-8').strip() == version, te.read_text(encoding='utf-8')
        result['checks'].append('textedit-two-saves')
        leftovers = sorted(p.name for p in root.iterdir() if p.name.startswith('.volisle-replaced-'))
        assert not leftovers, leftovers
        image.unmount(); image.detach()
        # Remount: content survives, volume clean.
        image.attach(); root = image.mount()
        assert (root / 'posix 保存.txt').read_bytes() == b'v2 posix\n'
        assert (root / 'filemanager.txt').read_text() == 'third\n'
        assert (root / '文本编辑.txt').read_text(encoding='utf-8').strip() == '第二次保存'
        image.unmount(); image.detach()
        check = offline_check(image.path); result['offline'] = check
        assert check['inspect'] == 0 and check['ntfsls_rc'] == 0 and check['sentinel_ok']
        result['checks'].append('remount-readback-clean-volume')
        result['success'] = True
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        try:
            image.unmount(force=True)
        finally:
            image.detach()
        (folder / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
        print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
