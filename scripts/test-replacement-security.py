#!/usr/bin/env python3
"""Target Windows security survives atomic publication on detached test images."""
import ctypes as C
import errno
import os
import sys
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from ntfs_bridge_test_support import ROOT, LIB, ImageIO

UP=ROOT/'.workbench/ntfs-3g-2026.7.7'
BIN=UP/'ntfsprogs'
replace=LIB.nk_replace_between
replace.argtypes=[C.c_void_p]+[C.c_char_p]*5;replace.restype=C.c_int

def descriptor(rid, audit=False, empty=False):
    def sid(authority,*parts):return bytes([1,len(parts)])+authority.to_bytes(6,'big')+struct.pack('<'+'I'*len(parts),*parts)
    owner=sid(5,21,111,222,333,rid);group=sid(5,32,545);everyone=sid(1,0)
    def ace(kind,flags,mask,who):return struct.pack('<BBHI',kind,flags,8+len(who),mask)+who
    def acl(entries):return struct.pack('<BBHHH',2,0,8+sum(map(len,entries)),len(entries),0)+b''.join(entries)
    dacl=acl([] if empty else [ace(1,0,2,everyone),ace(0,0,0x1f01ff,owner)])
    sacl=acl([ace(2,0x40,1,everyone)]) if audit else b''
    return struct.pack('<BBHIIII',1,0,0x9004|(0x10 if audit else 0),20,20+len(owner),20+len(owner)+len(group)+len(dacl) if audit else 0,20+len(owner)+len(group))+owner+group+dacl+sacl

def crash_child(image, point):
    assert image.is_file() and not image.is_symlink() and image.parent.parent==ROOT/'.workbench' and image.parent.name.startswith('replacement-security-')
    io=ImageIO(image);v=io.mount();assert v
    io.crash_after_write_at=io.writes+point
    replace(v,b'/incoming',b'draft',b'/',b'document',b'.old')
    raise AssertionError('write interruption did not trigger')

