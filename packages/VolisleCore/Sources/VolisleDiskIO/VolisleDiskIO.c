// SPDX-License-Identifier: GPL-2.0-only
#include "VolisleDiskIO.h"
#include <errno.h>
#include <unistd.h>
#include <sys/disk.h>
#include <sys/ioctl.h>

int volisle_read_disk_geometry(int fd, uint32_t *block_size, uint64_t *block_count) {
    if (!block_size || !block_count) { errno = EINVAL; return -1; }
    uint32_t size = 0;
    uint64_t count = 0;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &size) == -1 ||
        ioctl(fd, DKIOCGETBLOCKCOUNT, &count) == -1) return -1;
    *block_size = size;
    *block_count = count;
    return 0;
}

int volisle_disk_is_writable(int fd) {
    uint32_t value = 0;
    if (ioctl(fd, DKIOCISWRITABLE, &value) == -1) return -1;
    return value ? 1 : 0;
}
int volisle_sync_disk(int fd) {
    if (fsync(fd) == -1) return -1;
    return ioctl(fd, DKIOCSYNCHRONIZECACHE, 0);
}
