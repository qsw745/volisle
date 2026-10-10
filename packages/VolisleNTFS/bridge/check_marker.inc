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
 *
 * Every folder entry must carry the sequence number its record has now. One
 * that does not is stale: the record was freed, and perhaps reused, after the
 * entry was written (stale_entry.inc can remove such entries).
 */

/* A stale entry found while examining for repair. */
struct stale_ref {
    u64 folder;      /* MFT number of the folder holding it */
    u64 ref;         /* the entry's MFT reference, sequence number included */
    int in_use;      /* the record now belongs to another file or folder */
    int record_seq;  /* the record's sequence number now */
};

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
    u64 dir;                /* the folder being listed */
    int record_seq;         /* sequence number of the record last opened, -1 none */
    /* When a folder's entry was the problem: the folder and the sequence number
     * the entry carries. Unequal to the record's, the entry is stale: it names
     * a record that was freed (and perhaps reused) after the entry was written. */
    int failed_in_entry;
    u64 failed_folder;
    unsigned failed_entry_seq;
    int failed_record_seq;
    int record_in_use;      /* of the record last opened */
    u16 *seqs;              /* sequence number of every record checked */
    int collect;            /* examining for repair: list stale entries, go on */
    struct stale_ref stale[NK_STALE_MAX];
    int stale_count;
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
    w->record_seq = -1; w->record_in_use = 0;
    ntfs_inode *ni = ntfs_inode_open(w->vol, mft);
    if (!ni) {
        /* The header alone still tells a free (or reused) record from damage. */
        MFT_RECORD *m = malloc(w->vol->mft_record_size);
        if (m && !ntfs_mft_records_read(w->vol, MK_MREF(mft, 0), 1, m) && m->magic == magic_FILE) {
            w->record_seq = le16_to_cpu(m->sequence_number);
            w->record_in_use = !!(m->flags & MFT_RECORD_IN_USE);
        }
        free(m);
        w->failed_why = "record unreadable";
        return -1;
    }
    w->record_seq = le16_to_cpu(ni->mrec->sequence_number);
    w->record_in_use = !!(ni->mrec->flags & MFT_RECORD_IN_USE);
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

/* A problem with an entry of the folder being listed. */
static int check_entry_failed(struct check_walk *w, u64 mft, MFT_REF mref, const char *why, int record_seq) {
    w->failed = 1; w->failed_at = mft; w->failed_why = why;
    w->failed_in_entry = 1; w->failed_folder = w->dir; w->failed_entry_seq = MSEQNO(mref); w->failed_record_seq = record_seq;
    return -1;
}

/* The entry names the record with another sequence number than it has now. */
static int check_stale(struct check_walk *w, u64 mft, MFT_REF mref, int in_use, int record_seq) {
    if (!w->collect)
        return check_entry_failed(w, mft, mref, in_use ? "stale entry, record reused" : "stale entry, record free", record_seq);
    /* Several names of one record in the same folder are one entry to remove. */
    for (int i = 0; i < w->stale_count; i++)
        if (w->stale[i].folder == w->dir && w->stale[i].ref == (u64)mref) return 0;
    if (w->stale_count == NK_STALE_MAX) return check_entry_failed(w, mft, mref, "too many stale entries", record_seq);
    w->stale[w->stale_count++] = (struct stale_ref){ w->dir, (u64)mref, in_use, record_seq };
    return 0;
}

