import Foundation
import Testing
@testable import VolisleCore

private func request(_ bsd: String = "disk8s2", label: String = "qsw", size: UInt64 = 2_000_188_080_128) throws -> HelperFormatRequest {
    try HelperFormatRequest(bsdName: bsd, registryID: 42, byteCount: size, label: label)
}

private func facts(content: String? = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", internalDevice: Bool? = false, bus: String? = "USB",
                   whole: Bool? = false, writable: Bool? = true, mounted: Bool = false, registryID: UInt64 = 42,
                   size: UInt64 = 2_000_188_080_128) -> FormatTargetFacts {
    FormatTargetFacts(registryID: registryID, byteCount: size, internalDevice: internalDevice, deviceProtocol: bus,
                      whole: whole, writable: writable, content: content, mounted: mounted)
}

@Test("格式化请求只接受分区、合法卷名与合理容量", arguments: [
    ("disk8", "qsw", UInt64(2_000_000_000_000)), ("disk8s2/../x", "qsw", 2_000_000_000_000), ("/dev/disk8s2", "qsw", 2_000_000_000_000),
    ("disk8s2", "", 2_000_000_000_000), ("disk8s2", "a:b", 2_000_000_000_000), ("disk8s2", String(repeating: "A", count: 33), 2_000_000_000_000),
    ("disk8s2", "qsw", 512), ("disk8s2", "qsw", 2_000_000_000_001),
])
func formatRequestRejects(bsd: String, label: String, size: UInt64) {
    #expect(throws: HelperServiceError.invalidRequest) { try request(bsd, label: label, size: size) }
}

@Test("格式化请求经 JSON 往返后仍重新校验")
func formatRequestDecode() throws {
    let good = try request(label: "中文卷名")
    #expect(try HelperFormatRequest.decode(JSONEncoder().encode(good)) == good)
    var tampered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any]
    tampered["bsdName"] = "disk0"
    #expect(throws: HelperServiceError.invalidRequest) {
        try HelperFormatRequest.decode(JSONSerialization.data(withJSONObject: tampered))
    }
    #expect(throws: HelperServiceError.invalidRequest) { try HelperFormatRequest.decode(Data(count: 5000)) }
}

@Test("后台只格式化外接 USB、可写、未挂载、类型为 Windows 数据的同一分区")
func formatPolicy() throws {
    let r = try request()
    try HelperFormatPolicy.check(facts(), against: r)
    try HelperFormatPolicy.check(facts(content: "Windows_NTFS"), against: r)
    #expect(throws: VolumeError.identityChanged) { try HelperFormatPolicy.check(facts(registryID: 7), against: r) }
    #expect(throws: VolumeError.identityChanged) { try HelperFormatPolicy.check(facts(size: 5), against: r) }
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts(internalDevice: true), against: r) }
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts(internalDevice: nil), against: r) }
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts(bus: "Thunderbolt"), against: r) }
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts(whole: true), against: r) }
    #expect(throws: VolumeError.protectedVolume) { try HelperFormatPolicy.check(facts(writable: false), against: r) }
    for content in ["7C3457EF-0000-11AA-AA11-00306543ECAC", "Apple_HFS", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "DOS_FAT_32", nil] {
        #expect(throws: HelperDiskFailure.unsupportedPartition) { try HelperFormatPolicy.check(facts(content: content), against: r) }
    }
    #expect(throws: VolumeError.busy) { try HelperFormatPolicy.check(facts(mounted: true), against: r) }
}

@Test("格式化回复：成功与失败必须一致")
func formatReply() throws {
    try HelperFormatReply.decode(JSONEncoder().encode(HelperFormatReply(formatted: true, failure: nil)))
    #expect(throws: HelperDiskFailure.busy) { try HelperFormatReply.decode(JSONEncoder().encode(HelperFormatReply(formatted: false, failure: .busy))) }
    #expect(throws: HelperServiceError.invalidReply) {
        try HelperFormatReply.decode(JSONEncoder().encode(HelperFormatReply(formatted: true, failure: .busy)))
    }
    #expect(throws: HelperServiceError.invalidReply) {
        try HelperFormatReply.decode(JSONEncoder().encode(HelperFormatReply(formatted: false, failure: nil)))
    }
}

