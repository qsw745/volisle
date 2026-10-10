#!/usr/bin/env python3
"""New detached images only; never accepts a user disk or recovery path."""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from ntfs_bridge_test_support import ROOT, LIB, ImageIO, PWRITE
from fixture_block_journal import BlockJournal, recover
import fixture_block_journal as journal_module
from test_workdir import finish_workdir, make_workdir

BIN=ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs'
SENTINEL=b'preserve-existing-file'*128

class JournalIO(ImageIO):
    def __init__(self, image, journal):
        super().__init__(image)
        self.journal=BlockJournal(image,journal)
        original=self.callbacks[1]
        @PWRITE
        def write(ctx,buf,count,offset):
            try: self.journal.before_write(offset,C.string_at(buf,count))
            except Exception: return -1
            return original(ctx,buf,count,offset)
        self.protected_write=write
        self.io.pwrite=write
    def close(self):
        self.journal.close();super().close()

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    folder=make_workdir('block-journal-')
    base=folder/'base.img'
    with base.open('xb') as f:f.truncate(64*1024*1024)
    subprocess.run([BIN/'mkntfs','-F','-Q',base],check=True,capture_output=True)
    io=ImageIO(base);v=io.mount();assert v
    assert LIB.nk_create(v,b'/',b'sentinel')==0
    assert LIB.nk_write(v,b'/sentinel',0,len(SENTINEL),SENTINEL)==len(SENTINEL)
    assert LIB.nk_umount(v)==0;io.close()
    initial=digest(base);checks=[];complete=False
    try:
        for kind in ['file','directory']:
            create=LIB.nk_create if kind=='file' else LIB.nk_mkdir
            for fault in ['write','crash']:
                for point in range(1,7):
                    image=folder/f'{kind}-{fault}-{point}.img';journal=image.with_suffix('.journal')
                    shutil.copyfile(base,image)
                    if fault=='write':
                        io=JournalIO(image,journal);v=io.mount();assert v
                        io.fail_write_at=io.writes+point
                        assert create(v,b'/',b'new-node')==-1
                        assert LIB.nk_umount(v)==-1;io.close()
                    else:
                        command='''import sys,importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('fixture_test',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
io=m.JournalIO(Path(sys.argv[2]),Path(sys.argv[3]));v=m.LIB.nk_mount_io(m.C.byref(io.io),None,0);assert v
io.crash_after_write_at=io.writes+int(sys.argv[4])
getattr(m.LIB,sys.argv[5])(v,b'/',b'new-node')
raise AssertionError('fault point not reached')
'''
                        p=subprocess.run([sys.executable,'-c',command,str(Path(__file__).resolve()),str(image),str(journal),str(point),'nk_create' if kind=='file' else 'nk_mkdir'],cwd=ROOT/'scripts',capture_output=True,timeout=30)
                        assert p.returncode==86,p.stderr
                    result=recover(image,journal)
                    assert result['state']=='rolled-back' and digest(image)==initial
                    assert recover(image,journal)=={'state':'rolled-back','writes':0}
                    assert subprocess.check_output([BIN/'ntfscat',image,'/sentinel'])==SENTINEL
                    io=ImageIO(image);assert io.inspect()==0;v=io.mount();assert v;assert LIB.nk_umount(v)==0;io.close()
                    # Inspection mount changes NTFS timestamps, so repeat
                    # recovery is tested before opening another write session.
                    checks.append(f'{kind}-{fault}-{point}-exact-rollback-and-independent-read')
                    image.unlink()
        image=folder/'commit.img';journal=image.with_suffix('.journal');shutil.copyfile(base,image)
        io=JournalIO(image,journal);v=io.mount();assert v
        assert LIB.nk_create(v,b'/',b'new-node')==0
        assert LIB.nk_write(v,b'/new-node',0,3,b'new')==3
        assert LIB.nk_umount(v)==0
        io.journal.commit();io.close();after=digest(image)
        assert recover(image,journal)['state']=='committed' and digest(image)==after
        assert subprocess.check_output([BIN/'ntfscat',image,'/new-node'])==b'new'
        checks.append('committed-transaction-kept')
        def pending(name,overlap=False):
            image=folder/(name+'.img');journal=image.with_suffix('.journal');shutil.copyfile(base,image)
            record=BlockJournal(image,journal)
            for offset,data in [(100000,b'XYZ'*12),(100015 if overlap else 200000,b'ABC'*17)]:
                record.before_write(offset,data)
                assert os.pwrite(record.image,data,offset)==len(data)
            os.fsync(record.image);record.close()
            return image,journal
        for corruption in ['truncated','changed','extra-event']:
            image,journal=pending('log-'+corruption);before=digest(image)
            data=journal.read_bytes()
            if corruption=='truncated':data=data[:-10]
            elif corruption=='changed':data=data.replace(b'"offset":100000',b'"offset":100001')
            else:data+=b'{"payload":{}}\n'
            journal.write_bytes(data)
            try:recover(image,journal);raise AssertionError('invalid journal accepted')
            except (ValueError,KeyError):pass
            assert digest(image)==before;checks.append(corruption+'-log-refused-zero-image-change')
        image,journal=pending('identity');other=folder/'other.img';shutil.copyfile(image,other);before=digest(other)
        try:recover(other,journal);raise AssertionError('different inode accepted')
        except ValueError:pass
        assert digest(other)==before;checks.append('wrong-image-refused')
        for name,offset in [('unlogged-change',300000),('logged-unexpected-byte',100000)]:
            image,journal=pending(name)
            with image.open('r+b') as f:f.seek(offset);f.write(b'\xfe')
            before=digest(image)
            try:recover(image,journal);raise AssertionError('external change accepted')
            except ValueError:pass
            assert digest(image)==before;checks.append(name+'-refused')
        for link_type in ['symlink','hardlink']:
            image,journal=pending(link_type);link=folder/(link_type+'-link.img')
            if link_type=='symlink':link.symlink_to(image)
            else:os.link(image,link)
            before=digest(image)
            try:recover(link,journal);raise AssertionError('linked image accepted')
            except ValueError:pass
            assert digest(image)==before;checks.append(link_type+'-refused')
        for point in [1,2]:
            image,journal=pending('rollback-interrupted-'+str(point))
            def stop(count):
                if count==point:raise InterruptedError('test interruption')
            try:recover(image,journal,after_write=stop);raise AssertionError('hook not reached')
            except InterruptedError:pass
            assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
            assert recover(image,journal)['writes']==0
            checks.append(f'rollback-interruption-{point}-resumed')
        image,journal=pending('overlap',overlap=True)
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('overlapping-writes-restored')
        # A partial image write may contain both old and new bytes, but the
        # original entire-image digest must still reconstruct exactly.
        image=folder/'short.img';journal=image.with_suffix('.journal');shutil.copyfile(base,image)
        record=BlockJournal(image,journal);record.before_write(100000,b'partial-write')
        os.pwrite(record.image,b'part',100000);os.fsync(record.image);record.close()
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('partial-write-restored')
        # If journaling itself fails, the real bridge must never reach its
        # underlying disk-write callback; previously logged mount changes can
        # still be recovered from the valid log prefix.
        image=folder/'journal-fails.img';journal=image.with_suffix('.journal');shutil.copyfile(base,image)
        io=JournalIO(image,journal);v=io.mount();assert v
        writes=io.writes;before=digest(image);original_append=journal_module.append
        def failed_append(*args):raise OSError('injected journal persistence failure')
        journal_module.append=failed_append
        try:
            assert LIB.nk_create(v,b'/',b'not-allowed')==-1
            assert io.writes==writes and digest(image)==before
            assert LIB.nk_umount(v)==-1
        finally:journal_module.append=original_append;io.close()
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('journal-failure-prevents-image-write')
        image,journal=pending('rollback-process-crash')
        command='from pathlib import Path; import os,sys; from fixture_block_journal import recover; recover(Path(sys.argv[1]),Path(sys.argv[2]),after_write=lambda _: os._exit(87))'
        process=subprocess.run([sys.executable,'-c',command,str(image),str(journal)],cwd=ROOT/'scripts',capture_output=True,timeout=30)
        assert process.returncode==87,process.stderr
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('recovery-process-crash-resumed')
        image,journal=pending('rollback-partial-write',overlap=True)
        original_pwrite=journal_module.os.pwrite
        def torn_rollback(fd,data,offset):
            original_pwrite(fd,data[:max(1,len(data)//2)],offset);os.fsync(fd)
            raise OSError('injected partial recovery write')
        journal_module.os.pwrite=torn_rollback
        try:
            try:recover(image,journal);raise AssertionError('partial recovery fault not reached')
            except OSError:pass
        finally:journal_module.os.pwrite=original_pwrite
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('partial-recovery-write-resumed')
        image=folder/'commit-marker-fails.img';journal=image.with_suffix('.journal');shutil.copyfile(base,image)
        record=BlockJournal(image,journal);record.before_write(100000,b'pending')
        os.pwrite(record.image,b'pending',100000)
        journal_module.append=failed_append
        try:
            try:record.commit();raise AssertionError('commit failure not reported')
            except OSError:pass
        finally:journal_module.append=original_append;record.close()
        assert recover(image,journal)['state']=='rolled-back' and digest(image)==initial
        checks.append('failed-commit-marker-does-not-commit')
        complete=True
    finally:
        report={'success':complete,'checks':checks,'fixture':str(folder),'productionIntegrated':False}
        (folder/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report),flush=True)
        finish_workdir(folder,complete)

if __name__=='__main__':main()
