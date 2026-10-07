/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Volisle, 2026-10-06. File names between macOS and NTFS.
 *
 * libntfs-3g's own macOS conversion is turned off (below): names cross the
 * bridge byte for byte, so a name a listing returns always finds the same entry
 * again. Its conversion turned every name into NFD on the way out and NFC on
 * the way in, so an entry stored decomposed by another system (a Mac archive
 * unpacked on Windows, Korean and Japanese names especially) or holding a CJK
 * compatibility ideograph could be listed but never opened, and failed the
 * whole directory listing.
 *
 * Names this Mac creates are stored the way Windows writes them: composed
 * (NFC), with the characters Windows does not allow in a name mapped to the
 * private-use code points macOS itself uses for SMB and FAT volumes (Services
 * for Macintosh): controls U+0001-001F to U+F001-F01F, " * : < > ? \ | to
 * U+F020-F027, and a final space or period to U+F028/U+F029. Windows can then
 * open, rename and delete them; listings map them back.
 *
 * A lookup tries the exact name first, then the stored form, then the
 * decomposed form: an entry is found whichever spelling an app passes, and
 * names stored by older versions (unmapped) keep working. */

/* Process-wide: each FSKit volume instance and the helper run in their own process. */
__attribute__((constructor)) static void names_init(void) {
    (void)ntfs_macosx_normalize_filenames(0);
}

static const char sfm_punctuation[] = "\"*:<>?\\|";

static ntfschar sfm_map(ntfschar c) {
    unsigned v = le16_to_cpu(c);
    if (v >= 0x01 && v <= 0x1f) return cpu_to_le16((u16)(0xF000 + v));
    for (unsigned i = 0; i < sizeof(sfm_punctuation) - 1; i++)
        if (v == (unsigned char)sfm_punctuation[i]) return cpu_to_le16((u16)(0xF020 + i));
    return c;
}

/* Listing: the stored form back to the Mac name. */
static void sfm_unmap(ntfschar *name, int length) {
    for (int i = 0; i < length; i++) {
        unsigned v = le16_to_cpu(name[i]);
        if (v >= 0xF001 && v <= 0xF01F) name[i] = cpu_to_le16((u16)(v - 0xF000));
        else if (v >= 0xF020 && v <= 0xF027) name[i] = cpu_to_le16((u16)(unsigned char)sfm_punctuation[v - 0xF020]);
        else if (i == length - 1 && v == 0xF028) name[i] = const_cpu_to_le16(' ');
        else if (i == length - 1 && v == 0xF029) name[i] = const_cpu_to_le16('.');
    }
}

/* A name macOS may pass, never a path. "$" names belong to NTFS metadata at the root only. */
static int valid_name(const char *name) {
    if (!name || !*name || !strcmp(name, ".") || !strcmp(name, "..") || strchr(name, '/')) {
        errno = EINVAL; return 0;
    }
    return 1;
}

static int metadata_name(ntfs_inode *dir, const char *name) {
    return dir->mft_no == FILE_root && name[0] == '$';
}

static char *normalized(const char *name, int composed) {
    char *out = NULL;
    if (ntfs_macosx_normalize_utf8(name, &out, composed) < 0) { free(out); return NULL; }
    return out;
}

/* The UTF-16 name stored for a Mac name: NFC, then the SFM mapping. */
static int stored_name(const char *name, ntfschar **out) {
    *out = NULL;
    char *composed = normalized(name, 1);
    int length = ntfs_mbstoucs(composed ? composed : name, out);
    free(composed);
    if (length <= 0 || !*out) { free(*out); *out = NULL; if (length >= 0) errno = EINVAL; return -1; }
    if (length > 255) { free(*out); *out = NULL; errno = ENAMETOOLONG; return -1; }
    for (int i = 0; i < length; i++) (*out)[i] = sfm_map((*out)[i]);
    unsigned last = le16_to_cpu((*out)[length - 1]);
    if (last == ' ') (*out)[length - 1] = cpu_to_le16(0xF028);
    else if (last == '.') (*out)[length - 1] = cpu_to_le16(0xF029);
    return length;
}

