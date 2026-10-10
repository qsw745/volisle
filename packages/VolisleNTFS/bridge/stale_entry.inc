/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Mac-side repair of one kind of damage only: a folder entry whose MFT
 * reference carries an older sequence number than its record has now (a
 * "stale" entry). The record was freed after the entry was written, and
 * perhaps reused by another file or folder; the entry itself no longer opens
 * anything. It is what an index write lost to an unplug leaves behind.
 * Included by ntfs_bridge.c in the root helper's build only (NK_WITH_FORMAT),
 * after check_marker.inc.
 *
 * Only those index entries are removed, with NTFS-3G's own index code
 * (ntfs_index_lookup, ntfs_index_rm), and only where that is a plain removal:
 * a leaf entry, in the folder's INDEX_ROOT or in an index block that keeps
 * other entries. The record an entry names, file contents and every other
 * entry stay as they are; nothing is done about orphaned records. Everything
 * else is left to Windows' chkdsk.
 *
 * Writes: the "needs check" mark set first (when it was not), the index
 * changes, then "Check on This Mac" in full, which clears the mark last. Every
 * state before that last write is marked "needs check", so nothing mounts it
 * for writing; the host saves what each write overwrites and puts it back when
 * the result does not verify, or after an interruption (helper side).
 */

/* The names a stale entry has in its folder (its long and 8.3 names, rarely
 * more), and with `all`, every name of the folder. */
struct folder_name {
    ntfschar *name;
    int len, type;
    u64 ref;
};
struct folder_names {
    u64 only;                   /* collect only names with this reference; 0 = all */
    struct folder_name *names;
    size_t count, capacity;
    int failed;
};

static int folder_names_fill(void *ctx, const ntfschar *name, const int name_len,
                             const int name_type, const s64 pos, const MFT_REF mref,
                             const unsigned dt_type) {
    (void)pos; (void)dt_type;
    struct folder_names *n = ctx;
    if (n->failed || (n->only && (u64)mref != n->only)) return 0;
    /* NTFS-3G lists "." and ".." first; they are not in the index. */
    if (name_len <= 2 && name[0] == const_cpu_to_le16('.') && (name_len == 1 || name[1] == const_cpu_to_le16('.'))) return 0;
    if (name_len <= 0 || name_len > 255) { n->failed = 1; return 0; }
    if (n->count == n->capacity) {
        size_t capacity = n->capacity ? n->capacity * 2 : 16;
        struct folder_name *grown = realloc(n->names, capacity * sizeof(*grown));
        if (!grown) { n->failed = 1; return 0; }
        n->names = grown; n->capacity = capacity;
    }
    ntfschar *copy = malloc((size_t)name_len * sizeof(ntfschar));
    if (!copy) { n->failed = 1; return 0; }
    memcpy(copy, name, (size_t)name_len * sizeof(ntfschar));
    n->names[n->count++] = (struct folder_name){ copy, name_len, name_type, (u64)mref };
    return 0;
}

static void folder_names_free(struct folder_names *n) {
    for (size_t i = 0; i < n->count; i++) free(n->names[i].name);
    free(n->names);
    n->names = NULL; n->count = n->capacity = 0;
}

/* The names in `dir` (all, or those of one reference), in index order. */
static int folder_names_read(ntfs_inode *dir, u64 only, struct folder_names *out) {
    memset(out, 0, sizeof(*out));
    out->only = only;
    s64 pos = 0;
    if (ntfs_readdir(dir, &pos, out, folder_names_fill) || out->failed) { folder_names_free(out); return -1; }
    return 0;
}

/* The index context positioned on exactly this entry, or NULL. */
static ntfs_index_context *folder_lookup(ntfs_inode *dir, const struct folder_name *n) {
    size_t keylen = sizeof(FILE_NAME_ATTR) + (size_t)n->len * sizeof(ntfschar);
    FILE_NAME_ATTR *key = calloc(1, keylen);
    ntfs_index_context *icx = key ? ntfs_index_ctx_get(dir, NTFS_INDEX_I30, 4) : NULL;
    if (!icx) { free(key); return NULL; }
    key->file_name_length = (u8)n->len;
    key->file_name_type = (FILE_NAME_TYPE_FLAGS)n->type;
    memcpy(key->file_name, n->name, (size_t)n->len * sizeof(ntfschar));
    int found = !ntfs_index_lookup(key, (int)keylen, icx) && icx->entry &&
                le64_to_cpu(icx->entry->indexed_file) == n->ref;
    free(key);
    if (!found) { ntfs_index_ctx_put(icx); return NULL; }
    return icx;
}

/* The node holding the entry the context is on: why removing it would be
 * more than taking one leaf entry out of a node that stays in order and (for
 * an index block) not empty, or NULL. Entries of `ref` are the ones to go. */
