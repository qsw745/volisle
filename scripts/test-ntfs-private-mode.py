#!/usr/bin/env python3
"""Mac-only persistent modes on new ordinary images; never raw devices."""
import ctypes as C
import errno
import sys
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
from ntfs_bridge_test_support import ROOT, LIB, ImageIO, NAME_CB

assert hasattr(LIB, 'nk_create_mode'), '尚未实现持久私有权限创建接口'
assert hasattr(LIB, 'nk_set_mac_mode'), '尚未实现持久 Mac 权限接口'
from ntfs_replacement_recovery import Stat
LIB.nk_create_mode.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p,C.c_uint32,C.c_int]
LIB.nk_create_mode.restype=C.c_int
LIB.nk_set_mac_mode.argtypes=[C.c_void_p,C.c_char_p,C.c_uint32]
LIB.nk_set_mac_mode.restype=C.c_int
LIB.nk_stat_path.argtypes=[C.c_void_p,C.c_char_p,C.POINTER(Stat)]
LIB.nk_stat_reference.argtypes=[C.c_void_p,C.c_uint64,C.POINTER(Stat)]
LIB.nk_reference_path.argtypes=[C.c_void_p,C.c_char_p,C.POINTER(C.c_uint64)]
LIB.nk_set_file_mode.argtypes=[C.c_void_p,C.c_char_p,C.c_uint32]
DIR_CB=C.CFUNCTYPE(C.c_int,C.c_void_p,C.c_void_p)
LIB.nk_list.argtypes=[C.c_void_p,C.c_char_p,DIR_CB,C.c_void_p]
BIN=ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs'

def extract(image,path,attr=None):
    if attr=='security':
        # NTFS 3.x keeps the ACL in $Secure; a file only names it by the
        # security_id in $STANDARD_INFORMATION (offset 52), so compare that.
        info=subprocess.check_output([BIN/'ntfscat','-a','0x10',image,path],stderr=subprocess.DEVNULL)
        assert len(info)>=72, len(info)
        return info[52:56]
    return subprocess.check_output([BIN/'ntfscat',*(['-n',attr] if attr else []),image,path],stderr=subprocess.DEVNULL)

def stat(v,path):
    s=Stat();assert LIB.nk_stat_path(v,path,C.byref(s))==0;return s

if len(sys.argv)==4 and sys.argv[1]=='--crash':
    image=Path(sys.argv[2]).resolve()
    assert image.parent.parent==ROOT/'.workbench' and image.parent.name.startswith('volisle-private-mode-')
    assert image.is_file() and image.stat().st_size==64*1024*1024
    io=ImageIO(image);v=io.mount();assert v
    io.crash_after_write_at=io.writes+int(sys.argv[3])
    LIB.nk_create_mode(v,b'/',b'new-private',0o600,0)
    raise AssertionError('创建进程中断点未触发')

