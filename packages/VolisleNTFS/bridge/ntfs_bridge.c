/* Volisle modifications, 2026-09-20. Derived from ntfskit commit
 * b7153a8dd51b895d0a87345c6ad8e95bda963ed3, NTFSModule/bridge.
 * Changes: callback-only I/O; mandatory read-only preflight; no recovery,
 * formatting, BitLocker or kernel-offloaded I/O; bounds and durable sync.
 * See ../UPSTREAM.md. */
/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "ntfs_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/reparse.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/security.h>
#include <ntfs-3g/acls.h>
#include <limits.h>

struct nk_devctx {
    nk_io io;
    s64 pos;
    int failed; /* sticky: no more user mutations after any block I/O failure */
};

struct nk_volume {
    ntfs_volume *vol;
    struct nk_devctx *devctx;
    int owns_dirty;
    le16 initial_flags;
    unsigned char boot_identity[512];
};

static int mutation_result(nk_volume *v, int result, int error) {
    /* Running out of space is not damage: NTFS-3G backs out the allocation that
     * failed and leaves the volume consistent (its FUSE driver relies on that),
     * so the session stays usable and the user can delete files to make room.
     * A device error recorded meanwhile still locks the session below. */
    if (result && error == ENOSPC && !v->devctx->failed) { errno = ENOSPC; return -1; }
    if (result || v->devctx->failed) {
        /* An attempted metadata mutation failed: do not later mark this
         * session clean just because a subsequent fsync happened to succeed. */
        v->devctx->failed = 1;
        errno = error ? error : EIO;
        return -1;
    }
    return 0;
}
static int require_writable(nk_volume *v) {
    if (!v) { errno = EINVAL; return -1; }
    if (NVolReadOnly(v->vol)) { errno = EROFS; return -1; }
    if (v->devctx->failed) { errno = EIO; return -1; }
    return 0;
}
#include "mac_mode.inc"

static int writable_inode(ntfs_inode *ni) {
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL)) return 0;
    if (ni->mft_no < 16 || (ni->flags & (FILE_ATTR_COMPRESSED | FILE_ATTR_ENCRYPTED | FILE_ATTR_REPARSE_POINT))) {
        errno = EOPNOTSUPP; return 0;
    }
    return 1;
}
/* READONLY protects unnamed file content even for already-open references.
 * Permission denial is not a failed block mutation and must not poison I/O. */
static int writable_content_inode(ntfs_inode *ni) {
    if (!writable_inode(ni)) return 0;
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL)) return 0;
    if (!(mode & 0200)) { errno = EACCES; return 0; }
    return 1;
}

#include "names.inc"

/* ---- callback-backed ntfs_device ---- */


static int nkdev_open(struct ntfs_device *dev, int flags) {
    if ((flags & O_ACCMODE) == O_RDONLY)
        NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int nkdev_close(struct ntfs_device *dev) {
    NDevClearOpen(dev);
    return 0;
}

static s64 nkdev_seek(struct ntfs_device *dev, s64 offset, int whence) {
    struct nk_devctx *c = dev->d_private;
    s64 base = whence == SEEK_SET ? 0 :
               whence == SEEK_CUR ? c->pos : c->io.size;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) { errno = EINVAL; return -1; }
    if ((offset > 0 && base > LLONG_MAX - offset) || (offset < 0 && offset < -base)) { errno = EINVAL; return -1; }
    c->pos = base + offset;
    return c->pos;
}

static s64 nkdev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (offset < 0 || count < 0 || offset > c->io.size || count > c->io.size - offset) { errno = EINVAL; return -1; }
    s64 n = c->io.pread(c->io.ctx, buf, count, offset);
    if (n != count) { c->failed = 1; errno = EIO; return -1; }
    return n;
}

static s64 nkdev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev) || c->io.readonly) { errno = EROFS; return -1; }
    if (offset < 0 || count < 0 || offset > c->io.size || count > c->io.size - offset) { errno = EINVAL; return -1; }
    if (c->failed) { errno = EIO; return -1; }
    s64 n = c->io.pwrite(c->io.ctx, buf, count, offset);
    if (n != count) { c->failed = 1; errno = EIO; return -1; }
    NDevSetDirty(dev);
    return n;
}

