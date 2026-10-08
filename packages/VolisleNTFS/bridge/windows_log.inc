/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Mac-side answer for a disk Windows let go of without Safe Removal: its
 * $LogFile still says "in use" and may hold committed changes Windows had not
 * written into place yet. Windows itself replays them the next time it mounts
 * the disk; this does the same with NTFS-3G's ntfsrecover (playlog.c), then
 * checks every record as "Check on This Mac" does. Included by ntfs_bridge.c
 * in the root helper's build only (NK_WITH_FORMAT), after check_marker.inc.
 *
 * The disk alone cannot tell an unplug from Windows' fast startup or
 * hibernation with the disk attached (both leave a version 2.0 restart page;
 * NTFS-3G says the same). The App asks the user which one happened; this file
 * only refuses everything that is plainly something else: a "needs check"
 * flag, Windows maintenance pending, a hibernation file, an unreadable log, or
 * a replay that fails in simulation.
 */

extern int nk_ntfsrecover_main(int argc, char *argv[]);
extern struct ntfs_device *nk_recover_external_dev;
extern int nk_recover_dev_consumed;
extern unsigned int nk_recover_redo_actions;
extern int nk_recover_log_major, nk_recover_log_minor;

/* ntfsrecover reports on stdout and stderr: keep its status lines ("* ...",
 * "** ...": counts, block numbers, no names) as the reason a run failed. */
static void keep_status_lines(FILE *capture, char *note, size_t size) {
    if (!note || !size) return;
    note[0] = 0;
    long end = ftell(capture);
    if (end <= 0) return;
    long start = end > 16384 ? end - 16384 : 0;
    char *text = calloc(1, (size_t)(end - start) + 1);
    if (!text) return;
    fseek(capture, start, SEEK_SET);
    size_t got = fread(text, 1, (size_t)(end - start), capture);
    text[got] = 0;
    const char *lines[3] = { NULL, NULL, NULL };
    for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) {
        if (line[0] != '*') continue;
        lines[0] = lines[1]; lines[1] = lines[2]; lines[2] = line;
    }
    for (int i = 0; i < 3; i++) {
        if (!lines[i]) continue;
        size_t used = strlen(note);
        snprintf(note + used, size - used, "%s%s", used ? " | " : "", lines[i]);
    }
    free(text);
}

/* One ntfsrecover run on the host device: a simulation (read-only device) or
 * the real replay, which also marks the log clean. Returns 0 when it ran to
 * the end without error; *redo receives the actions it played. */
static int run_ntfsrecover(const nk_io *io, int apply, unsigned *redo, char *note, size_t note_size) {
    struct nk_devctx *c = calloc(1, sizeof(*c));
    if (!c) return -1;
    c->io = *io;
    if (!apply) c->io.readonly = 1;
    struct ntfs_device *dev = ntfs_device_alloc("volisle-log", 0, &nk_dev_ops, c);
    if (!dev) { free(c); return -1; }
    /* getopt state is process-global: reset it or a second run misparses. */
    optind = 1; optreset = 1;
    nk_recover_external_dev = dev;
    /* -k: a version 2.0 restart page is read even though it may be fast
     * startup; the user has already said Windows was running when unplugged. */
    char *simulate[] = { "ntfsrecover", "-n", "-k", "-s", "volisle-log", NULL };
    char *apply_argv[] = { "ntfsrecover", "-k", "-s", "volisle-log", NULL };
    /* The helper holds its maintenance lock: nothing else prints meanwhile. */
    fflush(stdout); fflush(stderr);
    FILE *capture = tmpfile();
    int saved_out = capture ? dup(STDOUT_FILENO) : -1, saved_err = capture ? dup(STDERR_FILENO) : -1;
    if (capture && saved_out >= 0 && saved_err >= 0) {
        dup2(fileno(capture), STDOUT_FILENO); dup2(fileno(capture), STDERR_FILENO);
    }
    int rc = apply ? nk_ntfsrecover_main(4, apply_argv) : nk_ntfsrecover_main(5, simulate);
    fflush(stdout); fflush(stderr);
    if (saved_out >= 0) { dup2(saved_out, STDOUT_FILENO); close(saved_out); }
    if (saved_err >= 0) { dup2(saved_err, STDERR_FILENO); close(saved_err); }
    if (capture) { keep_status_lines(capture, note, note_size); fclose(capture); }
    nk_recover_external_dev = NULL;
    /* ntfsrecover installs a stdout handler; libntfs-3g stays quiet otherwise. */
    ntfs_log_set_handler(ntfs_log_handler_null);
    /* The volume frees the device on unmount only once the mount took it. */
    if (!nk_recover_dev_consumed) ntfs_device_free(dev);
    int failed = c->failed;
    free(c);
    if (redo) *redo = nk_recover_redo_actions;
    return rc != 0 || failed ? -1 : 0;
}

