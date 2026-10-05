import Foundation
import Darwin
private enum Failure: Error { case accepted, injected }
@main struct ManagedTests {
    static let hash=String(repeating:"a",count:64)
    static func reject(_ body:() throws -> Void) throws {do {try body()} catch {return};throw Failure.accepted}
    static func openAuthority(_ dir:URL,recovering:Bool=false,capacity:Int=4) throws -> BlockJournalAuthority {
        try BlockJournalAuthority.fixture(directory:dir.appendingPathComponent("authority"),capacity:capacity,recovering:recovering,
            pool:BlockJournalStore.pool(directory:dir.appendingPathComponent("logs"),byteLimit:65536,fileLimit:4))
    }
    static func prepare(_ a:BlockJournalAuthority,_ volume:String="fixture",stop:@escaping ()->Void={}) throws -> (binding:BlockJournalBinding,transaction:BlockJournalTransaction,maintenance:BlockJournalMaintenanceResult) {
        try a.prepareTransaction(volumeIdentity:volume,bootSHA256:hash,deviceSize:8192,blockSize:4096,byteLimit:16384,stopWrites:stop)
    }
    static func seed(_ a:BlockJournalAuthority,_ dir:URL,_ volume:String="fixture",terminal:Bool=true,committed:Bool=true) throws -> BlockJournalBinding {
        let b=try a.newBinding(volumeIdentity:volume,bootSHA256:hash,deviceSize:8192,blockSize:4096)
        let t=try a.beginTransaction(b,byteLimit:16384,stopWrites:{})
        if committed {_=try t.commit(checkpoint:hash,prepare:{},flushDevice:{})};t.close()
        if terminal {
            if committed {_=try a.completeCommit(b,logDirectory:dir.appendingPathComponent("logs"),checkpoint:hash){_ in}}
            else {_=try a.recover(b,logDirectory:dir.appendingPathComponent("logs"),checkpoint:hash){_ in}}
        };return b
    }
    static func main() throws {
        let args=CommandLine.arguments
        if args.count == 3 {
            let dir=URL(fileURLWithPath:args[1]),a=try openAuthority(dir)
            a.storageBoundary={if $0==args[2] {_exit(86)}}
            let p=try prepare(a);p.transaction.close();_exit(87)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/managed-"+UUID().uuidString.lowercased())
        func setup(_ name:String) throws -> URL {
            let dir=root.appendingPathComponent(name)
            for leaf in ["authority","logs"] {try FileManager.default.createDirectory(at:dir.appendingPathComponent(leaf),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])};return dir
        }
        var checks:[String]=[]
        do {
            let dir=try setup("long-run");var a=try openAuthority(dir,capacity:1);var prior:BlockJournalBinding?
            for i in 0..<32 {
                let p=try prepare(a)
                precondition(p.maintenance.removedLogs == (i == 0 ? 0 : 1) && p.maintenance.advancedEpoch == (i != 0))
                if let prior {precondition(prior.authorityEpoch != p.binding.authorityEpoch)}
                if i%2 == 0 {
                    _=try p.transaction.commit(checkpoint:hash,prepare:{},flushDevice:{});p.transaction.close()
                    _=try a.completeCommit(p.binding,logDirectory:dir.appendingPathComponent("logs"),checkpoint:hash){_ in}
                } else {
                    p.transaction.close();_=try a.recover(p.binding,logDirectory:dir.appendingPathComponent("logs"),checkpoint:hash){_ in}
                }
                prior=p.binding;a.close();a=try openAuthority(dir,capacity:1)
            }
            let result=try a.maintainCompletedTransactions();precondition(result.removedLogs==1 && result.advancedEpoch)
            let again=try a.maintainCompletedTransactions();precondition(again.removedLogs==0 && !again.advancedEpoch)
            a.close();checks.append("32-alternating-terminal-outcomes-one-entry-capacity-restarts-without-manual-retirement")
            checks.append("repeated-idle-maintenance-is-no-op")
        }
        for mode in ["active-same-volume","commit-not-finalized","unknown-log","unknown-file","missing-active","corrupt-terminal","unknown-with-terminal","locked","replaced","invalid-request","oversized-reservation"] {
            let dir=try setup(mode),logs=dir.appendingPathComponent("logs"),a=try openAuthority(dir)
            var fd:Int32 = -1
            if ["active-same-volume","commit-not-finalized","missing-active"].contains(mode) {
                let b=try seed(a,dir,mode == "missing-active" ? "other-volume" : "fixture",terminal:false,committed:mode == "commit-not-finalized")
                if mode == "missing-active" {try FileManager.default.removeItem(at:logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog"))}
            } else if ["corrupt-terminal","unknown-with-terminal","invalid-request","oversized-reservation"].contains(mode) {
                let b=try seed(a,dir)
                if mode == "corrupt-terminal" {try Data("preserve-corrupt-log".utf8).write(to:logs.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog"))}
            }
            if ["unknown-log","unknown-file","unknown-with-terminal"].contains(mode) {
                try Data("preserve-unknown".utf8).write(to:logs.appendingPathComponent(mode == "unknown-file" ? "unknown" : UUID().uuidString.lowercased()+".blocklog"))
            }
            if mode == "locked" {fd=Darwin.open(logs.path,O_RDONLY|O_DIRECTORY);precondition(flock(fd,LOCK_EX|LOCK_NB)==0)}
            if mode == "replaced" {
                try FileManager.default.moveItem(at:logs,to:dir.appendingPathComponent("preserved"))
                try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            }
            let state=dir.appendingPathComponent("authority/anchors.json"),before=try Data(contentsOf:state)
            let files=try FileManager.default.contentsOfDirectory(atPath:logs.path).sorted();var stops=0
            try reject {
                if mode == "invalid-request" {_=try a.prepareTransaction(volumeIdentity:"fixture",bootSHA256:"bad",deviceSize:8192,blockSize:4096,stopWrites:{stops+=1})}
                else if mode == "oversized-reservation" {_=try a.prepareTransaction(volumeIdentity:"fixture",bootSHA256:hash,deviceSize:8192,blockSize:4096,byteLimit:131072,stopWrites:{stops+=1})}
                else {_=try prepare(a,stop:{stops+=1})}
            }
            let after=try Data(contentsOf:state),remaining=try FileManager.default.contentsOfDirectory(atPath:logs.path).sorted()
            precondition(stops==1 && a.failed && before==after && files==remaining)
            a.close();if fd>=0 {Darwin.close(fd)};checks.append(mode+"-refused-preserving-records-and-logs")
        }
        do {
            let dir=try setup("mixed"),a=try openAuthority(dir),logs=dir.appendingPathComponent("logs")
            let active=try seed(a,dir,"active",terminal:false,committed:false),ended=try seed(a,dir,"ended")
            let r=try a.maintainCompletedTransactions(),entries=try a.bindings()
            precondition(r.removedLogs==1 && r.unresolvedTransactions==1 && !r.advancedEpoch && entries.count==2)
            precondition(FileManager.default.fileExists(atPath:logs.appendingPathComponent(active.transactionID.uuidString.lowercased()+".blocklog").path))
            precondition(!FileManager.default.fileExists(atPath:logs.appendingPathComponent(ended.transactionID.uuidString.lowercased()+".blocklog").path))
            a.close();checks.append("mixed-pool-keeps-unresolved-log-and-generation")
        }
        let stages=["retirement-before-unlink","retirement-unlinked","retirement-before-directory-sync","retirement-directory-durable","written","file-durable","renamed","directory-durable"]
        for stage in stages {
            let dir=try setup("crash-"+stage),a=try openAuthority(dir);_=try seed(a,dir);a.close()
            let child=Process();child.executableURL=URL(fileURLWithPath:args[0]);child.arguments=[dir.path,stage];try child.run();child.waitUntilExit();precondition(child.terminationStatus==86)
            let r=try openAuthority(dir,recovering:true)
            if r.hasInterruptedPublication {try r.finishInterruptedPublication(logDirectory:dir.appendingPathComponent("logs"))}
            let p=try prepare(r),entries=try r.bindings();precondition(entries == [p.binding]);p.transaction.close();r.close()
            checks.append("maintenance-crash-"+stage+"-reopens-and-admits-new-binding")
        }
        for stage in ["retirement-before-unlink","file-durable"] {
            let dir=try setup("reentry-"+stage),a=try openAuthority(dir);_=try seed(a,dir)
            var inner=0,outer=0
            a.storageBoundary={if $0==stage {_=try? prepare(a,"reentrant",stop:{inner+=1})}}
            try reject {_=try prepare(a,stop:{outer+=1})};precondition(a.failed && inner==1 && outer==1);a.close()
            checks.append("maintenance-"+stage+"-rejects-swallowed-reentry")
        }
        let report:[String:Any]=["passed":checks.count,"checks":checks,"deviceIO":false,"productionHelperConnected":false]
        let result=root.appendingPathComponent("result.json");try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:result)
        print("passed \(checks.count): \(result.path)")
    }
}