static s64 nkdev_read(struct ntfs_device *dev, void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pread(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static s64 nkdev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pwrite(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static int nkdev_sync(struct ntfs_device *dev) {
    struct nk_devctx *c = dev->d_private;
    if (c->failed) { errno = EIO; return -1; }
    if (!c->io.readonly && c->io.sync(c->io.ctx) != 0) { c->failed = 1; errno = EIO; return -1; }
    NDevClearDirty(dev);
    return 0;
}

static int nkdev_stat(struct ntfs_device *dev, struct stat *buf) {
    struct nk_devctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFREG | 0600;   /* image-file semantics: no ioctls */
    buf->st_size = c->io.size;
    return 0;
}

static int nkdev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    (void)dev; (void)request; (void)argp;
    errno = ENOTSUP;
    return -1;
}

static struct ntfs_device_operations nk_dev_ops = {
    .open   = nkdev_open,
    .close  = nkdev_close,
    .seek   = nkdev_seek,
    .read   = nkdev_read,
    .write  = nkdev_write,
    .pread  = nkdev_pread,
    .pwrite = nkdev_pwrite,
    .sync   = nkdev_sync,
    .stat   = nkdev_stat,
    .ioctl  = nkdev_ioctl,
};

static nk_volume *mount_unchecked(const nk_io *io, char *errbuf, size_t errlen) {
    struct nk_devctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->io = *io;

    struct ntfs_device *dev = ntfs_device_alloc("fskit-block", 0, &nk_dev_ops, c);
    if (!dev) { free(c); return NULL; }

    ntfs_mount_flags flags = io->readonly ? NTFS_MNT_RDONLY : NTFS_MNT_FORENSIC;
    ntfs_volume *vol = ntfs_device_mount(dev, flags);
    if (!vol) {
        if (errbuf && errlen)
            snprintf(errbuf, errlen, "ntfs_device_mount: %s", strerror(errno));
        ntfs_device_free(dev);
        free(c);
        return NULL;
    }
    nk_volume *v = calloc(1, sizeof(*v));
    if (!v) { ntfs_umount(vol, TRUE); free(c); return NULL; }
    v->vol = vol;
    v->devctx = c;
    return v;
}

/* $Volume's flags, written exactly. ntfs_volume_write_flags keeps only the bits
 * NTFS-3G knows (VOLUME_FLAGS_MASK) and drops the rest; Windows 11 sets 0x0080
 * on volumes it formats, so masking both altered the volume and made the
 * session's own marker unrecognizable at release (flags no longer initial|dirty),
 * leaving every such volume marked dirty. Only the dirty bit may ever change. */
static int set_volume_flags(ntfs_volume *vol, le16 flags) {
    if (!vol || !vol->vol_ni) { errno = EINVAL; return -1; }
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(vol->vol_ni, NULL);
    if (!ctx) return -1;
    int r = -1;
    if (!ntfs_attr_lookup(AT_VOLUME_INFORMATION, AT_UNNAMED, 0, 0, 0, NULL, 0, ctx)) {
        ATTR_RECORD *a = ctx->attr;
        VOLUME_INFORMATION *c = (VOLUME_INFORMATION *)(le16_to_cpu(a->value_offset) + (char *)a);
        if (a->non_resident || le32_to_cpu(a->value_length) < sizeof(*c) ||
            (char *)c + le32_to_cpu(a->value_length) > (char *)ctx->mrec + le32_to_cpu(ctx->mrec->bytes_in_use) ||
            le16_to_cpu(a->value_offset) + le32_to_cpu(a->value_length) > le32_to_cpu(a->length)) {
            errno = EIO;
        } else {
            vol->flags = c->flags = flags;
            ntfs_inode_mark_dirty(vol->vol_ni);
            r = ntfs_inode_sync(vol->vol_ni) ? -1 : 0;
        }
    }
    ntfs_attr_put_search_ctx(ctx);
    return r;
}

static int write_volume_flags(ntfs_volume *vol, le16 flags) {
    if (!vol || ((vol->flags ^ flags) & ~VOLUME_IS_DIRTY)) { errno = EINVAL; return -1; }
    return set_volume_flags(vol, flags);
}

/* The marker versions up to 0.5.7 left on such a volume: initial|dirty with the
 * unknown bits dropped. Recognized only when the initial word had unknown bits. */
static int legacy_marker(le16 initial_flags, le16 now) {
    return (initial_flags & ~VOLUME_FLAGS_MASK) &&
           now == ((initial_flags | VOLUME_IS_DIRTY) & VOLUME_FLAGS_MASK);
}

/* Core release can write pending metadata. Only AFTER it succeeds may a
 * fresh forensic handle clear the marker owned by this exact session. */
static int release_volume(nk_volume *v) {
    int r = v->vol ? ntfs_umount(v->vol, FALSE) : 0;
    int failed = v->devctx->failed;
    free(v->devctx);
    free(v);
    if (r || failed) { errno = EIO; return -1; }
    return 0;
}

static int clear_owned_marker(const nk_io *io, le16 initial_flags,
                              const unsigned char identity[512]) {
    nk_volume *check = mount_unchecked(io, NULL, 0);
    if (!check) return -1;
    unsigned char boot[512];
    int r = -1;
    int owned = check->vol->flags == (initial_flags | VOLUME_IS_DIRTY);
    int legacy = !owned && legacy_marker(initial_flags, check->vol->flags);
    if (nkdev_pread(check->vol->dev, boot, sizeof(boot), 0) == sizeof(boot) &&
        !memcmp(boot, identity, sizeof(boot)) && (owned || legacy)) {
        /* A legacy marker is released to the exact initial word, which also
         * restores the bits the old release path had dropped. */
        r = owned ? write_volume_flags(check->vol, initial_flags) : set_volume_flags(check->vol, initial_flags);
        if (!r) r = nkdev_sync(check->vol->dev);
        if (r) {
            /* Best effort marker restoration only. Never report success after
             * an error, even if storage recovers during this final step. */
            check->devctx->failed = 0;
            (void)write_volume_flags(check->vol, initial_flags | VOLUME_IS_DIRTY);
            (void)nkdev_sync(check->vol->dev);
            check->devctx->failed = 1;
        }
    }
    if (release_volume(check)) r = -1;
    return r;
}

int nk_umount(nk_volume *v) {
    if (!v) { errno = EINVAL; return -1; }
    nk_io io = v->devctx->io;
    int owns = v->owns_dirty;
    le16 flags = v->initial_flags;
    unsigned char identity[512];
    memcpy(identity, v->boot_identity, sizeof(identity));
    int r = release_volume(v); /* handle is ALWAYS consumed, including error */
    if (!r && owns) r = clear_owned_marker(&io, flags, identity);
    return r;
}

int nk_statvfs(nk_volume *v, long long *total_bytes, long long *free_bytes,
               int *cluster_size) {
    if (!v) return -1;
    ntfs_volume *vol = v->vol;
    /* Scan $Bitmap once per mount; the engine then maintains free_clusters
     * on every allocation and release. Rescanning a 2 TB bitmap on each
     * statfs stalled every write behind it. */
    if (!NVolFreeSpaceKnown(vol) && ntfs_volume_get_free_space(vol) < 0) return -1;
    if (total_bytes)  *total_bytes  = (long long)vol->nr_clusters * vol->cluster_size;
    if (free_bytes)   *free_bytes   = (long long)vol->free_clusters * vol->cluster_size;
    if (cluster_size) *cluster_size = (int)vol->cluster_size;
    return 0;
}

int nk_label(nk_volume *v, char *buf, size_t buflen) {
    if (!v || !buf || buflen == 0) return -1;
    const char *name = v->vol->vol_name;
    snprintf(buf, buflen, "%s", name ? name : "");
    return 0;
}

/* Interix-style symlink: SYSTEM file whose data starts with "IntxLNK\1"
 * (the format ntfs_create_symlink writes, same as ntfs-3g's FUSE driver). */
static int is_intx_symlink(ntfs_attr *na) {
    if (!na || na->data_size < 10 || na->data_size > 4096 + 8) return 0;
    le64 magic = 0;
    if (ntfs_attr_pread(na, 0, sizeof(magic), &magic) != sizeof(magic)) return 0;
    return magic == INTX_SYMBOLIC_LINK;
}

/* UTF-8 length of an Interix link's target, or -1. Callers checked the magic. */
static long long intx_target_length(ntfs_attr *na) {
    s64 bytes = na->data_size - 8;
    if (bytes <= 0 || bytes % 2) return -1;
    ntfschar *ucs = malloc((size_t)bytes);
    if (!ucs) return -1;
    long long length = -1;
    char *utf8 = NULL;
    if (ntfs_attr_pread(na, 8, bytes, ucs) == bytes && ntfs_ucstombs(ucs, (int)(bytes / 2), &utf8, 0) >= 0 && utf8)
        length = (long long)strlen(utf8);
    free(utf8);
    free(ucs);
    return length;
}

static void decode_timestamp(ntfs_time value, long long *seconds, int *nanoseconds) {
    /* The upstream helper truncates toward zero for pre-1970 fractions.
     * Normalize to POSIX timespec, where the fractional part is nonnegative. */
    __int128 delta = (__int128)sle64_to_cpu(value) - NTFS_TIME_OFFSET;
    __int128 sec = delta / 10000000, fraction = delta % 10000000;
    if (fraction < 0) { --sec; fraction += 10000000; }
    *seconds = (long long)sec;
    *nanoseconds = (int)(fraction * 100);
}

static int fill_stat(ntfs_inode *ni, ntfs_attr *na, nk_stat *st) {
    memset(st, 0, sizeof(*st));
    st->is_dir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    st->inode = (uint64_t)ni->mft_no;
    st->file_flags = le32_to_cpu(ni->flags);
    if (mac_mode_read(ni, &st->mac_mode, NULL)) return -1;
    st->is_symlink = (ni->flags & FILE_ATTR_REPARSE_POINT) ? 1 : 0;
    int intx = !st->is_symlink && (ni->flags & FILE_ATTR_SYSTEM) && is_intx_symlink(na);
    if (intx) st->is_symlink = 1;
    if (na) {
        st->size = (long long)na->data_size;
        /* POSIX: a symlink's size is its target's length in bytes. */
        long long target = intx ? intx_target_length(na) : -1;
        if (target >= 0) st->size = target;
        st->alloc_size = (long long)na->allocated_size;
        st->is_resident = NAttrNonResident(na) ? 0 : 1;
        /* Compressed/encrypted data can't be mapped for the kernel — those go
         * through the byte-copy path. Resident files convert to non-resident
         * in nk_blockmap; sparse holes pack as zero-fill extents. */
        st->koio_ok = !(na->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED)) &&
                      !st->is_symlink;
    }
    decode_timestamp(ni->last_access_time, &st->atime, &st->atime_nsec);
    decode_timestamp(ni->last_data_change_time, &st->mtime, &st->mtime_nsec);
    decode_timestamp(ni->last_mft_change_time, &st->ctime, &st->ctime_nsec);
    decode_timestamp(ni->creation_time, &st->btime, &st->btime_nsec);
    return 0;
}

int nk_stat_path(nk_volume *v, const char *path, nk_stat *st) {
    if (!v || !st) return -1;
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    ntfs_attr *na = NULL;
    if (!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY))
        na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    int rc = fill_stat(ni, na, st);
    if (na) ntfs_attr_close(na);
    if (ntfs_inode_close(ni)) rc = -1;
    return rc;
}

int nk_reference_path(nk_volume *v, const char *path, uint64_t *reference) {
    if (!v || !path || !reference) { errno = EINVAL; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    uint64_t sequence = le16_to_cpu(ni->mrec->sequence_number);
    uint64_t result = ni->mft_no | (sequence << 48);
    if (ntfs_inode_close(ni)) { errno = EIO; return -1; }
    if (!sequence) { errno = ESTALE; return -1; }
    *reference = result;
    return 0;
}

static ntfs_inode *open_reference(nk_volume *v, uint64_t reference) {
    if (!v || !(reference >> 48)) { errno = EINVAL; return NULL; }
    /* libntfs's cache is keyed only by MFT number, and a cache hit skips its
     * sequence check. Always compare the actual record ourselves, including
     * the in-use flag, before returning an inode to any reference operation. */
    ntfs_inode *ni = ntfs_inode_open(v->vol, MREF(reference));
    if (!ni) { if (errno == ENOENT) errno = ESTALE; return NULL; }
    if (!(ni->mrec->flags & MFT_RECORD_IN_USE) ||
        le16_to_cpu(ni->mrec->sequence_number) != (reference >> 48)) {
        int error = ntfs_inode_close(ni) ? EIO : ESTALE;
        errno = error; return NULL;
    }
    return ni;
}
int nk_stat_reference(nk_volume *v, uint64_t reference, nk_stat *st) {
    if (!st) { errno = EINVAL; return -1; }
    ntfs_inode *ni = open_reference(v, reference);
    if (!ni) return -1;
    ntfs_attr *na = NULL;
    if (!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (!na) { int error = errno; ntfs_inode_close(ni); errno = error; return -1; }
    }
    int rc = fill_stat(ni, na, st);
    if (na) ntfs_attr_close(na);
    if (ntfs_inode_close(ni)) rc = -1;
    return rc;
}
/* `name` inside the directory `dir_reference`, by its index alone: no walk
 * from the root. Fills its reference (MFT number and sequence) and its stat. */
int nk_lookup_reference(nk_volume *v, uint64_t dir_reference, const char *name,
                        uint64_t *reference, nk_stat *st) {
    if (!name || !reference || !st || !valid_name(name)) { errno = EINVAL; return -1; }
    ntfs_inode *dir = open_reference(v, dir_reference);
    if (!dir) return -1;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { ntfs_inode_close(dir); errno = ENOTDIR; return -1; }
    u64 found = lookup_name(dir, name, NULL, NULL);
    int error = found == (u64)-1 ? (errno ? errno : ENOENT) : 0;
    if (ntfs_inode_close(dir) && !error) error = EIO;
    if (error) { errno = error; return -1; }
    if (MREF(found) < (u64)FILE_first_user) { errno = ENOENT; return -1; }  /* $MFT & friends stay hidden */
    ntfs_inode *ni = open_reference(v, found);
    if (!ni) return -1;
    /* As nk_stat_path: a file without an unnamed data stream still looks up. */
    ntfs_attr *na = NULL;
    if (!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY)) na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    int rc = fill_stat(ni, na, st);
    if (na) ntfs_attr_close(na);
    if (ntfs_inode_close(ni)) rc = -1;
    if (!rc) *reference = found;
    return rc;
}

