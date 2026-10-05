/* Disposable-image security fixture tool. Never linked into the application. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/security.h>
int main(int argc,char **argv) {
    struct stat st;
    if(argc!=4 || (strcmp(argv[1],"get") && strcmp(argv[1],"set") && strcmp(argv[1],"set-legacy") && strcmp(argv[1],"corrupt-id") && strcmp(argv[1],"create-legacy")) ||
       lstat(argv[2],&st) || !S_ISREG(st.st_mode) || st.st_size!=64LL*1024*1024) return 2;
    int write=strcmp(argv[1],"get")!=0, result=1;
    ntfs_volume *v=ntfs_mount(argv[2],write?NTFS_MNT_EXCLUSIVE:NTFS_MNT_RDONLY|NTFS_MNT_FORENSIC);
    if(!v) {perror("mount");return 3;}
    if(!strcmp(argv[1],"create-legacy")) {
        /* Root-level file with an inline descriptor (securid 0), as older
         * writers produced. The Volisle bridge now inherits a $Secure id. */
        ntfschar *u=NULL; int n=ntfs_mbstoucs(argv[3],&u);
        ntfs_inode *root=ntfs_inode_open(v,FILE_root);
        ntfs_inode *f=(root && n>0)?ntfs_create(root,const_cpu_to_le32(0),u,(u8)n,S_IFREG):NULL;
        if(f && !ntfs_inode_close(f)) result=0;
        if(root && ntfs_inode_close(root)) result=1;
        free(u);
        if(ntfs_umount(v,0)) result=1;
        return result;
    }
    ntfs_inode *ni=ntfs_pathname_to_inode(v,NULL,argv[3]);
    struct SECURITY_CONTEXT ctx={0};ctx.vol=v;
    char buf[65537];
    if(ni) {
        if(!strcmp(argv[1],"corrupt-id")) {
            if(test_nino_flag(ni,v3_Extensions)) {
                ni->security_id=cpu_to_le32(0x7fffffff);
                NInoSetDirty(ni);result=0;
            }
        } else if(!strcmp(argv[1],"set-legacy")) {
            size_t size=fread(buf,1,sizeof(buf),stdin);
            ntfs_attr *a=ntfs_attr_open(ni,AT_SECURITY_DESCRIPTOR,AT_UNNAMED,0);
            if(a && !test_nino_flag(ni,v3_Extensions) && size>0 && size<=65536 &&
               !ntfs_attr_truncate(a,size) && ntfs_attr_pwrite(a,0,size,buf)==(s64)size) result=0;
            if(a)ntfs_attr_close(a);
        } else if(write) {
            size_t size=fread(buf,1,sizeof(buf),stdin);
            if(size>0 && size<=65536 && !ntfs_set_ntfs_acl(&ctx,ni,buf,size,0)) result=0;
        } else {
            int size=ntfs_get_ntfs_acl(&ctx,ni,buf,65536);
            if(size>0 && size<=65536 && fwrite(buf,1,size,stdout)==(size_t)size) result=0;
        }
        if(ntfs_inode_close(ni)) result=1;
    }
    if(ntfs_umount(v,0)) result=1;
    return result;
}
