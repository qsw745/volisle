import Foundation

@main struct MetadataBlockTests {
    static func main() throws {
        var disk = [UInt8](repeating: 0, count: 8192)
        // Model the documented FSKit cache: keyed by offset, with no overlap
        // invalidation. A bitmap-sized read followed by a smaller write must
        // not leave a second, stale cached view of the same allocation bits.
        var cache: [Int64: [UInt8]] = [:]
        func read(_ start: Int64, _ length: Int) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: length)
            try MetadataBlocks.forEach(start: start, length: length, blockSize: 512, deviceSize: 8192) { offset, skip, count in
                let bytes = cache[offset] ?? Array(disk[Int(offset)..<Int(offset) + count])
                precondition(bytes.count == count, "同一缓存键不得改变长度")
                cache[offset] = bytes
                output.replaceSubrange(skip..<skip + count, with: bytes)
            }
            return output
        }
        _ = try read(0, 4096)
        try MetadataBlocks.forEach(start: 512, length: 512, blockSize: 512, deviceSize: 8192) { offset, _, count in
            let allocated = [UInt8](repeating: 255, count: count)
            cache[offset] = allocated
            disk.replaceSubrange(Int(offset)..<Int(offset) + count, with: allocated)
        }
        let bitmap = try read(0, 4096)
        precondition(bitmap[512..<1024].allSatisfy { $0 == 255 }, "分配位图读到了过期缓存，可导致重复分配")
        var tail: [(Int64, Int, Int)] = []
        try MetadataBlocks.forEach(start: 4096, length: 4608, blockSize: 4096, deviceSize: 8704) { tail.append(($0, $1, $2)) }
        precondition(tail.count == 2 && tail[0].2 == 4096 && tail[1].0 == 8192 && tail[1].2 == 512)
        for (offset, length) in [(Int64(1), 512), (Int64(0), 511), (Int64(8192), 1024), (Int64.max, 512)] {
            do {
                try MetadataBlocks.forEach(start: offset, length: length, blockSize: 512, deviceSize: 8192) { _, _, _ in }
                fatalError("非法范围未被拒绝")
            } catch {}
        }
        print("缓存回归通过：重叠位图更新、固定缓存键、尾块和越界拒绝。")
    }
}
