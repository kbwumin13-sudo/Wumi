import XCTest
import CSQLite
@testable import MijiCore

final class MetadataWriteTests: XCTestCase {
    private var directory: URL!
    private var db: SearchDatabase!
    private var root: IndexedRoot!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-metadata-\(UUID().uuidString)")
        db = try SearchDatabase(url: directory.appendingPathComponent("index.sqlite"))
        root = IndexedRoot(id: "root", path: directory.path)
        try db.saveRoot(root)
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ path: String = "数学.txt", state: String = "pending", error: String? = nil) -> FileRecord {
        FileRecord(rootID: root.id, relativePath: path, name: path, fileExtension: ".TXT", kind: .document,
                   size: 100, modified: 123.5, inode: 7, contentState: state, contentError: error)
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        XCTAssertTrue(try db.next(statement))
        return sqlite3_column_int64(statement, 0)
    }

    private var changes: Int32 { sqlite3_total_changes(db.connection) }

    func testUnchangedFilesOnlyTouchGenerationAndNeverConsumeIDs() throws {
        let records = [file(), file("cloud.txt", state: "deferred", error: "未下载"), file("skip.txt", state: "skipped")]
        try db.upsertFiles(records, generation: 1)
        let sequence = try scalar("SELECT seq FROM sqlite_sequence WHERE name='files'")
        let revision = try scalar("SELECT revision FROM catalog_state")
        // UPDATE OF observes the columns mentioned, even if values don't change.
        try db.execute("""
            CREATE TEMP TABLE unrelated_updates(n INTEGER);
            CREATE TEMP TRIGGER metadata_probe AFTER UPDATE OF name,extension,kind,size,modified,inode,content_state,content_error,content_id,name_search,pinyin_search,initials_search,path_search ON files
            BEGIN INSERT INTO unrelated_updates VALUES(1); END;
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        var before = changes
        try db.upsertFiles(records + records, generation: 1)
        XCTAssertEqual(changes - before, 0)
        let wal = db.url.path + "-wal"
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.int64Value, 0)
        before = changes
        try db.upsertFiles(records + records, generation: 2)
        XCTAssertEqual(changes - before, 3)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE generation=2"), 3)
        XCTAssertEqual(try scalar("SELECT count(*) FROM unrelated_updates"), 0)
        XCTAssertEqual(try scalar("SELECT revision FROM catalog_state"), revision)
        XCTAssertEqual(try scalar("SELECT seq FROM sqlite_sequence WHERE name='files'"), sequence)
        try db.upsertFiles([file("new.txt")], generation: 2)
        XCTAssertEqual(try scalar("SELECT max(id) FROM files"), sequence + 1)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
    }

    func testStateAndErrorMatrixMatchesExistingUpsertContract() throws {
        let states = ["pending", "deferred", "skipped", "done", "error"]
        for stored in states {
            for incoming in states {
                for incomingError in [nil, "旧错误", "新错误"] as [String?] {
                    let path = "\(stored)-\(incoming)-\(incomingError ?? "nil").txt"
                    try db.upsertFiles([file(path)], generation: 1)
                    try db.run("UPDATE files SET content_state=?,content_error='旧错误' WHERE relative_path=?",
                               [.string(stored), .string(path)])
                    let retains = stored == "done" || stored == "error"
                    let expectedState = retains ? stored : (["deferred", "skipped"].contains(incoming) ? incoming : "pending")
                    let expectedError = retains ? "旧错误" : (expectedState == "pending" ? nil : incomingError)
                    let unchanged = expectedState == stored && expectedError == "旧错误"
                    let before = changes
                    let record = file(path, state: incoming, error: incomingError)
                    try db.upsertFiles([record], generation: 1)
                    if unchanged { XCTAssertEqual(changes - before, 0, path) }
                    let statement = try db.prepare("SELECT content_state,content_error FROM files WHERE relative_path=?")
                    defer { sqlite3_finalize(statement) }
                    try db.bind([.string(path)], to: statement)
                    XCTAssertTrue(try db.next(statement))
                    XCTAssertEqual(db.text(statement, 0), expectedState, path)
                    let error = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : db.text(statement, 1)
                    XCTAssertEqual(error, expectedError, path)
                    let after = changes
                    try db.upsertFiles([record], generation: 1)
                    XCTAssertEqual(changes, after, path)
                }
            }
        }
    }

    func testDoneAndErrorContentSurviveGenerationTouchAndDeferredInput() throws {
        try db.upsertFiles([file("done.txt"), file("error.txt")], generation: 1)
        let pending = try db.pendingFiles(rootID: root.id)
        let content = ExtractedContent(text: "正文保留契约", warning: "保留警告")
        for record in pending { XCTAssertTrue(try db.completeContent(file: record, content: content)) }
        let failed = try XCTUnwrap(pending.first { $0.name == "error.txt" })
        try db.failContent(file: failed, message: "解析错误")
        let sequence = try scalar("SELECT seq FROM sqlite_sequence WHERE name='files'")
        var before = changes
        let incoming = pending.map { file($0.relativePath, state: "deferred", error: "未下载") }
        try db.upsertFiles(incoming, generation: 1)
        XCTAssertEqual(changes - before, 0)
        before = changes
        try db.upsertFiles(incoming, generation: 2)
        XCTAssertEqual(changes - before, 2)
        for record in pending { XCTAssertEqual(try db.storedContent(fileID: record.id), content) }
        XCTAssertEqual(try db.statistics().indexedContent, 2)
        XCTAssertEqual(try db.statistics().errors, 1)
        XCTAssertEqual(try db.search("正文保留契约").count, 2)
        XCTAssertEqual(try scalar("SELECT seq FROM sqlite_sequence WHERE name='files'"), sequence)
    }

    func testMetadataChangesKeepNameJournalAndSignatureInvalidation() throws {
        try db.upsertFiles([file()], generation: 1)
        let original = try XCTUnwrap(db.pendingFiles(rootID: root.id).first)
        XCTAssertTrue(try db.completeContent(file: original, content: ExtractedContent(text: "旧正文")))
        var changed = file()
        changed.name = "概率笔记.txt"
        var revision = try scalar("SELECT revision FROM catalog_state")
        try db.upsertFiles([changed], generation: 1)
        XCTAssertEqual(try scalar("SELECT revision FROM catalog_state"), revision + 1)
        XCTAssertEqual(try db.search("glbj").first?.id, original.id)
        XCTAssertEqual(try db.storedContent(fileID: original.id)?.text, "旧正文")
        changed.fileExtension = "PDF"
        changed.kind = .image
        revision = try scalar("SELECT revision FROM catalog_state")
        try db.upsertFiles([changed], generation: 1)
        XCTAssertEqual(try scalar("SELECT revision FROM catalog_state"), revision + 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE extension='pdf' AND kind='image'"), 1)
        for field in 0..<3 {
            let old = try XCTUnwrap(db.search("概率").first?.file)
            if field == 0 { changed.size += 1 }
            if field == 1 { changed.modified += 1 }
            if field == 2 { changed.inode += 1 }
            changed.contentState = field == 1 ? "deferred" : "done"
            changed.contentError = "待下载"
            try db.upsertFiles([changed], generation: 1)
            XCTAssertNil(try db.storedContent(fileID: original.id))
            XCTAssertFalse(try db.completeContent(file: old, content: ExtractedContent(text: "过期")))
            let current = try XCTUnwrap(db.search("概率").first?.file)
            XCTAssertEqual(current.contentState, field == 1 ? "deferred" : "pending")
            XCTAssertEqual(current.contentError, field == 1 ? "待下载" : nil)
            XCTAssertTrue(try db.completeContent(file: current, content: ExtractedContent(text: "新正文")))
        }
    }

    func testGenerationTouchSupportsFullAndIncrementalPruningAndRollback() throws {
        try db.upsertFiles([file("keep.txt"), file("gone.txt"), file("blocked/old.txt"), file("part/keep.txt"), file("part/gone.txt"), file("sibling.txt")], generation: 1)
        try db.upsertFiles([file("part/keep.txt")], generation: 2)
        try db.finishIncrementalScan(rootID: root.id, relativePath: "part", generation: 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"), 5)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE relative_path='part/gone.txt'"), 0)
        try db.upsertFiles([file("keep.txt")], generation: 3)
        XCTAssertThrowsError(try db.upsertFiles([file("keep.txt"), file("../invalid")], generation: 4))
        XCTAssertEqual(try scalar("SELECT generation FROM files WHERE relative_path='keep.txt'"), 3)
        try db.finishScan(rootID: root.id, generation: 3, preservingPaths: ["blocked"])
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"), 2)
        root.isOnline = false
        try db.saveRoot(root)
        try db.finishScan(rootID: root.id, generation: 99)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"), 2)
        root.isOnline = true
        root.enabled = false
        try db.saveRoot(root)
        try db.finishIncrementalScan(rootID: root.id, relativePath: "blocked", generation: 99)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"), 2)
    }

    func testIdenticalRootSavesDoNotWriteAndChangedPayloadPersists() throws {
        let before = changes
        for _ in 0..<5 { try db.saveRoot(root) }
        XCTAssertEqual(changes, before)
        root.name = "更新的盘"
        root.lastError = "离线原因"
        root.isOnline = false
        root.enabled = false
        try db.saveRoot(root)
        XCTAssertEqual(changes, before + 1)
        XCTAssertEqual(try db.roots(), [root])
        XCTAssertEqual(try scalar("SELECT online+enabled FROM roots"), 0)
        try db.saveRoot(root)
        XCTAssertEqual(changes, before + 1)
    }
}
