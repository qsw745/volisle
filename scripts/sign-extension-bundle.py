#!/usr/bin/env python3
"""Sign a separate local test candidate. Never installs, registers or uploads.

Requires an Apple-issued FSKit profile for the exact configured extension and
an existing valid Developer ID identity in the keychain. No keys are exported.
"""
import argparse
import os
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from bundle_manifest import verify_manifest, sha256
from fskit_fixture import validate_fixture
from physical_test_binding import validate_binding
from physical_service_policy import capture_service_scope

ROOT = Path(__file__).resolve().parents[1]


def validate_profile(profile, team, identifier, certificate_sha1, now=None):
    now = now or datetime.now(timezone.utc)
    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime) or expiration.replace(tzinfo=timezone.utc) <= now:
        raise ValueError('描述文件已过期或缺少有效期')
    if profile.get('TeamIdentifier') != [team]:
        raise ValueError('描述文件签名团队不匹配')
    entitlements = profile.get('Entitlements', {})
    if entitlements.get('com.apple.application-identifier') != team + '.' + identifier:
        raise ValueError('描述文件必须精确匹配扩展 Bundle ID，不接受通配符')
    if entitlements.get('com.apple.developer.team-identifier') != team:
        raise ValueError('描述文件权限中的团队不匹配')
    if entitlements.get('com.apple.developer.fskit.fsmodule') is not True:
        raise ValueError('描述文件没有 FSKit Module 权限')
    if entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('当前脚本只接受 Developer ID 分发描述文件')
    if profile.get('ProvisionsAllDevices') is not True or 'OSX' not in profile.get('Platform', []):
        raise ValueError('需要 macOS Developer ID 描述文件')
    fingerprints = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
    if certificate_sha1.upper() not in fingerprints:
        raise ValueError('描述文件未包含选定的 Developer ID 证书')
    return {
        'com.apple.security.app-sandbox': True,
        'com.apple.developer.fskit.fsmodule': True,
        'com.apple.application-identifier': team + '.' + identifier,
        'com.apple.developer.team-identifier': team,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True, help='Apple 下载的 FSKit Developer ID 描述文件')
    parser.add_argument('--candidate-dir', type=Path, default=ROOT / 'apps/macos/build/review', help='包含候选包和 build-manifest.json 的目录')
    parser.add_argument('--check-only', action='store_true', help='仅检查，不复制文件或调用签名')
    parser.add_argument('--write-fixture', type=Path, help='明确核对仅允许指定一次性镜像的实验候选')
    parser.add_argument('--physical-test', type=Path, help='明确核对限时、限制目录的实盘测试绑定')
    parser.add_argument('--experimental-replacement', action='store_true', help='单独核对覆盖保存实验开关')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'apps/macos/build/signed', help='新签名候选的父目录；不覆盖现有产物')
    parser.add_argument('--write-service-fixture', action='store_true', help='核对后台写入严格绑定本次镜像')
    parser.add_argument('--write-service-physical', action='store_true', help='核对后台限时实盘写入范围')
    parser.add_argument('--daily-write', action='store_true', help='显式生成外接 USB NTFS 日常读写验收候选')
    parser.add_argument('--experimental-private-permissions', action='store_true', help='仅为精确绑定镜像启用 Mac 私有权限实验')
    args = parser.parse_args()
    if args.experimental_private_permissions and (not args.write_fixture or args.daily_write or args.physical_test or args.write_service_fixture or args.write_service_physical):
        parser.error('私有权限实验仅接受直接镜像测试，不能用于日常或后台事务')
    if args.daily_write and (args.write_fixture or args.physical_test or args.experimental_replacement or args.write_service_fixture or args.write_service_physical):
        parser.error('日常读写与隔离测试模式不能混用')
    if args.write_service_physical and (not args.physical_test or args.write_service_fixture):
        parser.error('后台实盘事务需要独立的 --physical-test')
    if args.write_service_fixture and not args.write_fixture:
        parser.error('后台镜像事务需要 --write-fixture')
    if args.physical_test and (args.write_fixture or args.experimental_replacement):
        parser.error('实盘测试不能与镜像或覆盖保存实验混用')
    if args.experimental_replacement and not args.write_fixture:
        parser.error('覆盖保存实验必须绑定测试镜像')
    fixture = validate_fixture(args.write_fixture) if args.write_fixture else None
    if args.write_service_fixture and fixture['size'] != 64 * 1024 * 1024:
        parser.error('后台镜像事务目前仅支持 64 MiB；512 MiB 镜像只用于直接 FSKit 验收')
    physical = validate_binding(args.physical_test) if args.physical_test else None
    config = json.loads((ROOT / 'config/signing.json').read_text())
    team, bundle_id = config['team_id'], config['bundle_id']
    extension_id = config['extension_bundle_id']
    source = args.candidate_dir.resolve() / (bundle_id + '.app')
    output = args.output_dir.resolve() / (bundle_id + '.app')
    if output.exists() and not args.check_only:
        parser.error('签名候选已存在，请先核对，不能覆盖旧候选')
    if not args.profile.is_file():
        parser.error('找不到描述文件；未修改任何候选包')
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True).stdout
    matches = re.findall(r'\b([A-F0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(team) + r'\)"', identities)
    if len(matches) != 1:
        parser.error('该团队需要唯一有效的 Developer ID Application 身份')
    identity = matches[0]
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(args.profile.resolve())], capture_output=True, check=True).stdout
    try:
        profile = plistlib.loads(decoded)
        entitlements = validate_profile(profile, team, extension_id, identity)
        verify_manifest(source, source.parent / 'build-manifest.json', bundle_id, extension_id, fixture, args.experimental_replacement, physical, args.daily_write, args.experimental_private_permissions)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    daily_policy = source / 'Contents/Resources/DailyWritePolicy.json'
    if daily_policy.exists() != args.daily_write:
        parser.error('日常读写签名模式与候选不一致')
    if args.daily_write and json.loads(daily_policy.read_text()) != {'schema': 1, 'mode': 'external-usb-ntfs'}:
        parser.error('日常读写策略无效')
    policy_file = source / 'Contents/Resources/WriteFixturePolicy.json'
    if policy_file.exists() != args.write_service_fixture:
        parser.error('后台镜像写入范围与本次签名选项不一致')
    if args.write_service_fixture:
        image = args.write_fixture.resolve() / 'fixture.img'
        expected = {'schema': 1, 'imagePath': str(image), 'ownerUID': os.getuid(), 'byteCount': fixture['size'],
                    'bootSHA256': hashlib.sha256(image.read_bytes()[:512]).hexdigest(), 'imageSHA256': fixture['image_sha256']}
        if json.loads(policy_file.read_text()) != expected:
            parser.error('后台镜像写入范围不匹配')
    physical_policy = source / 'Contents/Resources/PhysicalWritePolicy.json'
    if physical_policy.exists() != args.write_service_physical:
        parser.error('后台实盘范围与本次签名选项不一致')
    if args.write_service_physical and json.loads(physical_policy.read_text()) != capture_service_scope(physical):
        parser.error('后台实盘连接身份或启动会话已变化')
    app_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    extension_relative = Path('Contents/Extensions/VolisleFS.appex')
    extension_info = plistlib.loads((source / extension_relative / 'Contents/Info.plist').read_bytes())
    if app_info['CFBundleIdentifier'] != bundle_id or extension_info['CFBundleIdentifier'] != extension_id:
        parser.error('候选包标识与配置不一致')
    attributes = extension_info['EXAppExtensionAttributes']
    if 'FSMediaTypes' in attributes or attributes.get('FSSupportsKernelOffloadedIO'):
        parser.error('测试包不能自动接管 NTFS 或启用内核卸载 I/O')
    if config['write_mode'] != 'read-only' or config['automatically_claim_ntfs']:
        parser.error('当前签名流程只放行默认只读测试包')
    subprocess.run([sys.executable, str(ROOT / 'scripts/verify-extension-entry.py'),
                    str(source / extension_relative / 'Contents/MacOS/VolisleFS')], check=True)
    helper_relative = Path('Contents/Library/LaunchServices/VolisleMountHelper')
    if (source / helper_relative).exists():
        helper_plist = source / ('Contents/Library/LaunchDaemons/' + bundle_id + '.mount-helper.plist')
        helper_info = plistlib.loads(helper_plist.read_bytes())
        if (helper_info.get('Label') != bundle_id + '.mount-helper'
                or helper_info.get('BundleProgram') != 'Contents/Library/LaunchServices/VolisleMountHelper'
                or helper_info.get('UserName') != 'root'
                or helper_info.get('MachServices') != {bundle_id + '.mount-helper': True}
                or 'Program' in helper_info or 'ProgramArguments' in helper_info):
            raise ValueError('后台组件启动配置不匹配，停止签名')
    if args.check_only:
        print('描述文件、证书、构建记录和候选包检查通过；未签名、安装或上传。')
        return
    # All checks precede copying/mutation. An incomplete copy is retained on
    # signing failure for inspection; it is never installed or launched.
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, output, symlinks=True)
    verify_manifest(output, source.parent / 'build-manifest.json', bundle_id, extension_id, fixture, args.experimental_replacement, physical, args.daily_write, args.experimental_private_permissions)
    extension = output / extension_relative
    helper = output / 'Contents/Library/LaunchServices/VolisleMountHelper'
    if helper.exists():
        subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity,
                        '--identifier', bundle_id + '.mount-helper', str(helper)], check=True)
    shutil.copyfile(args.profile, extension / 'Contents/embedded.provisionprofile')
    entitlement_file = output.parent / 'VolisleFS.entitlements'
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity,
                    '--entitlements', str(entitlement_file), str(extension)], check=True)
    sparkle = output / 'Contents/Frameworks/Sparkle.framework/Versions/B'
    if sparkle.exists():
        # Sign inside out with the app's team; never --deep sign.
        for component in ['XPCServices/Downloader.xpc', 'XPCServices/Installer.xpc', 'Autoupdate', 'Updater.app', '../..']:
            subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity,
                            str((sparkle / component).resolve())], check=True)
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, str(output)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(output)], check=True)
    signed_components = [(output, bundle_id), (extension, extension_id)]
    if helper.exists():
        signed_components.append((helper, bundle_id + '.mount-helper'))
    for candidate, expected_id in signed_components:
        details = subprocess.run(['codesign', '-dvv', str(candidate)], capture_output=True, text=True, check=True).stderr
        if 'TeamIdentifier=' + team not in details.splitlines() or 'Identifier=' + expected_id not in details.splitlines():
            raise RuntimeError('签名后的团队或标识不匹配')
        if '(runtime)' not in details:
            raise RuntimeError('签名未启用 Hardened Runtime')
    signed_entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(extension)],
                                        capture_output=True, check=True).stdout
    if plistlib.loads(signed_entitlements) != entitlements:
        raise RuntimeError('签入扩展的实际权限不匹配')
    (output.parent / 'signing-result.json').write_text(json.dumps({
        'team_id': team, 'bundle_id': bundle_id, 'extension_bundle_id': extension_id,
        'signed_at': datetime.now(timezone.utc).isoformat(),
        'codesign_verified': True, 'notarized': False, 'installed': False,
        'signed_entitlements_verified': True, 'hardened_runtime_verified': True,
        'extension_load_verified': False, 'write_mode': 'daily-write-candidate' if args.daily_write else 'physical-test-only' if physical else ('fixture-only' if fixture else 'read-only'),
        'helper_bundled': helper.exists(), 'helper_registered': False, 'helper_disk_operations_available': False,
        'physical_test': physical,
        'fixture': fixture, 'experimental_replacement': args.experimental_replacement, 'experimental_private_permissions': args.experimental_private_permissions,
        'build_manifest_sha256': sha256(source.parent / 'build-manifest.json'),
    }, ensure_ascii=False, indent=2) + '\n')
    print(output)
    print('签名结构核验通过；尚未公证、安装或验证 FSKit 加载，不能对外发布。')


if __name__ == '__main__':
    main()
