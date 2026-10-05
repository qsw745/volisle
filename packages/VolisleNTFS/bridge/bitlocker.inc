/* SPDX-License-Identifier: GPL-2.0-only
 *
 * BitLocker (Windows 7 and later, including To Go on NTFS): unlock with a
 * password or a 48-digit recovery password and present a decrypted view of
 * the volume as an nk_io, so the NTFS engine reads it unchanged. The view is
 * writable when the device under it is: writes are encrypted in place, sector
 * by sector, so the layer below (the write journal) only ever sees ciphertext.
 * Writes into BitLocker's own regions (the three metadata blocks and the store
 * of the relocated volume header, which Windows reserves as files under
 * System Volume Information) are refused, never silently dropped.
 * Written from the published format description (libyal "BitLocker Drive
 * Encryption (BDE) format"); crypto primitives come from CommonCrypto.
 *
 * Supported: fully encrypted volumes with AES-XTS 128/256 or AES-CBC 128/256.
 * Refused: partially encrypted/decrypting volumes, Elephant Diffuser (Vista/7),
 * Vista-format metadata, TPM-only protectors. Keys are wiped on close.
 */
#include <CommonCrypto/CommonCrypto.h>

#define BDE_STRETCH_ROUNDS 0x100000
#define BDE_META_REGION 65536

struct nk_bde {
    nk_io under;               /* the encrypted partition */
    int sector;                /* bytes per sector (512 or 4096) */
    int64_t header_offset;     /* where Windows moved the first sectors */
    int64_t header_length;
    int64_t meta[3];           /* FVE metadata block offsets */
    uint32_t method;           /* 0x8002..0x8005 */
    CCCryptorRef data_dec;     /* XTS key 1 / CBC key, decrypt */
    CCCryptorRef data_enc;     /* XTS key 1 / CBC key, encrypt */
    CCCryptorRef tweak_enc;    /* XTS key 2 / CBC key (IV), encrypt, ECB */
};

/* Sectors moved per call to the device below. */
#define BDE_RUN_BYTES (256 * 1024)

static uint16_t bde_le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t bde_le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t bde_le64(const uint8_t *p) { return (uint64_t)bde_le32(p) | (uint64_t)bde_le32(p + 4) << 32; }

static int bde_read(const nk_io *io, void *buf, int64_t count, int64_t offset) {
    return io->pread(io->ctx, buf, count, offset) == count ? 0 : -1;
}

static int aes_ecb(CCOperation op, const uint8_t *key, size_t key_len, const void *in, void *out, size_t len) {
    size_t moved = 0;
    return CCCrypt(op, kCCAlgorithmAES, kCCOptionECBMode, key, key_len, NULL, in, len, out, len, &moved) == kCCSuccess && moved == len ? 0 : -1;
}

/* The shared stretch: 0x100000 rounds of SHA256 over {last, initial, salt, count}. */
static void bde_stretch(const uint8_t initial[32], const uint8_t salt[16], uint8_t out[32]) {
    uint8_t block[88];
    memset(block, 0, sizeof(block));
    memcpy(block + 32, initial, 32);
    memcpy(block + 64, salt, 16);
    for (uint64_t count = 0; count < BDE_STRETCH_ROUNDS; count++) {
        for (int i = 0; i < 8; i++) block[80 + i] = (uint8_t)(count >> (8 * i));
        CC_SHA256(block, sizeof(block), block);
    }
    memcpy(out, block, 32);
    memset_s(block, sizeof(block), 0, sizeof(block));
}