long long nk_read_reference(nk_volume *v, uint64_t reference, long long offset,
                            long long count, void *buf) {
    if (offset < 0 || count < 0 || offset > LLONG_MAX - count || (count && !buf)) { errno = EINVAL; return -1; }
    ntfs_inode *ni = open_reference(v, reference);
    if (!ni) return -1;
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) { ntfs_inode_close(ni); errno = EISDIR; return -1; }
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL) || !(mode & 0400)) { ntfs_inode_close(ni); errno = EIO; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    long long n = na ? ntfs_attr_pread(na, offset, count, buf) : -1;
    int error = n < 0 ? (errno ? errno : EIO) : 0;
    if (na) ntfs_attr_close(na);
    if (ntfs_inode_close(ni)) error = EIO;
    if (error) { errno = error; return -1; }
    return n;
}
long long nk_write_reference(nk_volume *v, uint64_t reference, long long offset,
                             long long count, const void *buf) {
    if (require_writable(v)) return -1;
    if (offset < 0 || count < 0 || offset > LLONG_MAX - count || (count && !buf)) { errno = EINVAL; return -1; }
    /* Nothing to write. NTFS-3G rejects a null buffer even for zero bytes, and
     * that refusal would count as a failed mutation and lock the session. */
    if (!count) return 0;
    ntfs_inode *ni = open_reference(v, reference);
    if (!ni) return -1;
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) { ntfs_inode_close(ni); errno = EISDIR; return -1; }
    if (!writable_content_inode(ni)) { int error = errno; ntfs_inode_close(ni); errno = error; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int error = errno; ntfs_inode_close(ni); errno = error; return -1; }
    long long n = ntfs_attr_pwrite(na, offset, count, buf);
    int error = n == count ? 0 : (errno ? errno : EIO);
    ntfs_attr_close(na);
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) error = EIO;
    if (mutation_result(v, n != count || error, error)) return -1;
    return n;
}

struct list_ctx {
    nk_volume   *v;
    nk_dirent_cb cb;
    void        *ctx;
    int          stop;
};

static int nk_filldir(void *ctx, const ntfschar *name, const int name_len,
                      const int name_type, const s64 pos, const MFT_REF mref,
                      const unsigned dt_type) {
    (void)pos;
    struct list_ctx *lc = ctx;
    if (lc->stop) return 0;
    if (name_type == FILE_NAME_DOS) return 0;          /* skip 8.3 aliases */
    if (MREF(mref) < (u64)FILE_first_user) return 0;   /* skip $MFT & friends */
    if (name_len <= 0 || name_len > 255) return 0;

    ntfschar shown[255];
    memcpy(shown, name, (size_t)name_len * sizeof(ntfschar));
    sfm_unmap(shown, name_len);
    char *utf8 = NULL;
    if (ntfs_ucstombs(shown, name_len, &utf8, 0) < 0 || !utf8) return 0;

    int is_dot = utf8[0] == '.' &&
                 (utf8[1] == '\0' || (utf8[1] == '.' && utf8[2] == '\0'));
    if (!is_dot) {
        /* Nothing is opened per entry: a large directory lists in one pass. */
        nk_dirent e = { .name = utf8, .is_dir = dt_type == NTFS_DT_DIR,
                        .size = 0, .inode = MREF(mref), .is_symlink = dt_type == NTFS_DT_LNK,
                        .reference = (uint64_t)mref };
        if (lc->cb(lc->ctx, &e) != 0) lc->stop = 1;
    }
    free(utf8);
    return 0;
}

int nk_list(nk_volume *v, const char *dir_path, nk_dirent_cb cb, void *ctx) {
    if (!v || !cb) return -1;
    ntfs_inode *dir = path_inode(v, dir_path);
    if (!dir) return -1;
    uint32_t mode;
    if (mac_mode_read(dir, &mode, NULL) || !(mode & 0500)) { ntfs_inode_close(dir); errno = EIO; return -1; }
    struct list_ctx lc = { v, cb, ctx, 0 };
    s64 pos = 0;
    int r = ntfs_readdir(dir, &pos, &lc, nk_filldir);
    ntfs_inode_close(dir);
    return r ? -1 : 0;
}

long long nk_read(nk_volume *v, const char *path, long long offset,
                  long long count, void *buf) {
    if (!v) return -1;
    if (!path || offset < 0 || count < 0 || offset > LLONG_MAX - count || (count && !buf)) { errno = EINVAL; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL) || !(mode & 0400)) { ntfs_inode_close(ni); errno = EIO; return -1; }
    long long n = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        n = (long long)ntfs_attr_pread(na, offset, count, buf);
        ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    return n;
}

long long nk_write(nk_volume *v, const char *path, long long offset,
                   long long count, const void *buf) {
    if (require_writable(v)) return -1;
    if (!path || offset < 0 || count < 0 || offset > LLONG_MAX - count || (count && !buf)) { errno = EINVAL; return -1; }
    if (!count) return 0;  /* as nk_write_reference */
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    if (!writable_content_inode(ni)) { ntfs_inode_close(ni); return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int error = errno; ntfs_inode_close(ni); errno = error; return -1; }
    long long n = ntfs_attr_pwrite(na, offset, count, buf);
    int error = n == count ? 0 : (errno ? errno : EIO);
    ntfs_attr_close(na);
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) error = EIO;
    if (mutation_result(v, n != count || error, error)) return -1;
    return n;
}

/* `target` is used for S_IFLNK only: an Interix symbolic link (NTFS-3G's
 * default), which macOS and Linux read back verbatim and Windows keeps as a
 * small system file. */
static int create_node(nk_volume *v, const char *dir_path, const char *name,
                       mode_t type, const char *target) {
    if (require_writable(v)) return -1;
    if (!dir_path) { errno = EINVAL; return -1; }
    if (!valid_name(name)) return -1;
    if (type == S_IFLNK && (!target || !*target || strlen(target) > NK_SYMLINK_TARGET_MAX)) {
        errno = target && *target ? ENAMETOOLONG : EINVAL; return -1;
    }
    ntfs_inode *dir = path_inode(v, dir_path);
    if (!dir) return -1;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY) ||
        (dir->mft_no != FILE_root && !writable_inode(dir))) {
        int error = !(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? ENOTDIR : errno;
        ntfs_inode_close(dir); errno = error; return -1;
    }
    if (metadata_name(dir, name)) { ntfs_inode_close(dir); errno = EINVAL; return -1; }
    ntfschar *ucs = NULL;
    /* NTFS names are at most 255 UCS-2 units; (u8) casts must never wrap. */
    int len = stored_name(name, &ucs);
    if (len < 0) { int error = errno; ntfs_inode_close(dir); errno = error; return -1; }
    /* Reject ordinary name conflicts before entering the mutation boundary.
     * They must not poison an otherwise healthy write session. A name that
     * differs only in Unicode form counts as taken. One differing only in case
     * from another entry is refused for folders and links, as on Windows, but
     * not for a file: open(O_CREAT) answers EEXIST by looking the name up
     * again, and that exact lookup never finds it, so the kernel would retry
     * for ever (an unkillable process). Such files predate this check. */
    u64 existing = lookup_name(dir, name, NULL, NULL);
    int conflict = existing != (u64)-1 ? 1 : errno != ENOENT ? -1
                 : type == S_IFREG ? 0 : case_variant_exists(dir, ucs, len, (u64)-1);
    if (conflict) {
        int error = conflict > 0 ? EEXIST : (errno ? errno : EIO);
        free(ucs); ntfs_inode_close(dir); errno = error; return -1;
    }
    /* Like Windows: the new node's descriptor comes from the parent's
     * inheritable ACEs (owner/group from the parent, no UID mapping). Without
     * this libntfs-3g writes a default descriptor granting Everyone full access. */
    struct PERMISSIONS_CACHE *no_cache = NULL;
    struct SECURITY_CONTEXT inherit = {0};
    inherit.vol = v->vol; inherit.pseccache = &no_cache;
    inherit.uid = 1; inherit.gid = 1;
    le32 securid = ntfs_inherited_id(&inherit, dir, type == S_IFDIR);
    ntfs_inode *ni = NULL;
    /* Like macOS, hide dot files (.DS_Store, .Trashes, ...) from Windows
     * Explorer too: NTFS-3G sets HIDDEN at creation while this flag is on.
     * Only here, not on rename, so a file renamed later keeps what Windows set. */
    NVolSetHideDotFiles(v->vol);
    if (type == S_IFLNK) {
        ntfschar *utarget = NULL;
        int tlen = ntfs_mbstoucs(target, &utarget);
        if (tlen > 0 && utarget) ni = ntfs_create_symlink(dir, securid, ucs, (u8)len, utarget, tlen);
        else if (!errno) errno = EINVAL;
        free(utarget);
    } else {
        ni = ntfs_create(dir, securid, ucs, (u8)len, type);
    }
    NVolClearHideDotFiles(v->vol);
    free(ucs);
    int error = ni ? 0 : (errno ? errno : EIO);
    if (ni && ntfs_inode_close(ni)) error = errno ? errno : EIO;
    if (ntfs_inode_close(dir)) error = errno ? errno : EIO;
    /* Persist child, parent and held volume metadata before reporting creation.
     * ENOSPC or a flush failure after mutation retains the dirty marker. */
    if (!error && nk_sync(v)) error = errno ? errno : EIO;
    return mutation_result(v, error ? -1 : 0, error);
}

