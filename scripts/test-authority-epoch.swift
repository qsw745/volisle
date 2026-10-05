import Foundation
import Darwin
import CryptoKit
private enum Fault: Error { case injected }
@main struct EpochTests {
    static let checkpoint = String(repeating:"d",count:64)
    static func rejected(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw Fault.injected }
    static func main() throws {
        let args=CommandLine.arguments
        if args.count == 3 {
            let dir=URL(fileURLWithPath:args[1]), stage=args[2]
            let a=try BlockJournalAuthority.fixture(directory:dir.appendingPathComponent("authority"),recovering:stage.hasPrefix("recovery-"))
            a.storageBoundary={ if $0 == stage { _exit(86) } }
            if stage.hasPrefix("recovery-") { try a.finishInterruptedPublication(logDirectory:dir.appendingPathComponent("logs")) }
            else { try a.advanceEpoch(logDirectory:dir.appendingPathComponent("logs")) }
            _exit(87)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/epoch-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var checks:[String]=[]
        func setup(_ name:String) throws -> URL {
            let dir=root.appendingPathComponent(name)
            for leaf in ["authority","logs"] { try FileManager.default.createDirectory(at:dir.appendingPathComponent(leaf),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
            return dir
        }
        func newBinding(_ a:BlockJournalAuthority) throws -> BlockJournalBinding {
            try a.newBinding(volumeIdentity:"fixture",bootSHA256:String(repeating:"a",count:64),deviceSize:8192,blockSize:4096)
        }
        func complete(_ a:BlockJournalAuthority,_ dir:URL,retire:Bool=true) throws -> BlockJournalBinding {
            let b=try newBinding(a),logs=dir.appendingPathComponent("logs")
            let s=try BlockJournalStore(directory:logs,binding:b,key:a.key(),failClosed:{})
            _=try a.save(b,previous:nil,next:s.seal);let old=s.seal
            try s.commit(checkpoint:checkpoint,flushDevice:{})
            _=try a.save(b,previous:old,next:s.seal);s.close()
            _=try a.completeCommit(b,logDirectory:logs,checkpoint:checkpoint){_ in}
            if retire { _=try a.retireLog(b,logDirectory:logs) }
            return b
        }
        do {
            let dir=try setup("long-run"),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            var a=try BlockJournalAuthority.fixture(directory:auth,capacity:2)
            let key=try a.key();var expired:[BlockJournalBinding]=[]
            for i in 0..<260 {
                let b=try complete(a,dir);if i == 0 || i == 2 { expired.append(b) }
                if i%2 == 1 { try a.advanceEpoch(logDirectory:logs);a.close();a=try BlockJournalAuthority.fixture(directory:auth,capacity:2) }
            }
            let remaining=try a.bindings(),sameKey=try a.key();precondition(remaining.isEmpty && key==sameKey)
            a.close();checks.append("260-completions-with-two-entry-capacity-and-130-restarts")
            for first in expired {
            for operation in ["read","save","admit","recover","finish","retire","history"] {
                let r=try BlockJournalAuthority.fixture(directory:auth,capacity:2)
                try rejected {
                    switch operation {
                    case "read": _=try r.read(first)
                    case "save": _=try r.save(first,previous:nil,next:.init(sequence:1,authentication:String(repeating:"b",count:64)))
                    case "admit":try r.requireNewTransaction(first)
                    case "recover":_=try r.recover(first,logDirectory:logs,checkpoint:checkpoint){_ in throw Fault.injected}
                    case "finish":_=try r.completeCommit(first,logDirectory:logs,checkpoint:checkpoint){_ in throw Fault.injected}
                    case "retire":_=try r.retireLog(first,logDirectory:logs)
                    default:_=try r.commitCompletion(first)
                    }
                }
                precondition(r.failed);r.close();checks.append("old-epoch-"+operation+"-rejected")
            }
            }
        }
        for mode in ["active","commit-only","unretired","unknown-file","locked-directory","empty-initial"] {
            let dir=try setup(mode),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth)
            var held:Int32 = -1
            if mode == "active" || mode == "commit-only" {
                let b=try newBinding(a),s=try BlockJournalStore(directory:logs,binding:b,key:a.key(),failClosed:{})
                _=try a.save(b,previous:nil,next:s.seal)
                if mode == "commit-only" { let old=s.seal;try s.commit(checkpoint:checkpoint,flushDevice:{});_=try a.save(b,previous:old,next:s.seal) };s.close()
            } else if mode != "empty-initial" { _=try complete(a,dir,retire:mode != "unretired") }
            if mode == "unknown-file" { try Data("keep".utf8).write(to:logs.appendingPathComponent("unknown")) }
            if mode == "locked-directory" { held=open(logs.path,O_RDONLY|O_DIRECTORY);precondition(flock(held,LOCK_EX|LOCK_NB)==0) }
            let before=try Data(contentsOf:auth.appendingPathComponent("anchors.json"))
            try rejected {try a.advanceEpoch(logDirectory:logs)};precondition(a.failed);a.close();if held>=0 {close(held)}
            let after=try Data(contentsOf:auth.appendingPathComponent("anchors.json"));precondition(before==after)
            checks.append(mode+"-rollover-refused-with-state-retained")
        }
        for stage in ["before-write","written","file-durable","renamed","directory-durable"] {
            let dir=try setup("throw-"+stage),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth);_=try complete(a,dir)
            a.storageBoundary={if $0==stage {throw Fault.injected}}
            try rejected {try a.advanceEpoch(logDirectory:logs)};precondition(a.failed);a.close()
            let r=try BlockJournalAuthority.fixture(directory:auth);let entries=try r.bindings()
            precondition(entries.isEmpty == ["renamed","directory-durable"].contains(stage));r.close()
            checks.append("rollover-throw-"+stage)
        }
        func child(_ dir:URL,_ stage:String) throws {
            let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=[dir.path,stage]
            try p.run();p.waitUntilExit();precondition(p.terminationStatus==86)
        }
        for stage in ["written","file-durable","renamed","directory-durable","recovery-before-rename","recovery-after-rename","recovery-after-durable"] {
            let dir=try setup("crash-"+stage),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth);let old=try complete(a,dir);a.close()
            try child(dir,stage.hasPrefix("recovery-") ? "file-durable" : stage)
            if stage.hasPrefix("recovery-") {try child(dir,stage)}
            let r=try BlockJournalAuthority.fixture(directory:auth,recovering:true)
            if r.hasInterruptedPublication {try r.finishInterruptedPublication(logDirectory:logs)}
            let entries=try r.bindings();precondition(entries.isEmpty)
            _=try complete(r,dir);r.close()
            let q=try BlockJournalAuthority.fixture(directory:auth);try rejected {_=try q.read(old)};q.close()
            checks.append("rollover-crash-"+stage+"-new-work-admitted-old-work-fenced")
        }
        for mode in ["skip-generation","missing-epoch","downgrade-format","retain-entry","forget-active","replay-old-generation","recreated-log"] {
            let dir=try setup(mode),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth)
            _=try complete(a,dir);try a.advanceEpoch(logDirectory:logs)
            _=try complete(a,dir);a.close()
            try child(dir,"file-durable")
            let files=try FileManager.default.contentsOfDirectory(at:auth,includingPropertiesForKeys:nil)
            let temp=files.first{$0.pathExtension=="tmp"}!,state=auth.appendingPathComponent("anchors.json")
            if mode == "recreated-log" {
                try Data("do-not-delete".utf8).write(to:logs.appendingPathComponent("unexpected"))
                let r=try BlockJournalAuthority.fixture(directory:auth,recovering:true)
                try rejected {try r.finishInterruptedPublication(logDirectory:logs)};r.close()
                precondition(FileManager.default.fileExists(atPath:temp.path))
            } else {
                func payload(_ file:URL)throws->[String:Any] {
                    let e=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
                    return try JSONSerialization.jsonObject(with:Data(base64Encoded:e["payload"] as! String)!) as! [String:Any]
                }
                let target=mode == "forget-active" ? state : temp
                var changed=try payload(target)
                switch mode {
                case "skip-generation":changed["generation"]=3
                case "missing-epoch":changed.removeValue(forKey:"epoch")
                case "downgrade-format":changed["version"]=3
                case "retain-entry":changed["entries"]=(try payload(state))["entries"]
                case "forget-active":var values=changed["entries"] as! [[String:Any]];values[0].removeValue(forKey:"commitCheckpoint");changed["entries"]=values
                default:changed["generation"]=1
                }
                let raw=try JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys])
                let key=try Data(contentsOf:auth.appendingPathComponent("key.bin"))
                let tag=Data(HMAC<SHA256>.authenticationCode(for:Data("VolisleBlockAuthority/v1|".utf8)+raw,using:SymmetricKey(data:key)))
                try JSONSerialization.data(withJSONObject:["payload":raw.base64EncodedString(),"authentication":tag.base64EncodedString()],options:[.sortedKeys]).write(to:target)
                try rejected {_=try BlockJournalAuthority.fixture(directory:auth,recovering:true)}
            }
            checks.append(mode+"-authenticated-rollover-refused")
        }
        do {
            let dir=try setup("reentrant-new-work"),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth);_=try complete(a,dir)
            var injected=false
            a.storageBoundary={ stage in
                if stage == "before-write" && !injected {
                    injected=true
                    if let b=try? a.newBinding(volumeIdentity:"other",bootSHA256:String(repeating:"a",count:64),deviceSize:8192,blockSize:4096) {
                        _=try? a.save(b,previous:nil,next:.init(sequence:1,authentication:String(repeating:"b",count:64)))
                    }
                }
            }
            try rejected {try a.advanceEpoch(logDirectory:logs)};precondition(a.failed);a.close()
            let r=try BlockJournalAuthority.fixture(directory:auth);let retained=try r.bindings();precondition(retained.count==1);r.close()
            checks.append("new-work-during-rollover-refused-without-dropping-an-active-entry")
        }
        do {
            let dir=try setup("late-recovery-reentry"),auth=dir.appendingPathComponent("authority"),logs=dir.appendingPathComponent("logs")
            let a=try BlockJournalAuthority.fixture(directory:auth);_=try complete(a,dir);a.close()
            try child(dir,"file-durable")
            let r=try BlockJournalAuthority.fixture(directory:auth,recovering:true)
            r.storageBoundary={if $0 == "recovery-after-durable" {_=try? r.key()} }
            try rejected {try r.finishInterruptedPublication(logDirectory:logs)};precondition(r.failed);r.close()
            let q=try BlockJournalAuthority.fixture(directory:auth);let entries=try q.bindings();precondition(entries.isEmpty);q.close()
            checks.append("late-recovery-reentry-reports-failure-with-durable-fence-on-reopen")
        }
        let report:[String:Any]=["passed":checks.count,"checks":checks,"productionConnected":false]
        let file=root.appendingPathComponent("result.json");try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:file)
        print("\(checks.count) passed: \(file.path)")
    }
}
