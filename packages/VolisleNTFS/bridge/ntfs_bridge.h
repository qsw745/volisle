/*
 * ntfs_bridge — thin C facade over libntfs-3g for the ntfskit FSKit module.
 *
 * UTF-8 path-based operations: mount, stat, list, read, write, create, mkdir,
 * delete, rename, truncate. One nk_volume* per mounted NTFS volume. Not
 * thread-safe — callers must serialize (the Swift side uses one queue).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef NTFS_BRIDGE_H
#define NTFS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nk_volume nk_volume;

typedef struct {
    const char *name;      /* UTF-8, valid only during the callback */
    int         is_dir;
    long long   size;      /* always 0: listing does not open each entry */
    uint64_t    inode;     /* MFT record number — stable item id */
    int         is_symlink; /* Interix or reparse-point symbolic link */
    uint64_t    reference; /* MFT number and sequence, as nk_reference_path returns */
} nk_dirent;

/* Return 0 to continue, non-zero to stop enumeration early. */
typedef int (*nk_dirent_cb)(void *ctx, const nk_dirent *entry);

typedef struct {
    int       is_dir;
    long long size;        /* data size in bytes */
    long long alloc_size;  /* allocated bytes on disk */
    uint64_t  inode;       /* MFT record number */
    long long atime, mtime, ctime, btime;  /* unix epoch seconds */
    int       is_symlink;  /* NTFS reparse point (Interix symlink style) */
    int       koio_ok;     /* 1 = data is plain non-resident: kernel may map it */
    int       is_resident; /* data lives in the MFT record (small/new file) */
    int       atime_nsec, mtime_nsec, ctime_nsec, btime_nsec;
    uint32_t  mac_mode;    /* mount-local Mac permissions; never a Windows ACL */
    uint32_t  file_flags;  /* NTFS FILE_ATTRIBUTE_*; not a POSIX ACL */
} nk_stat;

typedef struct {
    long long seconds;
    int nanoseconds; /* POSIX [0, 1e9); persisted at NTFS 100 ns precision */
} nk_timestamp;

/* Callback-backed block I/O — lets the FSKit host route every device access
 * through FSBlockDeviceResource (the sandbox forbids opening /dev directly).
 * Callbacks return bytes transferred, or -1 on error. */
typedef long long (*nk_pread_cb)(void *ctx, void *buf, long long count,
                                 long long offset);
typedef long long (*nk_pwrite_cb)(void *ctx, const void *buf, long long count,
                                  long long offset);

typedef struct {
    void        *ctx;
    nk_pread_cb  pread;
    nk_pwrite_cb pwrite;
    long long    size;      /* device size in bytes */
    int          readonly;
    int        (*sync)(void *ctx); /* durable flush; mandatory for writes */
} nk_io;

/* Mount through the callback device. `io` is copied; `io->ctx` must stay
 * valid until nk_umount. */
nk_volume *nk_mount_io(const nk_io *io, char *errbuf, size_t errlen);

/* Flush and release. ALWAYS consumes v, including on error. Only a clean
 * session clears its own dirty marker after all metadata is closed/synced. */
int nk_umount(nk_volume *v);

/* Volume totals for statfs. Any out-pointer may be NULL. */
int nk_statvfs(nk_volume *v, long long *total_bytes, long long *free_bytes,
               int *cluster_size);

/* Volume label (UTF-8) into buf. Returns 0 on success. */
int nk_label(nk_volume *v, char *buf, size_t buflen);

int nk_stat_path(nk_volume *v, const char *path, nk_stat *st);
/* References include the 48-bit MFT number AND the 16-bit sequence number.
 * Scoped to this mounted volume; never transfer across volumes or retain
 * after unmount. They do not pin an unlinked inode. Callers must retain a
 * backing name until their last open object is reclaimed. Zero sequence is
 * rejected, and cached inodes are explicitly checked for stale references. */
int nk_reference_path(nk_volume *v, const char *path, uint64_t *reference);
int nk_stat_reference(nk_volume *v, uint64_t reference, nk_stat *st);
/* Looks `name` up inside directory `dir_reference` (no walk from the root):
 * its reference and stat. Names match as with paths (any spelling). */
