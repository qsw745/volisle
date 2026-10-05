#!/usr/bin/env python3
"""Drop root before probing only fixed names on a disposable FSKit test mount.

Does not mount, change permissions, write bytes, or create accounts. JSON goes
to stdout; the unprivileged test harness may retain it as evidence.
"""
import errno
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys


def main():
    if len(sys.argv) != 2 or os.geteuid() != 0:
        raise SystemExit('用 sudo 运行并指定当前一次性镜像挂载点；仅用于切换测试进程身份。')
    root = Path(sys.argv[1])
    if not re.fullmatch(r'/private/tmp/volisle-fskit-write-[a-z0-9_]+', str(root)):
        raise SystemExit('拒绝非测试挂载点')
    assert root.resolve() == root and root.is_mount()
    other = pwd.getpwnam('nobody')
    owner = root.stat().st_uid
    assert owner not in (0, other.pw_uid)
    # Check paths without following symlinks before dropping identity.
    for name, mode, directory in [('nonowner-control.txt', 0o644, False),
                                  ('nonowner-private.txt', 0o600, False),
                                  ('mac-private', 0o700, True)]:
        st = (root / name).lstat()
        assert st.st_uid == owner and stat.S_IMODE(st.st_mode) == mode
        assert (stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode))
        assert st.st_dev == root.stat().st_dev
    os.setgroups([])
    os.setgid(other.pw_gid)
    os.setuid(other.pw_uid)
    assert os.getuid() == os.geteuid() == other.pw_uid and os.geteuid() != owner
    assert (root / 'nonowner-control.txt').read_bytes() == b'public-control'
    checks = ['public-control-readable-as-nonowner']
    for name, flags, label in [('nonowner-private.txt', os.O_RDONLY, 'private-read'),
                               ('nonowner-private.txt', os.O_WRONLY, 'private-write'),
                               ('mac-private/secret.txt', os.O_RDONLY, 'private-directory-traversal')]:
        try:
            fd = os.open(root / name, flags | os.O_NOFOLLOW)
        except OSError as error:
            assert error.errno == errno.EACCES, (label, error.errno)
        else:
            os.close(fd)
            raise AssertionError(label + ' 未被拒绝')
        checks.append(label + '-denied')
    print(json.dumps({'success': True, 'root': str(root), 'uid': os.geteuid(),
                      'owner_uid': owner, 'checks': checks}, ensure_ascii=False))


if __name__ == '__main__':
    main()
