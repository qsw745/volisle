"""Local build receipts detect stale or changed artifacts, not hostile tampering."""
import hashlib
import json
import os
from pathlib import Path
import stat


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(bundle):
    result = {}
    for path in sorted(Path(bundle).rglob('*')):
        if path.is_symlink():
            # Sparkle is a standard versioned framework. Links are allowed only
            # inside it, with relative targets that resolve inside that framework.
            framework = Path(bundle) / 'Contents/Frameworks/Sparkle.framework'
            target = os.readlink(path)
            try:
                valid = (not framework.is_symlink() and path.is_relative_to(framework) and not Path(target).is_absolute()
                         and path.resolve(strict=True).is_relative_to(framework.resolve()))
            except (OSError, RuntimeError):
                valid = False
            if not valid:
                raise ValueError('候选包含越界、损坏或非框架符号链接')
            result[path.relative_to(bundle).as_posix()] = {'symlink': target}
            continue
        if path.is_file():
            result[path.relative_to(bundle).as_posix()] = {
                'sha256': sha256(path), 'mode': stat.S_IMODE(path.stat().st_mode),
            }
        elif not path.is_dir():
            raise ValueError('测试候选包含非普通文件')
    if not result:
        raise ValueError('测试候选为空')
    return result


def verify_manifest(bundle, receipt, bundle_id, extension_id, fixture=None, replacement=False, physical=None, daily=False, private_permissions=False):
    manifest = json.loads(Path(receipt).read_text())
    if manifest.get('schema_version') != 1:
        raise ValueError('不支持的构建记录版本')
    if manifest.get('bundle_id') != bundle_id or manifest.get('extension_bundle_id') != extension_id:
        raise ValueError('构建记录的应用标识不匹配')
    build = manifest.get('extension_build', {})
    if build.get('experimental_private_permissions', False) is not private_permissions or (private_permissions and (not fixture or physical or daily)):
        raise ValueError('私有权限实验必须单独确认并仅绑定镜像')
    if build.get('daily_writes', False) is not daily or (daily and (fixture or replacement or physical)):
        raise ValueError('日常读写模式必须单独明确核对')
    if physical and (fixture or replacement):
        raise ValueError('实盘测试不能与镜像或覆盖实验混用')
    if build.get('physical_test') != physical:
        raise ValueError('实盘测试绑定不匹配或未明确提供')
    if build.get('experimental_replacement', False) is not replacement or (replacement and not fixture):
        raise ValueError('覆盖保存实验必须单独确认并绑定测试镜像')
    if build.get('experimental_writes') is not bool(fixture or physical) or build.get('fixture') != fixture or build.get('target') != 'arm64+x86_64-apple-macos' + os.environ.get('VOLISLE_MIN_MACOS', '15.4'):
        raise ValueError('缺少只读扩展构建记录')
    files = inventory(bundle)
    if files != manifest.get('files'):
        raise ValueError('候选文件、权限或校验和已改变，请重新构建')
    binary = 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'
    if files.get(binary, {}).get('sha256') != build.get('binary_sha256'):
        raise ValueError('扩展二进制与编译记录不匹配')
    return manifest
