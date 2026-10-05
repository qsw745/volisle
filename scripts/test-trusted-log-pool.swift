import Foundation
import Darwin
import CryptoKit
private enum TestFailure: Error { case accepted, injected }
@main struct TrustedPoolTests {
    static let checkpoint=String(repeating:"c",count:64)
    static func rejected(_ body:() throws -> Void) throws {
        do { try body() } catch { return }; throw TestFailure.accepted
    }
    static func config(_ root:URL, bytes:Int=1024*1024*1024, files:Int=256) throws -> BlockJournalPool {
        try BlockJournalStore.pool(directory:root.appendingPathComponent("logs"),byteLimit:bytes,fileLimit:files)
    }
    static func authority(_ root:URL, recovering:Bool=false, bytes:Int=1024*1024*1024, files:Int=256) throws -> BlockJournalAuthority {
        try BlockJournalAuthority.fixture(directory:root.appendingPathComponent("authority"),recovering:recovering,pool:config(root,bytes:bytes,files:files))
    }
    static func binding(_ a:BlockJournalAuthority,_ volume:String="fixture") throws -> BlockJournalBinding {
        try a.newBinding(volumeIdentity:volume,bootSHA256:String(repeating:"a",count:64),deviceSize:8192,blockSize:4096)
    }
    static func terminal(_ a:BlockJournalAuthority,_ root:URL,retire:Bool=false) throws -> BlockJournalBinding {
        let b=try binding(a),t=try a.beginTransaction(b,byteLimit:16384,stopWrites:{})
        _=try t.commit(checkpoint:checkpoint,prepare:{},flushDevice:{});t.close()
        _=try a.completeCommit(b,logDirectory:root.appendingPathComponent("logs"),checkpoint:checkpoint){_ in}
        if retire { _=try a.retireLog(b,logDirectory:root.appendingPathComponent("logs")) };return b
    }
    static func main() throws {
        let args=CommandLine.arguments
        if args.count == 3 {
            let root=URL(fileURLWithPath:args[1]),stage=args[2],a=try authority(root)
            a.storageBoundary={if $0==stage {_exit(86)}}
            try a.advanceEpoch(logDirectory:root.appendingPathComponent("logs"));_exit(87)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/trusted-pool-"+UUID().uuidString.lowercased())
        func setup(_ name:String) throws -> URL {
            let dir=root.appendingPathComponent(name)
            for leaf in ["authority","logs","wrong"] {
                try FileManager.default.createDirectory(at:dir.appendingPathComponent(leaf),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            };return dir
        }
        var checks:[String]=[]
        for op in ["epoch","retire","commit","recover","inspect"] {
            let dir=try setup("wrong-"+op),logs=dir.appendingPathComponent("logs"),wrong=dir.appendingPathComponent("wrong"),a=try authority(dir)
            let b:BlockJournalBinding
            if op == "epoch" || op == "retire" { b=try terminal(a,dir) }
            else {
                b=try binding(a);let t=try a.beginTransaction(b,byteLimit:16384,stopWrites:{})
                if op != "recover" {_=try t.commit(checkpoint:checkpoint,prepare:{},flushDevice:{})};t.close()
            }
            let oldState=try Data(contentsOf:dir.appendingPathComponent("authority/anchors.json"))
            var callback=false
            try rejected {
                switch op {
                case "epoch":try a.advanceEpoch(logDirectory:wrong)
                case "retire":_=try a.retireLog(b,logDirectory:wrong)
                case "commit":_=try a.completeCommit(b,logDirectory:wrong,checkpoint:checkpoint){_ in callback=true}
                case "recover":_=try a.recover(b,logDirectory:wrong,checkpoint:checkpoint){_ in callback=true}
                default:
                    let file=b.transactionID.uuidString.lowercased()+".blocklog"
                    try FileManager.default.copyItem(at:logs.appendingPathComponent(file),to:wrong.appendingPathComponent(file))
                    _=try BlockJournalStore.inspect(directory:wrong,binding:b,key:a.key(),expectedSeal:a.read(b)!,expectedPool:config(dir))
                }
            }
            let now=try Data(contentsOf:dir.appendingPathComponent("authority/anchors.json"))
            let retained=try FileManager.default.contentsOfDirectory(atPath:logs.path)
            precondition(!callback && oldState==now && !retained.isEmpty)
            a.close();checks.append("wrong-pool-"+op+"-refused-state-and-original-log-retained")
        }
        for mode in ["replace-live","replace-restart","rename-live","symlink","permissions","changed-budget","changed-file-limit","other-path","omit-config","downgrade","tamper"] {
            let dir=try setup(mode),logs=dir.appendingPathComponent("logs"),auth=dir.appendingPathComponent("authority"),a=try authority(dir)
            _=try terminal(a,dir,retire:true)
            let bytes=try Data(contentsOf:auth.appendingPathComponent("anchors.json"))
            if mode.hasPrefix("replace") || mode == "rename-live" || mode == "symlink" {
                let moved=dir.appendingPathComponent("preserved")
                try FileManager.default.moveItem(at:logs,to:moved)
                if mode.hasPrefix("replace") {try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
                if mode == "symlink" {try FileManager.default.createSymbolicLink(at:logs,withDestinationURL:moved)}
            } else if mode == "permissions" {precondition(chmod(logs.path,0o755)==0)}
            if mode.hasSuffix("live") || mode == "symlink" || mode == "permissions" {
                try rejected {try a.advanceEpoch(logDirectory:logs)};precondition(a.failed);a.close()
            } else {
                a.close()
                if mode == "downgrade" || mode == "tamper" {
                    var e=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
                    var p=try JSONSerialization.jsonObject(with:Data(base64Encoded:e["payload"] as! String)!) as! [String:Any]
                    if mode == "downgrade" {p["version"]=4;p.removeValue(forKey:"pool")}
                    else {var pool=p["pool"] as! [String:Any];pool["byteLimit"]=16384;p["pool"]=pool}
                    let payload=try JSONSerialization.data(withJSONObject:p,options:[.sortedKeys]);e["payload"]=payload.base64EncodedString()
                    // Even a structurally valid authenticated downgrade cannot adopt a pool.
                    if mode == "downgrade" {
                        let key=try Data(contentsOf:auth.appendingPathComponent("key.bin"))
                        e["authentication"]=Data(HMAC<SHA256>.authenticationCode(for:Data("VolisleBlockAuthority/v1|".utf8)+payload,using:SymmetricKey(data:key))).base64EncodedString()
                    }
                    try JSONSerialization.data(withJSONObject:e,options:[.sortedKeys]).write(to:auth.appendingPathComponent("anchors.json"))
                }
                try rejected {
                    if mode == "omit-config" {_=try BlockJournalAuthority.fixture(directory:auth)}
                    else if mode == "other-path" {_=try BlockJournalAuthority.fixture(directory:auth,pool:BlockJournalStore.pool(directory:dir.appendingPathComponent("wrong")))}
                    else {_=try authority(dir,bytes:mode == "changed-budget" ? 32768 : 1024*1024*1024,files:mode == "changed-file-limit" ? 1 : 256)}
                }
            }
            checks.append(mode+"-refused")
        }
        for mode in ["unknown-file","old-log","pool-locked"] {
            let dir=try setup("bootstrap-"+mode),logs=dir.appendingPathComponent("logs")
            var fd:Int32 = -1
            if mode == "pool-locked" {fd=open(logs.path,O_RDONLY|O_DIRECTORY);precondition(flock(fd,LOCK_EX|LOCK_NB)==0)}
            else {try Data("preserved".utf8).write(to:logs.appendingPathComponent(mode == "old-log" ? UUID().uuidString.lowercased()+".blocklog" : "unknown"))}
            try rejected {_=try authority(dir)};if fd>=0 {close(fd)}
            let untouched=try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("authority").path)
            precondition(untouched.isEmpty)
            checks.append("bootstrap-"+mode+"-refused-before-key-creation")
        }
        for mode in ["byte-budget","file-budget"] {
            let dir=try setup(mode),bytes=mode == "byte-budget" ? 16384 : 65536,files=mode == "file-budget" ? 1 : 256
            var a=try authority(dir,bytes:bytes,files:files)
            let first=try terminal(a,dir),next=try binding(a,"second-volume")
            try rejected {_=try a.beginTransaction(next,byteLimit:16384,stopWrites:{})};a.close()
            a=try authority(dir,bytes:bytes,files:files)
            _=try a.retireLog(first,logDirectory:dir.appendingPathComponent("logs"))
            let t=try a.beginTransaction(binding(a,"third-volume"),byteLimit:16384,stopWrites:{});t.close();a.close()
            checks.append(mode+"-shared-across-volumes-and-reused-after-retirement")
        }
        do {
            let dir=try setup("write-path-replaced"),a=try authority(dir),logs=dir.appendingPathComponent("logs")
            let t=try a.beginTransaction(binding(a),stopWrites:{})
            try FileManager.default.moveItem(at:logs,to:dir.appendingPathComponent("preserved"))
            try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            var written=false
            try rejected {try t.write(offset:0,before:Data(count:4096),after:Data(repeating:1,count:4096)){_,_ in written=true}}
            precondition(!written && t.state == .failed);t.close();a.close();checks.append("pool-replacement-stops-before-device-write")
        }
        for stage in ["written","file-durable","renamed","directory-durable"] {
            let dir=try setup("crash-"+stage),a=try authority(dir);_=try terminal(a,dir,retire:true);a.close()
            let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=[dir.path,stage];try p.run();p.waitUntilExit();precondition(p.terminationStatus==86)
            var r=try authority(dir,recovering:true)
            if r.hasInterruptedPublication {
                try rejected {try r.finishInterruptedPublication(logDirectory:dir.appendingPathComponent("wrong"))};r.close()
                r=try authority(dir,recovering:true)
                try r.finishInterruptedPublication(logDirectory:dir.appendingPathComponent("logs"))
            }
            let entries=try r.bindings();precondition(entries.isEmpty)
            _=try terminal(r,dir);r.close();checks.append("bound-pool-epoch-crash-"+stage+"-resumed")
        }
        do {
            let dir=try setup("legacy-not-adopted"),auth=dir.appendingPathComponent("authority")
            let a=try BlockJournalAuthority.fixture(directory:auth);a.close()
            let old=try Data(contentsOf:auth.appendingPathComponent("anchors.json"))
            try rejected {_=try authority(dir)}
            let after=try Data(contentsOf:auth.appendingPathComponent("anchors.json"));precondition(old==after)
            checks.append("legacy-unbound-authority-not-silently-adopted")
        }
        do {
            let dir=try setup("raw-wrong-pool"),a=try authority(dir),b=try binding(a)
            try rejected {_=try BlockJournalStore(directory:dir.appendingPathComponent("wrong"),binding:b,key:a.key(),expectedPool:config(dir),failClosed:{})}
            let untouched=try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("wrong").path)
            precondition(untouched.isEmpty);a.close();checks.append("store-validates-held-directory-before-file-creation")
        }
        do {
            let dir=try setup("late-pool-replacement"),logs=dir.appendingPathComponent("logs"),a=try authority(dir)
            let b=try terminal(a,dir,retire:true)
            a.storageBoundary={stage in
                if stage == "file-durable" {
                    try FileManager.default.moveItem(at:logs,to:dir.appendingPathComponent("preserved"))
                    try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                }
            }
            try rejected {try a.advanceEpoch(logDirectory:logs)};a.close()
            try FileManager.default.removeItem(at:logs) // Only the new empty test directory.
            try FileManager.default.moveItem(at:dir.appendingPathComponent("preserved"),to:logs)
            let r=try authority(dir);let entries=try r.bindings();precondition(entries == [b]);r.close()
            checks.append("pool-replacement-before-publication-retains-receipts")
        }
        do {
            let dir=try setup("append-late-replacement"),logs=dir.appendingPathComponent("logs"),a=try authority(dir)
            let s=try BlockJournalStore(directory:logs,binding:binding(a),key:a.key(),expectedPool:config(dir),failClosed:{})
            s.storageBoundary={stage in
                if stage == "durable" {
                    try FileManager.default.moveItem(at:logs,to:dir.appendingPathComponent("preserved"))
                    try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                }
            }
            try rejected {try s.record(offset:0,before:Data(count:4096),after:Data(repeating:1,count:4096))}
            precondition(s.failed);s.close();a.close()
            checks.append("pool-replacement-during-log-flush-refuses-new-seal")
        }
        let report:[String:Any]=["passed":checks.count,"checks":checks,"productionHelperConnected":false,"qswTouched":false]
        let output=root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("passed \(checks.count): \(output.path)")
    }
}