/* Password: SHA256(SHA256(UTF-16LE password)). */
static int bde_password_initial(const char *password, uint8_t out[32]) {
    size_t n = strlen(password);
    if (!n || n > 1024) return -1;
    /* A UTF-16 string never has more units than its UTF-8 form has bytes. */
    uint16_t *units = calloc(n, sizeof(uint16_t));
    if (!units) return -1;
    size_t count = 0;
    const unsigned char *s = (const unsigned char *)password;
    for (size_t i = 0; i < n;) {
        uint32_t cp; size_t extra;
        if (s[i] < 0x80) { cp = s[i]; extra = 0; }
        else if ((s[i] & 0xe0) == 0xc0) { cp = s[i] & 0x1f; extra = 1; }
        else if ((s[i] & 0xf0) == 0xe0) { cp = s[i] & 0x0f; extra = 2; }
        else if ((s[i] & 0xf8) == 0xf0) { cp = s[i] & 0x07; extra = 3; }
        else { free(units); return -1; }
        if (i + extra >= n + (extra == 0)) { free(units); return -1; }
        for (size_t k = 1; k <= extra; k++) {
            if ((s[i + k] & 0xc0) != 0x80) { free(units); return -1; }
            cp = cp << 6 | (s[i + k] & 0x3f);
        }
        i += extra + 1;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            units[count++] = (uint16_t)(0xd800 | cp >> 10);
            units[count++] = (uint16_t)(0xdc00 | (cp & 0x3ff));
        } else {
            units[count++] = (uint16_t)cp;
        }
    }
    uint8_t *bytes = malloc(count * 2), first[32];
    if (!bytes) { free(units); return -1; }
    for (size_t i = 0; i < count; i++) { bytes[2 * i] = (uint8_t)units[i]; bytes[2 * i + 1] = (uint8_t)(units[i] >> 8); }
    CC_SHA256(bytes, (CC_LONG)(count * 2), first);
    CC_SHA256(first, 32, out);
    memset_s(bytes, count * 2, 0, count * 2); memset_s(units, count * 2, 0, count * 2); memset_s(first, 32, 0, 32);
    free(bytes); free(units);
    return 0;
}

/* Recovery password: 8 groups of 6 digits, each divisible by 11 into 16 bits. */
static int bde_recovery_initial(const char *recovery, uint8_t out[32]) {
    uint8_t key[16];
    int group = 0; uint32_t value = 0; int digits = 0;
    for (const char *p = recovery;; p++) {
        if (*p >= '0' && *p <= '9') {
            if (++digits > 6) return -1;
            value = value * 10 + (uint32_t)(*p - '0');
            continue;
        }
        if (*p != '-' && *p != ' ' && *p != 0) return -1;
        if (digits) {
            if (digits != 6 || group >= 8 || value % 11 || value / 11 > 0xffff) return -1;
            key[2 * group] = (uint8_t)(value / 11); key[2 * group + 1] = (uint8_t)((value / 11) >> 8);
            group++; value = 0; digits = 0;
        }
        if (!*p) break;
    }
    if (group != 8) return -1;
    CC_SHA256(key, 16, out);
    memset_s(key, 16, 0, 16);
    return 0;
}

/* AES-CCM with a 12-byte nonce (L = 3) and a 16-byte tag, as BitLocker
 * stores keys: nonce | tag | ciphertext. Returns 0 only if the tag verifies. */
static int bde_ccm_open(const uint8_t *key, size_t key_len, const uint8_t *nonce,
                        const uint8_t *tag, const uint8_t *in, size_t len, uint8_t *out) {
    if (len > 0xffffff) return -1;
    uint8_t ctr[16], pad[16], mac[16];
    int r = -1;
    size_t blocks = (len + 15) / 16;
    for (size_t b = 0; b <= blocks; b++) {
        memset(ctr, 0, 16);
        ctr[0] = 2;  /* L - 1 */
        memcpy(ctr + 1, nonce, 12);
        ctr[13] = (uint8_t)(b >> 16); ctr[14] = (uint8_t)(b >> 8); ctr[15] = (uint8_t)b;
        if (aes_ecb(kCCEncrypt, key, key_len, ctr, pad, 16)) goto done;
        if (b == 0) { for (int i = 0; i < 16; i++) mac[i] = tag[i] ^ pad[i]; continue; }
        size_t at = (b - 1) * 16, n = len - at < 16 ? len - at : 16;
        for (size_t i = 0; i < n; i++) out[at + i] = in[at + i] ^ pad[i];
    }
    /* CBC-MAC over B0 and the plaintext. */
    uint8_t x[16];
    memset(x, 0, 16);
    x[0] = 0x3a;  /* 8 * ((16 - 2) / 2) + (3 - 1), no associated data */
    memcpy(x + 1, nonce, 12);
    x[13] = (uint8_t)(len >> 16); x[14] = (uint8_t)(len >> 8); x[15] = (uint8_t)len;
    if (aes_ecb(kCCEncrypt, key, key_len, x, x, 16)) goto done;
    for (size_t at = 0; at < len; at += 16) {
        size_t n = len - at < 16 ? len - at : 16;
        for (size_t i = 0; i < n; i++) x[i] ^= out[at + i];
        if (aes_ecb(kCCEncrypt, key, key_len, x, x, 16)) goto done;
    }
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= (uint8_t)(x[i] ^ mac[i]);
    r = diff ? -1 : 0;
    if (r) memset_s(out, len, 0, len);
done:
    memset_s(pad, 16, 0, 16); memset_s(x, 16, 0, 16);
    return r;
}

