import Foundation

@main struct PhysicalPolicyTests {
    static func main() {
        let serial: [UInt8] = [1,2,3,4,5,6,7,8]
        let root = "/Volisle-Test-20260922-0123456789abcdef0123456789abcdef"
        let policy = PhysicalTestPolicy(bsdName: "disk7s1", serial: serial, byteCount: 2_000_396_321_280,
                                        option: "volisle-test-token", root: root, expiresAt: 200)
        func permit(name: String = "disk7s1", observed: [UInt8]? = nil,
                    size: UInt64 = 2_000_396_321_280, options: [String] = ["volisle-test-token"],
                    writable: Bool = true, now: TimeInterval = 100) -> Bool {
            policy.allows(bsdName: name, serial: observed ?? serial, byteCount: size,
                          options: options, writable: writable, now: now)
        }
        precondition(permit())
        precondition(!permit(name: "disk8s1"))
        precondition(!permit(observed: [8,7,6,5,4,3,2,1]))
        precondition(!permit(size: 67_108_864))
        precondition(!permit(options: []))
        precondition(!permit(options: ["volisle-test-token,rdonly"]))
        precondition(!permit(options: ["volisle-test-token", "ro"]))
        precondition(!permit(writable: false))
        precondition(!permit(now: 200))
        precondition(!permit(now: .nan))
        for path in [root, root+"/中文 文件.bin", root+"/nested/file"] {
            precondition(policy.allowsMutation(path: path, now: 100))
        }
        for path in ["/", "/existing.txt", root+"-other/file", root+"/../existing.txt",
                     root+"//file", root+"/./file", root+"/a/../../file", root+"/a\\b",
                     root+"/a:b", root+"/a\0b", root.lowercased()+"/file"] {
            precondition(!policy.allowsMutation(path: path, now: 100), path)
        }
        precondition(!policy.allowsMutation(path: root+"/file", now: 200))
        print("实盘测试约束 25 个场景通过；未访问磁盘。")
    }
}
