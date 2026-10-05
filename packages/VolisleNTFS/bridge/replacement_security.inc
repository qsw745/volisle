/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Preserve the destination's complete Windows descriptor before publishing a
 * replacement. Do not use ntfs_get_ntfs_acl here: its upstream implementation
 * synthesizes a descriptor when the stored one is missing or corrupt. */
static int replacement_security_read(ntfs_inode *ni, char **output, size_t *length) {
    char *data = NULL;
    size_t size = 0;
    ntfs_attr *attr = NULL;
    ntfs_volume *vol = ni->vol;
    if (test_nino_flag(ni, v3_Extensions) && ni->security_id) {
        if (!vol->secure_ni || !vol->secure_xsii) goto bad;
        SII_INDEX_KEY key = { .security_id = ni->security_id };
        ntfs_index_context *index = vol->secure_xsii;
        ntfs_index_ctx_reinit(index);
        if (ntfs_index_lookup(&key, sizeof(key), index)) goto bad;
        INDEX_ENTRY *entry = index->entry;
        size_t entry_size = le16_to_cpu(entry->length);
        size_t offset = le16_to_cpu(entry->data_offset);
        if (entry->ie_flags & INDEX_ENTRY_END ||
            le16_to_cpu(entry->key_length) != sizeof(key) ||
            entry->key.sii.security_id != key.security_id ||
            offset < sizeof(INDEX_ENTRY_HEADER) + sizeof(key) ||
            offset > entry_size || entry_size - offset < sizeof(SECURITY_DESCRIPTOR_HEADER) ||
            le16_to_cpu(entry->data_length) != sizeof(SECURITY_DESCRIPTOR_HEADER)) goto bad;
        SECURITY_DESCRIPTOR_HEADER expected, actual;
        memcpy(&expected, (char *)entry + offset, sizeof(expected));
        size_t total = le32_to_cpu(expected.length);
        u64 start = le64_to_cpu(expected.offset);
        if (expected.security_id != ni->security_id ||
            total < sizeof(expected) + sizeof(SECURITY_DESCRIPTOR_RELATIVE) ||
            total > sizeof(expected) + 65536 || start > LLONG_MAX - total || (start & 15)) goto bad;
        attr = ntfs_attr_open(vol->secure_ni, AT_DATA, STREAM_SDS, 4);
        if (!attr || attr->data_size < 0 || start + total > (u64)attr->data_size) goto bad;
        if (ntfs_attr_pread(attr, start, sizeof(actual), &actual) != sizeof(actual) ||
            memcmp(&actual, &expected, sizeof(actual))) goto bad;
        size = total - sizeof(actual);
        data = malloc(size);
        if (!data) goto bad;
        if (ntfs_attr_pread(attr, start + sizeof(actual), size, data) != (s64)size ||
            !ntfs_valid_descr(data, size) || ntfs_attr_size(data) != size ||
            ntfs_security_hash((const SECURITY_DESCRIPTOR_RELATIVE *)data, size) != actual.hash) goto bad;
    } else {
        attr = ntfs_attr_open(ni, AT_SECURITY_DESCRIPTOR, AT_UNNAMED, 0);
        if (!attr || attr->data_size < sizeof(SECURITY_DESCRIPTOR_RELATIVE) || attr->data_size > 65536) goto bad;
        size = (size_t)attr->data_size;
        data = malloc(size);
        if (!data || ntfs_attr_pread(attr, 0, size, data) != (s64)size ||
            !ntfs_valid_descr(data, size) || ntfs_attr_size(data) != size) goto bad;
    }
    ntfs_attr_close(attr);
    *output = data; *length = size;
    return 0;
bad:
    if (attr) ntfs_attr_close(attr);
    free(data);
    errno = EIO;
    return -1;
}

static int replacement_preserve_security(nk_volume *v, ntfs_inode *source, ntfs_inode *target) {
    char *old = NULL, *draft = NULL, *verified = NULL;
    size_t old_size = 0, draft_size = 0, verified_size = 0;
    int error = 0;
    if (replacement_security_read(target, &old, &old_size) ||
        replacement_security_read(source, &draft, &draft_size)) { error = EIO; goto out; }
    if (old_size == draft_size && !memcmp(old, draft, old_size)) goto out;
    struct SECURITY_CONTEXT context = {0};
    context.vol = v->vol;
    /* Retain owner, group, DACL, SACL and control flags without SID/UID mapping.
     * The old inode remains unchanged for retained handles and recovery. */
    if (ntfs_set_ntfs_acl(&context, source, old, old_size, 0) ||
        ntfs_inode_sync(source) || nkdev_sync(v->vol->dev) ||
        replacement_security_read(source, &verified, &verified_size) ||
        verified_size != old_size || memcmp(old, verified, old_size)) error = EIO;
out:
    free(old); free(draft); free(verified);
    if (error) return mutation_result(v, -1, error);
    return 0;
}
