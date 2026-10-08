#!/usr/bin/env python3
"""Package local signed binaries and corresponding source; never uploads."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import plistlib
from source_provenance import validate_receipt

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def validate_corresponding_source(app, root):
    receipt = app / 'Contents/Resources/SourceProvenance.json'
    if not receipt.is_file() or receipt.is_symlink():
        raise ValueError('候选缺少签名内的源码对应记录，请重新构建')
    document = json.loads(receipt.read_text())
    return validate_receipt(root, document)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    app = args.candidate.resolve(strict=True)
    out = args.output_dir.resolve()
    if out.exists(): parser.error('交付目录已存在，保留旧产物并使用新目录')
    result = json.loads((app.parent / 'signing-result.json').read_text())
    if not result.get('codesign_verified') or result.get('write_mode') != 'daily-write-candidate': parser.error('只接受明确签名的日常验收候选')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    source_inputs = validate_corresponding_source(app, ROOT)
    subprocess.run([str(ROOT / 'apps/macos/.build/out/Products/Release/VolisleHelperProbe'), '--check-package', str(app)], check=True)
    upstream = ROOT / '.workbench/ntfs-3g.tgz'
    if digest(upstream) != 'd67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab': parser.error('对应上游源码不匹配')
    guide = ROOT / 'docs/release/开始使用.md'
    if not guide.is_file(): parser.error('缺少开始使用说明')
    version = json.loads((ROOT / 'config/updates.json').read_text())['version']
    if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleShortVersionString') != version: parser.error('候选版本与 config/updates.json 不一致')
    out.mkdir(parents=True)
    stage = out / 'dmg-content'; stage.mkdir()
    packaged = stage / 'Volisle.app'
    shutil.copytree(app, packaged, symlinks=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(packaged)], check=True)
    shutil.copy2(guide, stage / '开始使用.md')
    shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE.txt')  # an extension gives Finder a text icon
    dmg = out / f'Volisle-{version}-arm64.dmg'
    # The installer window (background, icon places, no toolbar) comes from
    # scripts/dmg_settings.py; dmgbuild writes Finder's layout without driving Finder.
    background = ROOT / 'assets/brand/dmg/background.tiff'
    if not background.is_file(): parser.error('缺少安装窗口背景 assets/brand/dmg/background.tiff')
    # dmgbuild adds the Applications link itself.
    subprocess.run([sys.executable, '-m', 'dmgbuild', '-s', str(ROOT / 'scripts/dmg_settings.py'), '-D', f'stage={stage}',
                    '-D', f'background={background}', f'盘屿 {version}', str(dmg)], check=True)
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
    mountpoint = Path(tempfile.mkdtemp(prefix='volisle-package-verify-', dir='/private/tmp'))
    device = None
    try:
        attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-plist', '-mountpoint', str(mountpoint), str(dmg)]))
        mounted = [x for x in attached['system-entities'] if x.get('mount-point') == str(mountpoint)]
        if len(mounted) != 1: raise RuntimeError('无法确认安装镜像挂载位置')
        device = mounted[0]['dev-entry']
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mountpoint / 'Volisle.app')], check=True)
        for relative in ['Contents/MacOS/Volisle', 'Contents/Library/LaunchServices/VolisleMountHelper', 'Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS']:
            if digest(mountpoint / 'Volisle.app' / relative) != digest(app / relative): raise RuntimeError('最终安装镜像组件不一致')
    finally:
        if device: subprocess.run(['hdiutil', 'detach', device], check=True)
        if not mountpoint.is_mount(): mountpoint.rmdir()
    validate_corresponding_source(app, ROOT)
    source_files = [ROOT / name for name in source_inputs]
    source = out / f'Volisle-{version}-source.tar.gz'
    manifest = {}
    with tarfile.open(source, 'w:gz') as archive:
        for file in sorted(set(source_files)):
            name = file.relative_to(ROOT).as_posix()
            archive.add(file, arcname='Volisle/' + name, recursive=False)
            manifest[name] = digest(file)
    # Verify the actual archive, not just the filesystem used to create it.
    with tarfile.open(source, 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) != len(source_inputs) or {member.name for member in members} != {'Volisle/' + name for name in source_inputs}:
            raise RuntimeError('源码归档条目不一致')
        for member in members:
            name = member.name.removeprefix('Volisle/')
            expected = source_inputs.get(name)
            if not member.isfile() or not expected or member.mode != expected['mode'] or hashlib.sha256(archive.extractfile(member).read()).hexdigest() != expected['sha256']:
                raise RuntimeError('最终源码归档与签名内清单不一致')
    (out / 'source-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    shutil.copy2(guide, out / '开始使用.md')
    receipt = {'version': version, 'status': 'release-candidate', 'notarized': False, 'publicly_released': False, 'dmg_payload_signature_verified': True,
               'candidate': str(app), 'dmg_sha256': digest(dmg), 'source_sha256': digest(source), 'source_files': len(manifest), 'corresponding_source_verified': True,
               'source_provenance_sha256': digest(app / 'Contents/Resources/SourceProvenance.json')}
    (out / 'delivery.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(receipt, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
