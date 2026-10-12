/* SPDX-License-Identifier: GPL-2.0-only
 *
 * One kind of damage only: $Volume (file record 3) and its copy in $MFTMirr
 * differ in nothing but the "needs check" (dirty) flag and the record's update
 * sequence number. Setting or releasing that flag writes the record to both
 * places; a USB drive unplugged with one of the two writes still in its own
 * cache leaves exactly this (seen on a real disk, 2026-10-11). NTFS-3G then
 * refuses to open the volume at all ("$MFTMirr does not match $MFT (record
 * 3)"), so neither "Check on This Mac" nor anything else here can look at it.
 *
 * The answer is the cautious one of the two: the copy WITH the flag is written
 * over the other, raw, exactly as it lies on the disk. The volume is then
 * consistently marked "needs check", nothing mounts it for writing, and "Check
 * on This Mac" (or Windows' chkdsk) decides the rest: the same unplug may have
 * lost other recent writes. Nothing else is repaired here; any other
 * difference between the first four records and their copies is left alone.
 *
 * The examination reads the boot sector and those eight records directly: it
 * cannot use an opened volume, and it is small enough for the file system
 * extension to carry, which reports the condition instead of "unknown".
 */

/* File records are protected in 512-byte sectors, whatever the device's. */
#define NK_COPIES_VOLUME 3

struct copies_layout {
    s64 mft, mirror;   /* byte offsets of record 0 in $MFT and in $MFTMirr */
    u32 record;        /* bytes per file record */
    int count;         /* records NTFS-3G compares before it opens a volume */
};

static int copies_refuse(nk_volume_copies *out, const char *why) {
    snprintf(out->reason, sizeof(out->reason), "%s", why);
    return 0;
}

/* 0, or -1 when the device does not hold an NTFS volume this can read. */
static int copies_layout_read(const nk_io *io, struct copies_layout *l) {
    NTFS_BOOT_SECTOR bs;
    if (io->pread(io->ctx, &bs, sizeof(bs), 0) != (long long)sizeof(bs) || !ntfs_boot_sector_is_ntfs(&bs)) return -1;
    u32 sector = le16_to_cpu(bs.bpb.bytes_per_sector);
    u8 per = bs.bpb.sectors_per_cluster;
    /* Above 128 the field is a negative power of two (clusters over 64 KiB). */
    if (per > 128 && 256 - per > 12) return -1;
    u64 cluster = (u64)sector * (per > 128 ? 1u << (256 - per) : per);
    s8 size = bs.clusters_per_mft_record;
    if (size < 0 ? -size > 12 : size > 8) return -1;
    u64 record = size < 0 ? 1u << -size : (u64)size * cluster;
    s64 mft = sle64_to_cpu(bs.mft_lcn), mirror = sle64_to_cpu(bs.mftmirr_lcn);
    if (sector < 512 || sector > 4096 || (sector & (sector - 1)) || !cluster || (cluster & (cluster - 1)) ||
        cluster > 2 * 1024 * 1024 || record < 1024 || record > 4096 || (record & (record - 1)) ||
        mft <= 0 || mirror <= 0 || mft == mirror) return -1;
    /* volume.c: $MFTMirr holds four records, or a cluster's worth when that
     * is more, and the first sixteen at most are compared. */
    u64 count = cluster > 4 * record ? cluster / record : 4;
    if (count > 16) count = 16;
    s64 span = (s64)(record * count);
    /* Divide, never multiply: an on-disk cluster number must not wrap. */
    if (mft > (io->size - span) / (s64)cluster || mirror > (io->size - span) / (s64)cluster) return -1;
    l->mft = mft * (s64)cluster; l->mirror = mirror * (s64)cluster; l->record = (u32)record; l->count = (int)count;
    /* The two runs of four records must not share a byte. */
    s64 gap = l->mft > l->mirror ? l->mft - l->mirror : l->mirror - l->mft;
    return gap < span ? -1 : 0;
}

/* The record as the file system sees it: its sector ends restored. -1 when it
 * is not a complete, in-use file record (a torn or foreign one is not ours). */
static int copies_record_view(const unsigned char *raw, u32 size, unsigned char *view) {
    memcpy(view, raw, size);
    MFT_RECORD *m = (MFT_RECORD *)view;
    if (m->magic != magic_FILE || ntfs_mst_post_read_fixup_warn((NTFS_RECORD *)view, size, FALSE)) return -1;
    u32 used = le32_to_cpu(m->bytes_in_use), usa = le16_to_cpu(m->usa_ofs), attrs = le16_to_cpu(m->attrs_offset);
    /* Attributes start on an 8-byte boundary after the sequence array (as
     * NTFS-3G's own record check requires), so nothing read as an attribute
     * can lie in the header or in that array. */
    if (!(m->flags & MFT_RECORD_IN_USE) || used < sizeof(MFT_RECORD) || used > size || usa < 42 ||
        (attrs & 7) || attrs < usa + 2 * (u32)le16_to_cpu(m->usa_count) || attrs >= used) return -1;
    return 0;
}

