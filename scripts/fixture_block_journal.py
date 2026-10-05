"""Experimental before-image transactions for detached 64 MiB test files.

Not a driver or general-purpose repair tool. One transaction includes a clean
mount, a bounded operation and clean unmount. No earlier acknowledged session
is rolled back. Production operation boundaries, authenticated storage, FSKit,
removable-device identity and cross-host recovery are deliberately not claimed.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat

WORK=Path(__file__).resolve().parents[1]/'.workbench'
SIZE=64*1024*1024
MAX_WRITE=1024*1024
MAX_LOG=128*1024*1024


def sha(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()


def open_file(path,create=False):
    path=Path(path).absolute()
    if (path.parent.parent!=WORK or not re.fullmatch(r'block-journal-[a-z0-9_]+',path.parent.name)
        or path.resolve()!=path): raise ValueError('仅接受本工作区新建的隔离测试文件')
    flags=os.O_RDWR|os.O_NOFOLLOW
    if create: flags|=os.O_CREAT|os.O_EXCL
    fd=os.open(path,flags,0o600)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_uid!=os.getuid():
            raise ValueError('拒绝设备、链接或其他所有者文件')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        return fd
    except BaseException: os.close(fd);raise


def append(fd,payload):
    encoded=canonical({'payload':payload,'sha256':sha(canonical(payload))})+b'\n'
    if os.fstat(fd).st_size+len(encoded)>MAX_LOG: raise ValueError('测试日志达到上限')
    os.lseek(fd,0,os.SEEK_END)
    at=0
    while at<len(encoded):
        n=os.write(fd,encoded[at:])
        if n<=0: raise OSError('日志短写')
        at+=n
    os.fsync(fd)
    return sha(canonical(payload))


def records(fd):
    length=os.fstat(fd).st_size
    if not 0<length<=MAX_LOG: raise ValueError('日志大小无效')
    data=os.pread(fd,length,0)
    if len(data)!=length or not data.endswith(b'\n'): raise ValueError('日志截断')
    output=[];previous='0'*64
    for index,line in enumerate(data.splitlines()):
        if len(line)>3*MAX_WRITE: raise ValueError('日志记录过大')
        frame=json.loads(line);value=frame['payload']
        digest=sha(canonical(value))
        if frame.get('sha256')!=digest or value.get('previous')!=previous or value.get('sequence')!=index:
            raise ValueError('日志校验或顺序不匹配')
        output.append(value);previous=digest
    if output[0].get('kind')!='begin' or output[0].get('schema')!=1: raise ValueError('日志版本无效')
    for index,value in enumerate(output[1:],1):
        if value.get('kind') not in ['write','committed','rolled-back']: raise ValueError('未知日志事件')
        if value['kind']!='write' and index!=len(output)-1: raise ValueError('终止记录之后仍有写入')
    return output,previous


def read_image(fd):
    if os.fstat(fd).st_size!=SIZE: raise ValueError('只接受 64 MiB 普通测试镜像')
    data=os.pread(fd,SIZE,0)
    if len(data)!=SIZE or data[3:11]!=b'NTFS    ': raise ValueError('镜像读取或引导记录无效')
    return data


class BlockJournal:
    def __init__(self,image,journal):
        self.image=open_file(image);self.log=None;self.failed=False;self.ended=False
        try:
            content=read_image(self.image);info=os.fstat(self.image)
            self.log=open_file(journal,create=True)
            self.sequence=0;self.previous='0'*64
            self.emit({'kind':'begin','schema':1,'device':info.st_dev,'inode':info.st_ino,
                       'size':SIZE,'originalSHA256':sha(content),'bootSHA256':sha(content[:512])})
            directory=os.open(Path(journal).parent,os.O_RDONLY)
            try:os.fsync(directory)
            finally:os.close(directory)
        except BaseException:self.close();raise
    def emit(self,value):
        if self.failed or self.ended: raise ValueError('事务已经失败或结束')
        try:self.previous=append(self.log,dict(value,sequence=self.sequence,previous=self.previous))
        except BaseException:self.failed=True;raise
        self.sequence+=1
    def before_write(self,offset,data):
        if type(offset) is not int or not 0<len(data)<=MAX_WRITE or not 0<=offset<=SIZE-len(data):
            self.failed=True;raise ValueError('块写入范围无效')
        before=os.pread(self.image,len(data),offset)
        if len(before)!=len(data): self.failed=True;raise ValueError('原始块读取失败')
        self.emit({'kind':'write','offset':offset,'before':base64.b64encode(before).decode(),
                   'after':base64.b64encode(data).decode()})
    def commit(self):
        os.fsync(self.image)
        self.emit({'kind':'committed','imageSHA256':sha(read_image(self.image))})
        self.ended=True
    def close(self):
        if self.log is not None:os.close(self.log);self.log=None
        if self.image is not None:os.close(self.image);self.image=None


def plan_rollback(current,header,write_events):
    """Validate recorded bytes and reconstruct a transaction without writing."""
    parsed=[]
    for event in write_events:
        offset=event.get('offset')
        before=base64.b64decode(event['before'],validate=True)
        after=base64.b64decode(event['after'],validate=True)
        if type(offset) is not int or not 0<len(before)==len(after)<=MAX_WRITE or not 0<=offset<=SIZE-len(before):
            raise ValueError('日志块范围无效')
        parsed.append((offset,before,after))
    original=bytearray(current)
    for offset,before,_ in reversed(parsed):original[offset:offset+len(before)]=before
    if sha(original)!=header.get('originalSHA256'):raise ValueError('未记录区域发生变化或原始记录无效')
    # Accept only byte values actually recorded for the touched ranges.
    # This also permits retry after an interrupted/short rollback write.
    ranges=[]
    for offset,before,_ in sorted(parsed):
        end=offset+len(before)
        if ranges and offset<=ranges[-1][1]:ranges[-1]=(ranges[-1][0],max(end,ranges[-1][1]))
        else:ranges.append((offset,end))
    for start,end in ranges:
        valid=bytearray(end-start)
        for offset,before,after in parsed:
            left=max(start,offset);right=min(end,offset+len(before))
            for position in range(left,right):
                if current[position] in (before[position-offset],after[position-offset]):valid[position-start]=1
        if not all(valid):raise ValueError('记录区域包含无法解释的新字节')
    return original,ranges


def recover(image,journal,after_write=None):
    """Validate the entire plan before mutating; never guesses absent records.

    after_write is a test-only interruption hook. Original records are retained
    so an interrupted rollback can resume. The whole original image digest is
    checked in a virtual view before any write, and after recovery on disk.
    """
    fd=open_file(image);log=None
    try:
        log=open_file(journal);events,previous=records(log)
        header=events[0];info=os.fstat(fd);current=read_image(fd)
        if (header.get('device'),header.get('inode'),header.get('size'),header.get('bootSHA256'))!=(info.st_dev,info.st_ino,SIZE,sha(current[:512])):
            raise ValueError('镜像身份不匹配')
        final=events[-1]
        if final['kind'] in ['committed','rolled-back']:
            expected=final.get('imageSHA256')
            if sha(current)!=expected:raise ValueError('已结束事务的镜像发生变化')
            return {'state':final['kind'],'writes':0}
        original,ranges=plan_rollback(current,header,events[1:])
        # Recheck after planning, before the first write. The fixture holds an
        # advisory exclusive lock; real device fencing is not implemented here.
        if read_image(fd)!=current:raise ValueError('恢复规划期间镜像发生变化')
        writes=0
        for start,end in ranges:
            at=start
            while at<end:
                n=os.pwrite(fd,original[at:end],at)
                if n<=0:raise OSError('恢复短写')
                at+=n
            os.fsync(fd);writes+=1
            if after_write:after_write(writes)
        if sha(read_image(fd))!=header['originalSHA256']:raise ValueError('恢复后的全镜像摘要不一致')
        append(log,{'kind':'rolled-back','imageSHA256':header['originalSHA256'],
                    'sequence':len(events),'previous':previous})
        return {'state':'rolled-back','writes':writes}
    finally:
        if log is not None:os.close(log)
        os.close(fd)