@Test("没有安装格式化引擎（App 进程）或不是 root 时一律拒绝")
func formatNeedsHelperEngine() async throws {
    let r = try request()
    await #expect(throws: HelperDiskFailure.unavailable) { try await HelperPartitionFormatter.format(r) }
}

@Test("清除检查标记的回复：数量与失败必须二选一")
func checkMarkerReply() throws {
    #expect(try HelperCheckMarkerReply.decode(JSONEncoder().encode(HelperCheckMarkerReply(items: 12, failure: nil))) == 12)
    #expect(throws: HelperDiskFailure.checkFoundProblems) {
        try HelperCheckMarkerReply.decode(JSONEncoder().encode(HelperCheckMarkerReply(items: nil, failure: .checkFoundProblems)))
    }
    for bad in [HelperCheckMarkerReply(items: 3, failure: .busy), HelperCheckMarkerReply(items: nil, failure: nil),
                HelperCheckMarkerReply(items: -1, failure: nil)] {
        #expect(throws: HelperServiceError.invalidReply) { try HelperCheckMarkerReply.decode(JSONEncoder().encode(bad)) }
    }
}

@Test("检查未通过时带回技术信息（记录号与种类），格式不对的一律丢弃")
func checkMarkerReplyCarriesTheTechnicalReason() throws {
    let detail = "inconsistent record 1234: listed as a folder, record is a file"
    do {
        _ = try HelperCheckMarkerReply.decode(JSONEncoder().encode(HelperCheckMarkerReply(items: nil, failure: .checkFoundProblems, detail: detail)))
        Issue.record("应当抛出")
    } catch let refusal as CheckMarkerRefusal {
        #expect(refusal.failure == .checkFoundProblems && refusal.detail == detail)
        #expect(refusal.errorDescription?.contains(detail) == true)
    }
    #expect(CheckMarkerRefusal(.checkReadFailed, detail: "read failed at record 99") != nil)
    // The folder holding the entry and both sequence numbers (a stale entry when they differ).
    for good in ["inconsistent record 194973: listed as a folder, record is a file; folder 5, entry seq 3, record seq 7",
                 "inconsistent record 281474976710655: listed as a folder, record is a file; folder 281474976710655, entry seq 65535, record seq 65535",
                 "inconsistent record 99999: entry beyond the file table; folder 42, entry seq 1"] {
        #expect(CheckMarkerRefusal(.checkFoundProblems, detail: good)?.detail == good)
    }
    for bad in ["~/秘密.txt", "inconsistent record 12: 照片", "inconsistent record x: a", String(repeating: "a", count: 200),
                "inconsistent record 12: listed but not in use; folder 5", "inconsistent record 12: listed but not in use; folder 5, entry seq x",
                "inconsistent record 12: listed but not in use; folder 5, entry seq 1, record seq 2; 照片",
                "inconsistent record 12: listed but not in use; folder 5, record seq 2",
                "inconsistent record 12: a; folder 5, entry seq 1, record seq 2" + String(repeating: "0", count: 120)] {
        #expect(CheckMarkerRefusal(.checkFoundProblems, detail: bad) == nil)
        #expect(throws: HelperDiskFailure.checkFoundProblems) {
            try HelperCheckMarkerReply.decode(JSONEncoder().encode(HelperCheckMarkerReply(items: nil, failure: .checkFoundProblems, detail: bad)))
        }
    }
}

@Test("清除检查标记：没有维护引擎（App 进程）或不是 root 时拒绝；整盘请求无效")
func checkMarkerNeedsHelperEngine() async throws {
    let request = try HelperDiskRequest(bsdName: "disk8s1", registryID: 42, byteCount: 2_000_000_000_000)
    await #expect(throws: HelperDiskFailure.unavailable) { try await HelperPartitionFormatter.clearCheckMarker(request) }
    #expect(throws: HelperServiceError.invalidRequest) { try HelperDiskRequest(bsdName: "disk8", registryID: 42, byteCount: 2_000_000_000_000) }
}