int nk_lookup_reference(nk_volume *v, uint64_t dir_reference, const char *name,
                        uint64_t *reference, nk_stat *st);
long long nk_read_reference(nk_volume *v, uint64_t reference, long long offset,
                            long long count, void *buf);
long long nk_write_reference(nk_volume *v, uint64_t reference, long long offset,
                             long long count, const void *buf);
int nk_list(nk_volume *v, const char *dir_path, nk_dirent_cb cb, void *ctx);

long long nk_read(nk_volume *v, const char *path, long long offset,
                  long long count, void *buf);
long long nk_write(nk_volume *v, const char *path, long long offset,
                   long long count, const void *buf);

/* Only regular-file 0444/0644: toggles Windows READONLY, preserves security. */
int nk_set_file_mode(nk_volume *v, const char *path, uint32_t mode);
/* Set or clear the Windows HIDDEN attribute (Finder's hidden flag). Not on the root. */
int nk_set_hidden(nk_volume *v, const char *path, int hidden);
/* Experimental writers; default builds reject. Readers always fail closed. */
int nk_set_mac_mode(nk_volume *v, const char *path, uint32_t mode);
int nk_create_mode(nk_volume *v, const char *dir_path, const char *name, uint32_t mode, int is_dir);
/* Give to_path the complete Windows security descriptor of from_path. */
int nk_copy_security(nk_volume *v, const char *from_path, const char *to_path);
int nk_create(nk_volume *v, const char *dir_path, const char *name);  /* file */
int nk_mkdir(nk_volume *v, const char *dir_path, const char *name);
int nk_delete(nk_volume *v, const char *path);   /* file or empty dir */
/* Does not replace existing destinations. Mutation failure may leave both
 * names, or only the destination; error is reported and session stays dirty.
 * New link is synced before old name removal; not crash-atomic. */
int nk_rename(nk_volume *v, const char *old_path, const char *new_dir,
              const char *new_name);
/* Experimental replacement primitive, NOT POSIX rename: regular files in
 * one directory only. On success source is published at target and the old
 * target remains at backup. Caller must durably record a recovery plan before
 * calling; no automatic cleanup or recovery is performed here. Not atomic.
 * All names must be distinct, backup absent, files supported/single-link.
 * On mutation failure preserve every remaining name and lock the session.
 * Only enabled by NK_EXPERIMENTAL_REPLACEMENT for 64 MiB callback volumes;
 * otherwise ENOTSUP. FSKit builds never define that development-only macro.
 * Not connected to FSKit replacement/open-handle operations. */
int nk_replace_between(nk_volume *v, const char *source_dir, const char *source,
                       const char *target_dir, const char *target, const char *backup);
int nk_replace_preserving(nk_volume *v, const char *dir_path,
                          const char *source, const char *target,
                          const char *backup);
int nk_truncate(nk_volume *v, const char *path, long long size);
/* Flush held volume metadata before the durable device barrier. A failure
 * locks the write session; success retains its dirty marker. Does not make
 * a mutation crash-atomic or authorize recovery of an unclean volume. */
int nk_sync(nk_volume *v);
/* Host recovery metadata failed after an attempted mutation. Permanently
 * stop writes and prevent clean unmount from clearing this session's dirty
 * marker. Idempotent; NULL/read-only volumes are unchanged. */
void nk_abort_write_session(nk_volume *v);

/* Set POSIX times (seconds since epoch); pass -1 to leave a field unchanged. */
int nk_set_times(nk_volume *v, const char *path, long long atime,
                 long long mtime, long long btime);
/* NULL leaves that field unchanged. Validates every field before mutation. */
int nk_set_times_precise(nk_volume *v, const char *path,
                         const nk_timestamp *atime, const nk_timestamp *mtime,
                         const nk_timestamp *btime);

/* Read a symlink target (UTF-8) into buf. Returns 0 / -1. */
int nk_readlink(nk_volume *v, const char *path, char *buf, size_t buflen);