/* Opens an AES-CCM encrypted key entry's data (nonce | tag | ciphertext) and
 * returns the key bytes and method from its plaintext header. */
static int bde_unwrap(const uint8_t *key, size_t key_len, const uint8_t *data, size_t len,
                      uint8_t *out_key, size_t *out_len, uint32_t *method) {
    if (len < 28 + 12 || len - 28 > 1024) return -1;
    size_t plain_len = len - 28;
    uint8_t plain[1024];
    if (bde_ccm_open(key, key_len, data, data + 12, data + 28, plain_len, plain)) return -1;
    uint32_t size = bde_le32(plain);
    int r = -1;
    if (size >= 12 && size <= plain_len && size - 12 <= 64) {
        *method = bde_le32(plain + 8);
        *out_len = size - 12;
        memcpy(out_key, plain + 12, *out_len);
        r = 0;
    }
    memset_s(plain, sizeof(plain), 0, sizeof(plain));
    return r;
}

/* Finds, in an entry list, the first nested entry with value type `vtype`. */
static const uint8_t *bde_find(const uint8_t *p, const uint8_t *end, uint16_t vtype, size_t *len) {
    while (end - p >= 8) {
        uint16_t size = bde_le16(p);
        if (size < 8 || size > end - p) return NULL;
        if (bde_le16(p + 4) == vtype) { *len = size - 8; return p + 8; }
        p += size;
    }
    return NULL;
}

static int bde_parse_block(const nk_io *io, int64_t offset, uint8_t *buf, size_t cap, size_t *entries_len,
                           int64_t *header_offset, int64_t *header_sectors, int64_t *encrypted, uint32_t *method) {
    if (offset <= 0 || offset > io->size - 64 - 48 || bde_read(io, buf, 64 + 48, offset)) return -1;
    if (memcmp(buf, "-FVE-FS-", 8) || bde_le16(buf + 10) != 2) return -1;
    *encrypted = (int64_t)bde_le64(buf + 16);
    *header_sectors = bde_le32(buf + 28);
    *header_offset = (int64_t)bde_le64(buf + 56);
    uint32_t meta_size = bde_le32(buf + 64);
    if (bde_le32(buf + 68) != 1 || bde_le32(buf + 72) != 48 || meta_size < 48 || meta_size - 48 > cap) return -1;
    *method = bde_le32(buf + 64 + 36) & 0xffff;
    *entries_len = meta_size - 48;
    return bde_read(io, buf, (int64_t)*entries_len, offset + 64 + 48);
}

int nk_bde_probe(const nk_io *io) {
    uint8_t boot[512];
    if (!io || !io->pread || io->size < 512 || bde_read(io, boot, 512, 0)) return -1;
    return memcmp(boot + 3, "-FVE-FS-", 8) == 0 ? 1 : 0;
}

static int bde_set_keys(nk_bde *b, const uint8_t *fvek, size_t len) {
    size_t half = 0;
    switch (b->method) {
    case 0x8004: half = 16; if (len < 32) return -1; break;
    case 0x8005: half = 32; if (len < 64) return -1; break;
    case 0x8002: half = 16; if (len < 16) return -1; break;
    case 0x8003: half = 32; if (len < 32) return -1; break;
    default: return -1;
    }
    int xts = b->method == 0x8004 || b->method == 0x8005;
    const uint8_t *data_key = fvek, *tweak_key = xts ? fvek + half : fvek;
    if (CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, xts ? kCCOptionECBMode : 0, data_key, half, NULL, &b->data_dec) != kCCSuccess)
        return -1;
    if (CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, xts ? kCCOptionECBMode : 0, data_key, half, NULL, &b->data_enc) != kCCSuccess)
        return -1;
    if (CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, tweak_key, half, NULL, &b->tweak_enc) != kCCSuccess)
        return -1;
    return 0;
}

