import XCTest
import Foundation
import MijiCore
@testable import DirDeskCore

final class MijiBackendTests:XCTestCase {
    var directory:URL!,url:URL!,database:SearchDatabase!,root:IndexedRoot!
    override func setUpWithError() throws {
        directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wumi-backend-\(UUID().uuidString)")
        url=directory.appendingPathComponent("catalog.sqlite")
        database=try SearchDatabase(url:url)
        root=IndexedRoot(id:"fixture",path:directory.appendingPathComponent("source").path)
        try database.saveRoot(root)
    }
    override func tearDownWithError() throws {database=nil;try FileManager.default.removeItem(at:directory)}
    @discardableResult func add(_ name:String,size:Int64=100,created:Double?=nil,kind:FileKind = .document,
                                isDirectory:Bool=false,isPackage:Bool=false,content:ExtractedContent?=nil,state:String="pending")throws->FileRecord {
        let f=FileRecord(rootID:root.id,relativePath:name,name:(name as NSString).lastPathComponent,
            fileExtension:(name as NSString).pathExtension,kind:kind,size:size,modified:123,
            contentState:state,created:created,isDirectory:isDirectory,isPackage:isPackage)
        try database.upsertFiles([f],generation:1)
        let inserted=try XCTUnwrap(database.catalogBatch(afterID:0,limit:512).first(where:{$0.file.relativePath==name})?.file)
        if let content {XCTAssertTrue(try database.completeContent(file:inserted,content:content))}
        return inserted
    }
    func backend(temporary:Bool=true,creationDateReader:((URL)->Date?)?=nil)throws->MijiSearchBackend {
        let names=try NameSearchEngine(databaseURL:url);try names.load()
        let backend:MijiSearchBackend
        if let creationDateReader {
            backend=MijiSearchBackend(databaseURL:url,names:names,allowsTemporaryScopes:temporary,creationDateReader:creationDateReader)
        } else {backend=MijiSearchBackend(databaseURL:url,names:names,allowsTemporaryScopes:temporary)}
        backend.onError={XCTFail($0)}
        return backend
    }
    func search(_ expression:String,_ backend:MijiSearchBackend,sort:LightningSortKey = .none,descending:Bool=false,limit:Int=1000)throws->LightningSearchResult {
        backend.search(try LightningQueryParser.parse(expression),sort:sort,descending:descending,limit:limit)
    }

