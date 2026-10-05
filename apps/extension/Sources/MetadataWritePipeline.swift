// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Serialized by the engine queue. The optional recorder MUST persist the
/// complete block intent before returning; it never authorizes recovery.
final class MetadataWritePipeline {
    struct Intent {
        let offset: Int64
        let before: Data
        let after: Data
    }
    private(set) var failed = false
    func write(_ input: UnsafeRawBufferPointer, offset: Int64, blockSize: Int, deviceSize: Int64,
               read: (Int64, UnsafeMutableRawBufferPointer) throws -> Void,
               record: ((Intent) throws -> Void)? = nil,
               write: (Int64, UnsafeRawBufferPointer) throws -> Void) throws {
        guard !failed else { throw POSIXError(.EIO) }
        guard blockSize > 0, blockSize <= 1024 * 1024,
              blockSize & (blockSize - 1) == 0,
              deviceSize > 0, offset >= 0, offset <= deviceSize,
              Int64(input.count) <= deviceSize - offset else { throw POSIXError(.EINVAL) }
        guard !input.isEmpty else { return }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: blockSize, alignment: blockSize)
        defer { scratch.deallocate() }
        do {
            var consumed = 0
            while consumed < input.count {
                let position = offset + Int64(consumed)
                let start = position / Int64(blockSize) * Int64(blockSize)
                let length = Int(min(Int64(blockSize), deviceSize - start))
                let skip = Int(position - start)
                let count = min(input.count - consumed, length - skip)
                let block = UnsafeMutableRawBufferPointer(rebasing: scratch[..<length])
                // A journal protects actual cache-block writes, including the
                // unchanged neighbors and the device's short final block.
                if record != nil || skip != 0 || count != length { try read(start, block) }
                let before = record == nil ? nil : Data(block)
                UnsafeMutableRawBufferPointer(rebasing: block[skip..<skip+count])
                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: input[consumed..<consumed+count]))
                if let record, let before { try record(Intent(offset: start, before: before, after: Data(block))) }
                try write(start, UnsafeRawBufferPointer(block))
                consumed += count
            }
        } catch {
            // A partial device write is ambiguous. Do not try a second path,
            // nor accept subsequent writes even if the next callback succeeds.
            failed = true
            throw error
        }
    }
}