int nk_create(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFREG, NULL);
}

int nk_mkdir(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFDIR, NULL);
}

/* Split "/a/b/c" into parent "/a/b" (written into parent[]) and leaf "c". */
static const char *split_path(const char *path, char *parent, size_t plen_max) {
    const char *slash = strrchr(path, '/');
    if (!slash) return NULL;
    size_t plen = (size_t)(slash - path);
    if (plen == 0) { strcpy(parent, "/"); }
    else {
        if (plen >= plen_max) return NULL;
        memcpy(parent, path, plen);
        parent[plen] = '\0';
    }
    return slash + 1;
}

/* Whether a directory keeps another real name once one is removed (DOS short
 * names alias their Win32 name): a rename links the new name before removing
 * the old one. NTFS-3G's own rule for unlinking a non-empty directory. */
static int has_other_name(ntfs_inode *ni) {
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) return -1;
    int names = 0;
    while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, ctx)) {
        const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)((const u8 *)ctx->attr +
                                                            le16_to_cpu(ctx->attr->value_offset));
        if (fn->file_name_type != FILE_NAME_DOS) ++names;
    }
    int error = errno;
    ntfs_attr_put_search_ctx(ctx);
    if (error != ENOENT) { errno = error ? error : EIO; return -1; }
    return names > 1;
}

int nk_delete(nk_volume *v, const char *path) {
    if (require_writable(v)) return -1;
    if (!path) { errno = EINVAL; return -1; }
    char parent[4096];
    const char *leaf = split_path(path, parent, sizeof(parent));
    if (!leaf || !valid_name(leaf)) { errno = EINVAL; return -1; }

    ntfs_inode *dir = path_inode(v, parent);
    if (!dir) return -1;
    /* The entry under the spelling it is stored with, whichever one was passed. */
    ntfschar *ucs = NULL;
    int len = 0;
    u64 reference = lookup_name(dir, leaf, &ucs, &len);
    ntfs_inode *ni = reference == (u64)-1 ? NULL : ntfs_inode_open(v->vol, MREF(reference));
    if (!ni) {
        int error = reference == (u64)-1 ? (errno ? errno : ENOENT) : EIO;
        free(ucs); ntfs_inode_close(dir); errno = error; return -1;
    }
    if (!writable_inode(ni)) {
        int error = errno;
        free(ucs); ntfs_inode_close(ni); ntfs_inode_close(dir); errno = error; return -1;
    }
    /* A directory that still has entries and no other name: an ordinary
     * refusal, checked before ntfs_delete so it changes nothing and leaves the
     * session writable. Its other name during a rename lets it go as usual. */
    if ((ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) && ntfs_check_empty_dir(ni)) {
        int error = errno ? errno : EIO;
        if (error == ENOTEMPTY) {
            int other = has_other_name(ni);
            error = other < 0 ? (errno ? errno : EIO) : other ? 0 : ENOTEMPTY;
        }
        if (error) { free(ucs); ntfs_inode_close(ni); ntfs_inode_close(dir); errno = error; return -1; }
    }

    /* ntfs_delete consumes (closes) both inodes, success or failure. */
    int r = ntfs_delete(v->vol, path, ni, dir, ucs, (u8)len);
    int error = r ? (errno ? errno : EIO) : 0;
    free(ucs);
    /* Past the checks above a failure is a partial metadata change: lock the session. */
    return mutation_result(v, r ? -1 : 0, error);
}

/* Walk actual inode ancestry, not a textual prefix (paths may be aliases).
 * Reject cycles/corrupt ancestry before changing either directory. */
static int rename_directory_preflight(nk_volume *v, ntfs_inode *source, ntfs_inode *destination) {
    ntfs_inode *cursor = ntfs_inode_open(v->vol, destination->mft_no);
    if (!cursor) return -1;
    for (unsigned depth = 0; depth < 1024; ++depth) {
        if (cursor->mft_no == source->mft_no) {
            ntfs_inode_close(cursor); errno = EINVAL; return -1;
        }
        if (cursor->mft_no == FILE_root) return ntfs_inode_close(cursor);
        ntfs_inode *parent = ntfs_dir_parent_inode(cursor);
        int error = parent ? 0 : (errno ? errno : EIO);
        if (ntfs_inode_close(cursor)) error = EIO;
        if (error) {
            if (parent) ntfs_inode_close(parent);
            errno = error; return -1;
        }
        cursor = parent;
    }
    ntfs_inode_close(cursor); errno = ELOOP; return -1;
}

/* Non-replacing rename. Sync the new link before removing the old one.
 * A mutation failure locks the session and keeps remaining names; never
 * delete the new link when the old name's persistence is uncertain. This is
 * not a journaled or crash-atomic rename. Existing destinations are rejected. */
int nk_rename(nk_volume *v, const char *old_path, const char *new_dir,
              const char *new_name) {
    if (require_writable(v)) return -1;
    if (!old_path || old_path[0] != '/' || !new_dir || new_dir[0] != '/' ||
        !valid_name(new_name)) { errno = EINVAL; return -1; }
    ntfschar *ucs = NULL;
    int len = stored_name(new_name, &ucs);
    if (len < 0) return -1;
    int error = 0, mutated = 0;
    ntfs_inode *ni = path_inode(v, old_path);
    ntfs_inode *dir = NULL;
    if (!ni) { error = errno ? errno : ENOENT; goto out; }
    if (!writable_inode(ni)) { error = errno; goto out; }
    dir = path_inode(v, new_dir);
    if (!dir) { error = errno ? errno : ENOENT; goto out; }
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { error = ENOTDIR; goto out; }
    if (metadata_name(dir, new_name)) { error = EINVAL; goto out; }
    u64 existing = lookup_name(dir, new_name, NULL, NULL);
    if (existing != (u64)-1) {
        /* POSIX same-inode rename is a no-op, including identical paths. */
        if (MREF(existing) != ni->mft_no) error = EEXIST;
        goto out;
    }
    if (errno != ENOENT) { error = errno ? errno : EIO; goto out; }
    /* Another file whose name differs only in case: Windows would see one name.
     * The same file in another case is an ordinary case-only rename. */
    int variant = case_variant_exists(dir, ucs, len, ni->mft_no);
    if (variant) { error = variant > 0 ? EEXIST : (errno ? errno : EIO); goto out; }
    if ((ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) &&
        rename_directory_preflight(v, ni, dir)) { error = errno ? errno : EIO; goto out; }

    mutated = 1;
    if (ntfs_link(ni, dir, ucs, (u8)len)) error = errno ? errno : EIO;
    if (ntfs_inode_close(dir)) error = EIO;
    dir = NULL;
    if (ntfs_inode_close(ni)) error = EIO;
    ni = NULL;
    if (error || v->devctx->failed) { if (!error) error = EIO; goto out; }
    if (nkdev_sync(v->vol->dev)) { error = EIO; goto out; }
    if (nk_delete(v, old_path)) { error = errno ? errno : EIO; goto out; }
    if (nkdev_sync(v->vol->dev)) error = EIO;
out:
    if (dir && ntfs_inode_close(dir)) error = EIO;
    if (ni && ntfs_inode_close(ni)) error = EIO;
    free(ucs);
    if (mutated) return mutation_result(v, error ? -1 : 0, error);
    if (v->devctx->failed) error = EIO;
    if (error) { errno = error; return -1; }
    return 0;
}

#include "replacement_security.inc"

/* Replacement keeps the replaced file's complete Windows descriptor, as
 * Windows ReplaceFile does. Both names must exist; verified after writing. */
int nk_copy_security(nk_volume *v, const char *from_path, const char *to_path) {
    if (require_writable(v)) return -1;
    if (!from_path || !to_path) { errno = EINVAL; return -1; }
    ntfs_inode *from = path_inode(v, from_path);
    if (!from) return -1;
    ntfs_inode *to = path_inode(v, to_path);
    if (!to) { int error = errno; ntfs_inode_close(from); errno = error; return -1; }
    int r = replacement_preserve_security(v, to, from);
    int error = r ? errno : 0;
    if (ntfs_inode_close(to)) { r = -1; error = EIO; }
    if (ntfs_inode_close(from)) { r = -1; error = EIO; }
    return r ? mutation_result(v, -1, error) : 0;
}