def main():
    folder=Path(tempfile.mkdtemp(prefix='replacement-security-',dir=ROOT/'.workbench'))
    tool=folder/'security-fixture'
    subprocess.run(['clang','-DHAVE_CONFIG_H','-I',str(UP),'-I',str(UP/'include'),str(ROOT/'scripts/fixtures/ntfs-security.c'),str(UP/'libntfs-3g/.libs/libntfs-3g.a'),'-framework','CoreFoundation','-o',str(tool)],check=True)
    def security(image,path,value=None):
        r=subprocess.run([tool,'get' if value is None else 'set',image,path],input=value,capture_output=True,check=True)
        return r.stdout
    def read(image,path):
        r=subprocess.run([BIN/'ntfscat','-f',image,path],capture_output=True)
        return r.stdout if r.returncode==0 else None
    cases=[]
    for label,acl in [('custom-owner-deny',descriptor(1001)),('audit-sacl',descriptor(1002,True)),('empty-dacl',descriptor(1003,empty=True)),('legacy-descriptor',descriptor(1004))]:
        image=folder/(label+'.img')
        with image.open('xb') as f:f.truncate(64*1024*1024)
        subprocess.run([BIN/'mkntfs','-F','-Q',image],check=True,capture_output=True)
        io=ImageIO(image);v=io.mount();assert v
        assert LIB.nk_mkdir(v,b'/',b'incoming')==0
        for parent,name,data in [(b'/incoming',b'draft',b'new-data'),(b'/',b'document',b'old-data'),(b'/',b'sentinel',b'untouched')]:
            path=parent.rstrip(b'/')+b'/'+name
            if label=='legacy-descriptor' and name==b'document':
                assert LIB.nk_umount(v)==0;io.close()
                subprocess.run([tool,'create-legacy',image,'document'],check=True,capture_output=True)
                io=ImageIO(image);v=io.mount();assert v
            else:
                assert LIB.nk_create(v,parent,name)==0
            assert LIB.nk_write(v,path,0,len(data),data)==len(data)
        assert LIB.nk_umount(v)==0;io.close()
        if label=='legacy-descriptor':
            subprocess.run([tool,'set-legacy',image,'/document'],input=acl,check=True,capture_output=True)
        else:security(image,'/document',acl)
        assert security(image,'/document')==acl,'fixture must preserve exact owner/group/DACL/SACL bytes'
        source_acl=security(image,'/incoming/draft');assert source_acl!=acl
        sentinel_acl=security(image,'/sentinel')
        pristine=folder/(label+'-pristine.img');shutil.copyfile(image,pristine)
        if label=='custom-owner-deny':
            # The generic upstream getter silently substitutes a minimal ACL
            # for an invalid security ID; publication must instead fail closed.
            corrupt=folder/'missing-security-id.img';shutil.copyfile(pristine,corrupt)
            subprocess.run([tool,'corrupt-id',corrupt,'/document'],check=True,capture_output=True)
            io=ImageIO(corrupt);v=io.mount();assert v
            count=io.writes
            assert replace(v,b'/incoming',b'draft',b'/',b'document',b'.old')==-1
            assert C.get_errno()==errno.EIO and io.writes==count
            assert LIB.nk_write(v,b'/sentinel',0,1,b'X')==-1 and C.get_errno()==errno.EIO
            assert LIB.nk_umount(v)==-1;io.close()
            assert read(corrupt,'/document')==b'old-data' and read(corrupt,'/incoming/draft')==b'new-data'
            cases.append('invalid-security-id-denied-without-publication')
        io=ImageIO(image);v=io.mount();assert v
        initial_writes,initial_syncs=io.writes,io.syncs
        assert replace(v,b'/incoming',b'draft',b'/',b'document',b'.old')==0
        writes,syncs=io.writes-initial_writes,io.syncs-initial_syncs
        assert LIB.nk_umount(v)==0;io.close()
        assert read(image,'/document')==b'new-data' and read(image,'/.old')==b'old-data'
        assert security(image,'/document')==acl,'覆盖保存丢失了目标 Windows 安全描述符：'+label
        assert security(image,'/.old')==acl and security(image,'/sentinel')==sentinel_acl
        cases.append(label)
        if label=='custom-owner-deny':
            assert 0<writes<128 and 0<syncs<32
            for kind,count in [('write',writes),('sync',syncs),('crash',writes)]:
                for point in range(1,count+1):
                    failed=folder/(kind+'-'+str(point)+'.img');shutil.copyfile(pristine,failed)
                    if kind=='crash':
                        run=subprocess.run([sys.executable,__file__,'--crash',str(failed),str(point)],capture_output=True)
                        assert run.returncode==86,(kind,point,run.stderr)
                    else:
                        io=ImageIO(failed);v=io.mount();assert v
                        if kind=='write':io.fail_write_at=io.writes+point
                        else:io.fail_sync_at=io.syncs+point
                        assert replace(v,b'/incoming',b'draft',b'/',b'document',b'.old')==-1,(kind,point)
                        assert LIB.nk_write(v,b'/sentinel',0,1,b'X')==-1 and C.get_errno()==errno.EIO
                        assert LIB.nk_umount(v)==-1;io.close()
                    data=[read(failed,path) for path in ['/incoming/draft','/document','/.old']]
                    assert b'old-data' in data and b'new-data' in data,(kind,point,'content lost')
                    assert read(failed,'/sentinel')==b'untouched'
                    # Whichever path still carries the old inode must retain its original ACL.
                    old_path='/document' if read(failed,'/document')==b'old-data' else '/.old'
                    assert security(failed,old_path)==acl,(kind,point,'old ACL changed')
                    if read(failed,'/document')==b'new-data':assert security(failed,'/document')==acl
                    io=ImageIO(failed);assert io.mount() is None,'faulted image was reopened writable';io.close()
                    cases.append(kind+'-'+str(point))
    (folder/'result.json').write_text(json.dumps({'success':True,'cases':cases})+'\n')
    print('Windows security replacement PASS:',cases,'evidence:',folder)
if __name__=='__main__':
    if len(sys.argv)==4 and sys.argv[1]=='--crash':crash_child(Path(sys.argv[2]).resolve(),int(sys.argv[3]))
    else:main()
