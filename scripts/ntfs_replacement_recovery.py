"""Development-only content recovery; never repairs or writes the NTFS image.

Only detached 64 MiB ordinary files under .workbench/volisle-replacement-*
are accepted. A plan made BEFORE replacement is stored outside the image.
Exports contain the unnamed file data only, not timestamps/ACLs/streams.
"""
import argparse
from contextlib import contextmanager
import ctypes as C
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

SIZE = 64 * 1024 * 1024
MAX_FILE = SIZE
CHUNK = 256 * 1024
WORK = (ROOT / '.workbench').resolve()


class Stat(C.Structure):
    _fields_ = [('is_dir', C.c_int), ('size', C.c_longlong), ('alloc_size', C.c_longlong),
                ('inode', C.c_uint64), ('atime', C.c_longlong), ('mtime', C.c_longlong),
                ('ctime', C.c_longlong), ('btime', C.c_longlong), ('is_symlink', C.c_int),
                ('koio_ok', C.c_int), ('is_resident', C.c_int),
                ('atime_nsec', C.c_int), ('mtime_nsec', C.c_int),
                ('ctime_nsec', C.c_int), ('btime_nsec', C.c_int), ('mac_mode', C.c_uint32), ('file_flags', C.c_uint32)]


LIB.nk_stat_path.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(Stat)]
LIB.nk_stat_path.restype = C.c_int
LIB.nk_is_dirty.argtypes = [C.c_void_p]
LIB.nk_is_dirty.restype = C.c_int


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixture(image):
    image = Path(image).absolute()
    if (image != image.resolve() or image.parent.parent != WORK or
            not re.fullmatch(r'volisle-replacement-[a-z0-9_]+', image.parent.name)):
        raise ValueError('仅接受本项目替换测试的一次性普通镜像')
    info = image.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != SIZE:
        raise ValueError('必须是 64 MiB 非链接普通镜像')
    attached = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist'], timeout=10))
    if any(Path(item.get('image-path', '')).resolve() == image
           for item in attached.get('images', [])):
        raise ValueError('镜像尚未断开，不能离线恢复')
    with image.open('rb') as stream:
        boot = stream.read(512)
    if boot[3:11] != b'NTFS    ' or boot[510:] != b'\x55\xaa' or not any(boot[72:80]):
        raise ValueError('无效 NTFS 引导记录')
    return image, boot


def paths_for(directory, names):
    if (not isinstance(directory, str) or not directory.startswith('/') or '\x00' in directory or
            (directory != '/' and any(part in ('', '.', '..') for part in directory[1:].split('/')))):
        raise ValueError('目录必须是规范绝对路径')
    result = []
    for name in names:
        if (not isinstance(name, str) or not name or name in ('.', '..') or name.startswith('$') or
                any(char in name for char in '/\\:\x00') or len(name.encode('utf-16-le')) > 510):
            raise ValueError('恢复计划包含无效文件名')
        path = directory.rstrip('/') + '/' + name
        if len(path.encode('utf-8')) >= 4096:
            raise ValueError('路径过长')
        result.append(path)
    if len({name.casefold() for name in names}) != 3:
        raise ValueError('恢复名称必须互不相同')
    return result


@contextmanager
def readonly(image):
    io = ImageIO(image, readonly=True)
    volume = None
    try:
        volume = io.mount()
        if not volume:
            raise ValueError('无法只读打开镜像；不尝试修复')
        yield io, volume
    finally:
        try:
            if volume and LIB.nk_umount(volume) != 0:
                raise ValueError('只读会话关闭失败')
            if io.writes:
                raise ValueError('只读会话出现写入回调')
        finally:
            io.close()


def file_info(volume, path):
    info = Stat()
    if LIB.nk_stat_path(volume, path.encode('utf-8'), C.byref(info)) != 0:
        if C.get_errno() == errno.ENOENT:
            return None
        raise ValueError('读取候选文件属性失败')
    if info.is_dir or info.is_symlink or not 0 <= info.size <= MAX_FILE:
        raise ValueError('仅支持本次 64 MiB 镜像内的普通文件恢复实验')
    return info


def chunks(volume, path, size):
    offset = 0
    buf = C.create_string_buffer(min(CHUNK, max(1, size)))
    while offset < size:
        count = min(CHUNK, size - offset)
        read = LIB.nk_read(volume, path.encode('utf-8'), offset, count, buf)
        if read <= 0 or read > count:
            raise ValueError('候选文件未完整读回')
        yield bytes(buf.raw[:read])
        offset += read


def fingerprint(volume, path):
    info = file_info(volume, path)
    if info is None:
        return None
    hashed = hashlib.sha256()
    for chunk in chunks(volume, path, info.size):
        hashed.update(chunk)
    return {'size': info.size, 'sha256': hashed.hexdigest()}