static const char *index_node_refusal(ntfs_volume *vol, ntfs_index_context *icx, u64 ref) {
    if (icx->entry->ie_flags & INDEX_ENTRY_NODE) return "stale entry not in a leaf";
    INDEX_HEADER *ih = icx->is_in_root ? &icx->ir->index : &icx->ib->index;
    u8 *at = (u8 *)ih + le32_to_cpu(ih->entries_offset), *end = (u8 *)ih + le32_to_cpu(ih->index_length);
    const FILE_NAME_ATTR *previous = NULL;
    int others = 0;
    while (at + sizeof(INDEX_ENTRY_HEADER) <= end) {
        INDEX_ENTRY *ie = (INDEX_ENTRY *)at;
        u16 length = le16_to_cpu(ie->length);
        if (length < sizeof(INDEX_ENTRY_HEADER) || at + length > end) return "folder index broken";
        if (ie->ie_flags & INDEX_ENTRY_END) break;
        u16 keylen = le16_to_cpu(ie->key_length);
        const FILE_NAME_ATTR *key = &ie->key.file_name;
        if (keylen < sizeof(FILE_NAME_ATTR) || keylen > length - sizeof(INDEX_ENTRY_HEADER) ||
            sizeof(FILE_NAME_ATTR) + key->file_name_length * sizeof(ntfschar) > keylen) return "folder index broken";
        /* Within one node, entries ascend in the folder's collation order
         * (NTFS-3G's: case-insensitive first, case breaking ties). */
        if (previous && ntfs_names_full_collate(previous->file_name, previous->file_name_length,
                                                key->file_name, key->file_name_length,
                                                CASE_SENSITIVE, vol->upcase, vol->upcase_len) >= 0)
            return "folder index out of order";
        previous = key;
        if (le64_to_cpu(ie->indexed_file) != ref) others++;
        at += length;
    }
    /* An emptied index block would be freed and its parent rewritten. */
    if (!icx->is_in_root && !others) return "stale entry alone in its block";
    return NULL;
}

/* Every name in the folder is found by looking it up through the index, and
 * names `ref` exactly as many times as `expected`. */
static const char *folder_lookups_refusal(ntfs_inode *dir, u64 ref, size_t expected) {
    struct folder_names all;
    if (folder_names_read(dir, 0, &all)) return "folder unreadable";
    const char *why = NULL;
    size_t named = 0;
    for (size_t i = 0; i < all.count && !why; i++) {
        ntfs_index_context *icx = folder_lookup(dir, &all.names[i]);
        if (!icx) why = "folder index lookup failed";
        else ntfs_index_ctx_put(icx);
        if (all.names[i].ref == ref) named++;
    }
    if (!why && named != expected) why = "stale entry not found";
    folder_names_free(&all);
    return why;
}

/* Why this stale entry may not be removed here, or NULL. Read-only. */
static const char *stale_entry_refusal(ntfs_volume *vol, const struct stale_ref *s, size_t *names) {
    ntfs_inode *dir = ntfs_inode_open(vol, s->folder);
    if (!dir) return "folder unreadable";
    struct folder_names own;
    const char *why = NULL;
    if (folder_names_read(dir, s->ref, &own)) why = "folder unreadable";
    else if (!own.count) why = "stale entry not found";
    else if (own.count > 4) why = "stale entry has too many names";
    for (size_t i = 0; !why && i < own.count; i++) {
        ntfs_index_context *icx = folder_lookup(dir, &own.names[i]);
        if (!icx) { why = "folder index lookup failed"; break; }
        why = index_node_refusal(vol, icx, s->ref);
        ntfs_index_ctx_put(icx);
    }
    if (!why) why = folder_lookups_refusal(dir, s->ref, own.count);
    if (names) *names = own.count;
    folder_names_free(&own);
    if (ntfs_inode_close(dir) && !why) why = "folder could not be closed";
    return why;
}

/* "inconsistent record N: <why>; folder F, entry seq A, record seq B": the
 * wording CheckMarkerRefusal accepts. */
static void stale_reason(char *buf, size_t size, const struct stale_ref *s, const char *why) {
    snprintf(buf, size, "inconsistent record %llu: %s; folder %llu, entry seq %u, record seq %d",
             (unsigned long long)MREF(s->ref), why, (unsigned long long)s->folder, (unsigned)MSEQNO(s->ref), s->record_seq);
}