/* `name` in the open directory `dir`: exact, stored form, then decomposed.
 * Returns the MFT reference, or (u64)-1 with errno. With `found`, also the
 * UTF-16 name of the matching entry (the caller frees it). */
static u64 lookup_name(ntfs_inode *dir, const char *name, ntfschar **found, int *found_length) {
    ntfschar *spelling[3] = { NULL, NULL, NULL };
    int length[3] = { -1, -1, -1 };
    length[0] = ntfs_mbstoucs(name, &spelling[0]);
    length[1] = stored_name(name, &spelling[1]);
    char *decomposed = normalized(name, 0);
    if (decomposed) length[2] = ntfs_mbstoucs(decomposed, &spelling[2]);
    free(decomposed);
    u64 result = (u64)-1;
    int error = ENOENT;
    for (int i = 0; i < 3 && result == (u64)-1; i++) {
        if (length[i] <= 0 || !spelling[i]) continue;
        if (length[i] > 255) { error = ENAMETOOLONG; continue; }
        int seen = 0;
        for (int j = 0; j < i; j++)
            if (length[j] == length[i] && spelling[j] && !memcmp(spelling[j], spelling[i], length[i] * sizeof(ntfschar))) seen = 1;
        if (seen) continue;
        u64 reference = ntfs_inode_lookup_by_name(dir, spelling[i], length[i]);
        if (reference != (u64)-1) {
            result = reference;
            if (found) { *found = spelling[i]; *found_length = length[i]; spelling[i] = NULL; }
        } else if (errno != ENOENT) { error = errno ? errno : EIO; break; }
    }
    for (int i = 0; i < 3; i++) free(spelling[i]);
    if (result == (u64)-1) errno = error;
    return result;
}

/* Whether `dir` holds a different entry whose name differs from `name`'s
 * stored form only in letter case: Windows would see the two as one name. */
static int case_variant_exists(ntfs_inode *dir, const ntfschar *name, int length, u64 except) {
    ntfs_volume *vol = dir->vol;
    int sensitive = NVolCaseSensitive(vol);
    NVolClearCaseSensitive(vol);
    u64 reference = ntfs_inode_lookup_by_name(dir, name, length);
    int error = errno;
    if (sensitive) NVolSetCaseSensitive(vol);
    if (reference == (u64)-1) { errno = error; return error == ENOENT ? 0 : -1; }
    return MREF(reference) != MREF(except);
}

/* Absolute path to an open inode, every component found as lookup_name does. */
static ntfs_inode *path_inode(nk_volume *v, const char *path) {
    if (!v || !path) { errno = EINVAL; return NULL; }
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);  /* the exact spelling: the usual case */
    if (ni || errno != ENOENT) return ni;
    char *copy = strdup(path);
    if (!copy) { errno = ENOMEM; return NULL; }
    ni = ntfs_inode_open(v->vol, FILE_root);
    int error = ni ? 0 : EIO;
    char *p = copy;
    while (ni) {
        while (*p == '/') p++;
        if (!*p) break;
        char *end = strchr(p, '/');
        if (end) *end = '\0';
        u64 reference = lookup_name(ni, p, NULL, NULL);
        ntfs_inode *next = NULL;
        if (reference == (u64)-1) error = errno ? errno : ENOENT;
        else if (!(next = ntfs_inode_open(v->vol, MREF(reference)))) error = errno ? errno : EIO;
        if (ntfs_inode_close(ni) && !error) error = EIO;
        if (error && next) { ntfs_inode_close(next); next = NULL; }
        ni = next;
        if (!end) break;
        p = end + 1;
    }
    free(copy);
    if (!ni) errno = error ? error : ENOENT;
    return ni;
}
