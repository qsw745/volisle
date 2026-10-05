import Foundation
import FSKit

@main struct ItemIdentityTests {
    static func main() {
        let cache = ItemIdentityCache()
        let old = cache.item(path: "/document", kind: .file, reference: 0x1000000000040)
        let oldID = old.identifier
        let source = cache.item(path: "/draft", kind: .file, reference: 0x1000000000041)
        // Old object may still be in use after the destination name is rebound.
        let replacement = cache.item(path: "/document", kind: .file, reference: source.fileReference)
        precondition(replacement !== old && replacement.identifier != oldID,
                     "同一路径的新文件不能复用旧对象或标识")
        cache.reclaim(old)
        precondition(cache.item(path: "/document", kind: .file, reference: source.fileReference) === replacement,
                     "旧对象延迟回收不能清掉新文件的缓存")
        precondition(old.fileReference == 0x1000000000040, "路径替换不能把旧对象身份改为新文件")
        cache.move(source, to: "/document")
        cache.reclaim(replacement)
        precondition(cache.item(path: "/document", kind: .file, reference: source.fileReference) === source,
                     "源对象移动到目标路径后，旧目标的回收不得清掉源对象")

        let dir = cache.item(path: "/folder", kind: .directory, reference: 0x1000000000042)
        let child = cache.item(path: "/folder/file", kind: .file, reference: 0x1000000000043)
        let listedID = cache.identifier(path: "/folder/listed-only", reference: 0x1000000000044)
        cache.move(dir, to: "/moved")
        precondition(child.path == "/moved/file")
        precondition(cache.item(path: "/moved/file", kind: .file, reference: child.fileReference) === child)
        precondition(cache.identifier(path: "/moved/listed-only", reference: 0x1000000000044) == listedID,
                     "目录移动必须保留仅枚举过的子文件标识")
        let sameNumberNewSequence = cache.item(path: "/moved/file", kind: .file, reference: 0x2000000000043)
        precondition(sameNumberNewSequence !== child && sameNumberNewSequence.identifier != child.identifier,
                     "MFT 记录复用必须产生新的对象身份")
        cache.remove(child)
        precondition(cache.item(path: "/moved/file", kind: .file, reference: 0x2000000000043) === sameNumberNewSequence,
                     "过时删除对象不得清掉新文件映射")
        cache.reclaim(sameNumberNewSequence)
        let reacquired = cache.item(path: "/moved/file", kind: .file, reference: 0x2000000000043)
        precondition(reacquired !== sameNumberNewSequence && reacquired.identifier == sameNumberNewSequence.identifier,
                     "普通回收后再次 lookup 必须保留同一文件的标识")
        let root = cache.item(path: "/", kind: .directory, reference: 0x1000000000005)
        precondition(root.identifier == .rootDirectory)
        print("对象身份检查通过：路径替换、旧对象回收、目录子项迁移、MFT 复用、重新查找及根目录。")
    }
}