/* Longest symlink target accepted, in UTF-8 bytes (macOS PATH_MAX - 1). */
#define NK_SYMLINK_TARGET_MAX 1023
/* Create an Interix symlink `name` in `dir_path` pointing at `target`, stored
 * verbatim. Name conflicts fail with EEXIST without locking the session.
 * Returns 0 / -1 with errno. */
int nk_create_symlink(nk_volume *v, const char *dir_path, const char *name,
                      const char *target);

/* Volume dirty flag (unclean Windows shutdown). Returns 1 dirty, 0 clean, -1 err. */
int nk_is_dirty(nk_volume *v);


enum { NK_CHECK_CLEAN = 0, NK_CHECK_DIRTY = 1, NK_CHECK_HIBERNATED = 2,
       NK_CHECK_LOG_UNSAFE = 3, NK_CHECK_UNKNOWN = 4 };
int nk_inspect(const nk_io *io);
/* Named NTFS streams for xattrs; 4 MiB maximum per value. No silent short
 * reads. Host serializes every call on this volume, including policy checks. */
typedef int (*nk_name_cb)(void *ctx, const char *name);
enum { NK_XATTR_UPSERT = 0, NK_XATTR_CREATE = 1, NK_XATTR_REPLACE = 2 };
int nk_xattr_list(nk_volume *v, const char *path, nk_name_cb cb, void *ctx);
/* As nk_xattr_list / nk_xattr_get, for the file `reference` names (no walk from the root). */
int nk_xattr_list_reference(nk_volume *v, uint64_t reference, nk_name_cb cb, void *ctx);
long long nk_xattr_get_reference(nk_volume *v, uint64_t reference, const char *name, void *buf, long long size);
long long nk_xattr_get(nk_volume *v, const char *path, const char *name, void *buf, long long size);
int nk_xattr_set(nk_volume *v, const char *path, const char *name, const void *buf, long long size, int policy);
int nk_xattr_remove(nk_volume *v, const char *path, const char *name);
/* Host write journal support. nk_volume_state is read-only. The release
 * requires flags == initial|DIRTY and an identical boot sector; otherwise it
 * fails without changing the volume. When the initial word has bits NTFS-3G
 * does not know (Windows 11 sets 0x0080), the masked marker that versions up to
 * 0.5.7 wrote ((initial|DIRTY) & 0xc03f) is also released, back to initial. */
int nk_volume_state(const nk_io *io, uint16_t *flags, long long *logfile_offset,
                    long long *logfile_length);
int nk_release_owned_marker(const nk_io *io, uint16_t initial_flags,
                            const unsigned char identity[512]);
/* Where the cluster bitmap ($Bitmap data) lies on the device, in bitmap byte
 * order: runs[i] covers the next `length` bitmap bytes starting at device byte
 * `offset`; together exactly (clusters + 7) / 8 bytes. A host journal uses it
 * to tell which blocks were free at its last checkpoint. ENOSPC: more runs
 * than `capacity`. 0 / -1. */
typedef struct { long long offset; long long length; } nk_extent;
int nk_bitmap_layout(nk_volume *v, long long *cluster_size, long long *clusters,
                     nk_extent *runs, size_t capacity, size_t *count);
/* Quick-format the whole device behind `io` as NTFS (mkntfs -Q), flush it,
 * then require a read-only inspection to report NK_CHECK_CLEAN. `label` is
 * UTF-8, at most 32 UTF-16 units as in Windows (longer is EINVAL); `sector_size` is the
 * device's logical block size (0 = 512). Destroys every byte of metadata on
 * the device. Not thread-safe (mkntfs keeps process-global state). 0 / -1. */
int nk_format(const nk_io *io, const char *label, int sector_size, char *errbuf, size_t errlen);