#ifdef NK_EXPERIMENTAL_REPLACEMENT
struct replacement_name_check {
    ntfs_volume *vol;
    const ntfschar *name;
    int length, collision;
};
static int replacement_check_name(void *ctx, const ntfschar *name, int length,
                                  int type, s64 pos, MFT_REF ref, unsigned kind) {
    (void)type; (void)pos; (void)ref; (void)kind;
    struct replacement_name_check *check = ctx;
    if (ntfs_names_are_equal(name, length, check->name, check->length,
                             IGNORE_CASE, check->vol->upcase, check->vol->upcase_len))
        check->collision = 1;
    return 0;
}

int nk_replace_between(nk_volume *v, const char *source_dir, const char *source,
                       const char *dir_path, const char *target, const char *backup) {
    if (require_writable(v)) return -1;
    if (v->devctx->io.size != 64LL * 1024 * 1024 && v->devctx->io.size != 512LL * 1024 * 1024) { errno = ENOTSUP; return -1; }
    /* Both directories are canonical volume-relative paths. No caller path
     * is ever opened on the host. Retained old data lives beside the target. */
    const char *directories[] = {source_dir, dir_path};
    for (unsigned i = 0; i < 2; ++i) {
        const char *directory = directories[i];
        if (!directory || directory[0] != '/' || strlen(directory) >= 4096 ||
            strstr(directory, "//")) { errno = EINVAL; return -1; }
        for (const char *p = directory + 1; *p;) {
            const char *end = strchr(p, '/');
            size_t n = end ? (size_t)(end - p) : strlen(p);
            if ((n == 1 && p[0] == '.') || (n == 2 && !strncmp(p, "..", 2)) ||
                (end && !end[1])) { errno = EINVAL; return -1; }
            p = end ? end + 1 : p + n;
        }
    }
    const char *names[] = { source, target, backup };
    ntfschar *ucs[3] = { NULL, NULL, NULL };
    int lengths[3] = { 0, 0, 0 };
    ntfs_inode *dir = NULL, *source_parent = NULL, *files[2] = { NULL, NULL };
    int error = 0;
    char paths[3][4096];
    for (unsigned i = 0; i < 3; ++i) {
        /* Experimental path: keeps the earlier, stricter rule for "$" names. */
        if (!valid_name(names[i]) || names[i][0] == '$') { error = EINVAL; goto out; }
        lengths[i] = ntfs_mbstoucs(names[i], &ucs[i]);
        if (!ucs[i] || lengths[i] <= 0 || lengths[i] > 255) { error = EINVAL; goto out; }
        const char *parent = i == 0 ? source_dir : dir_path;
        if (snprintf(paths[i], sizeof(paths[i]), "%s%s%s", parent,
                              !strcmp(parent, "/") ? "" : "/", names[i]) >= (int)sizeof(paths[i])) {
            error = ENAMETOOLONG; goto out;
        }
    }
    dir = path_inode(v, dir_path);
    if (!dir) { error = errno ? errno : ENOENT; goto out; }
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { error = ENOTDIR; goto out; }
    source_parent = path_inode(v, source_dir);
    if (!source_parent) { error = errno ? errno : ENOENT; goto out; }
    if (!(source_parent->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { error = ENOTDIR; goto out; }
    if (source_parent->mft_no == dir->mft_no && ntfs_names_are_equal(ucs[0], lengths[0], ucs[1], lengths[1],
                             IGNORE_CASE, v->vol->upcase, v->vol->upcase_len)) {
        error = EINVAL; goto out;
    }
    for (unsigned i = 0; i < 2; ++i) {
        u64 ref = ntfs_inode_lookup_by_name(i == 0 ? source_parent : dir, ucs[i], lengths[i]);
        if (ref == (u64)-1) { error = errno ? errno : ENOENT; goto out; }
        files[i] = ntfs_inode_open(v->vol, ref);
        if (!files[i]) { error = errno ? errno : EIO; goto out; }
        if (files[i]->mrec->flags & MFT_RECORD_IS_DIRECTORY) { error = EISDIR; goto out; }
        if (!writable_inode(files[i])) { error = errno; goto out; }
        if (le16_to_cpu(files[i]->mrec->link_count) != 1 || (files[i]->flags & FILE_ATTR_SYSTEM)) {
            error = EOPNOTSUPP; goto out;
        }
    }
    if (files[0]->mft_no == files[1]->mft_no) { error = EINVAL; goto out; }
    /* A POSIX-namespace entry can be case-sensitive even on Windows media.
     * Conservatively reserve backup names across all namespaces/8.3 aliases. */
    struct replacement_name_check check = { v->vol, ucs[2], lengths[2], 0 };
    s64 pos = 0;
    if (ntfs_readdir(dir, &pos, &check, replacement_check_name)) error = errno ? errno : EIO;
    else if (check.collision) error = EEXIST;
    if (!error && replacement_preserve_security(v, files[0], files[1])) error = errno ? errno : EIO;
out:
    for (unsigned i = 0; i < 2; ++i)
        if (files[i] && ntfs_inode_close(files[i])) error = EIO;
    if (source_parent && ntfs_inode_close(source_parent)) error = EIO;
    if (dir && ntfs_inode_close(dir)) error = EIO;
    for (unsigned i = 0; i < 3; ++i) free(ucs[i]);
    if (v->devctx->failed) error = EIO;
    if (error) { errno = error; return -1; }

    /* First retain the old content durably. Only then publish the new one.
     * Each rename syncs its new link before removing its previous link.
     * A failure can leave multiple names or a temporarily missing target;
     * never try a destructive rollback/backup cleanup in that state. */
    if (nk_rename(v, paths[1], dir_path, backup) ||
        nk_rename(v, paths[0], dir_path, target))
        return mutation_result(v, -1, errno ? errno : EIO);
    return 0;
}
#else
int nk_replace_between(nk_volume *v, const char *source_dir, const char *source,
                       const char *dir_path, const char *target, const char *backup) {
    (void)source_dir; (void)dir_path; (void)source; (void)target; (void)backup;
    if (require_writable(v)) return -1;
    errno = ENOTSUP;
    return -1;
}
#endif

int nk_replace_preserving(nk_volume *v, const char *dir_path,
                          const char *source, const char *target, const char *backup) {
    return nk_replace_between(v, dir_path, source, dir_path, target, backup);
}

int nk_set_mac_mode(nk_volume *v, const char *path, uint32_t mode) {
#ifndef NK_EXPERIMENTAL_PRIVATE_MODES
    (void)v; (void)path; (void)mode; errno = ENOTSUP; return -1;
#else
    if (require_writable(v)) return -1;
    if (!path) { errno = EINVAL; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    int directory = !!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY);
    if (!mode_valid(mode, directory) || !writable_inode(ni) || le16_to_cpu(ni->mrec->link_count) != 1) {
        int error = errno;
        if (!mode_valid(mode, directory) || le16_to_cpu(ni->mrec->link_count) != 1) error = ENOTSUP;
        ntfs_inode_close(ni); errno = error; return -1;
    }
    int rc = mac_mode_store(ni, mode);
    if (!rc) {
        if (!directory) {
            ni->flags = mode & 0200 ? ni->flags & ~FILE_ATTR_READONLY : ni->flags | FILE_ATTR_READONLY;
            NInoFileNameSetDirty(ni);
        }
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
        NInoSetDirty(ni);
        if (ntfs_inode_sync(ni)) rc = -1;
    }
    if (ntfs_inode_close(ni)) rc = -1;
    if (!rc && nkdev_sync(v->vol->dev)) rc = -1;
    return mutation_result(v, rc, rc ? EIO : 0);
#endif
}

int nk_create_mode(nk_volume *v, const char *dir_path, const char *name, uint32_t mode, int is_dir) {
#ifndef NK_EXPERIMENTAL_PRIVATE_MODES
    (void)v; (void)dir_path; (void)name; (void)mode; (void)is_dir; errno = ENOTSUP; return -1;
#else
    if (require_writable(v)) return -1;
    if ((is_dir != 0 && is_dir != 1) || !mode_valid(mode, is_dir)) { errno = ENOTSUP; return -1; }
    if (!dir_path || !valid_name(name)) return -1;
    ntfs_inode *dir = path_inode(v, dir_path);
    if (!dir) return -1;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY) || (dir->mft_no != FILE_root && !writable_inode(dir))) {
        int error = errno ? errno : ENOTDIR; ntfs_inode_close(dir); errno = error; return -1;
    }
    ntfschar *ucs = NULL; int len = ntfs_mbstoucs(name, &ucs);
    if (len <= 0 || len > 255 || !ucs) { free(ucs); ntfs_inode_close(dir); errno = EINVAL; return -1; }
    u64 existing = ntfs_inode_lookup_by_name(dir, ucs, len);
    if (existing != (u64)-1 || errno != ENOENT) {
        int error = existing != (u64)-1 ? EEXIST : errno;
        free(ucs); ntfs_inode_close(dir); errno = error; return -1;
    }
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), ucs, (u8)len, is_dir ? S_IFDIR : S_IFREG);
    free(ucs);
    int rc = ni ? 0 : -1;
    if (ni) {
        // No FSKit item is published until both the restrictive staging mode
        // and final mode are durable. Any interruption leaves a dirty volume.
        if (mac_mode_store(ni, 0) || ntfs_inode_sync(ni) || nkdev_sync(v->vol->dev)) rc = -1;
        if (!rc && mac_mode_store(ni, mode)) rc = -1;
        if (!rc && !is_dir && !(mode & 0200)) {
            ni->flags |= FILE_ATTR_READONLY; NInoFileNameSetDirty(ni); NInoSetDirty(ni);
        }
        if (!rc && ntfs_inode_sync(ni)) rc = -1;
        if (ntfs_inode_close(ni)) rc = -1;
    }
    if (ntfs_inode_close(dir)) rc = -1;
    if (!rc && nkdev_sync(v->vol->dev)) rc = -1;
    return mutation_result(v, rc, rc ? EIO : 0);
