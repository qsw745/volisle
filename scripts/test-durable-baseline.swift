import Foundation
import Darwin
import CryptoKit
private enum Failure:Error {case accepted, injected}
@main struct BaselineTests {
    static let baseline=String(repeating:"b",count:64),boot=String(repeating:"a",count:64)
    static func reject(_ body:() throws -> Void) throws {do {try body()} catch {return};throw Failure.accepted}
    static func authority(_ dir:URL,recovering:Bool=false) throws -> BlockJournalAuthority {
        try BlockJournalAuthority.fixture(directory:dir.appendingPathComponent("authority"),recovering:recovering,pool:BlockJournalStore.pool(directory:dir.appendingPathComponent("logs")))
    }
    static func new(_ a:BlockJournalAuthority,baseline:String?=baseline) throws -> BlockJournalBinding {
        try a.newBinding(volumeIdentity:"fixture",bootSHA256:boot,deviceSize:8192,blockSize:4096,recoveryBaselineSHA256:baseline)
    }
    static func seed(_ a:BlockJournalAuthority,baseline:String?=baseline) throws -> BlockJournalBinding {
        let b=try new(a,baseline:baseline),t=try a.beginTransaction(b,stopWrites:{});t.close();return b
    }
    static func main() throws {
        let args=CommandLine.arguments
        if args.count==3 {
            let dir=URL(fileURLWithPath:args[1]),a=try authority(dir)
            let b=try new(a);a.storageBoundary={if $0==args[2] {_exit(86)}}
            let t=try a.beginTransaction(b,stopWrites:{});t.close();_exit(87)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/baseline-"+UUID().uuidString.lowercased())
        func setup(_ name:String) throws -> URL {
            let dir=root.appendingPathComponent(name)
            for leaf in ["authority","logs"] {try FileManager.default.createDirectory(at:dir.appendingPathComponent(leaf),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])};return dir
        }
        var checks:[String]=[]
        do {
            let dir=try setup("roundtrip"),a=try authority(dir),b=try seed(a);a.close()
            let r=try authority(dir),stored=try r.bindings();precondition(stored == [b] && stored[0].recoveryBaselineSHA256 == baseline)
            var observed=false
            let completion=try r.recoverUsingStoredBaseline(b,logDirectory:dir.appendingPathComponent("logs")){snapshot,digest in
                precondition(digest==baseline && snapshot.binding==b);observed=true
            }
            precondition(observed && completion.checkpoint==baseline);r.close()
            let reopened=try authority(dir),history=try reopened.recoveryCompletion(b);precondition(history==completion);reopened.close()
            checks.append("baseline-and-recovery-completion-survive-reopen")
        }
        for mode in ["wrong-checkpoint","missing-field","changed-field","missing-original","validator-fails","committed-log"] {
            let dir=try setup(mode),a=try authority(dir),logs=dir.appendingPathComponent("logs")
            var b=try new(a,baseline:mode == "missing-original" ? nil : baseline)
            let t=try a.beginTransaction(b,stopWrites:{})
            if mode == "committed-log" {_=try t.commit(checkpoint:boot,prepare:{},flushDevice:{})};t.close()
            let state=dir.appendingPathComponent("authority/anchors.json"),before=try Data(contentsOf:state)
            if mode == "missing-field" {b.recoveryBaselineSHA256=nil}
            if mode == "changed-field" {b.recoveryBaselineSHA256=boot}
            var calls=0
            try reject {
                if mode == "wrong-checkpoint" {_=try a.recover(b,logDirectory:logs,checkpoint:boot){_ in calls+=1}}
                else {_=try a.recoverUsingStoredBaseline(b,logDirectory:logs){_,_ in calls+=1;if mode == "validator-fails" {throw Failure.injected}}}
            }
            let after=try Data(contentsOf:state);precondition(before==after && a.failed && calls == (mode == "validator-fails" ? 1 : 0));a.close()
            checks.append(mode+"-refused-without-completion")
        }
        for value in ["",String(repeating:"B",count:64),String(repeating:"b",count:63),String(repeating:"b",count:65),String(repeating:"z",count:64)] {
            let dir=try setup("invalid-"+String(checks.count)),a=try authority(dir)
            let before=try Data(contentsOf:dir.appendingPathComponent("authority/anchors.json"))
            try reject {_=try new(a,baseline:value)}
            let after=try Data(contentsOf:dir.appendingPathComponent("authority/anchors.json"));precondition(before==after);a.close()
            checks.append("invalid-baseline-"+String(checks.count)+"-refused-before-log-creation")
        }
        do {
            let dir=try setup("managed"),a=try authority(dir)
            let p=try a.prepareTransaction(volumeIdentity:"fixture",bootSHA256:boot,deviceSize:8192,blockSize:4096,recoveryBaselineSHA256:baseline,stopWrites:{})
            precondition(p.binding.recoveryBaselineSHA256==baseline);p.transaction.close();a.close()
            let r=try authority(dir);let stored=try r.bindings();precondition(stored == [p.binding]);r.close()
            checks.append("managed-entry-binds-baseline-before-returning-writer")
        }
        for stage in ["written","file-durable","renamed","directory-durable"] {
            let dir=try setup("crash-"+stage),a=try authority(dir);a.close()
            let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=[dir.path,stage];try p.run();p.waitUntilExit();precondition(p.terminationStatus==86)
            let r=try authority(dir,recovering:true)
            if r.hasInterruptedPublication {try r.finishInterruptedPublication(logDirectory:dir.appendingPathComponent("logs"))}
            let b=try r.bindings()[0];precondition(b.recoveryBaselineSHA256==baseline)
            _=try r.recoverUsingStoredBaseline(b,logDirectory:dir.appendingPathComponent("logs")){_,digest in precondition(digest==baseline)}
            r.close();checks.append("initial-publication-"+stage+"-retains-independent-baseline")
        }
        for mode in ["downgrade-with-baseline","wrong-recovery-terminal","baseline-tamper"] {
            let dir=try setup(mode),a=try authority(dir),b=try seed(a)
            if mode == "wrong-recovery-terminal" {_=try a.recoverUsingStoredBaseline(b,logDirectory:dir.appendingPathComponent("logs")){_,_ in}}
            a.close()
            let state=dir.appendingPathComponent("authority/anchors.json"),key=try Data(contentsOf:dir.appendingPathComponent("authority/key.bin"))
            var e=try JSONSerialization.jsonObject(with:Data(contentsOf:state)) as! [String:Any]
            var payload=try JSONSerialization.jsonObject(with:Data(base64Encoded:e["payload"] as! String)!) as! [String:Any]
            var entries=payload["entries"] as! [[String:Any]]
            if mode == "downgrade-with-baseline" {payload["version"]=5}
            else if mode == "wrong-recovery-terminal" {entries[0]["recoveryCheckpoint"]=boot;payload["entries"]=entries}
            else {var binding=entries[0]["binding"] as! [String:Any];binding["recoveryBaselineSHA256"]=boot;entries[0]["binding"]=binding;payload["entries"]=entries}
            let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);e["payload"]=data.base64EncodedString()
            // Structural downgrades/contradictory terminal records fail even with a valid MAC.
            if mode != "baseline-tamper" {e["authentication"]=Data(HMAC<SHA256>.authenticationCode(for:Data("VolisleBlockAuthority/v1|".utf8)+data,using:SymmetricKey(data:key))).base64EncodedString()}
            try JSONSerialization.data(withJSONObject:e,options:[.sortedKeys]).write(to:state)
            try reject {_=try authority(dir)};checks.append(mode+"-rejected-at-open")
        }
        do {
            let dir=try setup("version-five"),a=try authority(dir),b=try seed(a,baseline:nil);a.close()
            let state=dir.appendingPathComponent("authority/anchors.json"),key=try Data(contentsOf:dir.appendingPathComponent("authority/key.bin"))
            var e=try JSONSerialization.jsonObject(with:Data(contentsOf:state)) as! [String:Any]
            var p=try JSONSerialization.jsonObject(with:Data(base64Encoded:e["payload"] as! String)!) as! [String:Any]
            p["version"]=5
            let data=try JSONSerialization.data(withJSONObject:p,options:[.sortedKeys]);e["payload"]=data.base64EncodedString()
            e["authentication"]=Data(HMAC<SHA256>.authenticationCode(for:Data("VolisleBlockAuthority/v1|".utf8)+data,using:SymmetricKey(data:key))).base64EncodedString()
            try JSONSerialization.data(withJSONObject:e,options:[.sortedKeys]).write(to:state)
            let r=try authority(dir),stored=try r.bindings();precondition(stored == [b] && stored[0].recoveryBaselineSHA256 == nil)
            try reject {_=try r.recoverUsingStoredBaseline(b,logDirectory:dir.appendingPathComponent("logs")){_,_ in throw Failure.injected}}
            r.close();checks.append("version-five-readable-but-no-baseline-invented")
        }
        do {
            let dir=try setup("reentry"),a=try authority(dir),b=try seed(a),logs=dir.appendingPathComponent("logs")
            let state=dir.appendingPathComponent("authority/anchors.json"),before=try Data(contentsOf:state)
            try reject {_=try a.recoverUsingStoredBaseline(b,logDirectory:logs){_,_ in
                _=try? a.recoverUsingStoredBaseline(b,logDirectory:logs){_,_ in}
            }}
            let after=try Data(contentsOf:state);precondition(a.failed && before==after);a.close()
            checks.append("stored-baseline-recovery-rejects-swallowed-reentry")
        }
        let result=root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"productionCheckpointPolicy":false],options:[.prettyPrinted,.sortedKeys]).write(to:result)
        print("passed \(checks.count): \(result.path)")
    }
}
