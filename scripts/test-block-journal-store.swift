import Foundation
import Darwin

@main struct StoreTests {
    static let key = Data(repeating: 7, count: 32) // Test-only, never a product key.
    static func main() throws {
        #if VOLISLE_BLOCK_JOURNAL_TESTING
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let dir=URL(fileURLWithPath:CommandLine.arguments[2]);let mode=CommandLine.arguments[3]
            let b=BlockJournalBinding(transactionID:UUID(uuidString:CommandLine.arguments[4])!,volumeIdentity:"fixture-device",bootSHA256:String(repeating:"a",count:64),deviceSize:64*1024*1024,blockSize:4096)
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{})
            func receipt() throws {
                try JSONSerialization.data(withJSONObject:["sequence":store.seal.sequence,"authentication":store.seal.authentication]).write(to:dir.appendingPathComponent("trusted-test-seal.json"))
            }
            if mode == "interrupted" {
                try receipt();store.storageBoundary={if $0=="written" {_exit(86)}}
            }
            try store.record(offset:0,before:Data(count:4096),after:Data(repeating:2,count:4096))
            if mode=="committed" {try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{})}
            try receipt();_exit(86)
        }
        #endif
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workbench/block-store-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var checks: [String] = []
        func fixture(_ name: String) throws -> (URL,BlockJournalBinding) {
            let directory=root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            return (directory,BlockJournalBinding(transactionID:UUID(),volumeIdentity:"fixture-device",bootSHA256:String(repeating:"a",count:64),deviceSize:64*1024*1024,blockSize:4096))
        }
        func path(_ dir: URL,_ b: BlockJournalBinding) -> URL { dir.appendingPathComponent(b.transactionID.uuidString.lowercased()+".blocklog") }
        func write(_ store: BlockJournalStore) throws { try store.record(offset:4096,before:Data(repeating:1,count:4096),after:Data(repeating:2,count:4096)) }
        func rejected(_ body: () throws -> Void) throws {
            var rejected=false
            do { try body() } catch { rejected=true }
            guard rejected else { throw NSError(domain:"test-expected-rejection",code:1) }
        }
        do {
            let (dir,b)=try fixture("roundtrip")
            var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{poisoned += 1})
            try rejected { _=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:store.seal) }
            checks.append("active-writer-excludes-inspection")
            try write(store)
            let pending=store.seal
            var flushed=false
            try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{flushed=true})
            precondition(flushed && poisoned==0)
            let seal=store.seal;store.close()
            let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)
            precondition(state.writes.count==1 && state.writes[0].before==Data(repeating:1,count:4096) && state.checkpoint==String(repeating:"b",count:64))
            checks.append("authenticated-write-and-durable-commit-roundtrip")
            try rejected { _=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:pending) }
            checks.append("stale-trusted-seal-refused")
            try rejected { _=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{}) }
            checks.append("existing-journal-never-overwritten")
        }
        for kind in ["wrong-key","wrong-volume","wrong-boot","wrong-size","wrong-block","wrong-transaction","changed-byte","truncated-byte","valid-prefix-rollback","duplicate-frame","file-permissions","hardlink","symlink"] {
            let (dir,b)=try fixture(kind)
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{})
            let initial=try Data(contentsOf:path(dir,b))
            try write(store);let seal=store.seal;store.close()
            var expected=b;var usedKey=key
            switch kind {
            case "wrong-key":usedKey=Data(repeating:8,count:32)
            case "wrong-volume","wrong-boot","wrong-size","wrong-block","wrong-transaction":
                expected=BlockJournalBinding(transactionID:kind=="wrong-transaction" ? UUID():b.transactionID,
                    volumeIdentity:kind=="wrong-volume" ? "different":b.volumeIdentity,
                    bootSHA256:kind=="wrong-boot" ? String(repeating:"c",count:64):b.bootSHA256,
                    deviceSize:kind=="wrong-size" ? b.deviceSize*2:b.deviceSize,blockSize:kind=="wrong-block" ? 8192:b.blockSize)
            case "changed-byte":var bytes=try Data(contentsOf:path(dir,b));bytes[bytes.count-12] ^= 1;try bytes.write(to:path(dir,b))
            case "truncated-byte":var bytes=try Data(contentsOf:path(dir,b));bytes.removeLast();try bytes.write(to:path(dir,b))
            case "valid-prefix-rollback":try initial.write(to:path(dir,b))
            case "duplicate-frame":var bytes=try Data(contentsOf:path(dir,b));bytes.append(initial);try bytes.write(to:path(dir,b))
            case "file-permissions":precondition(chmod(path(dir,b).path,0o644)==0)
            case "hardlink":try FileManager.default.linkItem(at:path(dir,b),to:dir.appendingPathComponent("alias"))
            case "symlink":
                let moved=dir.appendingPathComponent("moved");try FileManager.default.moveItem(at:path(dir,b),to:moved)
                try FileManager.default.createSymbolicLink(at:path(dir,b),withDestinationURL:moved)
            default:break
            }
            let before=try Data(contentsOf:path(dir,b))
            try rejected { _=try BlockJournalStore.inspect(directory:dir,binding:expected,key:usedKey,expectedSeal:seal) }
            let after=try Data(contentsOf:path(dir,b));precondition(after==before)
            checks.append(kind+"-refused-without-changing-log")
        }
        for kind in ["public-directory","symlink-directory","symlink-parent","short-key"] {
            let (dir,b)=try fixture(kind);var used=dir
            if kind=="public-directory" { precondition(chmod(dir.path,0o755)==0) }
            if kind=="symlink-directory" { used=root.appendingPathComponent("dir-alias");try FileManager.default.createSymbolicLink(at:used,withDestinationURL:dir) }
            if kind=="symlink-parent" {
                let nested=dir.appendingPathComponent("child");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let alias=root.appendingPathComponent("parent-alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:dir);used=alias.appendingPathComponent("child")
            }
            try rejected { _=try BlockJournalStore(directory:used,binding:b,key:kind=="short-key" ? Data([1]):key,failClosed:{}) }
            checks.append(kind+"-refused")
        }
        for kind in ["byte-limit","record-limit","invalid-offset","invalid-length","external-truncate","flush-failure"] {
            let (dir,b)=try fixture(kind);var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,byteLimit:32768,recordLimit:kind=="record-limit" ? 3:4096,failClosed:{poisoned += 1})
            try write(store);let prior=store.seal
            try rejected {
                switch kind {
                case "byte-limit","record-limit":try write(store)
                case "invalid-offset":try store.record(offset:1,before:Data(count:4096),after:Data(count:4096))
                case "invalid-length":try store.record(offset:0,before:Data(count:1),after:Data(count:1))
                case "external-truncate":precondition(truncate(path(dir,b).path,1)==0);try write(store)
                default:try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{throw POSIXError(.EIO)})
                }
            }
            precondition(store.failed && poisoned==1 && store.seal==prior)
            try rejected { try write(store) }
            var invoked=false
            try rejected { try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{invoked=true}) }
            precondition(poisoned==1 && !invoked);store.close()
            if kind != "external-truncate" {
                let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:prior,byteLimit:32768)
                precondition(state.writes.count==1 && state.checkpoint==nil)
            }
            checks.append(kind+"-locks-session-once")
        }
        do {
            let (dir,b)=try fixture("commit-reserve")
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,byteLimit:32768,recordLimit:3,failClosed:{})
            try write(store);try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{})
            let seal=store.seal;store.close()
            let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal);precondition(state.checkpoint != nil)
            checks.append("byte-and-record-budgets-reserve-commit")
        }
        #if VOLISLE_BLOCK_JOURNAL_TESTING
        for boundary in ["before-write","written","durable"] {
            let (dir,b)=try fixture("fault-"+boundary);var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{poisoned += 1})
            let prior=store.seal
            store.storageBoundary={if $0==boundary {throw POSIXError(.ENOSPC)}}
            try rejected {try write(store)}
            precondition(store.failed && poisoned==1 && store.seal==prior);store.close()
            if boundary=="before-write" {
                let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:prior);precondition(state.writes.isEmpty)
            } else {
                try rejected {_=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:prior)}
            }
            checks.append(boundary+"-failure-keeps-old-seal-and-blocks-ambiguous-tail")
        }
        for mode in ["pending","committed","interrupted"] {
            let (dir,b)=try fixture("crash-"+mode)
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
            p.arguments=["--child",dir.path,mode,b.transactionID.uuidString]
            try p.run();p.waitUntilExit();precondition(p.terminationStatus==86)
            let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("trusted-test-seal.json"))) as! [String:Any]
            let seal=BlockJournalSeal(sequence:receipt["sequence"] as! Int,authentication:receipt["authentication"] as! String)
            if mode=="interrupted" {
                try rejected {_=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)}
            } else {
                let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)
                precondition(state.writes.count==1 && (state.checkpoint != nil)==(mode=="committed"))
            }
            checks.append(mode+"-process-exit-releases-lock-and-preserves-boundary")
        }
        #endif
        for kind in ["live-hardlink","live-unlink","live-rename","live-permissions"] {
            let (dir,b)=try fixture(kind);var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{poisoned += 1})
            let prior=store.seal
            if kind=="live-hardlink" {try FileManager.default.linkItem(at:path(dir,b),to:dir.appendingPathComponent("alias"))}
            if kind=="live-unlink" {try FileManager.default.removeItem(at:path(dir,b))}
            if kind=="live-rename" {try FileManager.default.moveItem(at:path(dir,b),to:dir.appendingPathComponent("moved"))}
            if kind=="live-permissions" {precondition(chmod(path(dir,b).path,0o644)==0)}
            try rejected {try write(store)}
            precondition(store.failed && poisoned==1 && store.seal==prior);store.close()
            checks.append(kind+"-refused-before-append")
        }
        for fault in ["none","device","storage"] {
            let (dir,b)=try fixture("pipeline-"+fault);var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,byteLimit:fault=="storage" ? 16384:65536,failClosed:{poisoned += 1})
            let pipeline=MetadataWritePipeline();let original=Data(repeating:3,count:8192);var disk=original
            var deviceWrites=0
            do {
                try Data(repeating:9,count:5).withUnsafeBytes { input in
                    try pipeline.write(input,offset:4094,blockSize:4096,deviceSize:8192,read:{ at, block in
                        disk.withUnsafeBytes { bytes in block.copyMemory(from:UnsafeRawBufferPointer(rebasing:bytes[Int(at)..<Int(at)+block.count])) }
                    },record:{intent in try store.record(offset:intent.offset,before:intent.before,after:intent.after)},write:{at,block in
                        deviceWrites += 1
                        let length=fault=="device" ? block.count/2:block.count
                        disk.replaceSubrange(Int(at)..<Int(at)+length,with:UnsafeRawBufferPointer(rebasing:block[..<length]))
                        if fault=="device" {throw POSIXError(.EIO)}
                    })
                }
                precondition(fault=="none")
                try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{})
            } catch {precondition(fault != "none");store.abort()}
            let seal=store.seal;store.close()
            let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)
            if fault=="none" {precondition(state.writes.count==2 && state.checkpoint != nil && deviceWrites==2 && poisoned==0)}
            else {
                precondition(state.checkpoint==nil && poisoned==1 && pipeline.failed)
                if fault=="storage" {precondition(deviceWrites==0)}
                for record in state.writes.reversed() {disk.replaceSubrange(Int(record.offset)..<Int(record.offset)+record.before.count,with:record.before)}
                precondition(disk==original)
                try rejected {try store.commit(checkpoint:String(repeating:"b",count:64),flushDevice:{fatalError("failed operation flushed")})}
            }
            checks.append("native-pipeline-"+fault+"-honors-authenticated-storage-before-device")
        }
        for kind in ["maximum-block","short-final-block","oversized-frame-prefix","zero-frame-prefix"] {
            let (dir,base)=try fixture(kind)
            let b=BlockJournalBinding(transactionID:base.transactionID,volumeIdentity:base.volumeIdentity,bootSHA256:base.bootSHA256,
                deviceSize:kind=="short-final-block" ? 8704:base.deviceSize,blockSize:kind=="maximum-block" ? 1024*1024:4096)
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{})
            let offset:Int64=kind=="short-final-block" ? 8192:0
            let length=kind=="short-final-block" ? 512:b.blockSize
            try store.record(offset:offset,before:Data(repeating:1,count:length),after:Data(repeating:2,count:length))
            let seal=store.seal;store.close()
            if kind.hasSuffix("frame-prefix") {
                var bytes=try Data(contentsOf:path(dir,b))
                bytes.replaceSubrange(0..<4,with:Data(repeating:kind=="zero-frame-prefix" ? 0:255,count:4))
                try bytes.write(to:path(dir,b))
                try rejected {_=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)}
            } else {
                let state=try BlockJournalStore.inspect(directory:dir,binding:b,key:key,expectedSeal:seal)
                precondition(state.writes.count==1 && state.writes[0].before.count==length && state.writes[0].offset==offset)
            }
            checks.append(kind+"-bounded-and-validated")
        }
        #if VOLISLE_BLOCK_JOURNAL_TESTING
        do {
            let (dir,b)=try fixture("renamed-after-sync");var poisoned=0
            let store=try BlockJournalStore(directory:dir,binding:b,key:key,failClosed:{poisoned += 1})
            let prior=store.seal
            store.storageBoundary={if $0=="durable" {try FileManager.default.moveItem(at:path(dir,b),to:dir.appendingPathComponent("moved"))}}
            try rejected {try write(store)}
            precondition(store.failed && poisoned==1 && store.seal==prior);store.close()
            checks.append("path-changed-after-flush-refused-before-returning-seal")
        }
        #endif
        let result:[String:Any]=["success":true,"checks":checks,"fixture":root.path,"productionConnected":false]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        try data.write(to:root.appendingPathComponent("result.json"))
        print(String(decoding:data,as:UTF8.self))
    }
}
