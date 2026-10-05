#!/usr/bin/env python3
"""固定上游源码 + SHA-256，构建到工作区，不执行系统安装。"""
import argparse, hashlib, os, pathlib, subprocess, tarfile, urllib.request
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--clean', action='store_true', help='从固定源码重新构建全部本地依赖')
args=parser.parse_args()
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=ROOT/'.workbench'; WORK.mkdir(exist_ok=True)
VERSION='2026.7.7'
SHA='d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab'
archive=WORK/'ntfs-3g.tgz'
if not archive.exists():
    # The host refuses Python's default User-Agent (HTTP 403); the hash check below still decides.
    request=urllib.request.Request(f'https://tuxera.com/opensource/ntfs-3g_ntfsprogs-{VERSION}.tgz',headers={'User-Agent':'Mozilla/5.0 (Macintosh) Volisle-local-build'})
    with urllib.request.urlopen(request,timeout=45) as response:
        data=response.read(16*1024*1024)
    if hashlib.sha256(data).hexdigest()!=SHA: raise SystemExit('源码包校验失败，不解压')
    archive.write_bytes(data)
if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA: raise SystemExit('源码包校验失败，不解压')
source=WORK/f'ntfs-3g-{VERSION}'
if not source.exists():
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target=(WORK/member.name).resolve()
            if not target.is_relative_to(WORK.resolve()) or member.issym() or member.islnk():
                raise SystemExit('归档含非预期路径或链接')
        tar.extractall(WORK, filter='data')
env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.4')
stamp = source / '.volisle-deployment-target'
if (source/'Makefile').exists() and (args.clean or not stamp.exists() or stamp.read_text() != '15.4'):
    subprocess.run(['make','clean'], cwd=source, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
with (WORK/'ntfs-configure.log').open('w') as log:
    subprocess.run(['./configure','--disable-ntfs-3g','--disable-shared','--enable-static','--disable-crypto','--disable-nls'],cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
with (WORK/'ntfs-build.log').open('w') as log:
    subprocess.run(['make','-j4'],cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
stamp.write_text('15.4')
print('已验证上游哈希并构建隔离 NTFS 工具；未安装驱动。')