static int bde_hex_key(const char *hex, uint8_t out[32]) {
    if (strlen(hex) != 64) return -1;
    for (int i = 0; i < 64; i++) {
        char c = hex[i];
        int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (v < 0) return -1;
        out[i / 2] = (uint8_t)(i % 2 ? out[i / 2] | v : v << 4);
    }
    return 0;
}

/* Unlocks and, when vmk_out is given, also hands back the volume master key
 * (so the privileged helper can pass it on instead of the user's secret). */
static nk_bde *bde_unlock(const nk_io *io, int kind, const char *secret, uint8_t *vmk_out, char *errbuf, size_t errlen) {
    char scratch[96];
    if (!errbuf || !errlen) { errbuf = scratch; errlen = sizeof(scratch); }
    errbuf[0] = 0;
    uint8_t boot[512];
    if (!io || !io->pread || !secret || (kind != NK_BDE_PASSWORD && kind != NK_BDE_RECOVERY && kind != NK_BDE_KEY) ||
        io->size < 1024 * 1024 || bde_read(io, boot, 512, 0)) {
        snprintf(errbuf, errlen, "invalid request"); errno = EINVAL; return NULL;
    }
    if (memcmp(boot + 3, "-FVE-FS-", 8)) { snprintf(errbuf, errlen, "not BitLocker"); errno = EINVAL; return NULL; }
    int sector = bde_le16(boot + 11);
    if (sector != 512 && sector != 4096) { snprintf(errbuf, errlen, "unsupported sector size"); errno = ENOTSUP; return NULL; }
    int64_t meta[3];
    for (int i = 0; i < 3; i++) meta[i] = (int64_t)bde_le64(boot + 176 + 8 * i);
    size_t cap = 64 * 1024, entries_len = 0;
    uint8_t *entries = malloc(cap);
    if (!entries) { errno = ENOMEM; return NULL; }
    int64_t header_offset = 0, header_sectors = 0, encrypted = 0;
    uint32_t method = 0;
    int parsed = 0;
    for (int i = 0; i < 3 && !parsed; i++)
        parsed = !bde_parse_block(io, meta[i], entries, cap, &entries_len, &header_offset, &header_sectors, &encrypted, &method);
    nk_bde *b = NULL;
    uint8_t initial[32], stretched[32], vmk[64], fvek[64];
    size_t vmk_len = 0, fvek_len = 0;
    uint32_t vmk_method = 0, fvek_method = 0;
    int error = EIO;
    if (!parsed) { snprintf(errbuf, errlen, "no readable metadata (Vista or damaged)"); error = ENOTSUP; goto fail; }
    if (method < 0x8002 || method > 0x8005) { snprintf(errbuf, errlen, "unsupported method 0x%04x", method); error = ENOTSUP; goto fail; }
    if (encrypted != io->size) { snprintf(errbuf, errlen, "not fully encrypted"); error = ENOTSUP; goto fail; }
    int64_t header_length = header_sectors * sector;
    if (header_length <= 0 || header_length > 1024 * 1024 || header_offset <= 0 || header_offset > io->size - header_length) {
        snprintf(errbuf, errlen, "invalid header relocation"); error = ENOTSUP; goto fail;
    }
    int unlocked = 0, candidates = 0;
    if (kind == NK_BDE_KEY) {
        if (bde_hex_key(secret, vmk)) { snprintf(errbuf, errlen, "invalid key"); error = EINVAL; goto fail; }
        vmk_len = 32; unlocked = candidates = 1;
    } else if ((kind == NK_BDE_PASSWORD ? bde_password_initial(secret, initial) : bde_recovery_initial(secret, initial))) {
        snprintf(errbuf, errlen, kind == NK_BDE_PASSWORD ? "invalid password" : "invalid recovery password");
        error = EACCES; goto fail;
    }
    uint16_t wanted = kind == NK_BDE_PASSWORD ? 0x2000 : 0x0800;
    for (const uint8_t *p = entries, *end = entries + entries_len; end - p >= 8 && !unlocked;) {
        uint16_t size = bde_le16(p);
        if (size < 8 || size > end - p) break;
        if (bde_le16(p + 2) == 2 && bde_le16(p + 4) == 8 && size >= 8 + 28 && bde_le16(p + 8 + 26) == wanted) {
            candidates++;
            const uint8_t *props = p + 8 + 28, *pend = p + size;
            size_t stretch_len = 0, ccm_len = 0;
            const uint8_t *stretch = bde_find(props, pend, 3, &stretch_len), *ccm = bde_find(props, pend, 5, &ccm_len);
            if (stretch && ccm && stretch_len >= 20) {
                bde_stretch(initial, stretch + 4, stretched);
                unlocked = !bde_unwrap(stretched, 32, ccm, ccm_len, vmk, &vmk_len, &vmk_method) && vmk_len == 32;
            }
        }
        p += size;
    }
    if (!candidates) { snprintf(errbuf, errlen, kind == NK_BDE_PASSWORD ? "no password protector" : "no recovery protector"); error = ENOTSUP; goto fail; }
    if (!unlocked) { snprintf(errbuf, errlen, "wrong password"); error = EACCES; goto fail; }
    size_t fvek_entry_len = 0;
    const uint8_t *fvek_entry = NULL;
    for (const uint8_t *p = entries, *end = entries + entries_len; end - p >= 8;) {
        uint16_t size = bde_le16(p);
        if (size < 8 || size > end - p) break;
        if (bde_le16(p + 2) == 3 && bde_le16(p + 4) == 5) { fvek_entry = p + 8; fvek_entry_len = size - 8; break; }
        p += size;
    }
    if (!fvek_entry || bde_unwrap(vmk, 32, fvek_entry, fvek_entry_len, fvek, &fvek_len, &fvek_method)) {
        /* With a passed-in key the CCM tag is the only check that it belongs here. */
        snprintf(errbuf, errlen, kind == NK_BDE_KEY ? "wrong key" : "volume key could not be opened");
        error = kind == NK_BDE_KEY && fvek_entry ? EACCES : EIO; goto fail;
    }
    b = calloc(1, sizeof(*b));
    if (!b) { error = ENOMEM; goto fail; }
    b->under = *io; b->sector = sector; b->header_offset = header_offset; b->header_length = header_length;
    memcpy(b->meta, meta, sizeof(meta));
    b->method = method;
    if ((fvek_method & 0xffff) != method || bde_set_keys(b, fvek, fvek_len)) {
        snprintf(errbuf, errlen, "unsupported volume key"); error = ENOTSUP; nk_bde_close(b); b = NULL; goto fail;
    }
    if (vmk_out) memcpy(vmk_out, vmk, 32);
    error = 0;
fail:
    memset_s(initial, 32, 0, 32); memset_s(stretched, 32, 0, 32);
    memset_s(vmk, 64, 0, 64); memset_s(fvek, 64, 0, 64);
    memset_s(entries, cap, 0, cap); free(entries);
    if (error) errno = error;
    return b;
}