static int check_filldir(void *ctx, const ntfschar *name, const int name_len,
                         const int name_type, const s64 pos, const MFT_REF mref,
                         const unsigned dt_type) {
    (void)name; (void)name_len; (void)pos;
    struct check_walk *w = ctx;
    /* An 8.3 alias goes with its long name, which is checked. */
    if (w->failed || name_type == FILE_NAME_DOS) return 0;
    u64 mft = MREF(mref);
    if (mft < (u64)FILE_first_user) return 0;
    if (mft >= w->records) return check_entry_failed(w, mft, mref, "entry beyond the file table", -1);
    /* Sequence number 0 predates sequence numbers: nothing to compare. */
    unsigned entry_seq = MSEQNO(mref);
    /* Hard links reach one record by several names: check it once, but every
     * name must carry its sequence number. */
    if (w->seen[mft / 8] & (1u << (mft % 8))) {
        if (entry_seq && entry_seq != w->seqs[mft]) return check_stale(w, mft, mref, 1, w->seqs[mft]);
        return 0;
    }
    int is_dir = 0;
    int expect = dt_type == NTFS_DT_DIR ? 1 : (dt_type == NTFS_DT_LNK || dt_type == NTFS_DT_REPARSE) ? -1 : 0;
    /* Reparse points are checked but not entered: a junction's target is elsewhere. */
    int bad = check_record(w, mft, expect, &is_dir);
    /* Whatever else the record shows, it is not the one the entry was written for. */
    if (entry_seq && w->record_seq >= 0 && entry_seq != (unsigned)w->record_seq)
        return check_stale(w, mft, mref, w->record_in_use, w->record_seq);
    if (bad) return check_entry_failed(w, mft, mref, w->failed_why, w->record_seq);
    w->seen[mft / 8] |= (unsigned char)(1u << (mft % 8));
    w->seqs[mft] = (u16)w->record_seq;
    if (is_dir && expect == 1 && check_push(w, mft)) { w->failed = 1; w->failed_at = mft; return -1; }
    w->items++;
    return 0;
}

static int bit_set(const unsigned char *map, u64 bit) { return (map[bit / 8] >> (bit % 8)) & 1; }

/* Every record in use must be allocated in the file table's bitmap, and every
 * cluster any of its attributes maps must be allocated in $Bitmap: otherwise
 * a new file could take that record or overwrite those clusters. Allocated but
 * unused is only a leak and is left alone. Returns 0, or -1 with the record. */
static int check_allocation(ntfs_volume *vol, u64 records, u64 *failed_at, const char **why, s64 *leaked,
                            const struct stale_ref *stale, int stale_count) {
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
            /* Removing a stale entry must not leave a record in use whose
             * folder (its file name's parent) is that entry. */
            if (stale_count && a->type == AT_FILE_NAME && !a->non_resident && length >= 24) {
                u32 offset = le16_to_cpu(a->value_offset), size = le32_to_cpu(a->value_length);
                if (size >= sizeof(le64) && offset <= length && size <= length - offset) {
                    le64 raw;
                    memcpy(&raw, (char *)a + offset, sizeof(raw));  /* FILE_NAME_ATTR.parent_directory */
                    u64 parent = le64_to_cpu(raw);
                    for (int s = 0; s < stale_count; s++)
                        if (parent == stale[s].ref) { *why = "stale folder still holds items"; goto out; }
                }
            }
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
    CHECK_COLLECT_STALE = 8,     /* examining for repair: list stale entries instead of failing */
};

static int check_volume_walk(const nk_io *io, int options, long long *items, long long *held_bytes,
                             struct stale_ref *stale, int *stale_count, char *errbuf, size_t errlen);

static int check_volume_readonly_held(const nk_io *io, int options, long long *items, long long *held_bytes,
                                      char *errbuf, size_t errlen) {
    return check_volume_walk(io, options & ~CHECK_COLLECT_STALE, items, held_bytes, NULL, NULL, errbuf, errlen);
}

/* Read-only: every record reachable from the root must open and map, and with
 * CHECK_ALLOCATION nothing in use may be marked free. Returns 0, or -1 with a
 * reason. */
static int check_volume_readonly(const nk_io *io, int options, long long *items, char *errbuf, size_t errlen) {
    return check_volume_readonly_held(io, options, items, NULL, errbuf, errlen);
}