def contents(volume, path):
    # Compatibility helper for small development assertions only. Export paths
    # below stream directly to exclusive files and never buffer entire payloads.
    info = file_info(volume, path)
    return None if info is None else b''.join(chunks(volume, path, info.size))


def export_verified(volume, path, output, expected):
    info = file_info(volume, path)
    if info is None or info.size != expected['size']:
        raise ValueError('导出前源文件长度已变化')
    hashed = hashlib.sha256()
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        for chunk in chunks(volume, path, info.size):
            stream.write(chunk); hashed.update(chunk)
        stream.flush(); os.fsync(stream.fileno())
    if hashed.hexdigest() != expected['sha256']:
        raise ValueError('导出内容与检查点不一致；保留结果但不报告成功')


def image_hash(image):
    with image.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_new(path, data):
    # Exclusive creation prevents both overwrites and following a final symlink.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def sidecar_path(image, path):
    path = Path(path).absolute()
    if path.parent != image.parent or path != path.resolve():
        raise ValueError('恢复计划和输出只能放在同一个实验目录中')
    return path


def load_plan(path, boot):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= 16384:
        raise ValueError('无效恢复计划文件')
    plan = json.loads(path.read_text())
    if (not isinstance(plan, dict) or type(plan.get('schema')) is not int or plan['schema'] != 1 or
            type(plan.get('image_size')) is not int or plan['image_size'] != SIZE or
            plan.get('serial_hex') != boot[72:80].hex() or plan.get('boot_sha256') != digest(boot)):
        raise ValueError('恢复计划与镜像身份不匹配')
    paths = paths_for(plan.get('directory'), [plan.get(key) for key in ['source', 'target', 'backup']])
    for role in ['before', 'after']:
        version = plan.get(role)
        if (not isinstance(version, dict) or type(version.get('size')) is not int or
                not 0 <= version['size'] <= MAX_FILE or not isinstance(version.get('sha256'), str) or
                not re.fullmatch('[0-9a-f]{64}', version['sha256'])):
            raise ValueError('无效的预期内容校验值')
    return plan, paths


def prepare_plan(image, plan_path, directory, source, target, backup):
    image, boot = fixture(image)
    plan_path = sidecar_path(image, plan_path)
    paths = paths_for(directory, [source, target, backup])
    before_hash = image_hash(image)
    with readonly(image) as (_, volume):
        after, before, saved = [fingerprint(volume, path) for path in paths]
    if before is None or after is None or saved is not None:
        raise ValueError('替换前源/目标必须存在，恢复副本名称必须为空')
    if image_hash(image) != before_hash:
        raise ValueError('生成恢复计划期间镜像发生变化')
    plan = {'schema': 1, 'image_size': SIZE, 'serial_hex': boot[72:80].hex(),
            'boot_sha256': digest(boot), 'original_image_sha256': before_hash,
            'directory': directory, 'source': source, 'target': target, 'backup': backup,
            'before': before, 'after': after}
    write_new(plan_path, (json.dumps(plan, ensure_ascii=False, indent=2) + '\n').encode())
    sync_directory(image.parent)
    return plan


def recover(image, plan_path, output):
    image, boot = fixture(image)
    plan_path = sidecar_path(image, plan_path)
    output = sidecar_path(image, output)
    if output.exists() or output.is_symlink():
        raise ValueError('输出目录必须尚不存在')
    plan, paths = load_plan(plan_path, boot)
    before_hash = image_hash(image)
    with readonly(image) as (io, volume):
        values = {path: fingerprint(volume, path) for path in paths}
        dirty = LIB.nk_is_dirty(volume)
        chosen = {}
        for role, candidates in [('before', [paths[1], paths[2]]), ('after', [paths[0], paths[1]])]:
            for path in candidates:
                if values[path] == plan[role]:
                    chosen[role] = path
                    break
            else:
                raise ValueError('未找到与替换前记录匹配的两个版本；不创建输出')
        if image_hash(image) != before_hash:
            raise ValueError('恢复期间镜像发生变化')
        output.mkdir(mode=0o700)
        for role in ['before', 'after']:
            export_verified(volume, chosen[role], output / f'{role}.bin', plan[role])
    unchanged = image_hash(image) == before_hash
    if not unchanged:
        raise ValueError('导出期间镜像发生变化；导出内容保留但不报告成功')
    result = {'success': True, 'image_sha256': before_hash, 'image_unchanged': unchanged,
              'write_callbacks': io.writes, 'dirty': dirty, 'selected_paths': chosen,
              'exports': {role: {'file': f'{role}.bin', **plan[role]} for role in ['before', 'after']},
              'scope': 'verified unnamed data export only; no repair, cleanup or atomicity claim'}
    write_new(output / 'recovery.json', (json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode())
    sync_directory(output)
    sync_directory(image.parent)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('plan', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(recover(args.image, args.plan, args.output), ensure_ascii=False, indent=2))
    except (ValueError, OSError) as exc:
        parser.exit(1, f'恢复未完成：{exc}\n')