/* ---- BitLocker (read-only) ----
 * nk_bde_probe: 1 if the device carries a BitLocker volume header, 0 if not.
 * nk_bde_open: unlocks with a password or 48-digit recovery password. errno:
 * EACCES wrong or malformed secret, ENOTSUP unsupported (Vista, Elephant
 * Diffuser, not fully encrypted, no such protector), EIO, EINVAL. The secret is
 * not retained. nk_bde_io: the decrypted view, same size; writable (writes
 * encrypted in place, reserved BitLocker regions refused with EIO) only when
 * the device under it has pwrite and sync and is not read-only. Valid until
 * nk_bde_close, which wipes the keys.
 * NK_BDE_KEY: the secret is the volume master key as 64 lowercase hex digits,
 * as produced by nk_bde_derive_key (EACCES if it does not belong to the volume).
 * nk_bde_derive_key: unlocks with a password or recovery password and writes
 * that key, so a privileged process can hand the mount a key rather than the
 * user's secret. 0 / -1 with errno as nk_bde_open. */
typedef struct nk_bde nk_bde;
enum { NK_BDE_PASSWORD = 1, NK_BDE_RECOVERY = 2, NK_BDE_KEY = 3 };
int nk_bde_probe(const nk_io *io);
nk_bde *nk_bde_open(const nk_io *io, int kind, const char *secret, char *errbuf, size_t errlen);
int nk_bde_derive_key(const nk_io *io, int kind, const char *secret, char hex_out[65], char *errbuf, size_t errlen);
nk_io nk_bde_io(nk_bde *b);
void nk_bde_close(nk_bde *b);

/* Root helper only. For a volume marked "needs check" (dirty) and nothing
 * else: refuses hibernated volumes and unclean logs, walks every directory and
 * file record read-only and maps every data runlist; only if all of that
 * succeeds, clears the dirty flag and verifies the volume inspects clean.
 * `items` receives the number of files and folders checked. Not chkdsk.
 * errno: EALREADY not marked, EBUSY hibernated or log not clean, EIO a check
 * or write failed (the disk is left unchanged if the check failed). */
int nk_clear_check_marker(const nk_io *io, long long *items, char *errbuf, size_t errlen);

/* Root helper only. A disk Windows let go of without Safe Removal: its log
 * still says "in use". Examine is read-only: the flags below, and whether
 * NTFS-3G's ntfsrecover can replay the log (simulated, counting actions). */
typedef struct nk_windows_log {
    int dirty;                /* "needs check" flag set */
    int maintenance_pending;  /* chkdsk cut off, log resize, upgrade... */
    int hibernated;           /* hiberfil.sys on this volume says hibernated */
    int log_readable;
    int log_clean;            /* clean and not a version 2.0 restart page */
    int log_major, log_minor;
    int replay_simulated;     /* the simulated replay ran without error */
    long long redo_actions;   /* committed actions it would write into place */
    char note[256];           /* ntfsrecover's last status lines, for the log */
    /* When the replay cannot run: the read-only check that discarding needs. */
    int discard_checked;      /* the check ran */
    int discard_ok;           /* every record reachable, nothing in use marked free */
    long long checked_items;  /* files and folders it checked */
    char discard_reason[128]; /* why it did not pass */
    long long held_bytes;     /* marked used but mapped by no record (a leak) */
} nk_windows_log;
int nk_windows_log_examine(const nk_io *io, nk_windows_log *out, char *errbuf, size_t errlen);
/* Examines again, refuses anything but "log not clean" (errno EBUSY with the
 * reason; EALREADY when already clean), replays the log as Windows would on
 * its next mount, then requires the volume to inspect clean and every record
 * to open and map (`items` counts them). On EIO the disk was written: the
 * host restores it from its own before-images. */
int nk_windows_log_recover(const nk_io *io, nk_windows_log *before, long long *items, char *errbuf, size_t errlen);
/* When the log cannot be replayed (ntfsrecover stops): requires everything
 * already to hold together without it (every record reachable, nothing in use
 * marked free), then resets the log to empty as NTFS-3G does by default,
 * giving up what Windows had not written into place. Refuses a log that
 * replays (EBUSY "replay possible"). On EIO after the reset the host restores
 * the disk from its before-images. */
int nk_windows_log_discard(const nk_io *io, nk_windows_log *before, long long *items, char *errbuf, size_t errlen);
const char *nk_engine_version(void);
#ifdef __cplusplus
}
#endif
#endif
