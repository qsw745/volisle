import Foundation
import FSKit

@main struct AttributeUpdateTests {
    static func main() throws {
        let request = FSItem.SetAttributesRequest()
        request.size = 4097
        request.modifyTime = timespec(tv_sec: 1700000000, tv_nsec: 123456789)
        request.mode = 0o644
        let plan = try AttributeUpdate(request, kind: .file)
        precondition(request.consumedAttributes.isEmpty)
        try plan.apply(setMode: { _ in }, truncate: { _ in }, setTimes: { _, _, _ in })
        precondition(request.consumedAttributes == [.size, .modifyTime, .mode], "成功属性必须回报给 FSKit")

        let partial = FSItem.SetAttributesRequest()
        partial.size = 8
        partial.birthTime = timespec(tv_sec: 0, tv_nsec: 10)
        do {
            try AttributeUpdate(partial, kind: .file).apply(setMode: { _ in }, truncate: { _ in }, setTimes: { _, _, _ in throw POSIXError(.EIO) })
            fatalError("时间写入失败被隐藏")
        } catch {}
        precondition(partial.consumedAttributes == [.size], "失败时间不得标为成功；已完成截断必须准确回报")

        let truncated = FSItem.SetAttributesRequest(); truncated.size = 8
        do {
            try AttributeUpdate(truncated, kind: .file).apply(setMode: { _ in }, truncate: { _ in throw POSIXError(.ENOSPC) }, setTimes: { _, _, _ in fatalError() })
            fatalError("截断失败被隐藏")
        } catch {}
        precondition(truncated.consumedAttributes.isEmpty)

        let unsupported = FSItem.SetAttributesRequest()
        unsupported.size = 0; unsupported.backupTime = timespec(tv_sec: 1, tv_nsec: 0)
        do { _ = try AttributeUpdate(unsupported, kind: .file); fatalError("混合请求必须在截断前拒绝不支持的属性") } catch {}
        precondition(unsupported.consumedAttributes.isEmpty)
        for time in [timespec(tv_sec: 1, tv_nsec: -1), timespec(tv_sec: 1, tv_nsec: 1000000000), timespec(tv_sec: Int.max, tv_nsec: 0), timespec(tv_sec: -11644473601, tv_nsec: 0)] {
            let invalid = FSItem.SetAttributesRequest(); invalid.size = 0; invalid.modifyTime = time
            do { _ = try AttributeUpdate(invalid, kind: .file); fatalError("非法时间必须在截断前拒绝") } catch {}
        }
        let directory = FSItem.SetAttributesRequest(); directory.size = 12
        do { _ = try AttributeUpdate(directory, kind: .directory); fatalError("目录不能当文件截断") } catch {}
        // exFAT-style: only the Windows READONLY bit is persisted; the value
        // actually stored is what the setMode callback receives.
        for (requested, stored) in [(UInt32(0o600), UInt32(0o644)), (0o400, 0o444), (0o755, 0o644), (0o700, 0o644), (0o555, 0o444)] {
            let privateMode = FSItem.SetAttributesRequest(); privateMode.mode = requested
            var persisted: UInt32?
            try AttributeUpdate(privateMode, kind: .file).apply(setMode: { persisted = $0 }, truncate: { _ in fatalError() }, setTimes: { _, _, _ in })
            precondition(persisted == stored && privateMode.consumedAttributes == [.mode])
        }
        let privateDirectory = FSItem.SetAttributesRequest(); privateDirectory.mode = 0o700
        try AttributeUpdate(privateDirectory, kind: .directory).apply(setMode: { _ in fatalError("目录权限不写入磁盘") },
            truncate: { _ in fatalError() }, setTimes: { _, _, _ in })
        precondition(privateDirectory.consumedAttributes == [.mode])
        let badType = FSItem.SetAttributesRequest(); badType.mode = 0o040644
        do { _ = try AttributeUpdate(badType, kind: .file); fatalError("类型位不符必须拒绝") } catch {}
        let hidden = FSItem.SetAttributesRequest(); hidden.flags = UInt32(UF_HIDDEN)
        _ = try AttributeUpdate(hidden, kind: .file, currentFlags: UInt32(UF_HIDDEN))
        do { _ = try AttributeUpdate(hidden, kind: .file); fatalError("改变标志不能伪称成功") } catch {}
        let readOnly = FSItem.SetAttributesRequest(); readOnly.mode = 0o444
        do { _ = try AttributeUpdate(readOnly, kind: .file) }
        catch { fatalError("普通文件只读权限必须可持久化支持：\(error)") }
        var order: [String] = []
        let lock = FSItem.SetAttributesRequest(); lock.size = 12; lock.mode = 0o444
        try AttributeUpdate(lock, kind: .file).apply(setMode: { mode in
            precondition(mode == 0o444); order.append("lock")
        }, truncate: { _ in order.append("truncate") }, setTimes: { _,_,_ in })
        precondition(order == ["truncate", "lock"] && lock.consumedAttributes == [.size,.mode])
        order = []
        let unlock = FSItem.SetAttributesRequest(); unlock.size = 0; unlock.mode = 0o644
        try AttributeUpdate(unlock, kind: .file).apply(setMode: { _ in order.append("unlock") },
            truncate: { _ in order.append("truncate") }, setTimes: { _,_,_ in })
        precondition(order == ["unlock", "truncate"])
        let failed = FSItem.SetAttributesRequest(); failed.mode = 0o444
        do {
            try AttributeUpdate(failed, kind: .file).apply(setMode: { _ in throw POSIXError(.EIO) },
                truncate: { _ in fatalError() }, setTimes: { _,_,_ in fatalError() })
            fatalError("权限写入失败被隐藏")
        } catch {}
        precondition(failed.consumedAttributes.isEmpty)
        print("属性请求回归通过：成功/部分失败消费位、混合请求预校验、目录与权限保护。")
    }
}
