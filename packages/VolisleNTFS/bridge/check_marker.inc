/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Mac-side answer for a disk that is only marked "needs check" (the NTFS
 * dirty flag), for people without a Windows PC. Included by ntfs_bridge.c in
 * the root helper's build only (NK_WITH_FORMAT).
 *
 * It is NOT chkdsk. It refuses hibernated volumes and unclean $LogFiles (both
 * may hold Windows data not yet written), walks every directory and file
 * record read-only, maps every data runlist, and only when nothing fails
 * clears that one flag. Any finding leaves the disk untouched.
 */

struct check_walk {
    ntfs_volume *vol;
    u64 *pending;           /* directories still to list (MFT numbers) */
    size_t pending_count, pending_capacity;
    unsigned char *seen;    /* one bit per MFT record */
    u64 records;
    long long items;
    u64 failed_at;          /* MFT number of the first problem */
    int failed;
};

static int check_push(struct check_walk *w, u64 mft) {
    if (w->pending_count == w->pending_capacity) {
        size_t capacity = w->pending_capacity ? w->pending_capacity * 2 : 256;
        u64 *grown = realloc(w->pending, capacity * sizeof(*grown));
        if (!grown) return -1;
        w->pending = grown; w->pending_capacity = capacity;
    }
    w->pending[w->pending_count++] = mft;
    return 0;
}

/* A data runlist must map inside the volume. */
static int check_runlist(ntfs_volume *vol, ntfs_attr *na) {
    if (!NAttrNonResident(na)) return 0;
    if (ntfs_attr_map_whole_runlist(na)) return -1;
    for (runlist_element *rl = na->rl; rl && rl->length; rl++) {
        if (rl->lcn < 0) {
            if (rl->lcn != LCN_HOLE) return -1;
            continue;
        }
        if (rl->length < 0 || rl->lcn > vol->nr_clusters || rl->length > vol->nr_clusters - rl->lcn) return -1;
    }
    return 0;
}

static int check_record(struct check_walk *w, u64 mft, int is_dir) {
    ntfs_inode *ni = ntfs_inode_open(w->vol, mft);
    if (!ni) return -1;
    int bad = 0;
    if (!!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != !!is_dir) bad = 1;
    if (!bad && !is_dir) {
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) {
            if (check_runlist(w->vol, na)) bad = 1;
            ntfs_attr_close(na);
        } else if (errno != ENOENT) {
            bad = 1;
        }
    }
    if (ntfs_inode_close(ni)) bad = 1;
    return bad ? -1 : 0;
}

static int check_filldir(void *ctx, const ntfschar *name, const int name_len,
                         const int name_type, const s64 pos, const MFT_REF mref,
                         const unsigned dt_type) {
    (void)name; (void)name_len; (void)pos;
    struct check_walk *w = ctx;
    if (w->failed || name_type == FILE_NAME_DOS) return 0;
    u64 mft = MREF(mref);
    if (mft < (u64)FILE_first_user) return 0;
    if (mft >= w->records) { w->failed = 1; w->failed_at = mft; return -1; }
    /* Hard links reach one record by several names: check it once. */
    if (w->seen[mft / 8] & (1u << (mft % 8))) return 0;
    w->seen[mft / 8] |= (unsigned char)(1u << (mft % 8));
    int is_dir = dt_type == NTFS_DT_DIR;
    if (check_record(w, mft, is_dir) || (is_dir && check_push(w, mft))) {
        w->failed = 1; w->failed_at = mft; return -1;
    }
    w->items++;
    return 0;
}

static int check_log_clean(ntfs_volume *vol) {
    ntfs_inode *ni = ntfs_inode_open(vol, FILE_LogFile);
    ntfs_attr *na = ni ? ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0) : NULL;
    RESTART_PAGE_HEADER *rp = NULL;
    int clean = na && ntfs_check_logfile(na, &rp) && ntfs_is_logfile_clean(na, rp) &&
                !(rp && rp->major_ver == const_cpu_to_le16(2) && rp->minor_ver == const_cpu_to_le16(0));
    free(rp);
    if (na) ntfs_attr_close(na);
    if (ni && ntfs_inode_close(ni)) clean = 0;
    return clean;
}

/* Read-only: state must be exactly "dirty only", then every record reachable
 * from the root must open and map. Returns 0, or -1 with a reason. */
static int check_volume_readonly(const nk_io *io, long long *items, char *errbuf, size_t errlen) {
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be read"); errno = EIO; return -1; }
    ntfs_volume *vol = v->vol;
    int r = -1;
    if (!(vol->flags & VOLUME_IS_DIRTY)) {
        snprintf(errbuf, errlen, "not marked for check"); errno = EALREADY;
    } else if (ntfs_volume_check_hiberfile(vol, 0) < 0) {
        snprintf(errbuf, errlen, "hibernated"); errno = EBUSY;
    } else if (!check_log_clean(vol)) {
        snprintf(errbuf, errlen, "log not clean"); errno = EBUSY;
    } else {
        struct check_walk w = { .vol = vol };
        w.records = (u64)(vol->mft_na->initialized_size >> vol->mft_record_size_bits);
        w.seen = calloc((size_t)(w.records / 8 + 1), 1);
        if (!w.seen || check_record(&w, FILE_root, 1) || check_push(&w, FILE_root)) {
            w.failed = 1; w.failed_at = FILE_root;
        }
        while (!w.failed && w.pending_count) {
            u64 mft = w.pending[--w.pending_count];
            ntfs_inode *dir = ntfs_inode_open(vol, mft);
            s64 pos = 0;
            if (!dir || ntfs_readdir(dir, &pos, &w, check_filldir)) {
                if (!w.failed) { w.failed = 1; w.failed_at = mft; }
            }
            if (dir && ntfs_inode_close(dir) && !w.failed) { w.failed = 1; w.failed_at = mft; }
        }
        if (w.failed) {
            snprintf(errbuf, errlen, "inconsistent record %llu", (unsigned long long)w.failed_at);
            errno = EIO;
        } else {
            *items = w.items;
            r = 0;
        }
        free(w.pending);
        free(w.seen);
    }
    int error = errno;
    if (release_volume(v)) { if (!r) snprintf(errbuf, errlen, "read failed"); r = -1; error = EIO; }
    errno = error;
    return r;
}

int nk_clear_check_marker(const nk_io *io, long long *items, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 || !items) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    *items = 0;
    if (check_volume_readonly(io, items, errbuf, errlen)) return -1;
    /* The only write: $Volume's flags, without the dirty bit. */
    nk_volume *v = mount_unchecked(io, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be opened"); errno = EIO; return -1; }
    int r = write_volume_flags(v->vol, (le16)(v->vol->flags & ~VOLUME_IS_DIRTY));
    if (!r) r = nkdev_sync(v->vol->dev);
    if (release_volume(v)) r = -1;
    if (r || io->sync(io->ctx) != 0) { snprintf(errbuf, errlen, "flag write failed"); errno = EIO; return -1; }
    if (nk_inspect(io) != NK_CHECK_CLEAN) { snprintf(errbuf, errlen, "did not verify clean"); errno = EIO; return -1; }
    return 0;
}