int nk_stale_entries_examine(const nk_io *io, nk_stale_entries *out, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !out || io->size < 1024 * 1024) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    memset(out, 0, sizeof(*out));
    struct stale_ref stale[NK_STALE_MAX];
    int count = 0;
    long long items = 0;
    char reason[sizeof(out->reason)] = "";
    int walked = check_volume_walk(io, CHECK_ALLOCATION | CHECK_COLLECT_STALE, &items, NULL, stale, &count, reason, sizeof(reason));
    int error = errno;
    if (walked && !(error == EIO && !strncmp(reason, "inconsistent record", 19))) {
        /* Hibernated, maintenance pending, log not clean, or a read failed. */
        snprintf(errbuf, errlen, "%s", reason); errno = error; return -1;
    }
    out->count = count;
    out->checked_items = items;
    for (int i = 0; i < count; i++)
        out->entry[i] = (nk_stale_entry){ stale[i].folder, stale[i].ref, stale[i].in_use, stale[i].record_seq };
    nk_io ro = *io; ro.readonly = 1;
    nk_volume *v = mount_unchecked(&ro, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be read"); errno = EIO; return -1; }
    out->dirty = !!(v->vol->flags & VOLUME_IS_DIRTY);
    if (walked) {
        /* Something besides stale entries: not for the Mac. */
        snprintf(out->reason, sizeof(out->reason), "%s", reason);
    } else {
        for (int i = 0; i < count && !out->reason[0]; i++) {
            const char *why = stale_entry_refusal(v->vol, &stale[i], NULL);
            if (why) stale_reason(out->reason, sizeof(out->reason), &stale[i], why);
        }
        out->repairable = count > 0 && !out->reason[0];
    }
    int read_failed = v->devctx->failed;
    if (release_volume(v) || read_failed) {
        out->repairable = 0;
        snprintf(errbuf, errlen, "read failed"); errno = EIO; return -1;
    }
    return 0;
}

/* Takes every name of one stale entry out of its folder's index. */
static int stale_entry_remove(ntfs_volume *vol, const nk_stale_entry *e) {
    struct stale_ref s = { e->folder, e->reference, e->record_in_use, e->record_seq };
    ntfs_inode *dir = ntfs_inode_open(vol, e->folder);
    if (!dir) return -1;
    struct folder_names own;
    int r = folder_names_read(dir, e->reference, &own) || !own.count ? -1 : 0;
    for (size_t i = 0; !r && i < own.count; i++) {
        ntfs_index_context *icx = folder_lookup(dir, &own.names[i]);
        /* Checked again on the node as it is now, right before the change. */
        if (!icx || index_node_refusal(vol, icx, s.ref) || ntfs_index_rm(icx)) r = -1;
        if (icx) ntfs_index_ctx_put(icx);
    }
    folder_names_free(&own);
    /* Writes the folder's record when its INDEX_ROOT changed. */
    if (ntfs_inode_close(dir)) r = -1;
    return r;
}

int nk_stale_entries_repair(const nk_io *io, nk_stale_entries *before, long long *items, char *errbuf, size_t errlen) {
    char scratch[128];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    if (!io || !io->pread || !io->pwrite || !io->sync || io->readonly || io->size < 1024 * 1024 || !before || !items) {
        snprintf(errbuf, errlen, "invalid target"); errno = EINVAL; return -1;
    }
    *items = 0;
    /* Examined again here: the App's answer may be minutes old. */
    if (nk_stale_entries_examine(io, before, errbuf, errlen)) return -1;
    if (!before->count && !before->reason[0]) { snprintf(errbuf, errlen, "no stale entries"); errno = EALREADY; return -1; }
    if (!before->repairable) { snprintf(errbuf, errlen, "%s", before->reason); errno = ENOTSUP; return -1; }

    nk_volume *v = mount_unchecked(io, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be opened"); errno = EIO; return -1; }
    int r = 0;
    /* First write: "needs check", so that every state until the last write is
     * one nothing mounts for writing (and Windows checks). */
    if (!(v->vol->flags & VOLUME_IS_DIRTY)) {
        r = write_volume_flags(v->vol, (le16)(v->vol->flags | VOLUME_IS_DIRTY));
        if (!r) r = nkdev_sync(v->vol->dev);
    }
    for (int i = 0; !r && i < before->count; i++) r = stale_entry_remove(v->vol, &before->entry[i]);
    if (!r) r = nkdev_sync(v->vol->dev);
    if (release_volume(v)) r = -1;
    if (r || io->sync(io->ctx) != 0) { snprintf(errbuf, errlen, "repair failed"); errno = EIO; return -1; }

    /* Each folder changed: every name left is found through the index, none
     * names a removed entry. */
    nk_io ro = *io; ro.readonly = 1;
    v = mount_unchecked(&ro, NULL, 0);
    if (!v) { snprintf(errbuf, errlen, "volume could not be read"); errno = EIO; return -1; }
    const char *why = NULL;
    for (int i = 0; !why && i < before->count; i++) {
        ntfs_inode *dir = ntfs_inode_open(v->vol, before->entry[i].folder);
        why = dir ? folder_lookups_refusal(dir, before->entry[i].reference, 0) : "folder unreadable";
        if (dir && ntfs_inode_close(dir) && !why) why = "folder could not be closed";
    }
    if (release_volume(v) && !why) why = "read failed";
    if (why) { snprintf(errbuf, errlen, "did not verify: %s", why); errno = EIO; return -1; }
    /* Last: "Check on This Mac" in full, which clears the mark only if
     * everything holds and then verifies the volume inspects clean. */
    return nk_clear_check_marker(io, items, errbuf, errlen);
}
