/* SPDX-License-Identifier: GPL-2.0-or-later
 * Mac mount-local modes; this is not a Windows security descriptor.
 * Included by ntfs_bridge.c after device types and mutation helpers. */
static ntfschar mac_mode_name[] = {
    const_cpu_to_le16('$'), const_cpu_to_le16('V'), const_cpu_to_le16('O'),
    const_cpu_to_le16('L'), const_cpu_to_le16('I'), const_cpu_to_le16('S'),
    const_cpu_to_le16('L'), const_cpu_to_le16('E'), const_cpu_to_le16('.'),
    const_cpu_to_le16('M'), const_cpu_to_le16('O'), const_cpu_to_le16('D'),
    const_cpu_to_le16('E')
};
#define MAC_MODE_NAME_LEN 13
static int mac_mode_reserved(ntfs_volume *vol, const ntfschar *name, unsigned count) {
    return ntfs_names_are_equal(name, count, mac_mode_name, MAC_MODE_NAME_LEN,
                               IGNORE_CASE, vol->upcase, vol->upcase_len);
}
static uint64_t mode_get(const unsigned char *p, unsigned count) {
    uint64_t n = 0;
    for (unsigned i = 0; i < count; ++i) n |= (uint64_t)p[i] << (8 * i);
    return n;
}
static void mode_put(unsigned char *p, uint64_t value, unsigned count) {
    for (unsigned i = 0; i < count; ++i) p[i] = (unsigned char)(value >> (8 * i));
}
static uint32_t mode_checksum(const unsigned char *p) {
    uint32_t h = 2166136261u;
    for (unsigned i = 0; i < 24; ++i) h = (h ^ p[i]) * 16777619u;
    return h;
}
static int mode_valid(uint32_t mode, int directory) {
    return directory ? (mode == 0700 || mode == 0755) :
                       (mode == 0400 || mode == 0600 || mode == 0444 || mode == 0644);
}
static uint64_t mode_reference(ntfs_inode *ni) {
    return ni->mft_no | ((uint64_t)le16_to_cpu(ni->mrec->sequence_number) << 48);
}
static int mode_corrupt(ntfs_inode *ni) {
    ((struct nk_devctx *)ni->vol->dev->d_private)->failed = 1;
    errno = EIO;
    return -1;
}
/* A recognized record cannot be treated as absent on read/parse failure.
 * Check aliases to reject duplicate names, even on case-sensitive media. */
static int mac_mode_read(ntfs_inode *ni, uint32_t *mode, int *present) {
    int directory = !!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY);
    *mode = directory ? 0755 : 0644;
    if (present) *present = 0;
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) return mode_corrupt(ni);
    int count = 0, error = 0;
    for (;;) {
        if (ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
            if (errno != ENOENT) error = 1;
            break;
        }
        ATTR_RECORD *a = search->attr;
        if (!a->name_length) continue;
        unsigned offset = le16_to_cpu(a->name_offset), bytes = a->name_length * sizeof(ntfschar);
        if (offset > le32_to_cpu(a->length) || bytes > le32_to_cpu(a->length) - offset) { error = 1; break; }
        if (mac_mode_reserved(ni->vol, (ntfschar *)((char *)a + offset), a->name_length)) ++count;
    }
    ntfs_attr_put_search_ctx(search);
    if (error || count > 1) return mode_corrupt(ni);
    if (count) {
        ntfs_attr *a = ntfs_attr_open(ni, AT_DATA, mac_mode_name, MAC_MODE_NAME_LEN);
        unsigned char b[32];
        int valid = a && a->data_size == sizeof(b) &&
            !(a->data_flags & (ATTR_IS_COMPRESSED | ATTR_IS_ENCRYPTED | ATTR_IS_SPARSE)) &&
            ntfs_attr_pread(a, 0, sizeof(b), b) == sizeof(b);
        if (a) ntfs_attr_close(a);
        if (!valid || memcmp(b, "VOLMODE1", 8) || mode_get(b + 8, 2) != 1 ||
            mode_get(b + 10, 2) != (directory ? 2 : 1) ||
            mode_get(b + 16, 8) != mode_reference(ni) ||
            mode_get(b + 24, 4) != mode_checksum(b) || mode_get(b + 28, 4) != 0 ||
            (!mode_valid((uint32_t)mode_get(b + 12, 4), directory) && mode_get(b + 12, 4) != 0))
            return mode_corrupt(ni);
        *mode = (uint32_t)mode_get(b + 12, 4);
        if (present) *present = 1;
    }
    if (!directory && (ni->flags & FILE_ATTR_READONLY)) *mode &= ~0222u;
    return 0;
}
#ifdef NK_EXPERIMENTAL_PRIVATE_MODES
static int mac_mode_store(ntfs_inode *ni, uint32_t mode) {
    unsigned char b[32] = {0};
    memcpy(b, "VOLMODE1", 8);
    mode_put(b + 8, 1, 2);
    mode_put(b + 10, ni->mrec->flags & MFT_RECORD_IS_DIRECTORY ? 2 : 1, 2);
    mode_put(b + 12, mode, 4); mode_put(b + 16, mode_reference(ni), 8);
    mode_put(b + 24, mode_checksum(b), 4);
    ntfs_attr *a = ntfs_attr_open(ni, AT_DATA, mac_mode_name, MAC_MODE_NAME_LEN);
    int rc;
    if (a) {
        rc = a->data_size == sizeof(b) && ntfs_attr_pwrite(a, 0, sizeof(b), b) == sizeof(b) ? 0 : -1;
        ntfs_attr_close(a);
    } else if (errno == ENOENT) {
        rc = ntfs_attr_add(ni, AT_DATA, mac_mode_name, MAC_MODE_NAME_LEN, b, sizeof(b));
    } else rc = -1;
    return rc;
}
#endif
