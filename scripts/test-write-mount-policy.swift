import Foundation

@main struct PolicyTests {
    static func main() {
        let serial: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        func allowed(_ options: [String] = ["volisle-rw"], _ writable: Bool = true,
                     _ observed: [UInt8]? = nil, _ size: UInt64 = 67108864,
                     _ permit: [UInt8]? = nil) -> Bool {
            WriteMountPolicy.allows(options: options, writable: writable, serial: observed ?? serial,
                                    byteCount: size, allowedSerial: permit ?? serial)
        }
        precondition(allowed(), "指定镜像的显式写入应可用")
        precondition(!allowed([], true), "没有显式选项必须只读")
        precondition(!allowed(["volisle-rw,rdonly"]), "只读选项优先")
        precondition(!allowed(["ro", "volisle-rw"]), "只读选项优先")
        precondition(!allowed(["volisle-rw"], false), "只读设备不能写入")
        precondition(!allowed(["volisle-rw"], true, [8, 7, 6, 5, 4, 3, 2, 1]), "必须拒绝其他镜像序列号")
        precondition(!allowed(["volisle-rw"], true, nil, 2000000000000), "必须拒绝真实大容量设备")
        precondition(!allowed(["volisle-rw"], true, [], 67108864, []), "空序列号不能放行")
        precondition(!allowed(["volisle-rw"], true, [0,0,0,0,0,0,0,0], 67108864, [0,0,0,0,0,0,0,0]))
        for size: UInt64 in [67108864, 2000396321280] {
            precondition(WriteMountPolicy.allowsDaily(options: ["volisle-rw"], writable: true, serial: serial, byteCount: size))
        }
        for options in [[], ["volisle-rw,ro"], ["volisle-rw", "rdonly"]] {
            precondition(!WriteMountPolicy.allowsDaily(options: options, writable: true, serial: serial, byteCount: 67108864))
        }
        precondition(!WriteMountPolicy.allowsDaily(options: ["volisle-rw"], writable: false, serial: serial, byteCount: 67108864))
        precondition(!WriteMountPolicy.allowsDaily(options: ["volisle-rw"], writable: true, serial: [], byteCount: 67108864))
        precondition(WriteMountPolicy.allows(options: ["volisle-rw"], writable: true, serial: serial,
            byteCount: 536870912, allowedSerial: serial, allowedByteCount: 536870912))
        precondition(!WriteMountPolicy.allows(options: ["volisle-rw"], writable: true, serial: serial,
            byteCount: 67108864, allowedSerial: serial, allowedByteCount: 536870912))
        precondition(!WriteMountPolicy.allows(options: ["volisle-rw"], writable: true, serial: serial,
            byteCount: 2000000000000, allowedSerial: serial, allowedByteCount: 2000000000000))
        print("实验及日常写入策略场景通过；未访问磁盘。")
    }
}
