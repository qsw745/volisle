import Foundation

// swiftc -parse-as-library apps/extension/Sources/BitLockerMount.swift scripts/test-bitlocker-mount-option.swift
@main struct BitLockerMountTests {
    static func main() {
        let key = String(repeating: "0123456789abcdef", count: 4)
        precondition(BitLockerMount.key(in: ["rdonly,volisle-bde=\(key)"]) == key)
        precondition(BitLockerMount.key(in: ["-o", "volisle-bde=\(key),nosuid"]) == key)
        precondition(BitLockerMount.key(in: []) == nil, "没有密钥")
        precondition(BitLockerMount.key(in: ["volisle-bde=\(key),volisle-bde=\(key)"]) == nil, "重复必须拒绝")
        precondition(BitLockerMount.key(in: ["volisle-bde=\(key.uppercased())"]) == nil, "只接受小写")
        precondition(BitLockerMount.key(in: ["volisle-bde=\(key.dropLast())"]) == nil, "长度不对")
        precondition(BitLockerMount.key(in: ["volisle-bde=\(key)00"]) == nil, "长度不对")
        precondition(BitLockerMount.key(in: ["volisle-bde=" + String(repeating: "g", count: 64)]) == nil)
        precondition(BitLockerMount.key(in: ["volisle-bde=" + String(repeating: "٣", count: 64)]) == nil, "非 ASCII 数字")

        var boot = [UInt8](repeating: 0, count: 512)
        precondition(!BitLockerMount.isBitLocker(boot))
        boot.replaceSubrange(3..<11, with: Array("-FVE-FS-".utf8))
        precondition(BitLockerMount.isBitLocker(boot))
        precondition(!BitLockerMount.isBitLocker(Array(boot.prefix(100))), "过短")
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: ".workbench/bitlocker-fixtures/xts128.img")).prefix(512)
        precondition(BitLockerMount.isBitLocker([UInt8](fixture)))
        precondition(BitLockerMount.identifier([UInt8](fixture)).uuidString == "3BD66749-292E-D84A-8399-F6A339E3D001", "取头部 160 处的卷 GUID")
        print("BitLocker 挂载参数与识别：通过")
    }
}