#endif
}

int nk_set_file_mode(nk_volume *v, const char *path, uint32_t mode) {
    if (require_writable(v)) return -1;
    if (!path) { errno = EINVAL; return -1; }
    if (mode != 0444 && mode != 0644) { errno = ENOTSUP; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    uint32_t stored_mode; int has_mac_mode;
    if (mac_mode_read(ni, &stored_mode, &has_mac_mode)) { ntfs_inode_close(ni); errno = EIO; return -1; }
    // The legacy READONLY-only API cannot accurately apply a persisted mode.
    // Require the explicitly gated Mac-mode API instead of reporting success.
    if (has_mac_mode) { ntfs_inode_close(ni); errno = ENOTSUP; return -1; }
    int error = 0;
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) error = EISDIR;
    else if (!writable_inode(ni)) error = errno;
    else {
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (!na) error = errno ? errno : EIO;
        else {
            if ((ni->flags & FILE_ATTR_SYSTEM) && is_intx_symlink(na)) error = ENOTSUP;
            ntfs_attr_close(na);
        }
    }
    if (error) { ntfs_inode_close(ni); errno = error; return -1; }
    le32 flags = mode == 0444 ? ni->flags | FILE_ATTR_READONLY : ni->flags & ~FILE_ATTR_READONLY;
    if (flags == ni->flags) return ntfs_inode_close(ni);
    // Do not translate/replace Windows DACLs, ownership, or any other flags.
    ni->flags = flags;
    NInoFileNameSetDirty(ni); NInoSetDirty(ni);
    ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    int result = ntfs_inode_close(ni);
    return mutation_result(v, result, result ? EIO : 0);
}

/* Finder's "hidden" flag (UF_HIDDEN) as the Windows HIDDEN attribute, which
 * listings already report back as UF_HIDDEN. Nothing else is changed. */
int nk_set_hidden(nk_volume *v, const char *path, int hidden) {
    if (require_writable(v)) return -1;
    if (!path) { errno = EINVAL; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    if (ni->mft_no == FILE_root || !writable_inode(ni)) {
        int error = ni->mft_no == FILE_root ? EPERM : errno;
        ntfs_inode_close(ni); errno = error; return -1;
    }
    le32 flags = hidden ? ni->flags | FILE_ATTR_HIDDEN : ni->flags & ~FILE_ATTR_HIDDEN;
    if (flags == ni->flags) return ntfs_inode_close(ni);
    ni->flags = flags;
    NInoFileNameSetDirty(ni); NInoSetDirty(ni);
    ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    int result = ntfs_inode_close(ni);
    return mutation_result(v, result, result ? EIO : 0);
}

int nk_truncate(nk_volume *v, const char *path, long long size) {
    if (require_writable(v)) return -1;
    if (!path || size < 0) { errno = EINVAL; return -1; }
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    if (!writable_content_inode(ni)) { ntfs_inode_close(ni); return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int error = errno; ntfs_inode_close(ni); errno = error; return -1; }
    int r = ntfs_attr_truncate(na, size), error = errno;
    ntfs_attr_close(na);
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) { r = -1; error = EIO; }
    return mutation_result(v, r, error);
}

void nk_abort_write_session(nk_volume *v) {
    if (v && !NVolReadOnly(v->vol)) v->devctx->failed = 1;
}

static int inode_needs_sync(const ntfs_inode *ni) {
    if (NInoDirty(ni) || NInoAttrListDirty(ni) || NInoFileNameDirty(ni)) return 1;
    for (int i = 0; i < ni->nr_extents; i++) {
        const ntfs_inode *extent = ni->extent_nis[i];
        if (NInoDirty(extent) || NInoAttrListDirty(extent)) return 1;
    }
    return 0;
}

int nk_sync(nk_volume *v) {
    if (!v) { errno = EINVAL; return -1; }
    if (v->devctx->failed) { errno = EIO; return -1; }
    if (NVolReadOnly(v->vol)) return 0;
    /* Ordinary bridge calls close their temporary inodes before returning;
     * ntfs_inode_close syncs them before placing them in the upstream cache.
     * The volume's held system inodes do not go through that path. Flush them
     * before the device barrier, including dirty extent/attribute-list state.
     * This does not clear the owned dirty marker or provide crash atomicity.
     *
     * Upstream index-context release has a void API that discards errors.
     * A pending nonresident security index must be finished by its owning
     * operation, not silently discarded here and reported as durable. */
    if (v->vol->secure_ni &&
        ((v->vol->secure_xsii && v->vol->secure_xsii->ib_dirty) ||
         (v->vol->secure_xsdh && v->vol->secure_xsdh->ib_dirty))) {
        return mutation_result(v, -1, EIO);
    }
    ntfs_inode *held[] = { v->vol->secure_ni, v->vol->vol_ni,
        v->vol->lcnbmp_ni, v->vol->mft_ni, v->vol->mftmirr_ni };
    for (size_t i = 0; i < sizeof(held) / sizeof(held[0]); i++) {
        if (held[i] && inode_needs_sync(held[i]) && ntfs_inode_sync(held[i])) {
            int error = errno;
            return mutation_result(v, -1, error);
        }
        if (v->devctx->failed) return mutation_result(v, -1, EIO);
    }
    return nkdev_sync(v->vol->dev) ? -1 : 0;
}

int nk_set_times(nk_volume *v, const char *path, long long atime,
                 long long mtime, long long btime) {
    nk_timestamp a = {atime, 0}, m = {mtime, 0}, b = {btime, 0};
    return nk_set_times_precise(v, path, atime >= 0 ? &a : NULL,
                               mtime >= 0 ? &m : NULL, btime >= 0 ? &b : NULL);
}

static int encode_timestamp(const nk_timestamp *value, ntfs_time *output) {
    if (!value) return 0;
    if (value->nanoseconds < 0 || value->nanoseconds >= 1000000000) {
        errno = EINVAL; return -1;
    }
    __int128 ticks = (__int128)value->seconds * 10000000 + NTFS_TIME_OFFSET
                     + value->nanoseconds / 100;
    if (ticks < 0 || ticks > LLONG_MAX) { errno = EINVAL; return -1; }
    *output = cpu_to_sle64((s64)ticks);
    return 0;
}

int nk_set_times_precise(nk_volume *v, const char *path,
                         const nk_timestamp *atime, const nk_timestamp *mtime,
                         const nk_timestamp *btime) {
    if (require_writable(v)) return -1;
    ntfs_time a = 0, m = 0, b = 0;
    if (!path) { errno = EINVAL; return -1; }
    if (encode_timestamp(atime, &a) || encode_timestamp(mtime, &m) ||
        encode_timestamp(btime, &b)) return -1;
    if (!atime && !mtime && !btime) return 0;
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    if (!writable_inode(ni)) { ntfs_inode_close(ni); return -1; }
    if (atime) ni->last_access_time = a;
    if (mtime) ni->last_data_change_time = m;
    if (btime) ni->creation_time = b;
    NInoFileNameSetDirty(ni);
    ntfs_inode_mark_dirty(ni);
    int r = ntfs_inode_close(ni), error = errno;
    return mutation_result(v, r, error);
}

int nk_readlink(nk_volume *v, const char *path, char *buf, size_t buflen) {
    if (!v || !buf || buflen == 0) return -1;
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) return -1;
    int r = -1;
    if (ni->flags & FILE_ATTR_REPARSE_POINT) {
        char *target = ntfs_make_symlink(ni, "/");
        if (target) {
            snprintf(buf, buflen, "%s", target);
            free(target);
            r = 0;
        }
    } else {
        /* Interix symlink: UCS-2 target follows the 8-byte IntxLNK magic. */
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na && is_intx_symlink(na)) {
            s64 tlen_bytes = na->data_size - 8;
            ntfschar *ucs = malloc((size_t)tlen_bytes);
            if (ucs && ntfs_attr_pread(na, 8, tlen_bytes, ucs) == tlen_bytes) {
                char *utf8 = NULL;
                if (ntfs_ucstombs(ucs, (int)(tlen_bytes / 2), &utf8, 0) >= 0 && utf8) {
                    snprintf(buf, buflen, "%s", utf8);
                    free(utf8);
                    r = 0;
                }
            }
            free(ucs);
        }
        if (na) ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    return r;
}

