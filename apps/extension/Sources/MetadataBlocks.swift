// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Each cache key must always describe one immutable, non-overlapping region.
enum MetadataBlocks {
    static func forEach(start: Int64, length: Int, blockSize: Int, deviceSize: Int64,
                        body: (Int64, Int, Int) throws -> Void) throws {
        guard blockSize > 0, start >= 0, length >= 0,
              start % Int64(blockSize) == 0,
              start <= deviceSize, Int64(length) <= deviceSize - start,
              length % blockSize == 0 || start + Int64(length) == deviceSize else {
            throw POSIXError(.EINVAL)
        }
        var skip = 0
        while skip < length {
            let count = min(blockSize, length - skip)
            try body(start + Int64(skip), skip, count)
            skip += count
        }
    }
}
