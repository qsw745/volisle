import Foundation
import Darwin
private enum Failure:Error {case injected}
@main struct InspectionTests {
    static func actual(_ path: String) throws {
        let url=URL(fileURLWithPath:path),root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench")
        precondition(url.resolvingSymlinksInPath().path==url.path && url.deletingLastPathComponent().deletingLastPathComponent().path==root.path && url.deletingLastPathComponent().lastPathComponent.hasPrefix("block-journal-"))
        let fd=open(path,O_RDONLY|O_NOFOLLOW);precondition(fd>=0);defer {close(fd)}
        var info=stat();precondition(fstat(fd,&info)==0 && info.st_mode & S_IFMT == S_IFREG && info.st_size==64*1024*1024 && info.st_uid==getuid() && info.st_nlink==1)
        func read(_ offset:Int64,_ count:Int) throws -> Data {
            var data=Data(count:count)
            let n=data.withUnsafeMutableBytes {pread(fd,$0.baseAddress,count,off_t(offset))}
            guard n==count else {throw Failure.injected};return data
        }
        var calls=0
        let status=NTFSReadOnlyInspection.inspect(deviceSize:Int64(info.st_size)) {offset,count in calls+=1;return try read(offset,count)}
        precondition(status==NK_CHECK_CLEAN && calls>=3)
        var checks=1
        for at in Set([1,calls/2,calls]).sorted() {
            for short in [false,true] {
                var n=0
                let code=NTFSReadOnlyInspection.inspect(deviceSize:Int64(info.st_size)) {offset,count in
                    n+=1
                    if n==at {if short {return Data(count:max(0,count-1))};throw Failure.injected}
                    return try read(offset,count)
                }
                precondition(code==NK_CHECK_UNKNOWN);checks+=1
            }
        }
        precondition(NTFSReadOnlyInspection.inspect(deviceSize:Int64(info.st_size),readBudget:512,read:read)==NK_CHECK_UNKNOWN);checks+=1
        print("{\"passed\":\(checks),\"cleanReadCalls\":\(calls)}")
    }
    static func main() throws {
        if CommandLine.arguments.count==2 {try actual(CommandLine.arguments[1]);return}
        var checks:[String]=[]
        for status in [NK_CHECK_CLEAN,NK_CHECK_DIRTY,NK_CHECK_HIBERNATED,NK_CHECK_LOG_UNSAFE,NK_CHECK_UNKNOWN] {
            var calls=0
            let actual=NTFSReadOnlyInspection.fixture(deviceSize:8192,read:{offset,count in
                precondition(offset==0 && count==512);calls+=1;return Data(repeating:7,count:count)
            }) {io in
                precondition(io.readonly==1 && io.pwrite==nil && io.sync==nil)
                var bytes=[UInt8](repeating:0,count:512)
                let n=bytes.withUnsafeMutableBytes {io.pread!(io.ctx,$0.baseAddress,512,0)}
                precondition(n==512 && bytes.allSatisfy{$0==7});return Int32(status)
            }
            precondition(actual==status && calls==1);checks.append("readonly-inspector-preserves-status-\(status)")
        }
        for mode in ["negative-offset","negative-count","past-end","huge-offset","huge-count","oversized-read","nil-buffer","short-read","long-read","throw","budget","call-limit"] {
            var reads=0
            let actual=NTFSReadOnlyInspection.fixture(deviceSize:2*1024*1024,readBudget:mode == "budget" ? 512 : 128*1024*1024,read:{_,count in
                reads+=1
                if mode == "throw" {throw Failure.injected}
                return Data(count:count+(mode == "short-read" ? -1 : (mode == "long-read" ? 1 : 0)))
            }) {io in
                var bytes=[UInt8](repeating:0,count:512)
                bytes.withUnsafeMutableBytes {p in
                    switch mode {
                    case "negative-offset":_=io.pread!(io.ctx,p.baseAddress,1,-1)
                    case "negative-count":_=io.pread!(io.ctx,p.baseAddress,-1,0)
                    case "past-end":_=io.pread!(io.ctx,p.baseAddress,512,2*1024*1024-1)
                    case "huge-offset":_=io.pread!(io.ctx,p.baseAddress,512,Int64.max)
                    case "huge-count":_=io.pread!(io.ctx,p.baseAddress,Int64.max,0)
                    case "oversized-read":_=io.pread!(io.ctx,p.baseAddress,1024*1024+1,0)
                    case "nil-buffer":_=io.pread!(io.ctx,nil,1,0)
                    case "budget":precondition(io.pread!(io.ctx,p.baseAddress,512,0)==512);_=io.pread!(io.ctx,p.baseAddress,1,512)
                    case "call-limit":for _ in 0..<32769 {_=io.pread!(io.ctx,nil,0,0)}
                    default:_=io.pread!(io.ctx,p.baseAddress,512,0)
                    }
                    precondition(io.pread!(io.ctx,p.baseAddress,512,0) == -1)
                }
                return Int32(NK_CHECK_CLEAN) // Simulate an engine swallowing the failed probe.
            }
            let expected=["short-read","long-read","throw","budget"].contains(mode) ? 1 : 0
            precondition(actual==NK_CHECK_UNKNOWN && reads==expected);checks.append(mode+"-sticky-incomplete-inspection")
        }
        for (size,budget) in [(Int64(0),512),(511,512),(513,512),(8192,511),(8192,128*1024*1024+1)] {
            var called=false
            let status=NTFSReadOnlyInspection.fixture(deviceSize:size,readBudget:budget,read:{_,_ in throw Failure.injected}) {_ in called=true;return Int32(NK_CHECK_CLEAN)}
            precondition(status==NK_CHECK_UNKNOWN && !called);checks.append("invalid-size-or-budget-\(size)-\(budget)-rejected-before-engine")
        }
        var zeroReads=0
        let status=NTFSReadOnlyInspection.fixture(deviceSize:8192,read:{_,_ in zeroReads+=1;return Data()}) {io in
            precondition(io.pread!(io.ctx,nil,0,8192)==0);return Int32(NK_CHECK_CLEAN)
        }
        precondition(status==NK_CHECK_CLEAN && zeroReads==0);checks.append("zero-length-at-end-does-not-read-device")
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/checkpoint-health-20260925")
        try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("inspection-result.json"))
        print("passed \(checks.count) read-only inspection checks")
    }
}
