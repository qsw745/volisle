import Foundation
import FSKit

@main struct PrivateAttributeTests {
    static func main() throws {
        for (kind, mode): (FSItem.ItemType, UInt32) in [(.file,0o600),(.file,0o400),(.directory,0o700),(.directory,0o755)] {
            let request = FSItem.SetAttributesRequest(); request.mode = mode
            let plan = try AttributeUpdate(request, kind: kind, privateModes: true)
            precondition(request.consumedAttributes.isEmpty)
            var persisted: UInt32?
            try plan.apply(setMode: { persisted = $0 }, truncate: { _ in fatalError() }, setTimes: { _,_,_ in fatalError() })
            precondition(persisted == mode && request.consumedAttributes == [.mode])
        }
        let request = FSItem.SetAttributesRequest(); request.mode = 0o700
        do {
            try AttributeUpdate(request, kind: .directory, privateModes: true).apply(setMode: { _ in throw POSIXError(.EIO) },
                truncate: { _ in fatalError() }, setTimes: { _,_,_ in fatalError() })
            fatalError("目录权限失败不能伪称成功")
        } catch let error as POSIXError { precondition(error.code == .EIO) }
        precondition(request.consumedAttributes.isEmpty)
        let invalid = FSItem.SetAttributesRequest(); invalid.mode = 0o4600; invalid.size = 0
        do { _ = try AttributeUpdate(invalid, kind: .file, privateModes: true); fatalError() }
        catch let error as POSIXError { precondition(error.code == .ENOTSUP) }
        print("实验私有权限属性：持久化回调、失败消费位与混合请求预校验通过。")
    }
}
