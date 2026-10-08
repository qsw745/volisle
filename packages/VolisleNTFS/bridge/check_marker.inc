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
    const char *failed_why; /* what was wrong with it, for the log and the user */
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

/* `expect_dir`: 1 or 0 as the directory entry says, -1 for a reparse point
 * (a directory junction or symbolic link is listed as a link but its record
 * may be a directory: either is consistent). Sets *is_dir from the record and,
 * on a problem, w->failed_why. */
static int check_record(struct check_walk *w, u64 mft, int expect_dir, int *is_dir) {
    ntfs_inode *ni = ntfs_inode_open(w->vol, mft);
    if (!ni) { w->failed_why = "record unreadable"; return -1; }
    const char *why = NULL;
    /* A folder naming a record that is free could see it reused for another file. */
    if (!(ni->mrec->flags & MFT_RECORD_IN_USE)) why = "listed but not in use";
    int dir = !!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY);
    if (is_dir) *is_dir = dir;
    if (!why && expect_dir >= 0 && dir != expect_dir) why = dir ? "listed as a file, record is a folder" : "listed as a folder, record is a file";
    if (!why && !dir) {
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) {
            if (check_runlist(w->vol, na)) why = "data outside the volume";
            ntfs_attr_close(na);
        } else if (errno != ENOENT) {
            why = "data unreadable";
        }
    }
    if (ntfs_inode_close(ni) && !why) why = "record could not be closed";
    if (why) w->failed_why = why;
    return why ? -1 : 0;
}

static int check_filldir(void *ctx, const ntfschar *name, const int name_len,
                         const int name_type, const s64 pos, const MFT_REF mref,
                         const unsigned dt_type) {
    (void)name; (void)name_len; (void)pos;
    struct check_walk *w = ctx;
    if (w->failed || name_type == FILE_NAME_DOS) return 0;
    u64 mft = MREF(mref);
    if (mft < (u64)FILE_first_user) return 0;
    if (mft >= w->records) { w->failed = 1; w->failed_at = mft; w->failed_why = "entry beyond the file table"; return -1; }
    /* Hard links reach one record by several names: check it once. */
    if (w->seen[mft / 8] & (1u << (mft % 8))) return 0;
    w->seen[mft / 8] |= (unsigned char)(1u << (mft % 8));
    int is_dir = 0;
    int expect = dt_type == NTFS_DT_DIR ? 1 : (dt_type == NTFS_DT_LNK || dt_type == NTFS_DT_REPARSE) ? -1 : 0;
    /* Reparse points are checked but not entered: a junction's target is elsewhere. */
    if (check_record(w, mft, expect, &is_dir) || (is_dir && expect == 1 && check_push(w, mft))) {
        w->failed = 1; w->failed_at = mft; return -1;
    }
    w->items++;
    return 0;
}

static int bit_set(const unsigned char *map, u64 bit) { return (map[bit / 8] >> (bit % 8)) & 1; }

/* Every record in use must be allocated in the file table's bitmap, and every
 * cluster any of its attributes maps must be allocated in $Bitmap: otherwise
 * a new file could take that record or overwrite those clusters. Allocated but
 * unused is only a leak and is left alone. Returns 0, or -1 with the record. */
