import Foundation
import XCTest
@testable import MijiCore

/// No scanner, watcher, real volume or OCR input is involved in these fixtures.
final class VendoredFixtureTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var db: SearchDatabase!
    private var root: IndexedRoot!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wumi-miji-fixture-\(UUID().uuidString)")
        databaseURL = directory.appendingPathComponent("fixture.sqlite")
        db = try SearchDatabase(url: databaseURL)
        root = IndexedRoot(id: "fixture-volume", path: directory.appendingPathComponent("absent-volume").path,
                           name: "夹具离线盘", volumeUUID: "fixture-volume-uuid", isExternal: true)
        try db.saveRoot(root)
    }

    override func tearDownWithError() throws {
        db = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func insert(_ name: String, kind: FileKind, content: ExtractedContent) throws -> FileRecord {
        let file = FileRecord(rootID: root.id, relativePath: "资料/" + name, name: name,
                              fileExtension: URL(fileURLWithPath: name).pathExtension,
                              kind: kind, size: 1234, modified: 42)
        try db.upsertFiles([file], generation: 1)
        let pending = try XCTUnwrap(db.pendingFiles(rootID: root.id).first { $0.name == name })
        XCTAssertTrue(try db.completeContent(file: pending, content: content))
        return pending
    }

    func testStoredFullTextAndOCRSurviveReadOnlyReopenAndOfflineTransitions() throws {
        let body = ExtractedContent(text: "连续函数在闭区间有界。fixture全文复习", pages: 3)
        let ocr = ExtractedContent(text: "上海虹桥站 OCR固定夹具", labels: ["火车", "train"], pages: 1,
                                   warning: "固定OCR提取结果，未执行真实识别")
        let document = try insert("数学分析.pdf", kind: .document, content: body)
        let image = try insert("旅行截图.png", kind: .image, content: ocr)
        let engine = try NameSearchEngine(databaseURL: databaseURL)
        try engine.load()
        for query in ["数学", "shuxuefenxi", "sxfx"] {
            XCTAssertEqual(try engine.search(query, options: SearchOptions(scope: .name)), [document.id])
        }
        db = nil
        db = try SearchDatabase(url: databaseURL)
        root.isOnline = false
        try db.saveRoot(root)
        let reader = try SearchDatabase(url: databaseURL, readOnly: true)
        XCTAssertEqual(try reader.storedContent(fileID: document.id), body)
        XCTAssertEqual(try reader.storedContent(fileID: image.id), ocr)
        for (query, id) in [("闭区间", document.id), ("虹桥", image.id), ("train", image.id)] {
            let hits = try reader.search(query, options: SearchOptions(scope: .content))
            XCTAssertEqual(hits.map(\.id), [id])
            XCTAssertEqual(hits.first?.root.isOnline, false)
            XCTAssertTrue(try reader.search(query, options: SearchOptions(scope: .content, onlineOnly: true)).isEmpty)
        }
        XCTAssertEqual(try engine.search("sxfx"), [document.id])
        XCTAssertTrue(try engine.search("sxfx", options: SearchOptions(onlineOnly: true)).isEmpty)
        let nameHit = try XCTUnwrap(reader.nameHits(ids: [document.id], query: "sxfx").first)
        XCTAssertFalse(nameHit.root.isOnline)
        XCTAssertEqual(nameHit.path, root.path + "/资料/数学分析.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        root.isOnline = true
        try db.saveRoot(root)
        XCTAssertEqual(try engine.search("sxfx", options: SearchOptions(onlineOnly: true)), [document.id])
        XCTAssertEqual(try reader.search("虹桥", options: SearchOptions(scope: .content, onlineOnly: true)).map(\.id), [image.id])
        XCTAssertEqual(try reader.statistics().indexedContent, 2)
    }
}
