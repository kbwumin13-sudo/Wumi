import XCTest
import Foundation
import CSQLite
@testable import MijiCore

final class SearchQualityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func database(_ suffix: String, documents: [(String, String, Double)]) throws -> SearchDatabase {
        let db = try SearchDatabase(url: directory.appendingPathComponent(suffix + ".sqlite"))
        try db.saveRoot(IndexedRoot(id: "r", path: directory.path))
        for (path, body, modified) in documents {
            try db.upsertFiles([FileRecord(rootID: "r", relativePath: path, name: (path as NSString).lastPathComponent,
                fileExtension: "txt", kind: .document, size: Int64(body.utf8.count), modified: modified)], generation: 1)
            let file = try XCTUnwrap(db.pendingFiles(rootID: "r", limit: 1).first)
            XCTAssertTrue(try db.completeContent(file: file, content: ExtractedContent(text: body)))
        }
        return db
    }

    func testFocusedOldBodySurvivesThreeInsertionOrdersBeyondReturnLimit() throws {
        let target = ("notes/opaque.txt", "潮汐储能：电池容量、负荷调度的完整设计。", 1.0)
        var documents = [target]
        for i in 0..<90 {
            documents.append(("logs/\(i).txt", String(repeating: "巡检记录。", count: 120) + "附录提及潮汐储能 \(i)", 9_999))
        }
        var random = documents
        var seed: UInt64 = 741_219
        for i in random.indices.reversed() where i > 0 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1; random.swapAt(i, Int(seed % UInt64(i + 1)))
        }
        for (index, order) in [documents, Array(documents.reversed()), random].enumerated() {
            let db = try database("order-\(index)", documents: order)
            var metrics = SearchMetrics(); var partials: [[SearchHit]] = []
            let hits = try db.searchSupplementary("潮汐储能", options: SearchOptions(scope: .content, limit: 5),
                onPartial: { partials.append($0) }, traceCandidates: true, onMetrics: { metrics = $0 })
            XCTAssertEqual(hits.first?.file.relativePath, target.0)
            XCTAssertEqual(hits.count, 5)
            XCTAssertGreaterThan(metrics.candidates, 5)
            XCTAssertTrue(metrics.candidateOrder.contains("r/" + target.0))
            XCTAssertTrue(metrics.resultTruncated)
            XCTAssertFalse(metrics.budgetExhausted)
            XCTAssertTrue(partials.allSatisfy { $0.count <= 5 })
            XCTAssertTrue(partials.first?.first?.snippet.contains("潮汐储能") == true)
            XCTAssertTrue(hits.allSatisfy { !$0.snippet.isEmpty })
        }
    }

    func testAllAllowsWordsSplitAcrossNameAndBodyAndKeepsExclusions() throws {
        let db = try database("mixed", documents: [
            ("海棠-方案.txt", "灌溉周期和土壤湿度的设计。", 1),
            ("海棠-旧稿.txt", "灌溉周期和土壤湿度 blocked。", 2),
            ("other.txt", "海棠灌溉周期和土壤湿度的设计。", 3)])
        let hits = try db.searchSupplementary("海棠 湿度 -blocked path:方案", options: SearchOptions(scope: .all))
        XCTAssertEqual(hits.map(\.file.relativePath), ["海棠-方案.txt"])
        XCTAssertTrue(try db.searchSupplementary("海棠 湿度 path:方案", options: SearchOptions(scope: .content)).isEmpty)
    }

    func testMetricsCountSharedBodyOnceIncludingSelectedSnippets() throws {
        let body = "alpha beta: a focused explanation."
        let db = try database("copies", documents: [("a.txt", body, 1), ("b.txt", body, 2)])
        // Share the stored blob explicitly; JSON member order is not part of the content API contract.
        try db.run("UPDATE files SET content_id=(SELECT content_id FROM files ORDER BY id LIMIT 1)")
        var metrics = SearchMetrics(); var callbacks = 0
        let hits = try db.searchSupplementary("\"alpha beta\"", options: SearchOptions(scope: .content), onMetrics: {
            metrics = $0; callbacks += 1
        })
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(metrics.distinctBodies, 1)
        XCTAssertEqual(metrics.decompressions, 1, "摘要复用验证的有界缓存")
        XCTAssertEqual(metrics.summariesBuilt, 1, "共享正文摘要只生成一次")
        XCTAssertGreaterThan(metrics.decompressedBytes, body.utf8.count)
        XCTAssertTrue(hits.allSatisfy { $0.snippet.contains("alpha beta") })
    }

    func testInternalTopSetTrimStillReportsResultTruncation() throws {
        let docs = (0..<1_001).map { ("copies/\($0).txt", "needle", 1.0) }
        let db = try database("trim", documents: docs)
        try db.run("UPDATE files SET content_id=(SELECT content_id FROM files ORDER BY id LIMIT 1)")
        var metrics = SearchMetrics()
        let hits = try db.searchSupplementary("needle", options: SearchOptions(scope: .content, limit: 500), onMetrics: { metrics = $0 })
        XCTAssertEqual(hits.count, 500)
        XCTAssertEqual(metrics.verified, 1_001)
        XCTAssertTrue(metrics.resultTruncated)
        XCTAssertFalse(metrics.budgetExhausted)
    }

    func testBoundedFalsePositivesReportLimitedInsteadOfExhaustiveEmpty() throws {
        let docs = (0..<4_110).map { ("false/\($0).txt", "abcXbcd \($0)", 1.0) }
        let db = try database("bounded", documents: docs)
        var metrics = SearchMetrics()
        let hits = try db.searchSupplementary("abcd", options: SearchOptions(scope: .content, limit: 5), onMetrics: { metrics = $0 })
        XCTAssertTrue(hits.isEmpty, "gram候选不能代替原文精确验证")
        XCTAssertTrue(metrics.budgetExhausted)
        XCTAssertTrue(metrics.resultTruncated)
        XCTAssertLessThanOrEqual(metrics.candidates, 4_000)
        XCTAssertLessThanOrEqual(metrics.decompressedBytes, 64 * 1024 * 1024)
    }

    func testMergeProtectsStrongNamesAndSurfacesFocusedBodyOverWeakNames() {
        let root = IndexedRoot(id: "r", path: directory.path)
        func hit(_ id: Int64, _ name: String, strength: Int = 0) -> SearchHit {
            var hit = SearchHit(file: FileRecord(id: id, rootID: "r", relativePath: name, name: name,
                fileExtension: "txt", kind: .document, size: id, modified: Double(id)), root: root)
            hit.contentRelevance = strength; return hit
        }
        let exact = hit(1, "潮汐储能.txt"), body = hit(99, "opaque.txt", strength: 3)
        let weak = (2...20).map { hit(Int64($0), "旧稿-潮汐储能-\($0).txt") }
        let merged = SearchResultMerger.merge(nameResults: [exact] + weak, contentResults: [body], scope: .all,
            sort: .relevance, limit: 5, query: "潮汐储能")
        XCTAssertEqual(Array(merged.prefix(2).map(\.id)), [1, 99])
        let pinyin = hit(100, "数学分析.pdf")
        XCTAssertEqual(SearchResultMerger.merge(nameResults: [pinyin], contentResults: [body], scope: .all,
            sort: .relevance, limit: 5, query: "sxfx").first?.id, 100)
        XCTAssertEqual(SearchResultMerger.merge(nameResults: [exact], contentResults: [body], scope: .all,
            sort: .modified, limit: 5, query: "潮汐储能").first?.id, 99)
        XCTAssertEqual(SearchResultMerger.merge(nameResults: [exact], contentResults: [body], scope: .name,
            sort: .relevance, limit: 5).map(\.id), [1])
        XCTAssertEqual(SearchResultMerger.merge(nameResults: [exact], contentResults: [body], scope: .content,
            sort: .relevance, limit: 5).map(\.id), [99])
    }

    func testStrongBodyOverlapIsPromotedBeforeLimitWithoutDuplicatingStrongNames() {
        let root=IndexedRoot(id:"r",path:directory.path)
        func hit(_ id:Int64,_ name:String,_ strength:Int=0)->SearchHit {
            var hit=SearchHit(file:FileRecord(id:id,rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:0,modified:0),root:root)
            hit.contentRelevance=strength;return hit
        }
        let weak=hit(1,"A-tidal-cache-log.txt"),target=hit(2,"Z-tidal-cache-notes.txt",3),body=hit(3,"opaque.txt",2)
        let merge={ (names:[SearchHit],limit:Int) in SearchResultMerger.merge(nameResults:names,contentResults:[target,body],scope:.all,sort:.relevance,limit:limit,query:"tidal cache") }
        XCTAssertEqual(merge([weak,target],2).map(\.id),[2,1],"正文第一的目标不能因普通名称重叠被截掉")
        XCTAssertEqual(merge([weak,target],5).map(\.id),[2,1,3])
        let exact=hit(4,"tidal cache.txt",3)
        let merged=SearchResultMerger.merge(nameResults:[exact,weak,target],contentResults:[target,exact,body],scope:.all,sort:.relevance,limit:5,query:"tidal cache")
        XCTAssertEqual(merged.map(\.id),[4,2,1,3])
        XCTAssertEqual(Set(merged.map(\.id)).count,merged.count)
    }

    /// Force the fourth blob read (the first cache-missing summary) to cross
    /// the real deadline inside sqlite3_step, rather than before readContent.
    private final class SummaryInterrupt {
        let connection:OpaquePointer
        let external:Bool
        var reads=0,triggered=false,cancelled=false
        init(_ connection:OpaquePointer,external:Bool){self.connection=connection;self.external=external}
    }
    private func summaryInterruption(external:Bool) throws -> (SearchDatabase,SummaryInterrupt) {
        let text=String(repeating:"x",count:8*1024*1024-100)
        let db=try database(external ? "summary-cancel" : "summary-deadline",documents:(0..<3).map { ("\($0).txt","\($0)"+text+" needle",Double(3-$0)) })
        let probe=SummaryInterrupt(try XCTUnwrap(db.connection),external:external)
        sqlite3_trace_v2(db.connection,UInt32(SQLITE_TRACE_STMT),{_,context,statement,_ in
            guard let context,let statement,let sql=sqlite3_sql(OpaquePointer(statement)),String(cString:sql)=="SELECT packed FROM content_blobs WHERE id=?" else{return 0}
            let p=Unmanaged<SummaryInterrupt>.fromOpaque(context).takeUnretainedValue();p.reads += 1
            if p.reads==4 {
                p.triggered=true
                if p.external {p.cancelled=true}else{Thread.sleep(forTimeInterval:2.05)}
                sqlite3_interrupt(p.connection)
            }
            return 0
        },Unmanaged.passUnretained(probe).toOpaque())
        return (db,probe)
    }
    func testSummarySQLDeadlineReturnsVerifiedPartialResultsAsLimitedCompletion() throws {
        let (db,probe)=try summaryInterruption(external:false)
        defer{sqlite3_trace_v2(db.connection,0,nil,nil)}
        var metrics=SearchMetrics(),callbacks=0,partials:[[SearchHit]]=[]
        let hits=try db.searchSupplementary("needle",options:SearchOptions(scope:.content,limit:3),onPartial:{partials.append($0)},onMetrics:{metrics=$0;callbacks += 1})
        XCTAssertTrue(probe.triggered);XCTAssertFalse(partials.isEmpty)
        XCTAssertEqual(hits.count,3);XCTAssertTrue(partials.flatMap{$0}.allSatisfy {hit in hits.contains {$0.id==hit.id}})
        XCTAssertTrue(metrics.budgetExhausted);XCTAssertTrue(metrics.resultTruncated);XCTAssertEqual(callbacks,1)
        XCTAssertEqual(try db.search("",options:SearchOptions(scope:.name)).count,3,"预算结束后连接仍可查询")
    }
    func testSummarySQLInterruptionStillThrowsForExternalCancellation() throws {
        let (db,probe)=try summaryInterruption(external:true)
        defer{sqlite3_trace_v2(db.connection,0,nil,nil)}
        var callbacks=0,partial=false
        XCTAssertThrowsError(try db.searchSupplementary("needle",options:SearchOptions(scope:.content,limit:3),cancelled:{probe.cancelled},onPartial:{_ in partial=true},onMetrics:{_ in callbacks += 1})) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(probe.triggered);XCTAssertTrue(partial);XCTAssertEqual(callbacks,1)
    }
}