int nk_create_symlink(nk_volume *v, const char *dir_path, const char *name,
                      const char *target) {
    return create_node(v, dir_path, name, S_IFLNK, target);
}

int nk_is_dirty(nk_volume *v) {
    if (!v) return -1;
    return (v->vol->flags & VOLUME_IS_DIRTY) ? 1 : 0;
}


/* Extended attributes use named NTFS data streams. This does not implement
 * NTFS ACLs, EFS or macOS compression. Mutations are not transactional;
 * failed mutations lock the session and retain its dirty marker. */
#define NK_XATTR_LIMIT (4 * 1024 * 1024)
/* Stream names cannot hold ':' or '/', yet macOS names such as
 * "com.apple.metadata:kMDItemWhereFroms" (on every downloaded file) do.
 * Store them with the Services for Macintosh mapping Apple's and Linux's SMB
 * clients use, and map back when listing: ':' <-> U+F022, '/' <-> U+F026. */
#define NK_SFM_COLON 0xF022
#define NK_SFM_SLASH 0xF026
static ntfschar *xattr_name(const char *name, int *length) {
    if (!name || !*name || !strcmp(name, ".") || !strcmp(name, "..") ||
        strchr(name, '\\') || name[0] == '$') { errno = EINVAL; return NULL; }
    if (!strcmp(name, "com.apple.decmpfs") || !strcmp(name, "com.apple.system.Security")) {
        errno = ENOTSUP; return NULL;
    }
    ntfschar *unicode = NULL;
    int count = ntfs_mbstoucs(name, &unicode);
    if (count <= 0 || count > 255 || !unicode) { free(unicode); errno = EINVAL; return NULL; }
    for (int i = 0; i < count; i++) {
        if (unicode[i] == const_cpu_to_le16(':')) unicode[i] = const_cpu_to_le16(NK_SFM_COLON);
        else if (unicode[i] == const_cpu_to_le16('/')) unicode[i] = const_cpu_to_le16(NK_SFM_SLASH);
    }
    *length = count;
    return unicode;
}
/* The file by path, or by reference when `path` is NULL (no walk from the root). */
static ntfs_inode *open_target(nk_volume *v, const char *path, uint64_t reference) {
    return path ? path_inode(v, path) : open_reference(v, reference);
}

static int xattr_list(nk_volume *v, const char *path, uint64_t reference, nk_name_cb cb, void *ctx) {
    if (!v || !cb) { errno = EINVAL; return -1; }
    ntfs_inode *ni = open_target(v, path, reference);
    if (!ni) return -1;
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL) || !(mode & 0400)) { ntfs_inode_close(ni); errno = EIO; return -1; }
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) { ntfs_inode_close(ni); return -1; }
    int error = 0;
    for (;;) {
        if (ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
            if (errno != ENOENT) error = errno ? errno : EIO;
            break;
        }
        ATTR_RECORD *attr = search->attr;
        if (!attr->name_length) continue;
        unsigned int offset = le16_to_cpu(attr->name_offset);
        unsigned int bytes = attr->name_length * sizeof(ntfschar);
        if (offset > le32_to_cpu(attr->length) || bytes > le32_to_cpu(attr->length) - offset) { error = EIO; break; }
        if (mac_mode_reserved(v->vol, (ntfschar *)((char *)attr + offset), attr->name_length)) continue;
        ntfschar mapped[255];
        if (attr->name_length > 255) { error = EIO; break; }
        memcpy(mapped, (char *)attr + offset, bytes);
        for (int i = 0; i < attr->name_length; i++) {
            if (mapped[i] == const_cpu_to_le16(NK_SFM_COLON)) mapped[i] = const_cpu_to_le16(':');
            else if (mapped[i] == const_cpu_to_le16(NK_SFM_SLASH)) mapped[i] = const_cpu_to_le16('/');
        }
        char *name = NULL;
        if (ntfs_ucstombs(mapped, attr->name_length, &name, 0) < 0 || !name) {
            error = EILSEQ; free(name); break;
        }
        int stop = cb(ctx, name); free(name);
        if (stop) break;
    }
    ntfs_attr_put_search_ctx(search);
    if (ntfs_inode_close(ni)) error = EIO;
    if (v->devctx->failed) error = EIO;
    if (error) { errno = error; return -1; }
    return 0;
}
int nk_xattr_list(nk_volume *v, const char *path, nk_name_cb cb, void *ctx) {
    if (!path) { errno = EINVAL; return -1; }
    return xattr_list(v, path, 0, cb, ctx);
}
int nk_xattr_list_reference(nk_volume *v, uint64_t reference, nk_name_cb cb, void *ctx) {
    return xattr_list(v, NULL, reference, cb, ctx);
}

static long long xattr_get(nk_volume *v, const char *path, uint64_t reference, const char *name, void *buf, long long size) {
    if (!v || size < 0) { errno = EINVAL; return -1; }
    int length; ntfschar *unicode = xattr_name(name, &length);
    if (!unicode) return -1;
    ntfs_inode *ni = open_target(v, path, reference);
    if (!ni) { free(unicode); return -1; }
    uint32_t mode;
    if (mac_mode_read(ni, &mode, NULL) || !(mode & 0400)) { ntfs_inode_close(ni); free(unicode); errno = EIO; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int error = na ? 0 : (errno == ENOENT ? ENOATTR : errno);
    long long result = -1;
    if (na) {
        if (na->data_flags & (ATTR_IS_ENCRYPTED | ATTR_IS_COMPRESSED)) error = ENOTSUP;
        else if (na->data_size < 0 || na->data_size > NK_XATTR_LIMIT) error = E2BIG;
        else if (!buf) result = na->data_size;
        else if (size < na->data_size) error = ERANGE;
        else { result = ntfs_attr_pread(na, 0, na->data_size, buf); if (result != na->data_size) error = EIO; }
        ntfs_attr_close(na);
    }
    if (ntfs_inode_close(ni)) error = EIO;
    free(unicode);
    if (error) { errno = error; return -1; }
    return result;
}
long long nk_xattr_get(nk_volume *v, const char *path, const char *name, void *buf, long long size) {
    if (!path) { errno = EINVAL; return -1; }
    return xattr_get(v, path, 0, name, buf, size);
}
long long nk_xattr_get_reference(nk_volume *v, uint64_t reference, const char *name, void *buf, long long size) {
    return xattr_get(v, NULL, reference, name, buf, size);
}

int nk_xattr_set(nk_volume *v, const char *path, const char *name, const void *buf, long long size, int policy) {
    if (require_writable(v)) return -1;
    if (!path || size < 0 || size > NK_XATTR_LIMIT || (size && !buf) || policy < 0 || policy > 2) {
        errno = size > NK_XATTR_LIMIT ? E2BIG : EINVAL; return -1;
    }
    int length; ntfschar *unicode = xattr_name(name, &length);
    if (!unicode) return -1;
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) { free(unicode); return -1; }
    if (!writable_inode(ni)) { ntfs_inode_close(ni); free(unicode); return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int error = 0;
    if (na && policy == NK_XATTR_CREATE) error = EEXIST;
    if (!na) error = errno == ENOENT ? (policy == NK_XATTR_REPLACE ? ENOATTR : 0) : errno;
    if (na && na->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED)) error = ENOTSUP;
    if (error) {
        if (na) ntfs_attr_close(na);
        ntfs_inode_close(ni); free(unicode); errno = error; return -1;
    }
    int result;
    if (na) {
        result = (size && ntfs_attr_pwrite(na, 0, size, buf) != size) ? -1 : ntfs_attr_truncate(na, size);
        error = result ? errno : 0;
        ntfs_attr_close(na);
    } else {
        result = ntfs_attr_add(ni, AT_DATA, unicode, length, (u8 *)(size ? buf : (const void *)""), size);
        error = result ? errno : 0;
    }
    if (ntfs_inode_close(ni)) { result = -1; error = EIO; }
    free(unicode);
    return mutation_result(v, result, error);
}
int nk_xattr_remove(nk_volume *v, const char *path, const char *name) {
    if (require_writable(v)) return -1;
    if (!path) { errno = EINVAL; return -1; }
    int length; ntfschar *unicode = xattr_name(name, &length);
    if (!unicode) return -1;
    ntfs_inode *ni = path_inode(v, path);
    if (!ni) { free(unicode); return -1; }
    if (!writable_inode(ni)) { ntfs_inode_close(ni); free(unicode); return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, unicode, length); free(unicode);
    if (!na) { int error = errno == ENOENT ? ENOATTR : errno; ntfs_inode_close(ni); errno = error; return -1; }
    int result = ntfs_attr_rm(na);
    int error = result ? errno : 0;
    ntfs_attr_close(na);
    if (ntfs_inode_close(ni)) { result = -1; error = EIO; }
    return mutation_result(v, result, error);
}

/* Inspection never owns a writable callback context: the copied descriptor
 * is read-only at both the NTFS device and callback adapter boundaries. */
