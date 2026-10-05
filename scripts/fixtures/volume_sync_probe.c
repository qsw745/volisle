/* Test-only access to held system inodes; never linked into the application. */
#include "../../packages/VolisleNTFS/bridge/ntfs_bridge.c"

static ntfs_inode *probe_inode(nk_volume *v, int kind) {
    if (!v) return NULL;
    switch (kind) {
    case 0: return v->vol->vol_ni;
    case 1: return v->vol->lcnbmp_ni;
    case 2: return v->vol->mft_ni;
    case 3: return v->vol->mftmirr_ni;
    case 4:
        if (!v->vol->secure_ni && ntfs_open_secure(v->vol)) return NULL;
        return v->vol->secure_ni;
    default: return NULL;
    }
}
int probe_stage(nk_volume *v, int kind, long long seconds) {
    ntfs_inode *ni = probe_inode(v, kind);
    if (!ni || NVolReadOnly(v->vol)) return -1;
    ni->last_data_change_time = cpu_to_le64(seconds * 10000000LL + NTFS_TIME_OFFSET);
    NInoSetDirty(ni);
    return 0;
}
int probe_dirty(nk_volume *v, int kind) {
    ntfs_inode *ni = probe_inode(v, kind);
    return ni ? !!(NInoDirty(ni) || NInoAttrListDirty(ni)) : -1;
}
long long probe_time(nk_volume *v, int kind) {
    ntfs_inode *ni = probe_inode(v, kind);
    if (!ni) return -1;
    /* Bootstrap MFT handles do not hydrate the inode's cached timestamps.
     * Read the actual STANDARD_INFORMATION attribute on the fresh handle. */
    s64 length;
    STANDARD_INFORMATION *si = (STANDARD_INFORMATION *)ntfs_attr_readall(
        ni, AT_STANDARD_INFORMATION, AT_UNNAMED, 0, &length);
    if (!si || length < 32) { free(si); return -1; }
    long long result = (le64_to_cpu(si->last_data_change_time) - NTFS_TIME_OFFSET) / 10000000LL;
    free(si);
    return result;
}
int probe_pending_security_index(nk_volume *v, int which, int dirty) {
    if (!v->vol->secure_ni && ntfs_open_secure(v->vol)) return -1;
    ntfs_index_context *ctx = which ? v->vol->secure_xsdh : v->vol->secure_xsii;
    if (!ctx) return -1;
    ctx->ib_dirty = dirty;
    return 0;
}
int probe_close_security(nk_volume *v) {
    if (!v->vol->secure_ni && ntfs_open_secure(v->vol)) return -1;
    return ntfs_close_secure(v->vol);
}
