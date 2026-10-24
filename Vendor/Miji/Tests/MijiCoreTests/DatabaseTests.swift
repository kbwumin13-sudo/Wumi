import XCTest
import Foundation
import CSQLite
import CContentIndex
@testable import MijiCore

final class DatabaseTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var db: SearchDatabase!
    private var root: IndexedRoot!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-db-tests-\(UUID().uuidString)")
        databaseURL = directory.appendingPathComponent("index.sqlite")
        db = try SearchDatabase(url: databaseURL)
        root = IndexedRoot(id: "root", path: directory.appendingPathComponent("source").path, name: "学习盘", volumeUUID: "volume-uuid", volumeRelativePath: "资料", isExternal: true)
        try db.saveRoot(root)
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func record(_ path: String, rootID: String = "root", size: Int64 = 100, modified: Double = 100, inode: Int64 = 1, state: String = "pending") -> FileRecord {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: path).pathExtension
        return FileRecord(rootID: rootID, relativePath: path, name: name, fileExtension: ext, kind: FileKind.classify(extension: ext), size: size, modified: modified, inode: inode, contentState: state)
    }

    @discardableResult
    private func insert(_ path: String, content: ExtractedContent? = nil, generation: Int64 = 1) throws -> FileRecord {
        try db.upsertFiles([record(path)], generation: generation)
        let file = try XCTUnwrap(db.pendingFiles(rootID: "root", limit: 1000).first { $0.relativePath == path })
        if let content { XCTAssertTrue(try db.completeContent(file: file, content: content)) }
        return file
    }

    func testChineseShortWordsTrigramAndPinyin() throws {
        let math = try insert("课程/数学分析笔记.pdf", content: ExtractedContent(text: "证明：连续函数在闭区间上有界。期末复习材料。", pages: 2))
        let photo = try insert("照片/旅行截图.png", content: ExtractedContent(text: "上海虹桥站", labels: ["火车", "train", "旅行照片"]))
        for query in ["数", "数学", "数学分析", "shuxuefenxi", "sxfx"] {
            XCTAssertEqual(try db.search(query).map(\.id), [math.id], query)
        }
        for query in ["闭", "闭区", "闭区间", "连续函数", "期末复习"] {
            let hit = try XCTUnwrap(db.search(query).first)
            XCTAssertEqual(hit.id, math.id)
            XCTAssertTrue(hit.matchedIn.contains("正文"))
            XCTAssertTrue(hit.snippet.contains("闭区间"))
        }
        for query in ["火", "火车", "train", "旅行照片"] {
            let hit = try XCTUnwrap(db.search(query).first)
            XCTAssertEqual(hit.id, photo.id)
            XCTAssertTrue(hit.matchedIn.contains("图片标签"))
            XCTAssertEqual(hit.labels, "火车、train、旅行照片")
        }
        XCTAssertEqual(try db.search("上海虹桥站", options: SearchOptions(scope: .content)).map(\.id), [photo.id])
        XCTAssertTrue(try db.search("闭区间", options: SearchOptions(scope: .name)).isEmpty)
        XCTAssertTrue(try db.search("数学分析", options: SearchOptions(scope: .content)).isEmpty)
        XCTAssertEqual(try db.search("数学 证明").first?.matchedIn, "文件名、正文")
    }

    func testPunctuationPhrasesAndLiteralFTSOperators() throws {
        let literal = try insert("特殊/C++ (v2) [草稿].txt", content: ExtractedContent(text: "literal foo-bar; a*b OR NOT NEAR(foo). quote \"hello\"; 你好，世界！\n café CAFÉ。 !!!   a  b; emoji😀猫狗。"))
        _ = try insert("其他.txt", content: ExtractedContent(text: "foo goes elsewhere bar"))
        for query in ["C++", "\"(v2)\"", "\"[草稿]\"", "\"foo-bar\"", "a*b", "\"NEAR(foo)\"", "\"你好，世界！\"", "CAFÉ", "\"quote \\\"hello\\\"\"", "!!!", "\"   \"", "\"a  b\"", "😀猫狗"] {
            XCTAssertEqual(try db.search(query).map(\.id), [literal.id], query)
        }
        XCTAssertEqual(try db.search("\"foo-bar; a*b\"").map(\.id), [literal.id])
        XCTAssertEqual(try db.search("\"foo bar\"").count, 0)
        XCTAssertEqual(try db.search("foo bar").count, 2)
        // Parser operators and FTS operators are independent: OR is literal text.
        XCTAssertEqual(try db.search("OR NOT").map(\.id), [literal.id])
        XCTAssertEqual(try db.search("\"cafe\u{301}\"").map(\.id), [literal.id])
        XCTAssertNoThrow(try db.search("\"unterminated"))
        XCTAssertNoThrow(try db.search("a\0b"))
    }

    func testSelectedSnippetsKeepOriginalUnicodeOffsetsAndSharedBodyOrdering() throws {
        let body=String(repeating:"😀İCAFÉ 前言 ",count:40)+"目标 CAFÉ 神 数学分析 后文"
        let a=try insert("a.txt",content:ExtractedContent(text:body))
        let b=try insert("b.txt",content:ExtractedContent(text:body))
        for query in ["目标","神","数学分析","cafe\u{301}"] {
            let hits=try db.search(query,options:SearchOptions(scope:.content,sort:.name))
            XCTAssertEqual(hits.map(\.id),[a.id,b.id])
            XCTAssertEqual(hits[0].snippet,hits[1].snippet)
            XCTAssertFalse(hits[0].snippet.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(db.search("目标",options:SearchOptions(scope:.content)).first).snippet.contains("目标"))
    }

    func testProgressiveContentHitsAreVerifiedAndRemainCancellable() throws {
        _=try insert("blocked.txt",content:ExtractedContent(text:"needle blocked"))
        let wanted=try insert("wanted.txt",content:ExtractedContent(text:"needle allowed"))
        var partial:[SearchHit]=[],cancelled=false
        XCTAssertThrowsError(try db.searchSupplementary("needle -blocked",options:SearchOptions(scope:.content),cancelled:{cancelled},onPartial:{hits in
            partial=hits;cancelled=true
        })) {XCTAssertTrue($0 is CancellationError)}
        XCTAssertEqual(partial.map(\.id),[wanted.id])
        XCTAssertEqual(try db.search("needle -blocked",options:SearchOptions(scope:.content)).map(\.id),[wanted.id])
    }

    func testCombinedFiltersNegationsAndScopes() throws {
        let wanted = try insert("课程 资料/数学笔记.PDF", content: ExtractedContent(text: "连续函数的证明", labels: ["handwriting"]))
        _ = try insert("课程 资料/数学草稿.pdf", content: ExtractedContent(text: "连续函数的证明 草稿"))
        _ = try insert("其他/数学笔记.txt", content: ExtractedContent(text: "连续函数的证明"))
        XCTAssertEqual(try db.search("数学 连续 ext:.PDF kind:文档 path:\"课程 资料\" -草稿").map(\.id), [wanted.id])
        XCTAssertEqual(try db.search("数学 ext:pdf -path:其他 -kind:image -ext:txt -草稿").map(\.id), [wanted.id])
        XCTAssertEqual(try db.search("-草稿", options: SearchOptions(kind: .document)).count, 2)
        XCTAssertTrue(try db.search("数学", options: SearchOptions(kind: .image)).isEmpty)
        XCTAssertTrue(try db.search("数学", options: SearchOptions(rootID: "missing")).isEmpty)
        XCTAssertTrue(try db.search("kind:unknown").isEmpty)
        XCTAssertEqual(try db.search("数学 连续", options: SearchOptions(scope: .all)).count, 3)
        XCTAssertTrue(try db.search("数学 连续", options: SearchOptions(scope: .name)).isEmpty)
        XCTAssertTrue(try db.search("数学 连续", options: SearchOptions(scope: .content)).isEmpty)
        XCTAssertEqual(try db.search("path:\"课程 资料\" -ext:txt").count, 2)
        XCTAssertEqual(QueryParser.parse("\"ext:pdf\" -path:\"a b\" ext:.PDF").terms.map(\.field), [.text, .path, .ext])
        XCTAssertEqual(QueryParser.parse("\"ext:pdf\" -path:\"a b\" ext:.PDF").terms.map(\.value), ["ext:pdf", "a b", "pdf"])
    }

    func testSQLInjectionInputIsLiteralAndNoMatchGrammarLeaks() throws {
        let special = try insert("quote's.txt", content: ExtractedContent(text: "literal ' OR 1=1 -- ; DROP TABLE files; percent% under_score * ^ : { }"))
        _ = try insert("innocent.txt")
        XCTAssertEqual(try db.search("\"' OR 1=1 --\"").map(\.id), [special.id])
        XCTAssertEqual(try db.search("\"DROP TABLE files;\"").map(\.id), [special.id])
        for query in ["\"percent%\"", "under_score", "*", "^", ":", "{", "}"] {
            XCTAssertEqual(try db.search(query).map(\.id), [special.id], query)
        }
        XCTAssertTrue(try db.search("ext:pdf'OR'1'='1").isEmpty)
        XCTAssertTrue(try db.search("' OR 1=1 --").isEmpty)
        XCTAssertEqual(try db.statistics().files, 2)
        XCTAssertEqual(try db.roots().count, 1)
        XCTAssertTrue(try db.search("nonexistent%").isEmpty)
    }

    func testIncrementalChangesAndStaleExtractionResults() throws {
        let original = try insert("报告.pdf", content: ExtractedContent(text: "旧内容检索", labels: ["旧标签"], pages: 4, warning: "截断"))
        try db.upsertFiles([record("报告.pdf")], generation: 2)
        let unchanged = try XCTUnwrap(db.search("").first?.file)
        XCTAssertEqual(unchanged.id, original.id)
        XCTAssertEqual(unchanged.contentState, "done")
        XCTAssertEqual(try db.storedContent(fileID: original.id)?.warning, "截断")
        XCTAssertEqual(try db.storedContent(fileID: original.id)?.pages, 4)
        var previous = original
        let versions = [record("报告.pdf", size: 101), record("报告.pdf", size: 101, modified: 101), record("报告.pdf", size: 101, modified: 101, inode: 2)]
        for (offset, version) in versions.enumerated() {
            try db.upsertFiles([version], generation: Int64(offset + 3))
            let current = try XCTUnwrap(db.pendingFiles(rootID: "root").first)
            XCTAssertEqual(current.id, original.id)
            XCTAssertNil(try db.storedContent(fileID: original.id))
            XCTAssertTrue(try db.search("旧内容检索").isEmpty)
            XCTAssertFalse(try db.completeContent(file: previous, content: ExtractedContent(text: "陈旧结果")))
            try db.failContent(file: previous, message: "陈旧错误")
            XCTAssertEqual(try db.pendingFiles(rootID: "root").count, 1)
            XCTAssertTrue(try db.completeContent(file: current, content: ExtractedContent(text: "新内容第\(offset)版")))
            XCTAssertEqual(try db.search("新内容").count, 1)
            previous = current
        }
        try db.failContent(file: previous, message: "解析失败")
        try db.upsertFiles([versions.last!], generation: 10)
        XCTAssertEqual(try db.search("").first?.file.contentState, "error")
        XCTAssertEqual(try db.search("").first?.file.contentError, "解析失败")
        XCTAssertEqual(try db.statistics().errors, 1)
        try db.resetContent(rootID: "root", kind: .image)
        XCTAssertEqual(try db.statistics().errors, 1)
        try db.resetContent(rootID: "root", kind: .document)
        XCTAssertEqual(try db.statistics().errors, 0)
        XCTAssertEqual(try db.statistics().pending, 1)
        XCTAssertNil(try db.storedContent(fileID: original.id))
    }

    func testUpsertingMutatedDoneRecordRequeuesTheNewVersion() throws {
        _ = try insert("新版本.txt", content: ExtractedContent(text: "已完成版本"))
        var stored = try XCTUnwrap(db.search("").first?.file)
        XCTAssertEqual(stored.contentState, "done")
        stored.modified += 1
        try db.upsertFiles([stored], generation: 2)
        XCTAssertEqual(try db.pendingFiles(rootID: root.id).map(\.id), [stored.id])
        XCTAssertNil(try db.storedContent(fileID: stored.id))
        XCTAssertTrue(try db.search("已完成版本").isEmpty)
    }

    func testDeferredSkippedAndPendingKindFiltering() throws {
        try db.upsertFiles([record("第一张.png"), record("云文档.pdf", state: "deferred"), record("普通.bin", state: "skipped"), record("文档.txt")], generation: 1)
        XCTAssertEqual(try db.pendingFiles(rootID: "root", limit: 1, kind: .document).map(\.name), ["文档.txt"])
        XCTAssertEqual(try db.pendingFiles(rootID: "root", kind: .image).map(\.name), ["第一张.png"])
        XCTAssertEqual(try db.pendingFiles(rootID: "root", limit: 0).count, 0)
        XCTAssertEqual(try db.statistics().pending, 2)
        try db.resetContent(rootID: "root")
        XCTAssertEqual(try db.statistics().pending, 2)
        try db.upsertFiles([record("云文档.pdf")], generation: 2)
        XCTAssertEqual(try db.pendingFiles(rootID: "root", kind: .document).map(\.name).sorted(), ["云文档.pdf", "文档.txt"].sorted())
        let downloaded = try XCTUnwrap(db.pendingFiles(rootID: "root").first { $0.name == "云文档.pdf" })
        XCTAssertTrue(try db.completeContent(file: downloaded, content: ExtractedContent(text: "云端正文")))
        try db.upsertFiles([record("云文档.pdf", state: "deferred")], generation: 3)
        XCTAssertEqual(try db.search("云端正文").first?.file.contentState, "done")
        try db.upsertFiles([record("云文档.pdf", size: 101, state: "deferred")], generation: 4)
        XCTAssertTrue(try db.search("云端正文").isEmpty)
        XCTAssertEqual(try db.search("云文档").first?.file.contentState, "deferred")
    }

    func testPartialScanOfflineRetentionPruningAndRestart() throws {
        let keep = try insert("保留.pdf", content: ExtractedContent(text: "外置盘全文资料"))
        _ = try insert("删除.txt", content: ExtractedContent(text: "删除内容测试"))
        try db.upsertFiles([record("保留.pdf")], generation: 2)
        try db.finishScan(rootID: root.id, generation: 2, prune: false)
        XCTAssertEqual(try db.statistics().files, 2)
        XCTAssertNil(try db.roots().first?.lastScan)
        root.isOnline = false
        root.lastError = "磁盘未连接"
        try db.saveRoot(root)
        try db.finishScan(rootID: root.id, generation: 999)
        XCTAssertEqual(try db.statistics().files, 2)
        XCTAssertEqual(try db.search("外置盘全文资料").map(\.id), [keep.id])
        XCTAssertFalse(try XCTUnwrap(db.search("外置盘全文资料").first).root.isOnline)
        XCTAssertTrue(try db.search("外置盘全文资料", options: SearchOptions(onlineOnly: true)).isEmpty)
        db = nil
        db = try SearchDatabase(url: databaseURL)
        XCTAssertEqual(try db.roots(), [root])
        XCTAssertEqual(try db.search("外置盘全文资料").map(\.id), [keep.id])
        root.path = directory.appendingPathComponent("remounted").path
        root.isOnline = true
        try db.saveRoot(root)
        XCTAssertEqual(try db.search("外置盘全文资料").first?.path, root.path + "/保留.pdf")
        try db.finishScan(rootID: root.id, generation: 2)
        XCTAssertEqual(try db.statistics().files, 1)
        XCTAssertTrue(try db.search("删除内容测试").isEmpty)
        XCTAssertNotNil(try db.roots().first?.lastScan)
        XCTAssertNil(try db.roots().first?.lastError)
    }
    func testPruningProtectsExactFailedPathsWithoutWildcardOrSiblingMatches() throws {
        let preserved = ["blocked", "blocked/nested/keep.txt", "literal_%'/keep.txt", "unreadable.txt"]
        let removed = ["blocked-other/gone.txt", "literal_XX'/gone.txt", "unreadable.txt-other", "gone.txt"]
        try db.upsertFiles((preserved+removed+["seen.txt"]).map {record($0)},generation:1)
        try db.upsertFiles([record("seen.txt")],generation:2)
        try db.finishScan(rootID:root.id,generation:2,preservingPaths:["blocked","literal_%'","unreadable.txt"])
        XCTAssertEqual(Set(try db.search("").map(\.file.relativePath)),Set(preserved+["seen.txt"]))
        // A root-level enumeration failure must retain even unobserved paths.
        try db.finishScan(rootID:root.id,generation:3,preservingPaths:[""])
        XCTAssertEqual(try db.statistics().files,preserved.count+1)
        // Protection belongs to this scan, not later successful scans.
        try db.upsertFiles([record("seen.txt")],generation:4)
        try db.finishScan(rootID:root.id,generation:4)
        XCTAssertEqual(try db.search("").map(\.file.relativePath),["seen.txt"])
    }

    func testDeleteOnlyRemovesIndexAndRejectsWorkForReinsertedFile() throws {
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        let actual = URL(fileURLWithPath: root.path).appendingPathComponent("报告.pdf")
        try Data("原文件".utf8).write(to: actual)
        let original = try insert("报告.pdf", content: ExtractedContent(text: "删除前正文"))
        try db.removeRoot(id: root.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
        XCTAssertEqual(try db.statistics().files, 0)
        XCTAssertNil(try db.storedContent(fileID: original.id))
        XCTAssertTrue(try db.search("删除前正文").isEmpty)
        XCTAssertTrue(try db.roots().isEmpty)
        try db.saveRoot(root)
        let new = try insert("报告.pdf")
        XCTAssertNotEqual(new.id, original.id)
        XCTAssertFalse(try db.completeContent(file: original, content: ExtractedContent(text: "失效任务")))
        try db.failContent(file: original, message: "失效失败")
        XCTAssertEqual(try db.pendingFiles(rootID: root.id).map(\.id), [new.id])
    }

    func testRootIsolationAtomicBatchAndRelativePaths() throws {
        try db.saveRoot(IndexedRoot(id: "second", path: "/Volumes/second", isOnline: false))
        try db.upsertFiles([record("共享名.txt"), record("共享名.txt", rootID: "second")], generation: 1)
        XCTAssertEqual(try db.search("共享名").count, 2)
        XCTAssertEqual(try db.search("共享名", options: SearchOptions(rootID: "root")).count, 1)
        XCTAssertEqual(try db.search("共享名", options: SearchOptions(onlineOnly: true)).count, 1)
        XCTAssertThrowsError(try db.upsertFiles([record("应回滚.txt"), record("../越界.txt")], generation: 2))
        XCTAssertTrue(try db.search("应回滚").isEmpty)
        XCTAssertThrowsError(try db.upsertFiles([record("/绝对路径.txt")], generation: 2))
        XCTAssertThrowsError(try db.upsertFiles([record("不存在.txt", rootID: "missing")], generation: 2))
        XCTAssertEqual(try db.statistics().files, 2)
        try db.removeRoot(id: "second")
        XCTAssertEqual(try db.statistics().files, 1)
    }

    func testOptionsSortingLimitsAndStatistics() throws {
        try db.upsertFiles([record("b.pdf", size: 300, modified: 1), record("a.txt", size: 100, modified: 3), record("c.png", size: 200, modified: 2)], generation: 1)
        let files = try db.pendingFiles(rootID: root.id)
        XCTAssertTrue(try db.completeContent(file: files[0], content: ExtractedContent(text: "文档内容")))
        try db.failContent(file: files[1], message: "错误")
        XCTAssertEqual(try db.search("", options: SearchOptions(sort: .name)).map(\.file.name), ["a.txt", "b.pdf", "c.png"])
        XCTAssertEqual(try db.search("", options: SearchOptions(sort: .modified)).map(\.file.name), ["a.txt", "c.png", "b.pdf"])
        XCTAssertEqual(try db.search("", options: SearchOptions(sort: .size)).map(\.file.name), ["b.pdf", "c.png", "a.txt"])
        XCTAssertEqual(try db.search("", options: SearchOptions(limit: 2)).count, 2)
        XCTAssertTrue(try db.search("", options: SearchOptions(limit: -1)).isEmpty)
        let stats = try db.statistics()
        XCTAssertEqual(stats.files, 3)
        XCTAssertEqual(stats.documents, 2)
        XCTAssertEqual(stats.images, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.errors, 1)
        XCTAssertEqual(stats.indexedContent, 1)
        let filename = try insert("文档内容.txt")
        XCTAssertEqual(try db.search("文档内容").first?.id, filename.id)
    }

    func testLargeBodyIndexIsNotRewrittenByNameOrGenerationUpdate() throws {
        let file = try insert("原始名称.txt", content: ExtractedContent(text: String(repeating: "大正文唯一检索词。", count: 2000)))
        let before = try rawRows("SELECT id,hex(block) FROM content_fts_data ORDER BY id")
        var renamed = record("原始名称.txt")
        renamed.name = "更新名称.txt"
        try db.upsertFiles([renamed], generation: 2)
        XCTAssertEqual(try rawRows("SELECT id,hex(block) FROM content_fts_data ORDER BY id"), before)
        XCTAssertEqual(try db.search("大正文唯一检索词").map(\.id), [file.id])
        XCTAssertEqual(try db.search("更新名称").map(\.id), [file.id])
        XCTAssertTrue(try db.search("原始名称").isEmpty)
        try db.upsertFiles([renamed], generation: 3)
        XCTAssertEqual(try rawRows("SELECT id,hex(block) FROM content_fts_data ORDER BY id"), before)
        XCTAssertEqual(try rawRows("PRAGMA journal_mode").first, ["wal"])
    }

    func testConcurrentAccessAndSeparateConnections() throws {
        let other = try SearchDatabase(url: databaseURL)
        let errorLock = NSLock()
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                let database = index.isMultiple(of: 2) ? self.db! : other
                try database.upsertFiles([self.record("并发\(index).txt")], generation: 1)
                _ = try database.search("并发")
                _ = try database.statistics()
            } catch {
                errorLock.lock()
                errors.append(String(describing: error))
                errorLock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(try db.statistics().files, 40)
        XCTAssertEqual(try other.search("并发").count, 40)
    }

    func testCandidateIndexPlanAndSmallScaleTiming() throws {
        let count = 3000
        let files = (0..<count).map { record("目录/测试文档\($0).txt") }
        let insertStart = Date()
        try db.upsertFiles(files, generation: 1)
        let insertion = Date().timeIntervalSince(insertStart)
        let file = try XCTUnwrap(db.pendingFiles(rootID: root.id, limit: 1).first)
        XCTAssertTrue(try db.completeContent(file: file, content: ExtractedContent(text: "唯一中文检索目标字符串")))
        let longStart = Date()
        XCTAssertEqual(try db.search("中文检索目标").map(\.id), [file.id])
        let longTime = Date().timeIntervalSince(longStart)
        let shortStart = Date()
        XCTAssertEqual(try db.search("中文").map(\.id), [file.id])
        let shortTime = Date().timeIntervalSince(shortStart)
        let plan = try rawRows("EXPLAIN QUERY PLAN SELECT f.id FROM files f WHERE f.content_id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH 'ge4b8ad')")
        XCTAssertTrue(plan.flatMap { $0 }.contains(where: { $0.contains("VIRTUAL TABLE INDEX") }))
        print("Miji database sample: \(count) files; insert=\(insertion)s; trigram=\(longTime)s; short fallback=\(shortTime)s")
    }

    private func rawRows(_ sql: String) throws -> [[String]] {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SearchDatabaseError(message: "测试只读连接失败") }
        defer { sqlite3_close(connection) }
        XCTAssertEqual(miji_register_tokenizer(connection), SQLITE_OK)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw SearchDatabaseError(message: String(cString: sqlite3_errmsg(connection))) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw SearchDatabaseError(message: String(cString: sqlite3_errmsg(connection))) }
        return rows
    }

    func testReadOnlyOpenDoesNotCreateMissingParentOrDatabase() throws {
        let missing = directory.appendingPathComponent("missing/index.sqlite")
        XCTAssertThrowsError(try SearchDatabase(url: missing, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testReadOnlyOpenRunsNoDDLWhileWriterHoldsTransaction() throws {
        let before = try rawRows("SELECT type,name,sql FROM sqlite_master ORDER BY name")
        let version = try rawRows("PRAGMA user_version")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }
        let start = Date()
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        XCTAssertEqual(try reader.roots(), [root])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(try rawRows("SELECT type,name,sql FROM sqlite_master ORDER BY name"), before)
        XCTAssertEqual(try rawRows("PRAGMA user_version"), version)
    }

    func testReadOnlyOpenLeavesUninitializedSchemaUntouched() throws {
        db = nil
        try FileManager.default.removeItem(at: databaseURL)
        var empty: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &empty, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(empty), SQLITE_OK)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        XCTAssertTrue(try rawRows("SELECT name FROM sqlite_master").isEmpty)
        XCTAssertEqual(try rawRows("PRAGMA user_version"), [["0"]])
        XCTAssertEqual(try rawRows("PRAGMA journal_mode"), [["delete"]])
        XCTAssertThrowsError(try reader.roots(), "The caller must initialize the schema with a writer first")
    }

    func testReadOnlyConnectionRejectsWritesRetainsShortWordsAndOfflineSearch() throws {
        let file = try insert("数学笔记.pdf", content: ExtractedContent(text: "闭区间", labels: ["火车"]))
        root.isOnline = false
        try db.saveRoot(root)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        for term in ["数", "数学", "闭", "闭区", "火", "火车", "shuxue", "sx"] {
            XCTAssertEqual(try reader.search(term).map(\.id), [file.id], term)
        }
        XCTAssertTrue(try reader.search("数学", options: SearchOptions(onlineOnly: true)).isEmpty)
        XCTAssertThrowsError(try reader.saveRoot(root))
        XCTAssertThrowsError(try reader.upsertFiles([record("只读不可写.txt")], generation: 2))
        XCTAssertEqual(try reader.statistics().files, 1)
        try db.upsertFiles([record("后来写入.txt")], generation: 2)
        XCTAssertEqual(try reader.search("后来写入").count, 1)
        XCTAssertEqual(try reader.statistics().files, 2)
    }

    func testWriterAddsContentIndexToExistingSchemaWithoutLosingContent() throws {
        let file = try insert("历史资料.pdf", content: ExtractedContent(text: "历史正文", warning: "部分内容"))
        try db.failContent(file: file, message: "保留已有正文")
        db = nil
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &legacy, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(legacy, "DROP INDEX files_with_content", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacy), SQLITE_OK)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        XCTAssertTrue(try rawRows("SELECT name FROM sqlite_master WHERE name='files_with_content'").isEmpty)
        XCTAssertEqual(try reader.search("历史正文").map(\.id), [file.id])
        // Only opening the writer upgrades the schema, even for a live reader.
        db = try SearchDatabase(url: databaseURL)
        XCTAssertEqual(try reader.statistics().indexedContent, 1)
        XCTAssertEqual(try reader.statistics().errors, 1)
        XCTAssertEqual(try db.roots(), [root])
        XCTAssertEqual(try db.storedContent(fileID: file.id)?.warning, "部分内容")
    }

    func testSearchCancellationBeforeStartAndDuringNoMatchScanIsReusable() throws {
        try db.upsertFiles((0..<1500).map { record("item\($0).txt") }, generation: 1)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        XCTAssertThrowsError(try reader.search("字", cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        var polls = 0
        XCTAssertThrowsError(try reader.search("字", cancelled: {
            polls += 1
            return polls >= 6
        })) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertGreaterThanOrEqual(polls, 6, "No matching rows: cancellation must run inside SQLite, not just between results")
        XCTAssertLessThan(polls, 20)
        XCTAssertEqual(try reader.search("item1499").count, 1)
        XCTAssertEqual(try reader.statistics().files, 1500)
        XCTAssertNoThrow(try db.upsertFiles([record("after-cancel.txt")], generation: 2))
        XCTAssertEqual(try reader.search("after-cancel").count, 1)
    }

    func testActiveSearchCancellationDoesNotBlockOrInterruptWriterConnection() throws {
        try db.upsertFiles((0..<1500).map { record("item\($0).txt") }, generation: 1)
        let file = try XCTUnwrap(db.pendingFiles(rootID: root.id, limit: 1).first)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        let reachedProgressHandler = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = expectation(description: "SQLite search cancelled")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            var polls = 0
            do {
                _ = try reader.search("字", cancelled: {
                    polls += 1
                    guard polls == 3 else { return false }
                    // The first two calls check cancellation before acquiring the
                    // lock and before installing the handler. This one is in SQLite.
                    reachedProgressHandler.signal()
                    _ = resume.wait(timeout: .now() + 10)
                    return true
                })
                XCTFail("Search should have been cancelled inside SQLite")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        defer { resume.signal() }
        guard reachedProgressHandler.wait(timeout: .now() + 3) == .success else {
            XCTFail("Search never reached SQLite progress handler")
            wait(for: [finished], timeout: 3)
            return
        }
        let start = Date()
        try db.upsertFiles([record("writer-stays-live.txt")], generation: 2)
        XCTAssertTrue(try db.completeContent(file: file, content: ExtractedContent(text: "写连接提取结果")))
        XCTAssertEqual(try db.statistics().indexedContent, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Writer must commit while reader is paused inside SQLite")
        resume.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(try reader.search("writer-stays-live").count, 1)
        XCTAssertEqual(try reader.search("写连接提取结果").count, 1)
    }

    func testStatisticsUseCoveringIndexesAndCountContentIndependentOfState() throws {
        let file = try insert("warning.pdf", content: ExtractedContent(text: "可检索正文", warning: "截断"))
        try db.failContent(file: file, message: "后续失败但保留正文")
        try db.upsertFiles([record("pending.png"), record("deferred.pdf", state: "deferred"), record("skipped.bin", state: "skipped")], generation: 1)
        let stats = try db.statistics()
        XCTAssertEqual(stats.files, 4)
        XCTAssertEqual(stats.documents, 2)
        XCTAssertEqual(stats.images, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.errors, 1)
        XCTAssertEqual(stats.indexedContent, 1)
        let plan = try rawRows("EXPLAIN QUERY PLAN " + SearchDatabase.statisticsSQL).map { $0.last ?? "" }
        print("Miji statistics query plan: \(plan.joined(separator: "; "))")
        XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX files_pending") })
        XCTAssertTrue(plan.contains { $0.contains("INDEX files_with_content") })
        XCTAssertFalse(plan.contains { $0 == "SCAN files" || $0 == "SCAN f" })
        try db.resetContent(rootID: root.id)
        XCTAssertEqual(try db.statistics().indexedContent, 0)
        XCTAssertEqual(try db.statistics().pending, 2)
    }
}