/* Byte offset, in the record, of $VOLUME_INFORMATION's flags; 0 when it has none there. */
static u32 copies_flags_offset(const unsigned char *view) {
    const MFT_RECORD *m = (const MFT_RECORD *)view;
    u32 used = le32_to_cpu(m->bytes_in_use), at = le16_to_cpu(m->attrs_offset);
    while (at + 24 <= used) {
        const ATTR_RECORD *a = (const ATTR_RECORD *)(view + at);
        if (a->type == AT_END) break;
        u32 length = le32_to_cpu(a->length);
        /* Subtract, never add: a huge on-disk length would wrap at + length. */
        if (length < 24 || (length & 7) || length > used - at) return 0;
        if (a->type == AT_VOLUME_INFORMATION) {
            u32 offset = le16_to_cpu(a->value_offset), value = le32_to_cpu(a->value_length);
            /* The value follows the 24-byte resident header, inside the attribute. */
            if (a->non_resident || value < sizeof(VOLUME_INFORMATION) || offset < 24 || offset > length || value > length - offset) return 0;
            return at + offset + (u32)offsetof(VOLUME_INFORMATION, flags);
        }
        at += length;
    }
    return 0;
}

/* The number a record's next write carries (mst.c: 0 and 0xffff are skipped),
 * and the one its previous write carried. */
static u16 copies_next_usn(u16 usn) {
    u16 next = (u16)(usn + 1);
    return next == 0xffff || !next ? 1 : next;
}
static u16 copies_previous_usn(u16 usn) { return usn <= 1 ? 0xfffe : (u16)(usn - 1); }

/* `marked` (raw, complete, the mark set) as the write before or after it left
 * it without the mark: the flag, the sequence number and every sector end. */
static void copies_unmarked(const unsigned char *marked, u32 size, u32 flags, u16 usn, unsigned char *out) {
    memcpy(out, marked, size);
    le16 word, number = cpu_to_le16(usn);
    memcpy(&word, out + flags, 2);
    word ^= VOLUME_IS_DIRTY;
    memcpy(out + flags, &word, 2);
    memcpy(out + le16_to_cpu(((const MFT_RECORD *)marked)->usa_ofs), &number, 2);
    for (u32 end = NTFS_BLOCK_SIZE; end <= size; end += NTFS_BLOCK_SIZE) memcpy(out + end - 2, &number, 2);
}

/* $Volume's two copies (raw) differ. Repairable when one is complete and
 * marked, and the other is, sector by sector, that same record or the record
 * one write away without the mark: the unfinished marker write itself, or a
 * repair of it that was cut off in turn (so repairing again is always safe). */
static void copies_judge_volume(nk_volume_copies *out, const unsigned char *ra, const unsigned char *rb, u32 size,
                                unsigned char *scratch) {
    unsigned char *view = scratch, *unmarked = scratch + size;
    int marked = -1;
    u32 flags = 0;
    for (int copy = 0; copy < 2; copy++) {
        if (copies_record_view(copy ? rb : ra, size, view)) continue;
        u32 at = copies_flags_offset(view);
        le16 word;
        if (!at) continue;
        memcpy(&word, view + at, 2);
        if (!(word & VOLUME_IS_DIRTY)) continue;
        if (marked >= 0) { copies_refuse(out, "the record differs in more"); return; }  /* both marked, yet different */
        marked = copy; flags = at;
    }
    if (marked < 0) { copies_refuse(out, "a record is incomplete"); return; }
    const unsigned char *m = marked ? rb : ra, *other = marked ? ra : rb;
    /* A flag word on a sector end is stored elsewhere: not handled. */
    if (flags % NTFS_BLOCK_SIZE >= NTFS_BLOCK_SIZE - 2) { copies_refuse(out, "the record differs in more"); return; }
    u16 usn = le16_to_cpu(*(const le16 *)(m + le16_to_cpu(((const MFT_RECORD *)m)->usa_ofs)));
    for (int newer = 0; newer < 2; newer++) {
        copies_unmarked(m, size, flags, newer ? copies_previous_usn(usn) : copies_next_usn(usn), unmarked);
        int fits = 1, whole = 1;
        for (u32 at = 0; at < size && fits; at += NTFS_BLOCK_SIZE) {
            if (!memcmp(other + at, unmarked + at, NTFS_BLOCK_SIZE)) continue;
            whole = 0;
            if (memcmp(other + at, m + at, NTFS_BLOCK_SIZE)) fits = 0;
        }
        if (!fits) continue;
        out->repairable = 1;
        out->marked_copy = marked;
        out->marked_newer = newer;
        out->half_written = !whole;
        return;
    }
    /* Told apart for the log only: nothing is done about either. */
    int complete = !copies_record_view(other, size, view);
    le16 word = 0;
    if (complete && copies_flags_offset(view) == flags) memcpy(&word, view + flags, 2);
    le16 mine;
    memcpy(&mine, m + flags, 2);
    if (!complete) copies_refuse(out, "a record is incomplete");
    else if (copies_flags_offset(view) == flags && ((word ^ mine) & ~VOLUME_IS_DIRTY)) copies_refuse(out, "other flags differ");
    else {
        /* The same record but for the mark and the number: sessions apart. */
        u16 theirs = le16_to_cpu(*(const le16 *)(other + le16_to_cpu(((const MFT_RECORD *)other)->usa_ofs)));
        copies_unmarked(m, size, flags, theirs, unmarked);
        copies_refuse(out, !memcmp(other, unmarked, size) ? "more than one write apart" : "the record differs in more");
    }
}

