#!/usr/bin/env python3
"""Build an unsigned review bundle using the owner's explicit identifier.
Does not sign, register, install or launch any extension.
"""
import argparse
import os
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
from fskit_fixture import validate_fixture
from physical_test_binding import validate_binding
from physical_service_policy import capture_service_scope
from pathlib import Path
from bundle_manifest import inventory, sha256
from source_provenance import source_inventory, validate_receipt, verify_upstream

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--bundle-id',required=True,help='实际拥有的主应用 Bundle ID')
parser.add_argument('--output-dir',type=Path,help='新候选的父目录；不覆盖现有候选')
parser.add_argument('--write-fixture',type=Path,help='仅允许匹配指定一次性镜像的实验写入候选')
parser.add_argument('--physical-test',type=Path,help='已通过只读检查的、限时且限制目录的实盘测试绑定')
parser.add_argument('--experimental-replacement', action='store_true', help='仅在指定镜像上启用覆盖保存实验')
parser.add_argument('--write-service-fixture', action='store_true', help='仅为指定镜像启用后台写入事务')
parser.add_argument('--write-service-physical', action='store_true', help='仅为指定限时实盘测试绑定启用后台写入')
parser.add_argument('--daily-write', action='store_true', help='显式生成外接 USB NTFS 日常读写验收候选')
parser.add_argument('--experimental-private-permissions', action='store_true', help='仅为精确绑定镜像启用 Mac 私有权限实验')
args=parser.parse_args()
if args.experimental_private_permissions and (not args.write_fixture or args.daily_write or args.physical_test or args.write_service_fixture or args.write_service_physical):
    parser.error('私有权限实验仅接受直接镜像测试，不能用于日常或后台事务')
if args.daily_write and (args.write_fixture or args.physical_test or args.experimental_replacement or args.write_service_fixture or args.write_service_physical):
    parser.error('日常读写与隔离测试模式不能混用')
if args.write_service_physical and (not args.physical_test or args.write_service_fixture):parser.error('后台实盘事务需要独立的 --physical-test')
if args.write_service_fixture and not args.write_fixture:parser.error('后台镜像事务需要 --write-fixture')
if args.physical_test and (args.write_fixture or args.experimental_replacement):
    parser.error('实盘测试不能与镜像或覆盖保存实验混用')
if args.experimental_replacement and not args.write_fixture:
    parser.error('覆盖保存实验必须绑定测试镜像')
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*){2,}',args.bundle_id):
    parser.error('Bundle ID 格式无效')
if args.bundle_id.startswith(('com.example.','test.local.','com.whereteam.')):
    parser.error('不能将示例或第三方标识用于发行候选')
out=(args.output_dir.resolve() if args.output_dir else root/'apps/macos/build/review')/f'{args.bundle_id}.app'
if out.exists():parser.error('候选目录已存在，请先核对旧产物，避免覆盖')
fixture=validate_fixture(args.write_fixture) if args.write_fixture else None
if args.write_service_fixture and fixture['size'] != 64 * 1024 * 1024:
    parser.error('后台镜像事务目前仅支持 64 MiB；512 MiB 镜像只用于直接 FSKit 验收')
physical=validate_binding(args.physical_test) if args.physical_test else None
# Rebuild the pinned dependency locally so a stale archive is not paired with
# different source. No remote CI or system installation is involved.
subprocess.run(['python3',str(root/'scripts/prepare-ntfs-probe.py'),'--clean'],cwd=root,check=True)
verify_upstream(root)
subprocess.run(['python3',str(root/'scripts/prepare-sparkle.py')],cwd=root,check=True)
source_receipt={'schema':1,'files':source_inventory(root)}
subprocess.run([str(root/'scripts/build-macos.sh')],cwd=root,check=True)
subprocess.run([str(root/'scripts/build-fskit-extension.sh')] + (['--daily-write'] if args.daily_write else []) + (['--physical-test', str(args.physical_test.resolve())] if physical else []) + (['--write-fixture', str(args.write_fixture.resolve())] if fixture else []) + (['--experimental-replacement'] if args.experimental_replacement else []) + (['--experimental-private-permissions'] if args.experimental_private_permissions else []),cwd=root,check=True)
build=json.loads((root/'.workbench/fskit-build/VolisleFS.build.json').read_text())
# The oldest macOS this build runs on (test builds for older systems set it).
minimum=os.environ.get('VOLISLE_MIN_MACOS','15.4')
if build.get('target')!='arm64-apple-macos'+minimum: parser.error('扩展编译目标与最低系统版本不一致')
if build.get('experimental_private_permissions', False) != args.experimental_private_permissions or build.get('daily_writes', False) != args.daily_write or build['experimental_writes'] != bool(fixture or physical) or build.get('physical_test') != physical or build.get('experimental_replacement', False) != args.experimental_replacement or build.get('fixture') != fixture or build['binary_sha256'] != sha256(root/'.workbench/fskit-build/VolisleFS'):
    parser.error('扩展编译记录与二进制不一致')
