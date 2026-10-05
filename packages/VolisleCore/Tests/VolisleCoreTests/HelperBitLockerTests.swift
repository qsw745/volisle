import Foundation
import Testing
@testable import VolisleCore

private let recovery = "123456-234567-345678-456789-567890-678901-789012-890123"

private func request(_ bsd: String = "disk8s2", kind: BitLockerSecretKind? = .password, secret: String? = "口令 Pass!",
                     size: UInt64 = 2_000_188_080_128) throws -> HelperBitLockerRequest {
    try HelperBitLockerRequest(bsdName: bsd, registryID: 42, byteCount: size, kind: kind, secret: secret)
}

@Test("恢复密钥接受空格、短横线或连写，规整为 8 组 6 位")
func recoveryKeyNormalization() {
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery) == recovery)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery.replacingOccurrences(of: "-", with: " ")) == recovery)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery.replacingOccurrences(of: "-", with: "")) == recovery)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(" " + recovery + "\n") == recovery)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(String(recovery.dropLast())) == nil)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery + "1") == nil)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery.replacingOccurrences(of: "1", with: "a")) == nil)
    #expect(BitLockerSecretKind.normalizedRecoveryKey(recovery.replacingOccurrences(of: "1", with: "١")) == nil, "全角或其他文字的数字不算")
}

@Test("解锁请求只接受分区、成对的方式与密钥、合法长度")
func bitLockerRequestValidation() throws {
    _ = try request()
    _ = try request(kind: .recoveryKey, secret: recovery)
    _ = try request(kind: nil, secret: nil)
    for (bsd, kind, secret) in [("disk8", BitLockerSecretKind.password, "x"), ("disk8s2/../x", .password, "x"),
                                ("disk8s2", .password, ""), ("disk8s2", .password, "a\u{0}b"),
                                ("disk8s2", .password, String(repeating: "密", count: 342)),
                                ("disk8s2", .recoveryKey, recovery.replacingOccurrences(of: "-", with: " ")),
                                ("disk8s2", .recoveryKey, "123")] {
        #expect(throws: HelperServiceError.invalidRequest) { try request(bsd, kind: kind, secret: secret) }
    }
    #expect(throws: HelperServiceError.invalidRequest) { try request(kind: nil, secret: "x") }
    #expect(throws: HelperServiceError.invalidRequest) { try request(kind: .password, secret: nil) }
    #expect(throws: HelperServiceError.invalidRequest) { try request(size: 512) }
    _ = try request(secret: String(repeating: "a", count: 1024))
}

@Test("解锁请求经 JSON 往返后仍重新校验")
func bitLockerRequestDecode() throws {
    let good = try request(kind: .recoveryKey, secret: recovery)
    #expect(try HelperBitLockerRequest.decode(JSONEncoder().encode(good)) == good)
    var tampered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any]
    tampered["secret"] = NSNull()
    #expect(throws: HelperServiceError.invalidRequest) {
        try HelperBitLockerRequest.decode(JSONSerialization.data(withJSONObject: tampered))
    }
    #expect(throws: HelperServiceError.invalidRequest) { try HelperBitLockerRequest.decode(Data(count: 9000)) }
}

@Test("回复必须恰好一种结果，挂载点只能在盘屿的 BitLocker 目录下")
func bitLockerReplyDecode() throws {
    func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    let point = BitLockerMountPoint.root + "/" + UUID().uuidString.lowercased()
    #expect(try HelperBitLockerReply.decode(encode(["mountPath": point])).mountPath == point)
    #expect(try HelperBitLockerReply.decode(encode(["isBitLocker": false])).isBitLocker == false)
    #expect(throws: HelperDiskFailure.bitLockerWrongSecret) { try HelperBitLockerReply.decode(encode(["failure": "bitLockerWrongSecret"])) }
    for bad in [[:], ["isBitLocker": true, "mountPath": point], ["mountPath": "/Volumes/x"],
                ["mountPath": BitLockerMountPoint.root + "/../x"], ["mountPath": point.uppercased()]] as [[String: Any]] {
        #expect(throws: HelperServiceError.invalidReply) { try HelperBitLockerReply.decode(encode(bad)) }
    }
}

@Test("挂载点判定：/var/run 别名同样认，其他目录与非 UUID 名不认")
func mountPointOwnership() {
    let id = UUID().uuidString.lowercased()
    #expect(BitLockerMountPoint.owns("/private/var/run/volisle-bitlocker/" + id))
    #expect(BitLockerMountPoint.owns("/var/run/volisle-bitlocker/" + id))
    #expect(!BitLockerMountPoint.owns("/private/var/run/volisle-write-mounts/" + id))
    #expect(!BitLockerMountPoint.owns("/private/var/run/volisle-bitlocker/" + id + "/sub"))
    #expect(!BitLockerMountPoint.owns("/private/var/run/volisle-bitlocker/"))
}

@Test("只读核对允许写保护的盘，其余条件与格式化相同")
func readOnlyPolicy() throws {
    let facts = FormatTargetFacts(registryID: 42, byteCount: 1 << 30, internalDevice: false, deviceProtocol: "USB",
                                  whole: false, writable: false, content: "Windows_NTFS", mounted: false)
    try HelperFormatPolicy.check(facts, registryID: 42, byteCount: 1 << 30, writable: false)
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts, registryID: 42, byteCount: 1 << 30) }
    let internalDisk = FormatTargetFacts(registryID: 42, byteCount: 1 << 30, internalDevice: true, deviceProtocol: "Apple Fabric",
                                         whole: false, writable: true, content: "Windows_NTFS", mounted: false)
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(internalDisk, registryID: 42, byteCount: 1 << 30, writable: false) }
    let mounted = FormatTargetFacts(registryID: 42, byteCount: 1 << 30, internalDevice: false, deviceProtocol: "USB",
                                    whole: false, writable: false, content: "Windows_NTFS", mounted: true)
    #expect(throws: VolumeError.busy) { try HelperFormatPolicy.check(mounted, registryID: 42, byteCount: 1 << 30, writable: false) }
    let apfs = FormatTargetFacts(registryID: 42, byteCount: 1 << 30, internalDevice: false, deviceProtocol: "USB",
                                 whole: false, writable: false, content: "7C3457EF-0000-11AA-AA11-00306543ECAC", mounted: false)
    #expect(throws: HelperDiskFailure.unsupportedPartition) { try HelperFormatPolicy.check(apfs, registryID: 42, byteCount: 1 << 30, writable: false) }
}