nk_bde *nk_bde_open(const nk_io *io, int kind, const char *secret, char *errbuf, size_t errlen) {
    return bde_unlock(io, kind, secret, NULL, errbuf, errlen);
}

int nk_bde_derive_key(const nk_io *io, int kind, const char *secret, char hex_out[65], char *errbuf, size_t errlen) {
    uint8_t vmk[32];
    if (!hex_out || kind == NK_BDE_KEY) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "invalid request");
        errno = EINVAL; return -1;
    }
    nk_bde *b = bde_unlock(io, kind, secret, vmk, errbuf, errlen);
    if (!b) return -1;
    nk_bde_close(b);
    for (int i = 0; i < 32; i++) snprintf(hex_out + 2 * i, 3, "%02x", vmk[i]);
    memset_s(vmk, 32, 0, 32);
    return 0;
}

void nk_bde_close(nk_bde *b) {
    if (!b) return;
    if (b->data_dec) CCCryptorRelease(b->data_dec);   /* releases wipe the key schedule */
    if (b->data_enc) CCCryptorRelease(b->data_enc);
    if (b->tweak_enc) CCCryptorRelease(b->tweak_enc);
    memset_s(b, sizeof(*b), 0, sizeof(*b));
    free(b);
}

/* Multiply the XTS tweak by x in GF(2^128) (little-endian). */
static void xts_next(uint8_t t[16]) {
    uint8_t carry = t[15] >> 7;
    for (int i = 15; i > 0; i--) t[i] = (uint8_t)(t[i] << 1 | t[i - 1] >> 7);
    t[0] = (uint8_t)(t[0] << 1 ^ (carry ? 0x87 : 0));
}