static int check_allocation(ntfs_volume *vol, u64 records, u64 *failed_at, const char **why, s64 *leaked) {
    s64 lcn_bytes = vol->lcnbmp_na->initialized_size, mft_bytes = vol->mftbmp_na->initialized_size;
    unsigned char *lcn = lcn_bytes > 0 ? malloc((size_t)lcn_bytes) : NULL;
    /* Clusters some record maps: what is marked used beyond them is only held
     * (a leak, e.g. space Windows reserved for a file it never wrote). */
    unsigned char *mapped = lcn_bytes > 0 ? calloc(1, (size_t)lcn_bytes) : NULL;
    if (leaked) *leaked = 0;
    unsigned char *mftmap = mft_bytes > 0 ? malloc((size_t)mft_bytes) : NULL;
    MFT_RECORD *m = malloc(vol->mft_record_size);
    int r = -1;
    *failed_at = 0; *why = "allocation unreadable";
    if (!lcn || !mapped || !mftmap || !m || ntfs_attr_pread(vol->lcnbmp_na, 0, lcn_bytes, lcn) != lcn_bytes ||
        ntfs_attr_pread(vol->mftbmp_na, 0, mft_bytes, mftmap) != mft_bytes ||
        (u64)lcn_bytes * 8 < (u64)vol->nr_clusters) goto out;
    for (u64 i = 0; i < records; i++) {
        *failed_at = i;
        if (ntfs_mft_records_read(vol, MK_MREF(i, 0), 1, m)) {
            /* A free record may be blank or torn; only one in use matters. */
            if (i / 8 < (u64)mft_bytes && bit_set(mftmap, i)) { *why = "record unreadable"; goto out; }
            continue;
        }
        if (m->magic != magic_FILE || !(m->flags & MFT_RECORD_IN_USE)) continue;
        if (i / 8 >= (u64)mft_bytes || !bit_set(mftmap, i)) { *why = "in use but not allocated"; goto out; }
        u32 used = le32_to_cpu(m->bytes_in_use), at = le16_to_cpu(m->attrs_offset);
        if (used > vol->mft_record_size || at >= used) { *why = "record layout broken"; goto out; }
        while (at + 8 <= used) {
            ATTR_RECORD *a = (ATTR_RECORD *)((char *)m + at);
            if (a->type == AT_END) break;
            u32 length = le32_to_cpu(a->length);
            if (length < 16 || at + length > used) { *why = "record layout broken"; goto out; }
            if (a->non_resident) {
                runlist_element *rl = ntfs_mapping_pairs_decompress(vol, a, NULL);
                if (!rl) { *why = "runlist unreadable"; goto out; }
                for (runlist_element *run = rl; run->length; run++) {
                    if (run->lcn < 0) continue;  /* holes and the unmapped tail */
                    if (run->length < 0 || run->lcn > vol->nr_clusters || run->length > vol->nr_clusters - run->lcn) {
                        free(rl); *why = "data outside the volume"; goto out;
                    }
                    for (s64 c = run->lcn, end = run->lcn + run->length; c < end; ) {
                        if (!(c % 8) && end - c >= 8 && lcn[c / 8] == 0xff) { mapped[c / 8] = 0xff; c += 8; continue; }
                        if (!bit_set(lcn, (u64)c)) { free(rl); *why = "clusters marked free"; goto out; }
                        mapped[c / 8] |= (unsigned char)(1u << (c % 8));
                        c++;
                    }
                }
                free(rl);
            }
            at += length;
        }
    }
    if (leaked) {
        s64 held = 0;
        for (s64 c = 0; c < vol->nr_clusters; c++) {
            if (!(c % 8) && vol->nr_clusters - c >= 8 && lcn[c / 8] == mapped[c / 8]) { c += 7; continue; }
            if (bit_set(lcn, (u64)c) && !bit_set(mapped, (u64)c)) held++;
        }
        *leaked = held;
    }
    r = 0;
out:
    free(lcn); free(mapped); free(mftmap); free(m);
    return r;
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

/* What check_volume_readonly requires. */
enum {
    CHECK_NEED_DIRTY = 1,        /* exactly "needs check" ("Check on This Mac") */
    CHECK_ALLOW_UNCLEAN_LOG = 2, /* before the Windows log is discarded */
    CHECK_ALLOCATION = 4,        /* records and clusters in use are allocated */
};

static int check_volume_readonly_held(const nk_io *io, int options, long long *items, long long *held_bytes,
                                      char *errbuf, size_t errlen);

/* Read-only: every record reachable from the root must open and map, and with
 * CHECK_ALLOCATION nothing in use may be marked free. Returns 0, or -1 with a
 * reason. */
static int check_volume_readonly(const nk_io *io, int options, long long *items, char *errbuf, size_t errlen) {
    return check_volume_readonly_held(io, options, items, NULL, errbuf, errlen);
}

/* As above; `held_bytes` receives the space marked used that no record maps. */
static int check_volume_readonly_held(const nk_io *io, int options, long long *items, long long *held_bytes,
                                      char *errbuf, size_t errlen) {
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be read"); errno = EIO; return -1; }
    ntfs_volume *vol = v->vol;
    int r = -1;
    /* Windows maintenance still pending (chkdsk cut off, a log resize, an
     * upgrade or USN deletion): only Windows may finish it, so leave the disk. */
    const le16 pending = VOLUME_RESIZE_LOG_FILE | VOLUME_UPGRADE_ON_MOUNT | VOLUME_DELETE_USN_UNDERWAY |
                         VOLUME_REPAIR_OBJECT_ID | VOLUME_CHKDSK_UNDERWAY;
    if ((options & CHECK_NEED_DIRTY) && !(vol->flags & VOLUME_IS_DIRTY)) {
        snprintf(errbuf, errlen, "not marked for check"); errno = EALREADY;
    } else if (vol->flags & pending) {
        snprintf(errbuf, errlen, "Windows maintenance pending"); errno = EBUSY;
    } else if (ntfs_volume_check_hiberfile(vol, 0) < 0) {
        snprintf(errbuf, errlen, "hibernated"); errno = EBUSY;
    } else if (!(options & CHECK_ALLOW_UNCLEAN_LOG) && !check_log_clean(vol)) {
        snprintf(errbuf, errlen, "log not clean"); errno = EBUSY;
    } else {
        struct check_walk w = { .vol = vol };
        w.records = (u64)(vol->mft_na->initialized_size >> vol->mft_record_size_bits);
        w.seen = calloc((size_t)(w.records / 8 + 1), 1);
        if (!w.seen || check_record(&w, FILE_root, 1, NULL) || check_push(&w, FILE_root)) {
            w.failed = 1; w.failed_at = FILE_root;
        }
        while (!w.failed && w.pending_count) {
            u64 mft = w.pending[--w.pending_count];
            ntfs_inode *dir = ntfs_inode_open(vol, mft);
            s64 pos = 0;
            if (!dir || ntfs_readdir(dir, &pos, &w, check_filldir)) {
                if (!w.failed) { w.failed = 1; w.failed_at = mft; w.failed_why = "folder unreadable"; }
            }
            if (dir && ntfs_inode_close(dir) && !w.failed) { w.failed = 1; w.failed_at = mft; w.failed_why = "folder could not be closed"; }
        }
        s64 leaked = 0;
        if (!w.failed && (options & CHECK_ALLOCATION) &&
            check_allocation(vol, w.records, &w.failed_at, &w.failed_why, &leaked)) w.failed = 1;
        if (held_bytes) *held_bytes = (long long)leaked * vol->cluster_size;
        if (w.failed && v->devctx->failed) {
            /* The disk did not answer a read (a bad sector, a loose cable):
             * nothing is known about the records, so say that instead. */
            snprintf(errbuf, errlen, "read failed at record %llu", (unsigned long long)w.failed_at);
            errno = EIO;
        } else if (w.failed) {
            snprintf(errbuf, errlen, "inconsistent record %llu: %s", (unsigned long long)w.failed_at,
                     w.failed_why ? w.failed_why : "unknown");
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
    if (check_volume_readonly(io, CHECK_NEED_DIRTY | CHECK_ALLOCATION, items, errbuf, errlen)) return -1;
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