/* As above; `held_bytes` receives the space marked used that no record maps.
 * With CHECK_COLLECT_STALE, `stale` (NK_STALE_MAX) receives the stale entries
 * and the walk goes on past them; it still fails on anything else, on more
 * than NK_STALE_MAX of them, on a reused record reached only through a stale
 * entry, and on a record in use naming one as its folder. */
static int check_volume_walk(const nk_io *io, int options, long long *items, long long *held_bytes,
                             struct stale_ref *stale, int *stale_count, char *errbuf, size_t errlen) {
    if (stale_count) *stale_count = 0;
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
        struct check_walk w = { .vol = vol, .dir = FILE_root, .record_seq = -1, .collect = !!(options & CHECK_COLLECT_STALE) };
        w.records = (u64)(vol->mft_na->initialized_size >> vol->mft_record_size_bits);
        w.seen = calloc((size_t)(w.records / 8 + 1), 1);
        w.seqs = calloc((size_t)w.records + 1, sizeof(*w.seqs));
        if (!w.seen || !w.seqs || check_record(&w, FILE_root, 1, NULL) || check_push(&w, FILE_root)) {
            w.failed = 1; w.failed_at = FILE_root;
        }
        while (!w.failed && w.pending_count) {
            u64 mft = w.pending[--w.pending_count];
            w.dir = mft;
            ntfs_inode *dir = ntfs_inode_open(vol, mft);
            s64 pos = 0;
            if (!dir || ntfs_readdir(dir, &pos, &w, check_filldir)) {
                if (!w.failed) { w.failed = 1; w.failed_at = mft; w.failed_why = "folder unreadable"; }
            }
            if (dir && ntfs_inode_close(dir) && !w.failed) { w.failed = 1; w.failed_at = mft; w.failed_why = "folder could not be closed"; }
        }
        /* A reused record must also be reached through its own folder: removing
         * the stale entry would otherwise leave it where nothing shows it. */
        for (int i = 0; !w.failed && i < w.stale_count; i++) {
            u64 mft = MREF(w.stale[i].ref);
            if (w.stale[i].in_use && !(w.seen[mft / 8] & (1u << (mft % 8)))) {
                w.dir = w.stale[i].folder;
                check_entry_failed(&w, mft, (MFT_REF)w.stale[i].ref, "stale entry, record unreachable", w.stale[i].record_seq);
            }
        }
        s64 leaked = 0;
        if (!w.failed && (options & CHECK_ALLOCATION) &&
            check_allocation(vol, w.records, &w.failed_at, &w.failed_why, &leaked, w.stale, w.stale_count)) w.failed = 1;
        if (stale && stale_count) { memcpy(stale, w.stale, sizeof(w.stale)); *stale_count = w.stale_count; }
        if (held_bytes) *held_bytes = (long long)leaked * vol->cluster_size;
        if (w.failed && v->devctx->failed) {
            /* The disk did not answer a read (a bad sector, a loose cable):
             * nothing is known about the records, so say that instead. */
            snprintf(errbuf, errlen, "read failed at record %llu", (unsigned long long)w.failed_at);
            errno = EIO;
        } else if (w.failed) {
            snprintf(errbuf, errlen, "inconsistent record %llu: %s", (unsigned long long)w.failed_at,
                     w.failed_why ? w.failed_why : "unknown");
            /* Numbers only, never a name: the folder holding the entry and both
             * sequence numbers, added only when all of it fits. */
            char where[96] = "";
            if (w.failed_in_entry) {
                int n = snprintf(where, sizeof(where), "; folder %llu, entry seq %u",
                                 (unsigned long long)w.failed_folder, w.failed_entry_seq);
                if (n > 0 && (size_t)n < sizeof(where) && w.failed_record_seq >= 0)
                    snprintf(where + n, sizeof(where) - (size_t)n, ", record seq %d", w.failed_record_seq);
            }
            if (strlen(errbuf) + strlen(where) < errlen) strcat(errbuf, where);
            errno = EIO;
        } else {
            *items = w.items;
            r = 0;
        }
        free(w.pending);
        free(w.seen);
        free(w.seqs);
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
