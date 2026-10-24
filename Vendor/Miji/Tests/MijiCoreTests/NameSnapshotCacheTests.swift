import XCTest
import CSQLite
import CryptoKit
import OilFindCore
@testable import MijiCore

final class NameSnapshotCacheTests:XCTestCase {
    func testPreContextualPinyinCacheRebuildsWithoutChangingCatalog() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("重庆音乐.txt")],generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load();try first.saveCache()
        let cache=NameSnapshotCache.url(for:url)
        var old=try Data(contentsOf:cache)
        XCTAssertEqual(String(decoding:old.prefix(8),as:UTF8.self),"MJNAME03")
        old.replaceSubrange(0..<8,with:Data("MJNAME01".utf8))
        old.replaceSubrange((old.count-32)..<old.count,with:Data(SHA256.hash(data:old.dropLast(32))))
        try old.write(to:cache)
        XCTAssertThrowsError(try NameSnapshotCache.load(database:url,revision:1))
        let recovered=try NameSearchEngine(databaseURL:url);try recovered.load()
        XCTAssertEqual(try recovered.search("chongqing").count,1)
        XCTAssertEqual(try recovered.search("zhongqing").count,1)
        XCTAssertEqual(try db.statistics().files,1)
        try recovered.saveCache()
        XCTAssertEqual(String(decoding:try Data(contentsOf:cache).prefix(8),as:UTF8.self),"MJNAME03")
        let warm=try NameSearchEngine(databaseURL:url);try warm.load()
        XCTAssertEqual(try warm.search("chongqing").count,1)
        XCTAssertEqual(try warm.search("zhongqing").count,1)
    }

    func testEmptyCacheNumericColumnsRoundTrip() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let snapshot=try NameSnapshotCache.load(database:url,revision:0)
        XCTAssertEqual(snapshot.ids.count,0)
        XCTAssertEqual(snapshot.core.count,0)
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load()
        XCTAssertEqual(try restarted.search("anything"),[])
    }
    func testChecksummedInvalidSectionTablesAreRejected() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path));try db.upsertFiles([file("correct.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let cache=NameSnapshotCache.url(for:url),original=try Data(contentsOf:cache)
        // Each damaged table still carries a valid checksum: length not a whole
        // number of elements, out of the section area, misaligned, or missing.
        let ids=try XCTUnwrap(footerSections(original)["ids"])
        let damage:[(String,[Int]?)]=[("ids",[0,7]),("ids",[16,Int(UInt32.max)]),("sizes",[17,8]),("names.rowNames",nil),
                                      ("names.rowLive",ids)]
        for (name,entry) in damage {
            try rewriteFooter(original,to:cache) { sections,_ in sections[name]=entry }
            XCTAssertThrowsError(try NameSnapshotCache.load(database:url,revision:1),name)
            let recovered=try NameSearchEngine(databaseURL:url);try recovered.load()
            XCTAssertEqual(try recovered.search("correct").count,1)
        }
        // Counts that cannot fit the rows they describe.
        for uniqueCount in [Int(Int32.max),2] {
            try rewriteFooter(original,to:cache) { _,header in header["uniqueCount"]=uniqueCount }
            XCTAssertThrowsError(try NameSnapshotCache.load(database:url,revision:1),"uniqueCount \(uniqueCount)")
        }
    }
    func testLegacyCacheIsReadOnceAndReplacedByMappedCache() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("数学分析.txt"),file("README.md"),file("old.txt")],generation:1)
        let first=try NameSearchEngine(databaseURL:url,persistsCache:false);try first.load()
        let snapshot=try XCTUnwrap(first.currentSnapshot)
        XCTAssertFalse(first.mappedState.mapped)
        try writeLegacyCache(snapshot,database:url)
        // A change after the legacy cache was written arrives through the journal.
        try db.finishIncrementalScan(rootID:"r",relativePath:"old.txt",generation:2)
        let upgraded=try NameSearchEngine(databaseURL:url);try upgraded.load()
        XCTAssertEqual(String(decoding:try Data(contentsOf:NameSnapshotCache.url(for:url)).prefix(8),as:UTF8.self),"MJNAME03")
        XCTAssertTrue(upgraded.mappedState.mapped)
        XCTAssertEqual(try upgraded.search("shuxue").count,1)
        XCTAssertEqual(try upgraded.search("readme").count,1)
        XCTAssertTrue(try upgraded.search("old").isEmpty)
    }
    func testMappedSnapshotKeepsChangesInMemoryUntilCompaction() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<40).map {file("base-\($0).txt")}+[file("重庆音乐.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url)
        engine.compactionRows=8
        try engine.load()
        XCTAssertTrue(engine.mappedState.mapped)
        XCTAssertEqual(engine.mappedState.unmappedRows,0)
        // Changes land in memory next to the mapping: new names, a rename and a deletion.
        try db.upsertFiles((0..<5).map {file("tail-\($0).txt")},generation:1)
        try db.execute("UPDATE files SET name='renamed-base-1.txt' WHERE name='base-1.txt'")
        try db.execute("UPDATE files SET size=99 WHERE name='base-2.txt'")
        try db.finishIncrementalScan(rootID:"r",relativePath:"base-3.txt",generation:2)
        try engine.refresh(rootID:"r",relativePaths:[""],fullRescan:false)
        XCTAssertTrue(engine.mappedState.mapped)
        XCTAssertEqual(engine.mappedState.unmappedRows,6)
        XCTAssertFalse(engine.needsCompaction)
        XCTAssertEqual(try engine.search("tail").count,5)
        XCTAssertEqual(try engine.search("renamed-base-1").count,1)
        XCTAssertTrue(try engine.search("base-3.txt").isEmpty)
        XCTAssertEqual(try engine.search("chongqing").count,1)
        XCTAssertEqual(try engine.search("base",options:SearchOptions(sort:.size,limit:1)).count,1)
        let all=try engine.search("",options:SearchOptions(sort:.name,limit:100))
        XCTAssertEqual(all.count,45)
        // Past the threshold the snapshot is rewritten and mapped again, with the same answers.
        try db.upsertFiles((5..<9).map {file("tail-\($0).txt")},generation:1)
        try engine.refresh(rootID:"r",relativePaths:[""],fullRescan:false)
        XCTAssertTrue(engine.needsCompaction)
        try engine.compact()
        XCTAssertEqual(engine.mappedState.unmappedRows,0)
        XCTAssertEqual(try engine.search("tail").count,9)
        XCTAssertEqual(try engine.search("",options:SearchOptions(sort:.name,limit:100)).count,49)
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load()
        XCTAssertEqual(try restarted.search("",options:SearchOptions(sort:.name,limit:100)),
                       try engine.search("",options:SearchOptions(sort:.name,limit:100)))
    }
    func testLargeUnsortedTailIsRebuiltIntoASortedMapping() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<100).map {file("row-\($0).txt")},generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load()
        try db.execute("UPDATE files SET name='first-'||name WHERE id<=30")
        // At startup a long renamed tail is rebuilt rather than carried in an ID table.
        let restarted=try NameSearchEngine(databaseURL:url)
        restarted.tailRebuildRows=10
        try restarted.load()
        var cached=try NameSnapshotCache.load(database:url,revision:130)
        XCTAssertEqual(cached.baseCount,cached.ids.count)
        XCTAssertEqual(cached.ids.count,100)
        XCTAssertTrue(restarted.mappedState.mapped)
        XCTAssertEqual(try restarted.search("first-").count,30)
        // The same holds for changes that accumulate while running.
        try db.execute("UPDATE files SET name='second-'||name WHERE id>70")
        try restarted.refresh(rootID:"r",relativePaths:[""],fullRescan:false)
        XCTAssertTrue(restarted.needsCompaction)
        try restarted.compact()
        cached=try NameSnapshotCache.load(database:url,revision:160)
        XCTAssertEqual(cached.baseCount,100)
        XCTAssertEqual(restarted.mappedState.unmappedRows,0)
        XCTAssertFalse(restarted.needsCompaction)
        XCTAssertEqual(try restarted.search("second-").count,30)
        XCTAssertEqual(try restarted.search("row-",options:SearchOptions(limit:200)).count,100)
    }
    private func footerSections(_ original:Data) throws -> [String:[Int]] {
        let total=original.count
        let length=original.withUnsafeBytes {Int(UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:total-40,as:UInt64.self)))}
        let header=try XCTUnwrap(JSONSerialization.jsonObject(with:original[(total-40-length)..<(total-40)]) as? [String:Any])
        return try XCTUnwrap(header["sections"] as? [String:[Int]])
    }
    private func rewriteFooter(_ original:Data,to cache:URL,_ change:(inout [String:[Int]?],inout [String:Any])->Void) throws {
        let total=original.count
        let length=original.withUnsafeBytes {Int(UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:total-40,as:UInt64.self)))}
        let start=total-40-length
        var header=try XCTUnwrap(JSONSerialization.jsonObject(with:original[start..<(total-40)]) as? [String:Any])
        var sections:[String:[Int]?]=(header["sections"] as? [String:[Int]] ?? [:]).mapValues {$0}
        change(&sections,&header)
        header["sections"]=sections.compactMapValues {$0}
        let footer=try JSONSerialization.data(withJSONObject:header)
        var bytes=Data(original[0..<start])
        bytes.append(footer)
        var size=UInt64(footer.count).littleEndian
        withUnsafeBytes(of:&size) {bytes.append(contentsOf:$0)}
        bytes.append(Data(SHA256.hash(data:bytes)))
        try bytes.write(to:cache)
    }
    /// The version 2 layout that earlier releases wrote, for upgrade fixtures.
    private func writeLegacyCache(_ snapshot:NameSnapshot,database:URL) throws {
        let attributes=try FileManager.default.attributesOfItem(atPath:database.path)
        let header:[String:Any]=["inode":(attributes[.systemFileNumber] as! NSNumber).uint64Value,
                                 "device":(attributes[.systemNumber] as! NSNumber).uint64Value,
                                 "created":(attributes[.creationDate] as! Date).timeIntervalSince1970,
                                 "revision":snapshot.changeRevision!,"baseCount":snapshot.baseCount,"liveCount":snapshot.liveCount,
                                 "roots":snapshot.rootKeys,"extensions":snapshot.extensionKeys,"kinds":snapshot.kindKeys]
        var bytes=Data("MJNAME02".utf8)
        func block(_ data:Data) {
            var size=UInt64(data.count).littleEndian
            withUnsafeBytes(of:&size) {bytes.append(contentsOf:$0)}
            bytes.append(data)
        }
        func column<T>(_ values:SegmentedArray<T>) {
            var data=Data()
            values.forEachSegment {_,run in data.append(contentsOf:UnsafeRawBufferPointer(run))}
            block(data)
        }
        block(try JSONSerialization.data(withJSONObject:header))
        column(snapshot.ids);column(snapshot.sizes);column(snapshot.modified)
        column(snapshot.roots);column(snapshot.extensions);column(snapshot.kinds);column(snapshot.live)
        block(snapshot.core.serialized())
        bytes.append(Data(SHA256.hash(data:bytes)))
        try bytes.write(to:NameSnapshotCache.url(for:database))
    }
    func testStartupCompactsRenameTombstonesAndDoesNotRewriteCleanCache() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<17_000).map {file("old-\($0).txt")},generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load();try first.saveCache()
        let cacheURL=NameSnapshotCache.url(for:url)
        let before=try FileManager.default.attributesOfItem(atPath:cacheURL.path)[.systemFileNumber] as? NSNumber
        let clean=try NameSearchEngine(databaseURL:url);try clean.load();try clean.saveCache()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:cacheURL.path)[.systemFileNumber] as? NSNumber,before)
        try db.execute("UPDATE files SET name='renamed-'||name")
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load();try restarted.saveCache()
        let compact=try NameSnapshotCache.load(database:url,revision:34_000)
        XCTAssertEqual(compact.liveCount,17_000)
        XCTAssertEqual(compact.ids.count,17_000,"关闭期间反复改名不能使持久缓存累积墓碑")
        XCTAssertEqual(try restarted.search("renamed",options:SearchOptions(limit:20_000)).count,17_000)
    }
    func testCacheRoundTripAppliesJournalAndKeepsDeletedRowsDeleted() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("数学分析.txt"),file("old.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let initial=try NameSnapshotCache.load(database:url,revision:2)
        XCTAssertEqual(initial.liveCount,2)
        try db.finishIncrementalScan(rootID:"r",relativePath:"old.txt",generation:2)
        try db.upsertFiles([file("README.txt")],generation:2)
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load()
        XCTAssertEqual(try restarted.search("shuxue").count,1)
        XCTAssertEqual(try restarted.search("README").count,1)
        XCTAssertTrue(try restarted.search("old").isEmpty)
        // Save after a rename/upsert adds a tail entry and a tombstone.
        try db.execute("UPDATE files SET name='New数学.txt' WHERE name='数学分析.txt'")
        try restarted.refresh(rootID:"r",relativePaths:[""],fullRescan:true)
        try restarted.saveCache()
        let again=try NameSearchEngine(databaseURL:url);try again.load()
        XCTAssertEqual(try again.search("New数学").count,1)
        XCTAssertTrue(try again.search("数学分析").isEmpty)
        XCTAssertEqual(try again.search("README").count,1)
    }
    func testCorruptOrOtherDatabaseCacheFallsBackToSQLite() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite")
        let db=try SearchDatabase(url:url);try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("correct.txt")],generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load();try first.saveCache()
        let cache=NameSnapshotCache.url(for:url)
        var bytes=try Data(contentsOf:cache);bytes[bytes.count/2] ^= 0xff;try bytes.write(to:cache)
        let recovered=try NameSearchEngine(databaseURL:url);try recovered.load();try recovered.saveCache()
        XCTAssertEqual(try recovered.search("correct").count,1)
        let otherURL=directory.appendingPathComponent("other.sqlite"),other=try SearchDatabase(url:directory.appendingPathComponent("other.sqlite"))
        try other.saveRoot(IndexedRoot(id:"r",path:directory.path));try other.upsertFiles([file("different.txt")],generation:1)
        try FileManager.default.copyItem(at:cache,to:NameSnapshotCache.url(for:otherURL))
        let replacement=try NameSearchEngine(databaseURL:otherURL);try replacement.load()
        XCTAssertTrue(try replacement.search("correct").isEmpty)
        XCTAssertEqual(try replacement.search("different").count,1)
    }
    private func file(_ name:String)->FileRecord {
        FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)
    }
}
