import Foundation

@main struct WritePreflightTests {
    static func main() throws {
        let serial: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        var inspections = 0
        func decision(options: [String] = ["volisle-rw"], size: UInt64 = 67_108_864,
                      status: Int32 = 0, fail: Bool = false) throws -> Bool {
            try WriteMountPolicy.requiresReadOnly(options: options, writable: true,
                serial: serial, byteCount: size, allowedSerial: serial) {
                inspections += 1
                if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                return status
            }
        }
        let writable = try decision()
        precondition(writable == false, "只有预检 clean 才允许进入可写挂载")
        precondition(inspections == 1)
        for status: Int32 in [1, 2, 3, 4, -1, 99] {
            var refused = false
            do { _ = try decision(status: status) }
            catch { refused = true }
            precondition(refused, "风险、未知或非法预检值不能降级为成功挂载")
        }
        var readFailureRefused = false
        do { _ = try decision(fail: true) }
        catch { readFailureRefused = true }
        precondition(readFailureRefused)
        let before = inspections
        let readonly = try decision(options: ["ro"], status: 1)
        let large = try decision(size: 2_000_000_000_000)
        let mixed = try decision(options: ["volisle-rw,rdonly"], status: 2)
        precondition(readonly && large && mixed, "只读请求或不在夹具范围内的设备保持只读")
        precondition(inspections == before, "只读路径不触发额外写入资格检查")
        let largeReady = try WriteMountPolicy.requiresReadOnly(options: ["volisle-rw"], writable: true,
            serial: serial, byteCount: 536870912, allowedSerial: serial, allowedByteCount: 536870912) { 0 }
        precondition(!largeReady)
        do {
            _ = try WriteMountPolicy.requiresReadOnly(options: ["volisle-rw"], writable: true,
                serial: serial, byteCount: 536870912, allowedSerial: serial, allowedByteCount: 536870912) { 2 }
            fatalError("大镜像不能绕过风险预检")
        } catch {}
        print("挂载前只读预检策略 全部场景通过；未访问磁盘。")
    }
}
