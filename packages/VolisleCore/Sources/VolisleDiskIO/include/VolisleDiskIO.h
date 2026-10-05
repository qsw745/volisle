// SPDX-License-Identifier: GPL-2.0-only
#ifndef VOLISLE_DISK_IO_H
#define VOLISLE_DISK_IO_H
#include <stdint.h>
/* Read-only queries against the held descriptor. Returns 0 or -1 with errno. */
int volisle_read_disk_geometry(int fd, uint32_t *block_size, uint64_t *block_count);
int volisle_disk_is_writable(int fd);
int volisle_sync_disk(int fd);
#endif
