"""Callback adapters for tests using disposable regular NTFS images only."""
import ctypes as C
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = C.CDLL(str(ROOT / '.workbench/libVolisleNTFS.dylib'), use_errno=True)
PREAD = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_void_p, C.c_longlong, C.c_longlong)
PWRITE = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_void_p, C.c_longlong, C.c_longlong)
SYNC = C.CFUNCTYPE(C.c_int, C.c_void_p)
class IO(C.Structure):
    _fields_ = [('ctx',C.c_void_p),('pread',PREAD),('pwrite',PWRITE),('size',C.c_longlong),('readonly',C.c_int),('sync',SYNC)]
LIB.nk_inspect.argtypes=[C.POINTER(IO)]; LIB.nk_inspect.restype=C.c_int
LIB.nk_mount_io.argtypes=[C.POINTER(IO),C.c_void_p,C.c_size_t];LIB.nk_mount_io.restype=C.c_void_p
for name in ['nk_umount','nk_sync']:
    getattr(LIB,name).argtypes=[C.c_void_p];getattr(LIB,name).restype=C.c_int
for name in ['nk_create','nk_mkdir']:
    getattr(LIB,name).argtypes=[C.c_void_p,C.c_char_p,C.c_char_p];getattr(LIB,name).restype=C.c_int
LIB.nk_delete.argtypes=[C.c_void_p,C.c_char_p];LIB.nk_delete.restype=C.c_int
LIB.nk_rename.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p,C.c_char_p];LIB.nk_rename.restype=C.c_int
LIB.nk_truncate.argtypes=[C.c_void_p,C.c_char_p,C.c_longlong];LIB.nk_truncate.restype=C.c_int
for name in ['nk_read','nk_write']:
    getattr(LIB,name).argtypes=[C.c_void_p,C.c_char_p,C.c_longlong,C.c_longlong,C.c_void_p]
    getattr(LIB,name).restype=C.c_longlong

class ImageIO:
    def __init__(self, path, readonly=False):
        assert path.is_file() and not path.is_symlink()
        self.fd=os.open(path, os.O_RDONLY if readonly else os.O_RDWR)
        self.writes=0;self.syncs=0;self.fail_read=False;self.fail_write=False;self.fail_sync=False;self.short_read=False;self.short_write=False;self.fail_sync_at=None
        self.fail_write_at=None
        self.crash_after_write_at=None
        @PREAD
        def read(_,buf,count,offset):
            try:
                if self.fail_read:return -1
                data=os.pread(self.fd,max(0,count-1) if self.short_read else count,offset);C.memmove(buf,data,len(data));return len(data)
            except OSError:return -1
        @PWRITE
        def write(_,buf,count,offset):
            self.writes+=1
            try:
                if self.fail_write or self.writes == self.fail_write_at:return -1
                written=os.pwrite(self.fd,C.string_at(buf,max(0,count-1) if self.short_write else count),offset)
                if self.writes == self.crash_after_write_at:
                    os.fsync(self.fd)
                    os._exit(86)  # test child only; deliberately skip bridge cleanup
                return written
            except OSError:return -1
        @SYNC
        def sync(_):
            self.syncs+=1
            try:
                if self.fail_sync or self.syncs == self.fail_sync_at:return -1
                os.fsync(self.fd);return 0
            except OSError:return -1
        self.callbacks=(read,write,sync)
        self.io=IO(None,read,write,os.fstat(self.fd).st_size,int(readonly),sync)
    def close(self):os.close(self.fd)
    def inspect(self):return LIB.nk_inspect(C.byref(self.io))
    def mount(self):return LIB.nk_mount_io(C.byref(self.io),None,0)


NAME_CB=C.CFUNCTYPE(C.c_int,C.c_void_p,C.c_char_p)
LIB.nk_xattr_list.argtypes=[C.c_void_p,C.c_char_p,NAME_CB,C.c_void_p];LIB.nk_xattr_list.restype=C.c_int
LIB.nk_xattr_get.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p,C.c_void_p,C.c_longlong];LIB.nk_xattr_get.restype=C.c_longlong
LIB.nk_xattr_set.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p,C.c_void_p,C.c_longlong,C.c_int];LIB.nk_xattr_set.restype=C.c_int
LIB.nk_xattr_remove.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p];LIB.nk_xattr_remove.restype=C.c_int