shutil.copytree(root/'apps/macos/build/Volisle.app',out,symlinks=True)
p=out/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info['CFBundleIdentifier']=args.bundle_id
info['LSMinimumSystemVersion']=minimum
p.write_bytes(plistlib.dumps(info))
ext=out/'Contents/Extensions/VolisleFS.appex/Contents'
(ext/'MacOS').mkdir(parents=True);(ext/'Resources').mkdir()
shutil.copyfile(root/'.workbench/fskit-build/VolisleFS',ext/'MacOS/VolisleFS')
(ext/'MacOS/VolisleFS').chmod(0o755)
info={'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['zh-Hans','zh-Hant','en'],'CFBundleExecutable':'VolisleFS','CFBundleIdentifier':args.bundle_id+'.filesystem','CFBundleName':'VolisleFS','CFBundleDisplayName':'Volisle NTFS','CFBundlePackageType':'XPC!','CFBundleShortVersionString':json.loads((root/'config/updates.json').read_text())['version'],'CFBundleVersion':str(json.loads((root/'config/updates.json').read_text())['build']),'LSMinimumSystemVersion':minimum,'EXAppExtensionAttributes':{'EXExtensionPointIdentifier':'com.apple.fskit.fsmodule','FSName':'Volisle','FSShortName':'volisle','FSSupportsBlockResources':True,'FSSupportsKernelOffloadedIO':False,'FSSupportsGenericURLResources':False,'FSSupportsPathURLs':False,'FSSupportsServerURLs':False,'FSActivateOptionSyntax':{'shortOptions':'o:'},'FSPersonalities':{'Volisle':{'FSName':'盘屿 NTFS'}}}}
(ext/'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copyfile(root/'LICENSE',ext/'Resources/LICENSE')
for lproj in sorted((root/'assets/brand/Localization/extension').glob('*.lproj')):
    shutil.copytree(lproj,ext/'Resources'/lproj.name)
shutil.copyfile(root/'packages/VolisleNTFS/UPSTREAM.md',ext/'Resources/NTFS-NOTICE.md')
shutil.copyfile(root/'apps/extension/UPSTREAM.md',ext/'Resources/FSKit-NOTICE.md')
entitlements={'com.apple.security.app-sandbox':True,'com.apple.developer.fskit.fsmodule':True}
(out.parent/'VolisleFS.entitlements').write_bytes(plistlib.dumps(entitlements))
if args.daily_write:
    (out/'Contents/Resources/DailyWritePolicy.json').write_text(json.dumps({'schema':1,'mode':'external-usb-ntfs'})+'\n')
if args.write_service_fixture:
    image=args.write_fixture.resolve()/'fixture.img'
    policy={'schema':1,'imagePath':str(image),'ownerUID':os.getuid(),'byteCount':fixture['size'],
            'bootSHA256':hashlib.sha256(image.read_bytes()[:512]).hexdigest(),'imageSHA256':fixture['image_sha256']}
    (out/'Contents/Resources/WriteFixturePolicy.json').write_text(json.dumps(policy,indent=2)+'\n')
if args.write_service_physical:
    (out/'Contents/Resources/PhysicalWritePolicy.json').write_text(json.dumps(capture_service_scope(physical),indent=2)+'\n')
verify_upstream(root)
validate_receipt(root,source_receipt)
(out/'Contents/Resources/SourceProvenance.json').write_text(json.dumps(source_receipt,ensure_ascii=False,indent=2)+'\n')
manifest={'schema_version':1,'bundle_id':args.bundle_id,'extension_bundle_id':args.bundle_id+'.filesystem',
          'extension_build':build,'files':inventory(out)}
(out.parent/'build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(out)
print('仅生成未签名审查候选；实验写入绑定明确的测试范围，普通构建固定只读。未安装或注册，不能公开分发。')