    func testNamesPinyinFullTextOCRAndPhasesDeduplicate()throws {
        try add("数学分析.pdf",content:ExtractedContent(text:"数学分析 连续函数 闭区间",pages:2))
        try add("截图.png",kind:.image,content:ExtractedContent(text:"上海虹桥站",labels:["train"]))
        try add("正文.pdf",content:ExtractedContent(text:"数学分析的证明"))
        let b=try backend()
        let q=try LightningQueryParser.parse("数学分析")
        XCTAssertEqual(b.searchNames(q).totalCount,1)
        XCTAssertEqual(b.search(q).totalCount,2)
        XCTAssertEqual(try search("sxfx",b).rows.map(\.name),["数学分析.pdf"])
        XCTAssertEqual(try search("content:虹桥",b).rows.map(\.name),["截图.png"])
        XCTAssertEqual(try search("train",b).rows.map(\.name),["截图.png"])
        XCTAssertEqual(try search("case:数学分析",b).totalCount,2)
        let multi=try LightningQueryParser.parse("数学分析 证明")
        XCTAssertEqual(b.searchNames(multi).totalCount,0)
        XCTAssertEqual(b.search(multi).rows.map(\.name),["正文.pdf"])
        XCTAssertTrue(try XCTUnwrap(search("content:闭区间",b).rows.first?.snippet).contains("闭区间"))
    }
    func testUnknownBodyCannotSatisfyAndOrNot()throws {
        try add("report-pending.pdf")
        try add("report-allowed.pdf",content:ExtractedContent(text:"allowed"))
        try add("report-blocked.pdf",content:ExtractedContent(text:"blocked"))
        let b=try backend()
        XCTAssertEqual(try search("name:report !content:blocked",b).rows.map(\.name),["report-allowed.pdf"])
        XCTAssertEqual(try search("name:report content:blocked",b).rows.map(\.name),["report-blocked.pdf"])
        XCTAssertEqual(try search("name:report-pending | content:blocked",b).totalCount,2)
        XCTAssertEqual(try search("!(content:blocked | content:allowed)",b).totalCount,0)
    }
    func testCompleteCountsAndSortAfterLateFilter()throws {
        for i in 0..<350 {try add(String(format:"item-%03d.txt",i),size:Int64(i),created:Double(i))}
        let b=try backend()
        let selected=try search("name:item size:>=300",b,sort:.size,descending:true,limit:3)
        XCTAssertEqual(selected.totalCount,50);XCTAssertEqual(selected.rows.map(\.size),[349,348,347])
        XCTAssertTrue(selected.truncated)
        let all=try search("item",b,sort:.created,descending:true,limit:2)
        XCTAssertEqual(all.totalCount,350);XCTAssertEqual(all.rows.map(\.name),["item-349.txt","item-348.txt"])
        XCTAssertEqual(try search("size:>=0",b,limit:0).totalCount,350)
    }
    func testMetadataASTCompatibilityWithLegacyEngine()throws {
        let created=Date(timeIntervalSince1970:1_700_000_000)
        let samples:[(String,Int64,Bool,Bool)]=[("a/Alpha.txt",500,false,false),("a/beta.pdf",20,false,false),("b/Gamma.swift",900,false,false),("b/Example.app",0,true,true),("b/folder",0,true,false)]
        var storage=LightningStorage()
        var parents:[String:Int32]=[:]
        func ancestor(_ path:String)->Int32 {
            if let existing=parents[path] {return existing}
            let p:Int32=path == "/" ? -1 : ancestor((path as NSString).deletingLastPathComponent)
            let i=storage.append(name:path == "/" ? "" : (path as NSString).lastPathComponent,parent:p,flags:LightningEntryFlag.directory | LightningEntryFlag.ancestor)
            parents[path]=i;return i
        }
        for (path,size,dir,package) in samples {
            try add(path,size:size,created:created.timeIntervalSince1970,kind:dir ? (package ? .application : .folder) : .document,
                    isDirectory:dir,isPackage:package,state:"skipped")
            let full=root.path+"/"+path
            let parent=ancestor((full as NSString).deletingLastPathComponent)
            storage.append(name:(path as NSString).lastPathComponent,parent:parent,flags:(dir ? LightningEntryFlag.directory : 0) | (package ? LightningEntryFlag.package : 0),size:size,modified:123,created:created.timeIntervalSince1970)
        }
        let index=LightningIndex(configuration:LightningIndexConfiguration(roots:[URL(fileURLWithPath:root.path)]))
        index.install(storage,stage:.ready,eventID:0)
        let legacy=LightningSearchEngine(index:index),miji=try backend()
        for expression in ["ext:txt;pdf", "type:file", "folder:", "file:", "name:A*", "regex:^A", "size:>100", "dc:2023", "dm:1970", "!ext:txt", "case:name:Alpha", "infolder:\(root.path)/a", "nosubfolders:\(root.path)/b", "name:Alpha | name:beta name:Gamma"] {
            let query=try LightningQueryParser.parse(expression)
            XCTAssertEqual(Set(miji.search(query).rows.map(\.path)),Set(legacy.search(query).rows.map(\.path)),expression)
        }
    }
    func testOfflineAndMetadataPersistAcrossBackupAndReopen()throws {
        let f=try add("Bundle.app",created:111,kind:.application,isDirectory:true,isPackage:true,
                      content:ExtractedContent(text:"离线正文",labels:["OCR"],pages:3,warning:"fixture"))
        root.isOnline=false;try database.saveRoot(root)
        let target=directory.appendingPathComponent("backup/index.sqlite")
        try MijiIndexHost.backup(from:url,to:target)
        let copy=try SearchDatabase(url:target)
        XCTAssertEqual(try copy.storedContent(fileID:f.id),try database.storedContent(fileID:f.id))
        let metadata=try XCTUnwrap(copy.catalogBatch().first?.file)
        XCTAssertEqual(metadata.created,111);XCTAssertEqual(metadata.isDirectory,true);XCTAssertEqual(metadata.isPackage,true)
        let names=try NameSearchEngine(databaseURL:target);try names.load()
        let b=MijiSearchBackend(databaseURL:target,names:names)
        let row=try XCTUnwrap(search("content:离线",b).rows.first)
        XCTAssertFalse(row.isOnline);XCTAssertTrue(row.isPackage);XCTAssertTrue(row.isDirectory)
        XCTAssertEqual(row.created,Date(timeIntervalSince1970:111))
        b.retainsOffline=false
        XCTAssertEqual(try search("content:离线",b).totalCount,0)
        XCTAssertNotNil(try copy.storedContent(fileID:f.id))
        b.retainsOffline=true
        XCTAssertEqual(try search("content:离线",b).totalCount,1)
        XCTAssertThrowsError(try MijiIndexHost.backup(from:url,to:target))
    }
    func testReadOnlyHostDoesNotStartScannerOrMutateRoots()throws {
        try add("indexed.txt",state:"skipped")
        let host=try MijiIndexHost(databaseURL:url,readOnly:true)
        try host.start(watchedFolders:["/"],ignoredFolders:[root.path])
        host.rebuildIndex()
        XCTAssertEqual(try host.roots(),[root])
        XCTAssertEqual(host.engine.search(.everything).totalCount,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path+".incremental.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path+".names.cache"))
        XCTAssertThrowsError(try MijiIndexHost(databaseURL:url,readOnly:true))
        host.shutdown()
        let second=try MijiIndexHost(databaseURL:url,readOnly:true);second.shutdown()
    }
    func testProcessLockAndBackupConflict()throws {
        var lease:DatabaseLease?=try DatabaseLease(databaseURL:url)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments=["-c","import fcntl,sys\nf=open(sys.argv[1],'a')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(0)\nsys.exit(7)",url.path+".host.lock"]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertThrowsError(try MijiIndexHost.backup(from:url,to:url))
        withExtendedLifetime(lease) {};lease=nil
        XCTAssertNoThrow(try DatabaseLease(databaseURL:url))
    }
    func testFinderTagsAndGlobPathUseFixtureFilesystem()throws {
        let folder=URL(fileURLWithPath:root.path).appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent("Report.txt")
        try Data("fixture".utf8).write(to:file)
        try (file as NSURL).setResourceValue(["Fixture Work"], forKey: .tagNamesKey)
        guard (try file.resourceValues(forKeys:[.tagNamesKey]).tagNames ?? []).contains("Fixture Work") else {
            throw XCTSkip("Temporary filesystem does not support Finder tags")
        }
        try add("Docs/Report.txt",state:"skipped")
        let b=try backend()
        XCTAssertEqual(try search("tagexact:\"Fixture Work\"",b).totalCount,1)
        XCTAssertEqual(try search("tag:work",b).totalCount,1)
        XCTAssertEqual(try search("Docs/*.txt",b).totalCount,1)
        XCTAssertEqual(try search("Docs/*.pdf",b).totalCount,0)
    }

    @discardableResult
    private func historicalFixture(_ name:String,created:Date)throws->URL {
        let file=URL(fileURLWithPath:root.path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("historical fixture".utf8).write(to:file)
        try FileManager.default.setAttributes([.creationDate:created],ofItemAtPath:file.path)
        let actual=try XCTUnwrap(file.resourceValues(forKeys:[.creationDateKey]).creationDate)
        XCTAssertEqual(actual.timeIntervalSince1970,created.timeIntervalSince1970,accuracy:1)
        return file
    }

    func testHistoricalCreatedFilterHydratesOnlineOnlyWithoutPersisting()throws {
        let year2020=Date(timeIntervalSince1970:1_591_012_800)
        let year2022=Date(timeIntervalSince1970:1_654_171_200)
        let file=try historicalFixture("historical-online.txt",created:year2020)
        let online=try add("historical-online.txt",content:ExtractedContent(text:"preserved body"))
        let onlineRoot=root!
        root=IndexedRoot(id:"offline-history",path:directory.appendingPathComponent("offline-source").path,isOnline:false)
        try database.saveRoot(root)
        try historicalFixture("historical-offline.txt",created:year2020)
        try add("historical-offline.txt",state:"skipped")
        root=onlineRoot
        try add("historical-missing.txt",state:"skipped")
        let b=try backend()
        // The cached catalog initially has no created values, even though two files exist.
        XCTAssertTrue(try database.catalogBatch().allSatisfy {$0.file.created == nil})
        let direct=try search("dc:2020",b)
        XCTAssertEqual(direct.rows.map(\.name),["historical-online.txt"])
        XCTAssertEqual(direct.rows.first?.created,year2020)
        let nested=LightningQuery.matchCase(true,.and([
            .filter(.name(LightningTerm("historical"))),
            .or([.not(.not(.filter(.dateCreated([.compare(.equal,.year(2020))])))),
                 .filter(.name(LightningTerm("absent-name")))])
        ]))
        XCTAssertEqual(b.search(nested).rows.map(\.name),["historical-online.txt"])
        let sorted=b.search(.everything,sort:.created)
        XCTAssertEqual(sorted.totalCount,3)
        XCTAssertNil(try XCTUnwrap(sorted.rows.first {$0.name == "historical-offline.txt"}).created)
        XCTAssertFalse(try XCTUnwrap(sorted.rows.first {$0.name == "historical-offline.txt"}).isOnline)
        XCTAssertNil(try XCTUnwrap(sorted.rows.first {$0.name == "historical-missing.txt"}).created)
        // A later query reads the new birth date, proving there is no persistent/path cache.
        try FileManager.default.setAttributes([.creationDate:year2022],ofItemAtPath:file.path)
        XCTAssertEqual(try search("dc:2020",b).totalCount,0)
        XCTAssertEqual(try search("dc:2022",b).rows.map(\.name),["historical-online.txt"])
        XCTAssertTrue(try database.catalogBatch().allSatisfy {$0.file.created == nil})
        XCTAssertEqual(try database.storedContent(fileID:online.id),ExtractedContent(text:"preserved body"))
        XCTAssertEqual(try database.roots().first {$0.id == "offline-history"}?.isOnline,false)
        XCTAssertEqual(try Data(contentsOf:file),Data("historical fixture".utf8))
    }

    func testHistoricalCreatedSortUsesAllCandidatesAndKeepsNameHotPathUnchanged()throws {
        let year2024=Date(timeIntervalSince1970:1_717_243_200)
        let year2020=Date(timeIntervalSince1970:1_591_012_800)
        let year2010=Date(timeIntervalSince1970:1_275_350_400)
        let newFile=try historicalFixture("historical-new.txt",created:year2024)
        try add("historical-new.txt",state:"skipped")
        try historicalFixture("historical-old.txt",created:year2020)
        try add("historical-old.txt",state:"skipped")
        // Stored dates remain authoritative over current filesystem metadata.
        try historicalFixture("historical-stored.txt",created:year2024)
        try add("historical-stored.txt",created:year2010.timeIntervalSince1970,state:"skipped")
        try add("historical-missing.txt",state:"skipped")
        let b=try backend(),query=LightningQuery.term(LightningTerm("historical"))
        for sort:LightningSortKey in [.none,.name,.modified,.size] {
            let plain=b.searchNames(query,sort:sort)
            XCTAssertEqual(plain.totalCount,4)
            XCTAssertNil(try XCTUnwrap(plain.rows.first {$0.name == "historical-new.txt"}).created)
            XCTAssertNil(try XCTUnwrap(plain.rows.first {$0.name == "historical-old.txt"}).created)
        }
        let ascending=b.searchNames(query,sort:.created,limit:1)
        XCTAssertEqual(ascending.totalCount,4);XCTAssertTrue(ascending.truncated)
        XCTAssertEqual(ascending.rows.map(\.name),["historical-stored.txt"])
        let descending=b.searchNames(query,sort:.created,descending:true,limit:1)
        XCTAssertEqual(descending.totalCount,4)
        XCTAssertEqual(descending.rows.map(\.name),["historical-new.txt"])
        XCTAssertEqual(b.search(query,sort:.created,descending:true).rows.map(\.name),
                       ["historical-new.txt","historical-old.txt","historical-stored.txt","historical-missing.txt"])
        try FileManager.default.setAttributes([.creationDate:Date(timeIntervalSince1970:1_212_278_400)],ofItemAtPath:newFile.path)
        XCTAssertEqual(b.searchNames(query,sort:.created,limit:1).rows.map(\.name),["historical-new.txt"])
        let records=try database.catalogBatch()
        XCTAssertEqual(records.count,4)
        XCTAssertNil(try XCTUnwrap(records.first {$0.file.name == "historical-new.txt"}).file.created)
        XCTAssertEqual(try XCTUnwrap(records.first {$0.file.name == "historical-stored.txt"}).file.created,year2010.timeIntervalSince1970)
    }

    func testLazyCreatedReadsOnlyReachedPredicatesAndMatchedSortRows()throws {
        let date=Date(timeIntervalSince1970:1_591_012_800)
        try historicalFixture("target-old.txt",created:date)
        try add("target-old.txt",state:"skipped")
        try historicalFixture("target-new.txt",created:Date(timeIntervalSince1970:1_717_243_200))
        try add("target-new.txt",state:"skipped")
        try historicalFixture("target-stored.txt",created:date)
        try add("target-stored.txt",created:date.timeIntervalSince1970,state:"skipped")
        // Cross a catalog page so early filtering is tested beyond its first batch.
        for i in 0..<260 {try add("unrelated-\(i).txt",state:"skipped")}
        let onlineRoot=root!
        root=IndexedRoot(id:"offline-lazy",path:directory.appendingPathComponent("offline-lazy").path,isOnline:false)
        try database.saveRoot(root)
        try historicalFixture("target-offline.txt",created:date)
        try add("target-offline.txt",state:"skipped")
        root=onlineRoot
        var reads:[String]=[]
        let b=try backend(creationDateReader:{url in
            reads.append(url.lastPathComponent)
            return (try? url.resourceValues(forKeys:[.creationDateKey]))?.creationDate
        })
        let plain=LightningQuery.term(LightningTerm("target"))
        for sort:LightningSortKey in [.none,.name,.size,.modified] {
            XCTAssertEqual(b.searchNames(plain,sort:sort).totalCount,4)
            XCTAssertEqual(b.search(plain,sort:sort).totalCount,4)
        }
        XCTAssertEqual(try search("name:target*",b).totalCount,4)
        XCTAssertTrue(reads.isEmpty,"普通名称、glob与非创建日期排序必须零创建日期读取")
        for expression in ["name:target* dc:2020","dc:2020 name:target*","dc:2020 name:target* dc:2020"] {
            reads.removeAll()
            let result=try search(expression,b,sort:.created,limit:1)
            XCTAssertEqual(result.totalCount,2,expression)
            XCTAssertEqual(result.rows.count,1)
            XCTAssertEqual(Set(reads),["target-old.txt","target-new.txt"],expression)
            XCTAssertEqual(reads.count,2,"重复日期谓词及排序共享单次读取：\(expression)")
        }
        reads.removeAll()
        let sorted=try search("name:target*",b,sort:.created,descending:true,limit:1)
        XCTAssertEqual(sorted.totalCount,4)
        XCTAssertEqual(sorted.rows.map(\.name),["target-new.txt"])
        XCTAssertEqual(Set(reads),["target-old.txt","target-new.txt"])
        XCTAssertEqual(reads.count,2,"仅已匹配、在线、缺日期项读取；不限于显示的前一条")
        reads.removeAll()
        XCTAssertEqual(try search("dc:2020 name:no-such-file",b).totalCount,0)
        XCTAssertTrue(reads.isEmpty,"名称先排除，不按输入顺序先stat")
        XCTAssertNil(try database.catalogBatch().first {$0.file.name == "target-old.txt"}?.file.created)
    }

    func testLazyCreatedCachesFailedReadsAndPreservesOrNotUnknownSemantics()throws {
        let date=Date(timeIntervalSince1970:1_591_012_800)
        try historicalFixture("known.txt",created:date)
        try add("known.txt",state:"skipped")
        try add("missing.txt",state:"skipped")
        try historicalFixture("pending.txt",created:date)
        try add("pending.txt")
        var reads:[String]=[]
        var cancel=false
        let b=try backend(creationDateReader:{url in
            reads.append(url.lastPathComponent)
            return (try? url.resourceValues(forKeys:[.creationDateKey]))?.creationDate
        })
        // The first OR branch accepts known without reaching the date predicate.
        let any=try search("name:known | dc:2020",b)
        XCTAssertEqual(Set(any.rows.map(\.name)),["known.txt","pending.txt"])
        XCTAssertEqual(Set(reads),["missing.txt","pending.txt"])
        XCTAssertEqual(reads.count,2)
        reads.removeAll()
        // A failed read is cached even when NOT, OR, a second date leaf and sorting need it.
        let missing=try search("name:missing !(dc:2020 | dc:2024)",b,sort:.created)
        XCTAssertEqual(missing.rows.map(\.name),["missing.txt"])
        XCTAssertNil(missing.rows.first?.created)
        XCTAssertEqual(reads,["missing.txt"])
        reads.removeAll()
        XCTAssertEqual(try search("name:pending !(content:blocked dc:2020)",b).totalCount,0)
        XCTAssertEqual(reads,["pending.txt"],"不能因正文未知跳过可能影响NOT结果的日期谓词")
        reads.removeAll()
        XCTAssertEqual(try search("name:pending !(content:blocked dc:2024)",b).rows.map(\.name),["pending.txt"])
        XCTAssertEqual(reads,["pending.txt"])
        // Cancellation observed after the filesystem read must not publish the row.
        let cancelling=try backend(creationDateReader:{url in cancel=true;return date})
        let interrupted=cancelling.search(.filter(.dateCreated([.compare(.equal,.year(2020))])),isCancelled:{cancel})
        XCTAssertTrue(interrupted.cancelled)
        XCTAssertTrue(interrupted.rows.isEmpty)
        XCTAssertNil(try database.catalogBatch().first {$0.file.name == "known.txt"}?.file.created)
    }

    func testContextualAndCharacterPinyinAgreeInOrdinaryAndAdvancedQueries()throws {
        try add("重庆音乐.txt",content:ExtractedContent(text:"fixture body"))
        try add("other.txt",content:ExtractedContent(text:"chongqing body-only"))
        let b=try backend()
        for key in ["chongqing","zhongqing","cq","zq"] {
            let plain=LightningQuery.term(LightningTerm(key))
            XCTAssertEqual(b.searchNames(plain).rows.map(\.name),["重庆音乐.txt"],key)
            XCTAssertEqual(try search("name:\(key)",b).rows.map(\.name),["重庆音乐.txt"],key)
            XCTAssertEqual(try search("name:\(key) ext:txt size:>1",b).rows.map(\.name),["重庆音乐.txt"],key)
            XCTAssertEqual(try search("name:\(key) content:fixture",b).rows.map(\.name),["重庆音乐.txt"],key)
            XCTAssertEqual(try search("\(key) fixture",b).rows.map(\.name),["重庆音乐.txt"],key)
            XCTAssertTrue(try search("name:\(key) !name:\(key)",b).rows.isEmpty,key)
        }
        XCTAssertEqual(try search("chongqing",b).totalCount,2)
        XCTAssertEqual(try search("zhongqing",b).totalCount,1)
        XCTAssertTrue(b.search(.filter(.name(LightningTerm("CHONGQING"))),caseSensitive:true).rows.isEmpty)
        // Derived name-cache restoration must preserve both aliases.
        try b.names.saveCache()
        let restored=try backend()
        XCTAssertEqual(try search("name:zhongqing",restored).rows.map(\.name),["重庆音乐.txt"])
        XCTAssertEqual(restored.searchNames(.term(LightningTerm("chongqing"))).rows.map(\.name),["重庆音乐.txt"])
    }

    func testCancellationAndUnindexedOrExcludedTemporaryScope()throws {
        let folder=directory.appendingPathComponent("unindexed")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("fixture local needle".utf8).write(to:folder.appendingPathComponent("local.txt"))
        let b=try backend()
        let result=b.search(.everything,scope:.folder(folder))
        XCTAssertEqual(result.rows.map(\.name),["local.txt"])
        XCTAssertEqual(result.totalCount,1)
        b.discardTemporaryIndexes()
        let q=try LightningQueryParser.parse("content:needle")
        XCTAssertEqual(b.search(q,scope:.folder(folder)).totalCount,1)
        let readonly=try backend(temporary:false)
        let unavailable=readonly.search(.everything,scope:.folder(folder))
        XCTAssertTrue(unavailable.rows.isEmpty);XCTAssertTrue(unavailable.truncated)
        let cancelled=b.search(.everything,isCancelled:{true})
        XCTAssertTrue(cancelled.cancelled);XCTAssertTrue(cancelled.truncated)
    }
}
