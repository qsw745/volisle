import Foundation
import Testing
@testable import VolisleCore
struct RecoveryWriteAdmissionTests {
    private func binding() -> BlockJournalBinding {
        .init(transactionID: UUID(), volumeIdentity: "connection", bootSHA256: String(repeating:"a",count:64),
            deviceSize: 8192, blockSize: 4096, authorityEpoch: UUID(), recoveryBaselineSHA256: String(repeating:"b",count:64))
    }
    @Test func matchingAuthenticatedGeometryAdmitted() throws {
        try RecoveryWriteAdmission.validate(binding(), volumeIdentity:"connection", bootSHA256:String(repeating:"a",count:64), byteCount:8192, sectorSize:512)
    }
    @Test func initialAuthorityEpochIsValid() throws {
        var b = binding(); b.authorityEpoch = nil
        try RecoveryWriteAdmission.validate(b, volumeIdentity:"connection", bootSHA256:String(repeating:"a",count:64), byteCount:8192, sectorSize:512)
    }
    @Test(arguments: 0..<6) func differentConnectionOrGeometryRejected(_ change: Int) {
        var b = binding()
        var volume="connection", boot=String(repeating:"a",count:64), size:Int64=8192, sector=512
        switch change {
        case 0: volume="new-connection"
        case 1: boot=String(repeating:"c",count:64)
        case 2: size=16384
        case 3: sector=8192
        case 4: sector=0
        default: b.recoveryBaselineSHA256=nil
        }
        #expect(throws:(any Error).self) {
            try RecoveryWriteAdmission.validate(b,volumeIdentity:volume,bootSHA256:boot,byteCount:size,sectorSize:sector)
        }
    }
    @Test func unalignedReadsUseBoundedSectorEnvelopes() throws {
        let g = try RecoveryDiskGeometry(blockSize:512,blockCount:4096)
        for (offset,count,start,length) in [(Int64(3),8,Int64(0),512), (511,2,0,1024),
                                            (1,1_048_576,0,1_049_088), (2_097_151,1,2_096_640,512), (2_097_152,0,2_097_152,0)] {
            let p = try RecoveryRawReadPlan(offset:offset,count:count,geometry:g)
            #expect(p.start == start && p.length == length)
        }
        for (offset,count) in [(Int64(-1),1),(2_097_152,1),(Int64.max,1),(0,1_048_577),(0,-1)] {
            #expect(throws:(any Error).self) { try RecoveryRawReadPlan(offset:offset,count:count,geometry:g) }
        }
    }
}
