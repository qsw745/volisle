/* Test adapter: compiles the actual BitLocker layer without NTFS or FSKit. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../packages/VolisleNTFS/bridge/ntfs_bridge.h"
#include "../../packages/VolisleNTFS/bridge/bitlocker.inc"

int test_bde_sector(uint32_t method, const uint8_t *key, size_t key_len,
                    int sector_size, int64_t source, int encrypt, uint8_t *sector) {
    nk_bde *b = calloc(1, sizeof(*b));
    if (!b) return -1;
    b->method = method;
    b->sector = sector_size;
    int result = bde_set_keys(b, key, key_len);
    if (!result) result = bde_crypt_sector(b, sector, source, encrypt);
    nk_bde_close(b);
    return result;
}

#ifdef NK_DIFFUSER_TEST_MAIN
struct test_memory { uint8_t *raw; long long size; int writes; };
static long long test_read(void *ctx, void *buf, long long count, long long offset) {
    struct test_memory *m = ctx;
    if (offset < 0 || count < 0 || offset > m->size || count > m->size - offset) return -1;
    memcpy(buf, m->raw + offset, (size_t)count);
    return count;
}
static long long test_write(void *ctx, const void *buf, long long count, long long offset) {
    struct test_memory *m = ctx;
    if (offset < 0 || count < 0 || offset > m->size || count > m->size - offset) return -1;
    memcpy(m->raw + offset, buf, (size_t)count);
    m->writes++;
    return count;
}
static int test_sync(void *ctx) { (void)ctx; return 0; }

static int test_memory_io(char **argv) {
    long long size = strtoll(argv[3], NULL, 10), offset = strtoll(argv[5], NULL, 10);
    int sector = atoi(argv[4]);
    if (size != 1 << 20 || (sector != 512 && sector != 4096)) return 2;
    struct test_memory m = {calloc(1, (size_t)size), size, 0};
    uint8_t expected[12288], actual[12288], patch[4196];
    nk_bde *b = NULL;
    int result = 1;
    if (!m.raw || fread(m.raw, 1, (size_t)size, stdin) != (size_t)size ||
        fread(expected, 1, (size_t)sector * 3, stdin) != (size_t)sector * 3) goto done;
    nk_io io = {&m, test_read, test_write, size, 0, test_sync};
    b = nk_bde_open(&io, NK_BDE_KEY, argv[2], NULL, 0);
    if (!b) goto done;
    nk_io view = nk_bde_io(b);
    if (view.pread(view.ctx, actual, sector * 3, offset) != sector * 3) goto done;
    for (int i = 0; i < sector * 3; i++) {
        int at = i % sector;
        if (actual[i] != (uint8_t)(at * 37 + (at >> 3) + 19)) goto done;
    }
    if (view.pread(view.ctx, actual, 8192, 0) != 8192) goto done;
    for (int i = 0; i < 8192; i++) {
        int at = i % sector;
        if (actual[i] != (uint8_t)(at * 37 + (at >> 3) + 19)) goto done;
    }
    if (view.pwrite(view.ctx, "!!", 2, 65535) != -1 || m.writes) goto done;
    for (int i = 0; i < sector + 100; i++) patch[i] = (uint8_t)"VOLISLE"[i % 7];
    if (view.pwrite(view.ctx, patch, sector + 100, offset + 13) != sector + 100 ||
        memcmp(m.raw + offset, expected, (size_t)sector * 3)) goto done;
    nk_bde_close(b);
    io.readonly = 1;
    b = nk_bde_open(&io, NK_BDE_KEY, argv[2], NULL, 0);
    if (!b) goto done;
    view = nk_bde_io(b);
    if (!view.readonly || view.pwrite || view.sync ||
        view.pread(view.ctx, actual, sector + 100, offset + 13) != sector + 100 ||
        memcmp(actual, patch, (size_t)sector + 100)) goto done;
    result = 0;
done:
    nk_bde_close(b);
    free(m.raw);
    return result;
}

/* Native sanitizer runner: a signed Python host may strip DYLD_* variables,
 * so load the sanitizer at executable startup rather than via ctypes/dlopen. */
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    if (!strcmp(argv[1], "--io")) return test_memory_io(argv);
    uint8_t key[128];
    size_t len = strlen(argv[2]) / 2;
    if (len > sizeof(key)) return 2;
    for (size_t i = 0; i < len; i++) {
        unsigned int value;
        if (sscanf(argv[2] + 2 * i, "%2x", &value) != 1) return 2;
        key[i] = (uint8_t)value;
    }
    int size = atoi(argv[3]);
    if (size != 512 && size != 4096) return 2;
    uint8_t *buf = calloc(1, (size_t)size + 1);
    if (!buf || fread(buf + 1, 1, (size_t)size, stdin) != (size_t)size) { free(buf); return 2; }
    int result = test_bde_sector((uint32_t)strtoul(argv[1], NULL, 0), key, len, size,
                                 strtoll(argv[4], NULL, 0), atoi(argv[5]), buf + 1);
    if (!result && fwrite(buf + 1, 1, (size_t)size, stdout) != (size_t)size) result = -1;
    free(buf);
    return result ? 1 : 0;
}
#endif
