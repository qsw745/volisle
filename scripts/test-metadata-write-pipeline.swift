import Foundation

@main struct PipelineTests {
    static func main() throws {
        var checks = 0
        func scenario(offset: Int64, count: Int, blockSize: Int, deviceSize: Int) throws {
            let pipeline = MetadataWritePipeline()
            let original = Data((0..<deviceSize).map { UInt8($0 % 251) })
            var disk = original
            let input = Data(repeating: 0xfe, count: count)
            var intents: [MetadataWritePipeline.Intent] = []
            var order: [String] = []
            try input.withUnsafeBytes { bytes in
                try pipeline.write(bytes, offset: offset, blockSize: blockSize, deviceSize: Int64(deviceSize), read: { at, buffer in
                    precondition(buffer.count <= blockSize)
                    disk.withUnsafeBytes { source in buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[Int(at)..<Int(at)+buffer.count])) }
                    order.append("read")
                }, record: { intent in
                    precondition(intent.before == disk[Int(intent.offset)..<Int(intent.offset)+intent.before.count])
                    precondition(intent.offset % Int64(blockSize) == 0)
                    intents.append(intent); order.append("record")
                }, write: { at, bytes in
                    precondition(order.last == "record")
                    disk.replaceSubrange(Int(at)..<Int(at)+bytes.count, with: bytes)
                    order.append("write")
                })
            }
            var expected = original
            expected.replaceSubrange(Int(offset)..<Int(offset)+count, with: input)
            precondition(disk == expected && !pipeline.failed)
            for intent in intents.reversed() { disk.replaceSubrange(Int(intent.offset)..<Int(intent.offset)+intent.before.count, with: intent.before) }
            precondition(disk == original)
            checks += 1
        }
        for block in [512, 4096, 16384] {
            for (offset,count) in [(0,0),(0,block),(1,1),(block-2,5),(3,block*2+7)] {
                try scenario(offset: Int64(offset), count: count, blockSize: block, deviceSize: block*4+512)
            }
            try scenario(offset: Int64(block*4+500), count: 12, blockSize: block, deviceSize: block*4+512)
        }
        for stage in ["read", "record", "write"] {
            let pipeline = MetadataWritePipeline()
            var calls: [String] = []
            let data = Data(repeating: 1, count: 4)
            do {
                try data.withUnsafeBytes { bytes in
                    try pipeline.write(bytes, offset: 1, blockSize: 4096, deviceSize: 8192,
                        read: { _, buffer in calls.append("read"); if stage == "read" { throw POSIXError(.EIO) }; buffer.initializeMemory(as: UInt8.self, repeating: 0) },
                        record: { _ in calls.append("record"); if stage == "record" { throw POSIXError(.ENOSPC) } },
                        write: { _, _ in calls.append("write"); throw POSIXError(.EIO) })
                }
                fatalError("failure swallowed")
            } catch {}
            precondition(pipeline.failed)
            precondition(calls == (stage == "read" ? ["read"] : stage == "record" ? ["read","record"] : ["read","record","write"]))
            let before = calls
            do {
                try data.withUnsafeBytes { bytes in try pipeline.write(bytes, offset: 0, blockSize: 4096, deviceSize: 8192,
                    read: { _, _ in calls.append("unexpected") }, write: { _, _ in calls.append("unexpected") }) }
                fatalError("failed pipeline reused")
            } catch {}
            precondition(calls == before); checks += 1
        }
        for (offset,size,block,total) in [(Int64(-1),1,4096,Int64(8192)),(8191,2,4096,8192),(0,1,3,8192),(0,1,0,8192),(0,1,2097152,8192),(Int64.max,1,4096,Int64.max)] {
            let pipeline = MetadataWritePipeline()
            var called = false
            do {
                try Data(repeating: 1,count: size).withUnsafeBytes { bytes in try pipeline.write(bytes,offset:offset,blockSize:block,deviceSize:total,
                    read:{_,_ in called=true},write:{_,_ in called=true}) }
                fatalError("invalid input accepted")
            } catch {}
            precondition(!called); checks += 1
        }
        // Aligned writes without a recorder need no read and stay bounded.
        let pipeline = MetadataWritePipeline(); var blocks = 0
        try Data(repeating: 7, count: 4096*64).withUnsafeBytes { bytes in try pipeline.write(bytes, offset:0, blockSize:4096, deviceSize:4096*64,
            read:{_,_ in fatalError("unnecessary read")}, write:{_,block in precondition(block.count==4096); blocks += 1}) }
        precondition(blocks==64); checks += 1
        // Failure on the second block cannot reach the third block; the
        // persisted intent still covers a torn second-block write.
        for fault in ["record", "partial-write"] {
            let writer = MetadataWritePipeline()
            let original = Data(repeating: 3, count: 4096*3)
            var disk = original
            var intents: [MetadataWritePipeline.Intent] = []
            var writes = 0
            do {
                try Data(repeating: 8, count: disk.count).withUnsafeBytes { input in
                    try writer.write(input,offset:0,blockSize:4096,deviceSize:Int64(disk.count),read:{ at, block in
                        disk.withUnsafeBytes { raw in block.copyMemory(from: UnsafeRawBufferPointer(rebasing:raw[Int(at)..<Int(at)+block.count])) }
                    },record:{ intent in
                        if fault == "record" && intents.count == 1 { throw POSIXError(.ENOSPC) }
                        intents.append(intent)
                    },write:{ at, block in
                        writes += 1
                        let length = writes == 2 ? block.count/2 : block.count
                        disk.replaceSubrange(Int(at)..<Int(at)+length,with:UnsafeRawBufferPointer(rebasing:block[..<length]))
                        if writes == 2 { throw POSIXError(.EIO) }
                    })
                }
                fatalError("failure swallowed")
            } catch {}
            precondition(writer.failed && writes == (fault == "record" ? 1 : 2))
            precondition(disk[8192..<12288] == original[8192..<12288])
            for intent in intents.reversed() { disk.replaceSubrange(Int(intent.offset)..<Int(intent.offset)+intent.before.count,with:intent.before) }
            precondition(disk == original); checks += 1
        }
        print("{\"success\":true,\"checks\":\(checks)}")
    }
}