int nk_windows_log_examine(const nk_io *io, nk_windows_log *out, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !out || io->size < 1024 * 1024) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    memset(out, 0, sizeof(*out));
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be read"); errno = EIO; return -1; }
    ntfs_volume *vol = v->vol;
    const le16 pending = VOLUME_RESIZE_LOG_FILE | VOLUME_UPGRADE_ON_MOUNT | VOLUME_DELETE_USN_UNDERWAY |
                         VOLUME_REPAIR_OBJECT_ID | VOLUME_CHKDSK_UNDERWAY;
    out->dirty = !!(vol->flags & VOLUME_IS_DIRTY);
    out->maintenance_pending = !!(vol->flags & pending);
    /* Unreadable counts as hibernated, as "Check on This Mac" treats it. */
    out->hibernated = ntfs_volume_check_hiberfile(vol, 0) < 0;
    ntfs_inode *ni = ntfs_inode_open(vol, FILE_LogFile);
    ntfs_attr *na = ni ? ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0) : NULL;
    RESTART_PAGE_HEADER *rp = NULL;
    if (na && ntfs_check_logfile(na, &rp) && rp) {
        out->log_readable = 1;
        out->log_major = le16_to_cpu(rp->major_ver);
        out->log_minor = le16_to_cpu(rp->minor_ver);
        out->log_clean = ntfs_is_logfile_clean(na, rp) && !(out->log_major == 2 && out->log_minor == 0);
    }
    free(rp);
    if (na) ntfs_attr_close(na);
    if (ni) ntfs_inode_close(ni);
    int read_failed = v->devctx->failed;
    if (release_volume(v) || read_failed) {
        snprintf(errbuf, errlen, "read failed"); errno = EIO; return -1;
    }
    if (out->log_readable && !out->log_clean && !out->hibernated && !out->maintenance_pending) {
        unsigned redo = 0;
        out->replay_simulated = run_ntfsrecover(io, 0, &redo, out->note, sizeof(out->note)) == 0;
        out->redo_actions = redo;
    }
    /* No replay: show what giving the log up would rest on before anyone asks for it. */
    if (!out->log_clean && !out->replay_simulated && !out->hibernated && !out->maintenance_pending && !out->dirty) {
        long long items = 0;
        out->discard_checked = 1;
        long long held = 0;
        out->discard_ok = check_volume_readonly_held(io, CHECK_ALLOW_UNCLEAN_LOG | CHECK_ALLOCATION, &items, &held,
                                                     out->discard_reason, sizeof(out->discard_reason)) == 0;
        out->held_bytes = held;
        out->checked_items = items;
    }
    return 0;
}

/* Why this disk may not be replayed, or NULL. */
static const char *log_refusal(const nk_windows_log *s) {
    if (s->hibernated) return "hibernated";
    if (s->maintenance_pending) return "Windows maintenance pending";
    if (s->dirty) return "marked for check";
    if (!s->log_readable) return "log unreadable";
    if (s->log_clean) return "log already clean";
    if (!s->replay_simulated) return "replay failed in simulation";
    return NULL;
}

int nk_windows_log_recover(const nk_io *io, nk_windows_log *before, long long *items, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 || !before || !items) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    *items = 0;
    /* Examined again here: the App's answer may be minutes old. */
    if (nk_windows_log_examine(io, before, errbuf, errlen)) return -1;
    const char *refusal = log_refusal(before);
    if (refusal) {
        snprintf(errbuf, errlen, "%s", refusal);
        errno = !strcmp(refusal, "log already clean") ? EALREADY : EBUSY;
        return -1;
    }
    unsigned redo = 0;
    if (run_ntfsrecover(io, 1, &redo, before->note, sizeof(before->note)) || io->sync(io->ctx) != 0) {
        snprintf(errbuf, errlen, "replay failed"); errno = EIO; return -1;
    }
    /* Now as after Windows mounted it: log clean, nothing marked. Then every
     * record must open and map, as "Check on This Mac" requires. */
    int state = nk_inspect(io);
    if (state != NK_CHECK_CLEAN) {
        snprintf(errbuf, errlen, "not clean after replay (%d)", state); errno = EIO; return -1;
    }
    if (check_volume_readonly(io, CHECK_ALLOCATION, items, errbuf, errlen)) return -1;
    return 0;
}

int nk_windows_log_discard(const nk_io *io, nk_windows_log *before, long long *items, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 || !before || !items) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    *items = 0;
    if (nk_windows_log_examine(io, before, errbuf, errlen)) return -1;
    const char *refusal = before->hibernated ? "hibernated" : before->maintenance_pending ? "Windows maintenance pending"
                        : before->dirty ? "marked for check" : before->log_clean ? "log already clean"
                        /* A log that replays is replayed, never thrown away. */
                        : before->replay_simulated ? "replay possible" : NULL;
    if (refusal) {
        snprintf(errbuf, errlen, "%s", refusal);
        errno = !strcmp(refusal, "log already clean") ? EALREADY : EBUSY;
        return -1;
    }
    /* Everything must already hold together without what the log still has
     * (records reachable and in use, nothing in use marked free): the
     * examination above ran that check read-only. */
    if (!before->discard_checked || !before->discard_ok) {
        snprintf(errbuf, errlen, "%s", before->discard_reason[0] ? before->discard_reason : "check did not run");
        errno = EIO; return -1;
    }
    *items = before->checked_items;
    /* The only write: the log reset to empty, as NTFS-3G does by default. */
    nk_volume *v = mount_unchecked(io, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be opened"); errno = EIO; return -1; }
    int r = ntfs_logfile_reset(v->vol);
    if (!r) r = nkdev_sync(v->vol->dev);
    if (release_volume(v)) r = -1;
    if (r || io->sync(io->ctx) != 0) { snprintf(errbuf, errlen, "log reset failed"); errno = EIO; return -1; }
    int state = nk_inspect(io);
    if (state != NK_CHECK_CLEAN) {
        snprintf(errbuf, errlen, "not clean after reset (%d)", state); errno = EIO; return -1;
    }
    return 0;
}
