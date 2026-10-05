#!/usr/bin/env python3
"""Prepare one bounded administrator task. Never formats, repairs or forces unmounts.

Preparation is unprivileged and does not mount a disk. The matching signed physical
candidate must already be installed. Opening the generated command asks sudo once.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import traceback


def run(args):
    return subprocess.run([str(a) for a in args],check=True,capture_output=True,timeout=120)


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def check_disk(binding,disk,native=False):
    if (not re.fullmatch(r'disk[0-9]+s[0-9]+',binding['bsd_name']) or
        disk.get('DeviceIdentifier')!=binding['bsd_name'] or
        disk.get('Size')!=binding['size'] or disk.get('ParentWholeDisk')!=binding['parent_disk'] or
        disk.get('PartitionMapPartitionOffset')!=binding['offset'] or
        disk.get('Internal') is not False or disk.get('BusProtocol')!='USB'):
        raise ValueError('设备身份或分区关系改变，停止操作')
    if native and (disk.get('FilesystemType')!='ntfs' or disk.get('VolumeUUID')!=binding['volume_uuid']):
        raise ValueError('系统 NTFS 卷身份改变')


def prepare(binding_path,candidate):
    if os.geteuid()==0:raise ValueError('请以普通用户准备任务')
    # This import is only used in the unprivileged project environment.
    from physical_test_binding import validate_binding
    binding=validate_binding(binding_path)
    candidate=Path(candidate).resolve()
    receipt=json.loads((candidate/'signing-result.json').read_text())
    if receipt.get('physical_test')!=binding or receipt.get('write_mode')!='physical-test-only':
        raise ValueError('签名候选与实盘绑定不一致')
    app=Path.home()/'Applications/Volisle Test.app'
    signed=candidate/'top.qisw.volisle.app'
    hashes={}
    for rel in ['Contents/MacOS/Volisle','Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS']:
        hashes[rel]=digest(signed/rel)
        if digest(app/rel)!=hashes[rel]:raise ValueError('请先安装匹配本轮绑定的测试候选')
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    stage=Path(tempfile.mkdtemp(prefix='volisle-acceptance-',dir='/private/tmp'))
    for source,name in [(Path(__file__),'runner.py'),(Path(__file__).with_name('physical_test_files.py'),'physical_test_files.py'),(Path(__file__).with_name('verify-windows.ps1'),'verify-windows.ps1')]:
        shutil.copy2(source,stage/name)
    config={'binding':binding,'app':str(app),'installed_hashes':hashes,'uid':os.getuid(),'gid':os.getgid(),
            'files':{n:digest(stage/n) for n in ['physical_test_files.py','verify-windows.ps1']}}
    (stage/'session.json').write_text(json.dumps(config,indent=2)+'\n')
    # Pin the reviewed runner and all inputs before entering elevated execution.
    pinned={n:digest(stage/n) for n in ['runner.py','session.json','physical_test_files.py','verify-windows.ps1']}
    bootstrap=('import hashlib,pathlib,runpy,sys; p=pathlib.Path('+repr(str(stage))+'); '
               'expected='+repr(pinned)+'; '
               'assert all(hashlib.sha256((p/n).read_bytes()).hexdigest()==h for n,h in expected.items()); '
               'sys.argv=[str(p/"runner.py"),"--execute",str(p)]; runpy.run_path(sys.argv[0],run_name="__main__")')
    command=stage/'验收.command'
    command.write_text('#!/bin/zsh\nprint "一次授权：受限文件测试、只读重挂校验、恢复系统挂载。"\n'+
                       'sudo '+shlex.quote(sys.executable)+' -I -c '+shlex.quote(bootstrap)+
                       '\nresult=$?\nprint "验收退出状态：$result；结果保存在 '+str(stage/'result.json')+'"\nexit "$result"\n')
    command.chmod(0o700)
    print(command)
    print('已准备任务；尚未提权、挂载或写入磁盘。')


def execute(stage):
    stage=Path(stage).resolve()
    if os.geteuid()!=0 or stage.parent!=Path('/private/tmp') or not stage.name.startswith('volisle-acceptance-'):
        raise ValueError('只接受已准备的本机管理员任务')
    config=json.loads((stage/'session.json').read_text());b=config['binding']
    if b.get('backup_confirmed') is not True:raise ValueError('缺少备份确认记录')
    owner=pwd.getpwuid(config['uid'])
    if owner.pw_uid==0 or stage.stat().st_uid!=owner.pw_uid or config['gid']!=owner.pw_gid:
        raise ValueError('任务属主不一致')
    if not re.fullmatch(r'/Volisle-Test-[0-9]{8}-[0-9a-f]{32}',b['root']):raise ValueError('测试目录无效')
    if b['option']!='volisle-test-'+b['root'].rsplit('-',1)[1] or not 0<b['expires_at']-time.time()<=7200:
        raise ValueError('测试绑定选项或有效期无效')
    for n,h in config['files'].items():
        if n not in ['physical_test_files.py','verify-windows.ps1'] or digest(stage/n)!=h:raise ValueError('任务文件改变')
    spec=importlib.util.spec_from_file_location('physical_test_files',stage/'physical_test_files.py')
    files=importlib.util.module_from_spec(spec);spec.loader.exec_module(files)
    result={'success':False,'checks':[],'restored_system_readonly':False,'binding':b}
    target=stage/'result.json'
    if target.exists():raise ValueError('一次性任务已执行，不得重复使用')
    def record():
        temporary=stage/'result.tmp';temporary.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');os.replace(temporary,target)
        if os.geteuid()==0:os.chown(target,owner.pw_uid,owner.pw_gid)
    def passed(message):result['checks'].append(message);record();print(message,flush=True)
    def info():return plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',b['bsd_name']]).stdout)
    def bootcheck():
        check_disk(b,info());fd=os.open('/dev/r'+b['bsd_name'],os.O_RDONLY|os.O_NOFOLLOW)
        try:boot=os.pread(fd,512,0)
        finally:os.close(fd)
        if hashlib.sha256(boot).hexdigest()!=b['boot_sha256']:raise ValueError('引导记录与绑定不一致')
    mountpoint=None;unmounted=False
    try:
        record()
        app=Path(config['app'])
        if app!=Path(owner.pw_dir)/'Applications/Volisle Test.app':raise ValueError('安装路径不一致')
        for rel,h in config['installed_hashes'].items():
            if rel not in ['Contents/MacOS/Volisle','Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'] or digest(app/rel)!=h:raise ValueError('安装候选改变')
        run(['/usr/bin/codesign','--verify','--deep','--strict',app])
        d=info();check_disk(b,d,True);bootcheck()
        if d.get('WritableVolume') is not False or not d.get('MountPoint') or run(['/sbin/mount','-t','volisle']).stdout:
            raise ValueError('开始前必须只有系统只读挂载')
        if (Path(d['MountPoint'])/b['root'][1:]).exists():raise ValueError('测试目录已存在')
        mountpoint=Path(tempfile.mkdtemp(prefix='volisle-acceptance-mount-',dir='/private/tmp'))
        # Kernel normal unmount, never -f. Any busy/flush failure stops the task.
        run(['/sbin/umount',d['MountPoint']]);unmounted=True;bootcheck()
        run(['/sbin/mount','-F','-t','volisle','-o',b['option']+',nobrowse,nosuid,nodev,noexec','/dev/'+b['bsd_name'],mountpoint])
        d=info();check_disk(b,d)
        if d.get('MountPoint')!=str(mountpoint) or os.statvfs(mountpoint).f_flag&os.ST_RDONLY:raise ValueError('可写挂载未得到确认')
        passed('精确绑定的测试卷可写挂载成功')
        previous_umask=os.umask(0o022)
        os.setegid(owner.pw_gid);os.seteuid(owner.pw_uid)
        try:
            forbidden=mountpoint/('Volisle-Blocked-'+b['option'].removeprefix('volisle-test-'))
            if forbidden.exists():raise ValueError('越界探针目标已存在')
            import errno
            try:
                with forbidden.open('xb') as stream:stream.write(b'blocked')
            except OSError as error:
                if error.errno not in (errno.EROFS,errno.EPERM,errno.EACCES):raise
            else:raise ValueError('错误地允许测试目录外写入')
            passed('测试目录之外的新建被拒绝')
            expected=files.populate(mountpoint/b['root'][1:],progress=passed)
        finally:os.seteuid(0);os.setegid(0);os.umask(previous_umask)
        result['expected_files']=expected;record()
        run(['/sbin/umount',mountpoint]);bootcheck()
        run(['/sbin/mount','-F','-t','volisle','-o','rdonly,nobrowse,nosuid,nodev,noexec','/dev/'+b['bsd_name'],mountpoint])
        if not os.statvfs(mountpoint).f_flag&os.ST_RDONLY:raise ValueError('只读重挂未得到确认')
        files.verify(mountpoint/b['root'][1:],expected);passed('盘屿只读重挂：20 文件、扩展属性及删除状态一致')
        run(['/sbin/umount',mountpoint]);bootcheck()
        run(['/usr/sbin/diskutil','mount','readOnly',b['bsd_name']]);d=info();check_disk(b,d,True)
        if d.get('WritableVolume') is not False:raise ValueError('系统未恢复只读')
        result['restored_system_readonly']=True
        files.verify(Path(d['MountPoint'])/b['root'][1:],expected);passed('系统 NTFS 独立回读：20 文件、扩展属性及删除状态一致')
        result['success']=True
    except BaseException as error:
        result['error']=repr(error);result['traceback']=traceback.format_exc()
        if isinstance(error,subprocess.CalledProcessError):result['stderr']=error.stderr.decode(errors='replace')
    finally:
        try:
            if unmounted and not result['restored_system_readonly']:
                d=info();check_disk(b,d)
                if d.get('MountPoint'):
                    if d['MountPoint']!=str(mountpoint):raise ValueError('卷已在其他位置挂载，停止恢复')
                    run(['/sbin/umount',mountpoint])
                run(['/usr/sbin/diskutil','mount','readOnly',b['bsd_name']]);d=info();check_disk(b,d,True)
                if d.get('WritableVolume') is not False:raise ValueError('恢复后不是只读状态')
                result['restored_system_readonly']=True
            if mountpoint and not os.path.ismount(mountpoint):mountpoint.rmdir()
        except BaseException as error:
            result['restore_error']=repr(error)
            if isinstance(error,subprocess.CalledProcessError):result['restore_stderr']=error.stderr.decode(errors='replace')
        record()
    if not result['success'] or not result['restored_system_readonly']:raise SystemExit(1)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare',type=Path,help='新一轮绑定 JSON；不执行磁盘操作')
    mode.add_argument('--execute',type=Path,help=argparse.SUPPRESS)
    parser.add_argument('--candidate-dir',type=Path,help='已安装的匹配签名候选目录')
    args=parser.parse_args()
    if args.prepare:
        if not args.candidate_dir:parser.error('准备任务需要 --candidate-dir')
        prepare(args.prepare,args.candidate_dir)
    else:execute(args.execute)
