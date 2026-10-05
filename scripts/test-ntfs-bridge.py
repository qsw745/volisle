#!/usr/bin/env python3
"""Real NTFS bridge tests restricted to newly created regular images.
Never attaches a filesystem or accepts a user device/path argument.
"""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
from datetime import datetime, timezone

from ntfs_bridge_test_support import ROOT, LIB, ImageIO, NAME_CB, IO, PWRITE, SYNC
import errno
import sys

def digest(path):return hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
checks=[]
def passed(name):checks.append({'name':name,'passed':True});print('PASS',name,flush=True)
def write(v,path,data,offset=0):
    buf=C.create_string_buffer(data);return LIB.nk_write(v,path,offset,len(data),buf)
def read(v,path,size,offset=0):
    buf=C.create_string_buffer(size);n=LIB.nk_read(v,path,offset,size,buf)
    assert n>=0,(path,n);return buf.raw[:n]

with tempfile.TemporaryDirectory(prefix='volisle-bridge-',dir=ROOT/'.workbench') as tmp:
    folder=Path(tmp);base=folder/'clean.img'
    with base.open('xb') as f:f.truncate(64*1024*1024)
    subprocess.run([str(ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs'),'-F','-Q','-L','VOLISLE_TEST',str(base)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=45)
    clean_hash=digest(base);device=ImageIO(base)
    assert device.inspect()==0
    assert device.writes==0 and digest(base)==clean_hash
    passed('干净卷预检：零写回调且整镜像 SHA-256 不变')
    # The FSKit activation preflight deliberately supplies no writer/flusher.
    # Characterize that real C boundary, not just a mocked clean status.
    inspection_io = IO.from_buffer_copy(device.io)
    inspection_io.readonly = 1
    inspection_io.pwrite = PWRITE()
    inspection_io.sync = SYNC()
    assert LIB.nk_inspect(C.byref(inspection_io)) == 0
    assert device.writes == 0 and digest(base) == clean_hash
    passed('无写入和刷新回调的只读描述符可完成真实预检，镜像不变')
    v=device.mount();assert v
    payload=bytes(range(256))*8192
    filename='/中文 空格 💽.bin'.encode()
    assert LIB.nk_create(v,b'/',filename[1:])==0
    assert write(v,filename,payload)==len(payload)
    assert write(v,filename,b'changed',12345)==7
    payload=payload[:12345]+b'changed'+payload[12352:]
    assert read(v,filename,len(payload))==payload
    assert LIB.nk_mkdir(v,b'/',b'folder')==0
    assert LIB.nk_rename(v,filename,b'/folder','移动.bin'.encode())==0
    destination='/folder/移动.bin'.encode()
    assert LIB.nk_truncate(v,destination,1048576)==0
    payload=payload[:1048576]
    assert LIB.nk_sync(v)==0
    assert device.syncs>0
    assert LIB.nk_umount(v)==0;device.close()
    passed('创建、随机覆盖、中文路径、移动改名、截断、同步与关闭')
    # New native process, independent engine API, read the same persisted file.
    observed=subprocess.run([str(ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat'),str(base),destination.decode()],capture_output=True,check=True,timeout=30).stdout
    assert hashlib.sha256(observed).digest()==hashlib.sha256(payload).digest()
    passed('新进程 ntfscat 重新读取，内容 SHA-256 一致')
    device=ImageIO(base);v=device.mount();assert v
    assert LIB.nk_delete(v,destination)==0
    assert LIB.nk_delete(v,b'/folder')==0
    assert LIB.nk_sync(v)==0;assert LIB.nk_umount(v)==0;device.close()
    passed('删除文件与空目录并持久化')
    device=ImageIO(base,readonly=True);before=digest(base);v=device.mount();assert v
    assert LIB.nk_create(v,b'/',b'forbidden')!=0
    assert LIB.nk_umount(v)==0
    assert device.writes==0 and before==digest(base);device.close()
    passed('只读挂载拒绝创建，零写回调且镜像不变')
    dirty=folder/'dirty.img';shutil.copyfile(base,dirty)
    with dirty.open('r+b') as f:
        boot=f.read(512);sector=struct.unpack_from('<H',boot,11)[0];cluster=sector*boot[13]
        cpr=struct.unpack_from('b',boot,64)[0];record=(1<<-cpr) if cpr<0 else cpr*cluster
        for mft in [struct.unpack_from('<Q',boot,48)[0],struct.unpack_from('<Q',boot,56)[0]]:
            pos=mft*cluster+3*record;f.seek(pos);data=f.read(record);a=struct.unpack_from('<H',data,20)[0]
            while struct.unpack_from('<I',data,a)[0]!=0xffffffff:
                kind,length=struct.unpack_from('<II',data,a)
                assert length>=24 and a+length<=record
                if kind==0x70:
                    value=struct.unpack_from('<H',data,a+20)[0];flags_at=pos+a+value+10
                    f.seek(flags_at);flags=struct.unpack('<H',f.read(2))[0];f.seek(flags_at);f.write(struct.pack('<H',flags|1));break
                a+=length
            else:raise AssertionError('volume flags fixture missing')
    before=digest(dirty);device=ImageIO(dirty)
    assert device.inspect()==1
    inspection_io = IO.from_buffer_copy(device.io)
    inspection_io.readonly = 1
    inspection_io.pwrite = PWRITE()
    inspection_io.sync = SYNC()
    assert LIB.nk_inspect(C.byref(inspection_io)) == 1
    assert not device.mount()
    assert device.writes==0 and digest(dirty)==before;device.close()
    passed('dirty 卷拒绝写挂载，不清 dirty，镜像不变')
    hiber=folder/'hiber.img';shutil.copyfile(base,hiber);device=ImageIO(hiber)
    v=device.mount();assert v
    assert LIB.nk_create(v,b'/',b'hiberfil.sys')==0
    assert write(v,b'/hiberfil.sys',b'hibr'+bytes(4092))==4096
    assert LIB.nk_umount(v)==0
    before=digest(hiber);device.writes=0
    assert device.inspect()==2
    assert not device.mount()
    assert device.writes==0 and digest(hiber)==before;device.close()
    passed('休眠卷拒绝写挂载，不删除休眠文件，镜像不变')
    corrupt=folder/'corrupt.img';shutil.copyfile(base,corrupt)
    with corrupt.open('r+b') as f:f.write(bytes(512))
    before=digest(corrupt);device=ImageIO(corrupt)
    assert device.inspect()==4 and not device.mount()
    assert device.writes==0 and digest(corrupt)==before;device.close()
    passed('损坏引导区返回未知并拒绝写挂载')
    badlog=folder/'badlog.img';shutil.copyfile(base,badlog)
    # Offline fixture tool only; production bridge cannot modify metadata files.
    logpayload=folder/'log.bin';logpayload.write_bytes(b'BROKEN_LOG'*4096)
    subprocess.run([str(ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscp'),str(badlog),str(logpayload),'/$LogFile'],capture_output=True,check=True,timeout=30)
    before=digest(badlog);device=ImageIO(badlog)
    assert device.inspect()!=0 and not device.mount()
    assert device.writes==0 and digest(badlog)==before;device.close()
    passed('损坏日志拒绝写挂载，不重置日志，镜像不变')
    device=ImageIO(base);v=device.mount();assert v
    for badname in [b'../escape',b'.',b'..',b'$MFT',b'file:stream']:
        assert LIB.nk_create(v,b'/',badname)!=0
    assert write(v,b'/$MFT',b'bad')<0
    assert LIB.nk_umount(v)==0;device.close()
    passed('拒绝非法文件名和对系统元数据文件的直接写入')
    failed=folder/'failed-write.img';shutil.copyfile(base,failed);device=ImageIO(failed)
    v=device.mount();assert v;device.fail_write=True
    assert LIB.nk_create(v,b'/',b'fail.txt')!=0
    device.fail_write=False
    LIB.nk_umount(v);device.close()
    passed('写回调失败不会冒充文件创建成功')
    device=ImageIO(base);device.fail_read=True
    assert device.inspect()==4 and not device.mount() and device.writes==0
    device.close();passed('I/O 读取失败拒绝写挂载')
    attrs=folder/'attrs.img';shutil.copyfile(base,attrs);device=ImageIO(attrs)
    v=device.mount();assert v
    assert LIB.nk_create(v,b'/',b'attributes')==0
    path=b'/attributes';name=b'com.apple.FinderInfo';value=bytes(range(32))
    assert LIB.nk_xattr_set(v,path,name,value,len(value),1)==0
    assert LIB.nk_xattr_set(v,path,name,b'bad',3,1)==-1 and C.get_errno()==errno.EEXIST
    assert LIB.nk_xattr_set(v,path,b'missing',b'bad',3,2)==-1 and C.get_errno()==errno.ENOATTR
    buf=C.create_string_buffer(32)
    assert LIB.nk_xattr_get(v,path,name,buf,31)==-1 and C.get_errno()==errno.ERANGE
    assert LIB.nk_xattr_get(v,path,name,buf,32)==32 and buf.raw==value
    assert LIB.nk_xattr_set(v,path,b'empty',None,0,0)==0
    assert LIB.nk_xattr_get(v,path,b'empty',buf,32)==0
    large=bytes(range(256))*1024;unicode_name='标签.颜色'.encode()
    assert LIB.nk_xattr_set(v,path,unicode_name,large,len(large),0)==0
    assert LIB.nk_xattr_set(v,path,b'too-big',b'x',4*1024*1024+1,0)==-1 and C.get_errno()==errno.E2BIG
    assert LIB.nk_xattr_set(v,path,b'com.apple.decmpfs',b'x',1,0)==-1 and C.get_errno()==errno.ENOTSUP
    names=[]
    @NAME_CB
    def collect(_,n):names.append(n);return 0
    assert LIB.nk_xattr_list(v,path,collect,None)==0
    assert set(names)=={name,b'empty',unicode_name},names
    assert LIB.nk_xattr_set(v,path,unicode_name,b'short',5,2)==0
    assert LIB.nk_xattr_remove(v,path,b'empty')==0
    assert LIB.nk_xattr_remove(v,path,b'empty')==-1 and C.get_errno()==errno.ENOATTR
    assert LIB.nk_umount(v)==0;device.close()
    observed=subprocess.run([str(ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat'),'-n',name.decode(),str(attrs),path.decode()],capture_output=True,check=True,timeout=30).stdout
    assert observed==value
    passed('扩展属性新增、替换策略、空值、中文名、大值缩短、删除与独立进程持久化')
    device=ImageIO(attrs,readonly=True);v=device.mount();assert v;before=digest(attrs)
    assert LIB.nk_xattr_get(v,path,unicode_name,buf,32)==5 and buf.raw[:5]==b'short'
    assert LIB.nk_xattr_set(v,path,name,b'bad',3,0)==-1 and C.get_errno()==errno.EROFS
    assert LIB.nk_xattr_remove(v,path,name)==-1 and C.get_errno()==errno.EROFS
    assert LIB.nk_umount(v)==0 and device.writes==0 and digest(attrs)==before;device.close()
    passed('只读扩展属性可读，修改和删除拒绝且整镜像不变')
    lifecycle=folder/'lifecycle.img';shutil.copyfile(base,lifecycle);device=ImageIO(lifecycle)
    v=device.mount();assert v
    assert device.inspect()==1
    assert LIB.nk_sync(v)==0 and device.inspect()==1
    assert LIB.nk_umount(v)==0 and device.inspect()==0;device.close()
    passed('写会话先持久化 dirty，同步不清标记，正常关闭后恢复干净')
    crash=folder/'crash.img';shutil.copyfile(base,crash)
    child="""import os,sys
from pathlib import Path
from ntfs_bridge_test_support import LIB,ImageIO
d=ImageIO(Path(sys.argv[1]));v=d.mount();assert v
assert LIB.nk_create(v,b'/',b'durable-before-crash')==0
assert LIB.nk_sync(v)==0
os._exit(73)
"""
    result=subprocess.run([sys.executable,'-c',child,str(crash)],cwd=ROOT/'scripts',capture_output=True,timeout=30)
    assert result.returncode==73,result.stderr
    device=ImageIO(crash);before=digest(crash)
    assert device.inspect()==1 and not device.mount()
    assert device.writes==0 and digest(crash)==before;device.close()
    passed('独立写进程异常退出后保留 dirty，再次写挂载拒绝且镜像不变')
    for fault in ['short_read','short_write']:
        image=folder/(fault+'.img');shutil.copyfile(base,image);device=ImageIO(image)
        v=device.mount();assert v;setattr(device,fault,True)
        assert LIB.nk_create(v,b'/',b'fault')!=0
        setattr(device,fault,False);writes=device.writes
        assert LIB.nk_create(v,b'/',b'must-stay-blocked')!=0 and device.writes==writes
        assert LIB.nk_umount(v)!=0 and device.inspect()==1;device.close()
    passed('短读、短写后会话持续拒绝写入，关闭报错并保留 dirty')
    marker=folder/'marker-sync.img';shutil.copyfile(base,marker);device=ImageIO(marker)
    device.fail_sync=True
    assert not device.mount()
    device.fail_sync=False
    assert device.inspect()==1;device.close()
    passed('会话标记同步失败时不返回可写句柄')
    full=folder/'full.img';shutil.copyfile(base,full);device=ImageIO(full)
    v=device.mount();assert v
    sentinel=b'untouched file content\x00'*100
    assert LIB.nk_create(v,b'/',b'sentinel')==0
    assert write(v,b'/sentinel',sentinel)==len(sentinel)
    assert LIB.nk_create(v,b'/',b'fill')==0
    chunk=bytes(range(256))*4096
    for index in range(65):
        count=write(v,b'/fill',chunk,index*len(chunk))
        if count!=len(chunk):break
    else:raise AssertionError('bounded disk-full fixture did not fill')
    assert count<0 and C.get_errno()==errno.ENOSPC
    # Out of space is not damage (2026-10-04): the session stays usable, so
    # writing inside existing allocation works and the volume closes clean.
    assert write(v,b'/sentinel',b'allowed!!')==9
    assert LIB.nk_umount(v)==0 and device.inspect()==0;device.close()
    observed=subprocess.run([str(ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/ntfscat'),'-f',str(full),'/sentinel'],capture_output=True,check=True,timeout=30).stdout
    assert observed==b'allowed!!'+sentinel[9:]
    passed('真实镜像写满时返回空间不足，会话不锁定，已有文件仍可写入，卸载后卷干净')
    closing=folder/'close-baseline.img';shutil.copyfile(base,closing);device=ImageIO(closing)
    v=device.mount();assert v;before_sync=device.syncs
    assert LIB.nk_umount(v)==0
    close_syncs=device.syncs-before_sync;device.close();assert close_syncs>0
    for point in range(1,close_syncs+1):
        image=folder/('close-sync-'+str(point)+'.img');shutil.copyfile(base,image);device=ImageIO(image)
        v=device.mount();assert v;device.fail_sync_at=device.syncs+point
        assert LIB.nk_umount(v)!=0,point
        # A final failure after an already durable clean marker is still an
        # error; only failures before that marker must retain dirty state.
        if point<close_syncs:assert device.inspect()==1,(point,close_syncs)
        device.close()
    passed('逐一注入关闭同步点故障，所有故障均向调用方报告失败')
    device=ImageIO(base);v=device.mount();assert v
    device.fail_sync=True
    assert LIB.nk_sync(v)!=0
    device.fail_sync=False
    assert LIB.nk_umount(v)!=0
    assert device.inspect()==1;device.close()
    passed('同步失败锁定会话并保留 dirty 标记')
report={'executed_at':datetime.now(timezone.utc).isoformat(),'engine':'NTFS-3G 2026.7.7 + Volisle callback bridge','scope':'新建普通文件镜像，未 attach，未访问原始设备','checks':checks,'temporary_images_removed':not folder.exists(),'not_covered':['FSKit 扩展安装与 Finder 挂载','Windows 与 chkdsk','真实拔盘、断电、睡眠','完整特性与兼容性矩阵']}
(ROOT/'docs/testing/ntfs-bridge-result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