/* Decrypts (encrypt == 0) or encrypts one sector in place; `source` is its
 * position on disk, which sets the XTS tweak or the CBC IV. */
static int bde_crypt_sector(nk_bde *b, uint8_t *sector, int64_t source, int encrypt) {
    size_t n = (size_t)b->sector, moved = 0;
    uint8_t iv[16], t[16];
    memset(iv, 0, 16);
    CCCryptorRef data = encrypt ? b->data_enc : b->data_dec;
    if (b->method == 0x8004 || b->method == 0x8005) {
        uint64_t number = (uint64_t)source / (uint64_t)b->sector;
        for (int i = 0; i < 8; i++) iv[i] = (uint8_t)(number >> (8 * i));
        /* ECB cryptors carry no state between blocks: no reset needed. */
        if (CCCryptorUpdate(b->tweak_enc, iv, 16, t, 16, &moved) || moved != 16) return -1;
        uint8_t tweaks[4096];
        for (size_t at = 0; at < n; at += 16) {
            memcpy(tweaks + at, t, 16);
            for (int i = 0; i < 16; i++) sector[at + i] ^= t[i];
            xts_next(t);
        }
        if (CCCryptorUpdate(data, sector, n, sector, n, &moved) || moved != n) return -1;
        for (size_t at = 0; at < n; at++) sector[at] ^= tweaks[at];
        return 0;
    }
    for (int i = 0; i < 8; i++) iv[i] = (uint8_t)((uint64_t)source >> (8 * i));
    if (CCCryptorUpdate(b->tweak_enc, iv, 16, t, 16, &moved) || moved != 16) return -1;
    if (CCCryptorReset(data, t) || CCCryptorUpdate(data, sector, n, sector, n, &moved) || moved != n) return -1;
    return 0;
}

/* Where the plaintext of the sector at `offset` comes from: 1 = decrypt from
 * *source, 0 = reads as zeros (metadata and the relocated header's store). */
static int bde_map(const nk_bde *b, int64_t offset, int64_t *source) {
    if (offset < b->header_length) { *source = b->header_offset + offset; return 1; }
    if (offset >= b->header_offset && offset < b->header_offset + b->header_length) return 0;
    for (int i = 0; i < 3; i++)
        if (offset >= b->meta[i] && offset < b->meta[i] + BDE_META_REGION) return 0;
    *source = offset;
    return 1;
}

/* Contiguous sectors from `offset` (sector aligned, at most `limit` bytes)
 * that share one fate: all decrypted from consecutive disk positions starting
 * at *source (returns 1), or all in a reserved region (returns 0). */
static int bde_run(const nk_bde *b, int64_t offset, int64_t limit, int64_t *source, int64_t *length) {
    int mapped = bde_map(b, offset, source);
    int64_t at = offset + b->sector, next = 0;
    while (at < offset + limit) {
        int m = bde_map(b, at, &next);
        if (m != mapped || (mapped && next != *source + (at - offset))) break;
        at += b->sector;
    }
    *length = at - offset;
    return mapped;
}

static long long bde_pread(void *ctx, void *buf, long long count, long long offset) {
    nk_bde *b = ctx;
    if (!b || !buf || count < 0 || offset < 0 || offset > b->under.size || count > b->under.size - offset) return -1;
    uint8_t *run = malloc(BDE_RUN_BYTES);
    if (!run) return -1;
    long long done = 0, result = count;
    while (done < count) {
        int64_t at = offset + done, start = at / b->sector * b->sector, source = 0, length = 0;
        size_t skip = (size_t)(at - start);
        int64_t want = (int64_t)skip + (count - done);
        int64_t limit = (want + b->sector - 1) / b->sector * b->sector;
        if (limit > BDE_RUN_BYTES) limit = BDE_RUN_BYTES;
        if (bde_run(b, start, limit, &source, &length)) {
            if (bde_read(&b->under, run, length, source)) { result = -1; break; }
            int failed = 0;
            for (int64_t s = 0; s < length && !failed; s += b->sector)
                failed = bde_crypt_sector(b, run + s, source + s, 0);
            if (failed) { result = -1; break; }
        } else {
            memset(run, 0, (size_t)length);
        }
        size_t n = (size_t)length - skip;
        if ((long long)n > count - done) n = (size_t)(count - done);
        memcpy((uint8_t *)buf + done, run + skip, n);
        done += (long long)n;
    }
    memset_s(run, BDE_RUN_BYTES, 0, BDE_RUN_BYTES);
    free(run);
    return result;
}