/* Reads both runs (raw) and fills `out`. With `raw_marked` (4096 bytes), also
 * hands back what a repair writes, how much and where. 0, or -1 with errno EIO
 * (a read failed) or EINVAL (not an NTFS volume this can read). */
static int copies_examine(const nk_io *io, nk_volume_copies *out, unsigned char *raw_marked, u32 *write_size, s64 *write_at) {
    memset(out, 0, sizeof(*out));
    struct copies_layout l;
    if (copies_layout_read(io, &l)) { errno = EINVAL; return -1; }
    u32 size = l.record, span = size * (u32)l.count;
    unsigned char *raw = malloc((size_t)span * 2), *scratch = malloc((size_t)size * 2);
    int r = -1;
    if (!raw || !scratch) { errno = ENOMEM; goto out; }
    if (io->pread(io->ctx, raw, span, l.mft) != (long long)span ||
        io->pread(io->ctx, raw + span, span, l.mirror) != (long long)span) { errno = EIO; goto out; }
    r = 0;
    for (int i = 0; i < l.count; i++) {
        const unsigned char *ra = raw + (size_t)i * size, *rb = raw + span + (size_t)i * size;
        /* Byte for byte the same is the same, whatever the record looks like. */
        if (!memcmp(ra, rb, size)) continue;
        /* As NTFS-3G compares them: what each record uses, sector ends
         * restored. Copies that differ only in their sequence numbers are the
         * same to it, and the volume opens. */
        unsigned char *a = scratch, *b = scratch + size;
        int complete = !copies_record_view(ra, size, a) && !copies_record_view(rb, size, b);
        u32 used = complete ? le32_to_cpu(((MFT_RECORD *)a)->bytes_in_use) : 0;
        if (complete && used == le32_to_cpu(((MFT_RECORD *)b)->bytes_in_use) && !memcmp(a, b, used)) continue;
        out->differ = 1;
        if (i != NK_COPIES_VOLUME) {
            /* One after $Volume makes even a repairable $Volume not the whole story. */
            out->repairable = 0;
            copies_refuse(out, complete ? "another record differs" : "a record is incomplete"); goto out;
        }
        copies_judge_volume(out, ra, rb, size, scratch);
        if (!out->repairable) goto out;
        if (raw_marked) {
            memcpy(raw_marked, out->marked_copy ? rb : ra, size);
            *write_size = size;
            *write_at = (out->marked_copy ? l.mft : l.mirror) + (s64)i * size;
        }
    }
out:
    free(raw); free(scratch);
    return r;
}

int nk_volume_copies_examine(const nk_io *io, nk_volume_copies *out) {
    if (!io || !io->pread || io->size < 1024 * 1024 || !out) { errno = EINVAL; return -1; }
    return copies_examine(io, out, NULL, NULL, NULL);
}

#ifdef NK_WITH_FORMAT
int nk_volume_copies_repair(const nk_io *io, nk_volume_copies *before, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 || !before) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    unsigned char record[4096];
    u32 size = 0;
    s64 at = 0;
    /* Examined again here: the App's answer may be minutes old. */
    if (copies_examine(io, before, record, &size, &at)) {
        int code = errno == EINVAL ? EINVAL : EIO;
        snprintf(errbuf, errlen, code == EIO ? "read failed" : "not an NTFS volume"); errno = code; return -1;
    }
    if (!before->differ) { snprintf(errbuf, errlen, "copies agree"); errno = EALREADY; return -1; }
    if (!before->repairable) { snprintf(errbuf, errlen, "%s", before->reason); errno = ENOTSUP; return -1; }
    /* The only write: one file record, the marked copy as it lies on the disk. */
    if (io->pwrite(io->ctx, record, size, at) != (long long)size || io->sync(io->ctx) != 0) {
        snprintf(errbuf, errlen, "write failed"); errno = EIO; return -1;
    }
    nk_volume_copies after;
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = copies_examine(io, &after, NULL, NULL, NULL) || after.differ ? NULL : mount_unchecked(&ro, NULL, 0);
    int marked = v && (v->vol->flags & VOLUME_IS_DIRTY);
    if ((v && release_volume(v)) || !marked) { snprintf(errbuf, errlen, "did not verify"); errno = EIO; return -1; }
    return 0;
}
#endif
