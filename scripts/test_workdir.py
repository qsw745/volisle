"""Temporary test folders under .workbench: removed when the test passes, kept
(and their path printed) when it fails, so a failed run can be inspected but
passing runs no longer pile up gigabytes of images.

Set VOLISLE_KEEP_TEST_DIRS=1 to keep the folder of a passing run as well."""
import atexit
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

WORKBENCH = Path(__file__).resolve().parents[1] / '.workbench'
_pending = set()


def make_workdir(prefix):
    """A new folder .workbench/<prefix><random>; reported at exit unless finished."""
    folder = Path(tempfile.mkdtemp(prefix=prefix, dir=WORKBENCH))
    _pending.add(folder)
    return folder


def _attached_images_under(folder):
    # A disk image still attached must not lose its backing file. None: unknown.
    try:
        reply = subprocess.run(['/usr/bin/hdiutil', 'info', '-plist'], capture_output=True, check=True, timeout=60)
        images = plistlib.loads(reply.stdout).get('images', [])
    except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException):
        return None
    root = folder.resolve()
    return [path for x in images if (path := Path(x.get('image-path', '/')).resolve()).is_relative_to(root)]


def _keep(folder, reason):
    _pending.discard(folder)
    print(f'保留测试目录（{reason}）：{folder}', file=sys.stderr, flush=True)


def finish_workdir(folder, passed, keep=False):
    """Remove the folder of a passing test; keep it (and say where) otherwise."""
    if not passed:
        return _keep(folder, '测试未通过')
    if keep or os.environ.get('VOLISLE_KEEP_TEST_DIRS') == '1':
        return _keep(folder, '按要求保留')
    if folder.is_symlink() or folder.resolve().parent != WORKBENCH.resolve() or folder not in _pending:
        return _keep(folder, '不是本次新建的临时目录，未删除')
    attached = _attached_images_under(folder)
    if attached is None:
        return _keep(folder, '无法确认镜像已分离')
    if attached:
        return _keep(folder, '仍有镜像挂接：' + ', '.join(map(str, attached)))
    try:
        shutil.rmtree(folder)
    except OSError as error:
        return _keep(folder, f'删除失败：{error}')
    _pending.discard(folder)


@atexit.register
def _report_unfinished():
    # Reached on an exception or an early exit before finish_workdir().
    for folder in sorted(_pending):
        if folder.exists():
            print(f'保留测试目录（测试未完成）：{folder}', file=sys.stderr, flush=True)