with tempfile.TemporaryDirectory(prefix='volisle-private-mode-',dir=ROOT/'.workbench') as tmp:
    image=Path(tmp)/'fixture.img'
    with image.open('xb') as f:f.truncate(64*1024*1024)
    subprocess.run([BIN/'mkntfs','-F','-Q',image],capture_output=True,check=True)
    io=ImageIO(image);v=io.mount();assert v
    assert LIB.nk_create(v,b'/',b'legacy')==0
    assert LIB.nk_write(v,b'/legacy',0,8,b'original')==8
    assert LIB.nk_umount(v)==0;io.close()
    acl=extract(image,'/legacy','security')
    io=ImageIO(image);v=io.mount();assert v
    before=io.writes
    for mode,isdir in [(0o777,0),(0o4600,0),(0,0),(0o600,1),(0o700,0)]:
        assert LIB.nk_create_mode(v,b'/',b'invalid',mode,isdir)==-1
        assert C.get_errno()==errno.ENOTSUP and io.writes==before
    assert LIB.nk_create_mode(v,b'/',b'private',0o600,0)==0, C.get_errno()
    assert LIB.nk_create_mode(v,b'/',b'folder',0o700,1)==0
    assert LIB.nk_write(v,b'/private',0,7,b'private')==7
    assert LIB.nk_set_mac_mode(v,b'/legacy',0o600)==0
    assert stat(v,b'/legacy').mac_mode==0o600
    before=io.writes
    assert LIB.nk_set_file_mode(v,b'/legacy',0o644)==-1 and C.get_errno()==errno.ENOTSUP
    assert io.writes==before and stat(v,b'/legacy').mac_mode==0o600
    ref=C.c_uint64();assert LIB.nk_reference_path(v,b'/private',C.byref(ref))==0
    assert LIB.nk_rename(v,b'/private',b'/folder',b'moved')==0
    s=Stat();assert LIB.nk_stat_reference(v,ref.value,C.byref(s))==0 and s.mac_mode==0o600
    names=[]
    @NAME_CB
    def collect(_,name):names.append(name.decode());return 0
    assert LIB.nk_xattr_list(v,b'/legacy',collect,None)==0 and not names
    before=io.writes
    for name in [b'$VOLISLE.MODE',b'$volisle.mode']:
        assert LIB.nk_xattr_get(v,b'/legacy',name,None,0)==-1
        assert LIB.nk_xattr_set(v,b'/legacy',name,b'x',1,0)==-1
        assert LIB.nk_xattr_remove(v,b'/legacy',name)==-1
    assert io.writes==before
    assert LIB.nk_set_mac_mode(v,b'/legacy',0o400)==0
    assert LIB.nk_write(v,b'/legacy',0,1,b'X')==-1 and C.get_errno()==errno.EACCES
    assert stat(v,b'/legacy').mac_mode==0o400
    assert LIB.nk_set_mac_mode(v,b'/legacy',0o600)==0
    assert LIB.nk_umount(v)==0;io.close()
    assert extract(image,'/legacy','security')==acl
    assert extract(image,'/legacy')==b'original'
    blob=extract(image,'/folder/moved','$VOLISLE.MODE')
    assert len(blob)==32 and blob[:8]==b'VOLMODE1'
    assert struct.unpack_from('<HHIQ',blob,8)==(1,1,0o600,ref.value)
    io=ImageIO(image,readonly=True);v=io.mount();assert v
    for path,mode in [(b'/legacy',0o600),(b'/folder',0o700),(b'/folder/moved',0o600)]:assert stat(v,path).mac_mode==mode
    assert LIB.nk_set_mac_mode(v,b'/legacy',0o644)==-1 and C.get_errno()==errno.EROFS
    folder_inode=stat(v,b'/folder').inode
    assert io.writes==0 and LIB.nk_umount(v)==0;io.close()
    print('私有权限创建、持久化、改名引用、只读卷、Windows ACL 保留及保留流隔离通过。')

    # Each malformed record is injected by an independent upstream utility.
    mutations = {'truncated': blob[:-1], 'checksum': blob[:24] + bytes(4) + blob[28:],
                 'empty': b''}
    for label, offset, value in [('version',8,2),('kind',10,2),('mode',12,0o777),('reference',16,1)]:
        b=bytearray(blob)
        width=8 if offset==16 else 4 if offset==12 else 2
        b[offset:offset+width]=value.to_bytes(width,'little')
        h=2166136261
        for x in b[:24]:h=((h^x)*16777619)&0xffffffff
        b[24:28]=h.to_bytes(4,'little');mutations[label]=bytes(b)
    for label, damaged in mutations.items():
        bad=Path(tmp)/(label+'.img');shutil.copyfile(image,bad)
        source=Path(tmp)/(label+'.bin');source.write_bytes(damaged)
        subprocess.run([BIN/'ntfscp','-N','$VOLISLE.MODE',bad,source,'/folder/moved'],capture_output=True,check=True)
        io=ImageIO(bad);v=io.mount();assert v
        writes=io.writes;s=Stat()
        assert LIB.nk_stat_path(v,b'/folder/moved',C.byref(s))==-1, label
        assert LIB.nk_write(v,b'/legacy',0,1,b'X')==-1 and C.get_errno()==errno.EIO
        assert io.writes==writes
        assert LIB.nk_umount(v)==-1;io.close()
    print('7 类损坏记录拒绝访问，并封锁其他后续写入。')
    for failure in ['write','short','sync']:
        bad=Path(tmp)/('io-'+failure+'.img');shutil.copyfile(image,bad)
        io=ImageIO(bad);v=io.mount();assert v
        if failure=='write':io.fail_write_at=io.writes+1
        elif failure=='short':io.short_write=True
        else:io.fail_sync_at=io.syncs+1
        assert LIB.nk_set_mac_mode(v,b'/legacy',0o644)==-1, failure
        assert LIB.nk_write(v,b'/legacy',0,1,b'X')==-1 and C.get_errno()==errno.EIO
        assert LIB.nk_umount(v)==-1;io.close()
        check=ImageIO(bad,readonly=True);assert check.inspect()!=0 and check.writes==0;check.close()
    print('写入失败、短写、刷新失败均锁定会话且保留脏标记。')

    baseline=Path(tmp)/'create-baseline.img';shutil.copyfile(image,baseline)
    io=ImageIO(baseline);v=io.mount();assert v
    before_writes, before_syncs=io.writes,io.syncs
    assert LIB.nk_create_mode(v,b'/',b'new-private',0o600,0)==0
    write_count,sync_count=io.writes-before_writes,io.syncs-before_syncs
    assert LIB.nk_umount(v)==0;io.close()
    for kind,count in [('write',write_count),('sync',sync_count)]:
        for point in range(1,count+1):
            bad=Path(tmp)/f'create-{kind}-{point}.img';shutil.copyfile(image,bad)
            io=ImageIO(bad);v=io.mount();assert v
            if kind=='write':io.fail_write_at=io.writes+point
            else:io.fail_sync_at=io.syncs+point
            assert LIB.nk_create_mode(v,b'/',b'new-private',0o600,0)==-1,(kind,point)
            assert LIB.nk_write(v,b'/legacy',0,1,b'X')==-1 and C.get_errno()==errno.EIO
            assert LIB.nk_umount(v)==-1;io.close()
            check=ImageIO(bad,readonly=True);assert check.inspect()!=0 and check.writes==0;check.close()
    print(f'创建过程逐点注入 {write_count} 个写入、{sync_count} 个同步故障，均保留失败状态。')

    for point in range(1,write_count+1):
        bad=Path(tmp)/f'create-crash-{point}.img';shutil.copyfile(image,bad)
        child=subprocess.run([sys.executable,__file__,'--crash',str(bad),str(point)],capture_output=True,timeout=15)
        assert child.returncode==86,(point,child.stderr[-500:])
        check=ImageIO(bad);writes=check.writes
        assert check.inspect()!=0 and not check.mount() and check.writes==writes
        check.close()
    print(f'创建过程 {write_count} 个完整写回调后中断，全部拒绝重新读写挂载。')
    @DIR_CB
    def collect_entry(_,entry):return 0
    for operation in ['list','xattr-list','xattr-get']:
        bad=Path(tmp)/(operation+'.img');shutil.copyfile(image,bad)
        source=Path(tmp)/(operation+'.bin');source.write_bytes(b'bad')
        target='/folder' if operation=='list' else '/folder/moved'
        subprocess.run([BIN/'ntfscp',*(['-i'] if operation=='list' else []),'-N','$VOLISLE.MODE',bad,source,str(folder_inode) if operation=='list' else target],capture_output=True,check=True)
        io=ImageIO(bad);v=io.mount();assert v;writes=io.writes
        if operation=='list':rc=LIB.nk_list(v,b'/folder',collect_entry,None)
        elif operation=='xattr-list':rc=LIB.nk_xattr_list(v,b'/folder/moved',collect,None)
        else:rc=LIB.nk_xattr_get(v,b'/folder/moved',b'user.test',None,0)
        assert rc==-1 and C.get_errno()==errno.EIO,operation
        assert LIB.nk_write(v,b'/legacy',0,1,b'X')==-1 and io.writes==writes
        assert LIB.nk_umount(v)==-1;io.close()
    print('损坏权限在目录枚举、扩展属性枚举和读取入口直接拒绝。')