/* Encrypts and writes. A partial first or last sector is read, decrypted and
 * merged first. Nothing is written into a reserved region: such a write fails
 * with EIO as a whole before any sector of it reaches the disk. */
static long long bde_pwrite(void *ctx, const void *buf, long long count, long long offset) {
    nk_bde *b = ctx;
    if (!b || !buf || count < 0 || offset < 0 || offset > b->under.size || count > b->under.size - offset ||
        !b->under.pwrite || b->under.readonly) { errno = EINVAL; return -1; }
    int64_t first = offset / b->sector * b->sector, last = (offset + count + b->sector - 1) / b->sector * b->sector;
    for (int64_t at = first, source = 0; at < last; at += b->sector)
        if (!bde_map(b, at, &source)) { errno = EIO; return -1; }
    uint8_t *run = malloc(BDE_RUN_BYTES);
    if (!run) { errno = ENOMEM; return -1; }
    long long done = 0, result = count;
    while (done < count) {
        int64_t at = offset + done, start = at / b->sector * b->sector, source = 0, length = 0;
        size_t skip = (size_t)(at - start);
        int64_t want = (int64_t)skip + (count - done);
        int64_t limit = (want + b->sector - 1) / b->sector * b->sector;
        if (limit > BDE_RUN_BYTES) limit = BDE_RUN_BYTES;
        bde_run(b, start, limit, &source, &length);
        size_t n = (size_t)length - skip;
        if ((long long)n > count - done) n = (size_t)(count - done);
        /* Sectors this call only partly covers keep their other bytes. */
        int partial_head = skip != 0, partial_tail = (skip + n) % (size_t)b->sector != 0;
        int64_t tail = (int64_t)((skip + n) / (size_t)b->sector * (size_t)b->sector);
        if (partial_head || (partial_tail && tail == 0)) {
            if (bde_read(&b->under, run, b->sector, source) || bde_crypt_sector(b, run, source, 0)) { result = -1; break; }
        }
        if (partial_tail && tail > 0) {
            if (bde_read(&b->under, run + tail, b->sector, source + tail) || bde_crypt_sector(b, run + tail, source + tail, 0)) { result = -1; break; }
        }
        memcpy(run + skip, (const uint8_t *)buf + done, n);
        int64_t span = (int64_t)((skip + n + (size_t)b->sector - 1) / (size_t)b->sector * (size_t)b->sector);
        int failed = 0;
        for (int64_t s = 0; s < span && !failed; s += b->sector)
            failed = bde_crypt_sector(b, run + s, source + s, 1);
        if (failed || b->under.pwrite(b->under.ctx, run, span, source) != span) { result = -1; break; }
        done += (long long)n;
    }
    memset_s(run, BDE_RUN_BYTES, 0, BDE_RUN_BYTES);
    free(run);
    if (result < 0 && !errno) errno = EIO;
    return result;
}

static int bde_sync(void *ctx) {
    nk_bde *b = ctx;
    return b && b->under.sync ? b->under.sync(b->under.ctx) : -1;
}

nk_io nk_bde_io(nk_bde *b) {
    nk_io io;
    memset(&io, 0, sizeof(io));
    if (!b) return io;
    int writable = b->under.pwrite && !b->under.readonly && b->under.sync;
    io.ctx = b; io.pread = bde_pread; io.size = b->under.size;
    io.pwrite = writable ? bde_pwrite : NULL;
    io.readonly = !writable;
    io.sync = writable ? bde_sync : NULL;
    return io;
}