static int inspect_volume(nk_volume *v) {
    int status = NK_CHECK_CLEAN;
    if (v->vol->flags & VOLUME_IS_DIRTY) status = NK_CHECK_DIRTY;
    else if (ntfs_volume_check_hiberfile(v->vol, 0) < 0) status = NK_CHECK_HIBERNATED;
    else {
        ntfs_inode *ni = ntfs_inode_open(v->vol, FILE_LogFile);
        ntfs_attr *na = ni ? ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0) : NULL;
        RESTART_PAGE_HEADER *rp = NULL;
        if (!na || !ntfs_check_logfile(na, &rp) || !ntfs_is_logfile_clean(na, rp)) status = NK_CHECK_LOG_UNSAFE;
        if (rp && rp->major_ver == const_cpu_to_le16(2) && rp->minor_ver == const_cpu_to_le16(0)) status = NK_CHECK_LOG_UNSAFE;
        free(rp);
        if (na) ntfs_attr_close(na);
        if (ni && ntfs_inode_close(ni)) status = NK_CHECK_UNKNOWN;
    }
    return status;
}
/* ---- format (mkntfs from NTFS-3G ntfsprogs, patched to take this device;
 * see packages/VolisleNTFS/patches/mkntfs-external-device.patch) ---- */
/* Only the root helper's engine and the test library build this
 * (NK_WITH_FORMAT): formatting and clearing the "needs check" marker. The file
 * system extension carries neither. */
#ifdef NK_WITH_FORMAT
extern int nk_mkntfs_main(int argc, char *argv[]);
extern struct ntfs_device *nk_mkntfs_external_dev;
extern int nk_mkntfs_dev_consumed;

int nk_format(const nk_io *io, const char *label, int sector_size, char *errbuf, size_t errlen) {
    if (errbuf && errlen) errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 ||
        (sector_size && (sector_size < 512 || sector_size > 4096 || (sector_size & (sector_size - 1))))) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "invalid format target");
        errno = EINVAL; return -1;
    }
    /* Windows accepts at most 32 UTF-16 units for an NTFS label; refuse
     * rather than let mkntfs store a name Windows would cut short. */
    if (label && *label) {
        ntfschar *ucs = NULL;
        int units = ntfs_mbstoucs(label, &ucs);
        free(ucs);
        if (units <= 0 || units > 32) {
            if (errbuf && errlen) snprintf(errbuf, errlen, "invalid volume name");
            errno = EINVAL; return -1;
        }
    }
    struct nk_devctx *c = calloc(1, sizeof(*c));
    if (!c) return -1;
    c->io = *io;
    struct ntfs_device *dev = ntfs_device_alloc("fskit-format", 0, &nk_dev_ops, c);
    if (!dev) { free(c); return -1; }
    char sectors[16];
    snprintf(sectors, sizeof(sectors), "%d", sector_size ? sector_size : 512);
    /* getopt state is process-global: reset it or a second run misparses. */
    optind = 1; optreset = 1;
    nk_mkntfs_external_dev = dev;
    nk_mkntfs_dev_consumed = 0;
    char *argv[] = { "mkntfs", "--force", "--quick", "--quiet", "-s", sectors,
                     "-L", (char *)(label && *label ? label : "NTFS"), "fskit-format", NULL };
    int rc = nk_mkntfs_main(9, argv);
    nk_mkntfs_external_dev = NULL;
    /* mkntfs frees the device during cleanup only once it took ownership. */
    if (!nk_mkntfs_dev_consumed) ntfs_device_free(dev);
    int failed = c->failed;
    free(c);
    if (rc != 0 || failed) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "mkntfs failed (rc=%d%s)", rc, failed ? ", I/O error" : "");
        errno = EIO; return -1;
    }
    if (io->sync(io->ctx) != 0) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "flush after format failed");
        errno = EIO; return -1;
    }
    int status = nk_inspect(io);
    if (status != NK_CHECK_CLEAN) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "formatted volume did not verify (status %d)", status);
        errno = EIO; return -1;
    }
    return 0;
}
#include "check_marker.inc"
#include "windows_log.inc"
#endif /* NK_WITH_FORMAT */

#include "bitlocker.inc"

int nk_inspect(const nk_io *io) {
    if (!io || !io->pread || io->size < 512) return NK_CHECK_UNKNOWN;
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) return NK_CHECK_UNKNOWN;
    int status = inspect_volume(v);
    if (release_volume(v)) status = NK_CHECK_UNKNOWN;
    return status;
}

/* Read-only facts for the host write journal. The $LogFile head is only a
 * location: Windows rewrites its restart pages when it mounts the volume,
 * while this bridge (forensic mode) never writes $LogFile. */
int nk_volume_state(const nk_io *io, uint16_t *flags, long long *logfile_offset,
                    long long *logfile_length) {
    if (!io || !io->pread || io->size < 512 || !flags || !logfile_offset || !logfile_length) {
        errno = EINVAL; return -1;
    }
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) return -1;
    int r = -1;
    ntfs_inode *ni = ntfs_inode_open(v->vol, FILE_LogFile);
    ntfs_attr *na = ni ? ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0) : NULL;
    if (na && NAttrNonResident(na) && !ntfs_attr_map_whole_runlist(na) &&
        na->rl && na->rl[0].lcn >= 0 && na->rl[0].length > 0) {
        s64 bytes = na->rl[0].length << v->vol->cluster_size_bits;
        *flags = le16_to_cpu(v->vol->flags);
        *logfile_offset = (long long)(na->rl[0].lcn << v->vol->cluster_size_bits);
        *logfile_length = (long long)(bytes < 8192 ? bytes : 8192);
        r = 0;
    }
    if (na) ntfs_attr_close(na);
    if (ni && ntfs_inode_close(ni)) r = -1;
    if (release_volume(v)) r = -1;
    if (r) errno = EIO;
    return r;
}

int nk_bitmap_layout(nk_volume *v, long long *cluster_size, long long *clusters,
                     nk_extent *runs, size_t capacity, size_t *count) {
    if (!v || !v->vol || !cluster_size || !clusters || !count || (!runs && capacity)) { errno = EINVAL; return -1; }
    ntfs_volume *vol = v->vol;
    ntfs_attr *na = vol->lcnbmp_na;
    if (!na || !NAttrNonResident(na) || ntfs_attr_map_whole_runlist(na) || !na->rl) { errno = EIO; return -1; }
    s64 need = (vol->nr_clusters + 7) / 8, covered = 0;
    size_t n = 0;
    for (const runlist_element *rl = na->rl; rl->length && covered < need; rl++) {
        /* A sparse or out-of-order run would make the layout meaningless. */
        if (rl->lcn < 0 || (rl->vcn << vol->cluster_size_bits) != covered) { errno = EIO; return -1; }
        s64 bytes = rl->length << vol->cluster_size_bits;
        if (bytes > need - covered) bytes = need - covered;
        if (n >= capacity) { errno = ENOSPC; return -1; }
        runs[n].offset = (long long)(rl->lcn << vol->cluster_size_bits);
        runs[n].length = (long long)bytes;
        n++; covered += bytes;
    }
    if (covered != need) { errno = EIO; return -1; }
    *cluster_size = (long long)vol->cluster_size;
    *clusters = (long long)vol->nr_clusters;
    *count = n;
    return 0;
}

/* Same ownership rule as nk_umount: only the exact marker this host set on
 * a volume that was clean, with an unchanged boot sector, is removed. */
int nk_release_owned_marker(const nk_io *io, uint16_t initial_flags,
                            const unsigned char identity[512]) {
    if (!io || io->readonly || !io->pwrite || !io->sync || !identity ||
        (initial_flags & le16_to_cpu(VOLUME_IS_DIRTY))) { errno = EINVAL; return -1; }
    if (clear_owned_marker(io, cpu_to_le16(initial_flags), identity)) { errno = EIO; return -1; }
    return 0;
}

nk_volume *nk_mount_io(const nk_io *io, char *errbuf, size_t errlen) {
    if (!io || !io->pread || io->size < 512 || (!io->readonly && (!io->pwrite || !io->sync))) {
        errno = EINVAL; return NULL;
    }
    if (!io->readonly) {
        int status = nk_inspect(io);
        if (status != NK_CHECK_CLEAN) {
            if (errbuf && errlen) snprintf(errbuf, errlen, "unsafe NTFS state (%d)", status);
            errno = EPERM; return NULL;
        }
    }
    nk_volume *v = mount_unchecked(io, errbuf, errlen);
    if (!v || io->readonly) return v;
    /* Forensic open does not repair metadata. Inspect the newly opened handle
     * again before writing the owned marker, then make that marker durable. */
    if (inspect_volume(v) != NK_CHECK_CLEAN ||
        nkdev_pread(v->vol->dev, v->boot_identity, 512, 0) != 512) {
        release_volume(v); errno = EPERM; return NULL;
    }
    v->initial_flags = v->vol->flags;
    if (write_volume_flags(v->vol, v->initial_flags | VOLUME_IS_DIRTY) ||
        nkdev_sync(v->vol->dev)) {
        v->devctx->failed = 1;
        release_volume(v); errno = EIO; return NULL;
    }
    v->owns_dirty = 1;
    return v;
}
const char *nk_engine_version(void) { return "ntfs-3g 2026.7.7 / Volisle bridge 2"; }
