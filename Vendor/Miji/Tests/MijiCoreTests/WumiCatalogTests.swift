import XCTest
import Foundation
@testable import MijiCore

final class WumiCatalogTests:XCTestCase {
    func testOldSchemaReopenAddsMetadataWithoutLosingContent() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("wumi-schema-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("fixture.sqlite")
        var db:SearchDatabase?=try SearchDatabase(url:url)
        let root=IndexedRoot(id:"fixture",path:dir.appendingPathComponent("absent").path,isOnline:false)
        try db!.saveRoot(root)
        var file=FileRecord(rootID:root.id,relativePath:"数学.pdf",name:"数学.pdf",fileExtension:"pdf",kind:.document,size:1,modified:1)
        try db!.upsertFiles([file],generation:1)
        file=try XCTUnwrap(db!.pendingFiles(rootID:root.id).first)
        let content=ExtractedContent(text:"旧schema正文和OCR",labels:["train"],pages:7)
        XCTAssertTrue(try db!.completeContent(file:file,content:content))
        try db!.execute("DROP TABLE wumi_file_metadata")
        db=nil
        let reader=try SearchDatabase(url:url,readOnly:true)
        XCTAssertNil(try reader.catalogBatch().first?.file.created)
        db=try SearchDatabase(url:url)
        XCTAssertEqual(try db!.storedContent(fileID:file.id),content)
        XCTAssertEqual(try db!.roots(),[root])
        XCTAssertEqual(try db!.search("OCR",options:SearchOptions(scope:.content)).map(\.id),[file.id])
        file.created=77;file.isDirectory=false;file.isPackage=false
        try db!.upsertFiles([file],generation:2)
        XCTAssertEqual(try db!.catalogBatch().first?.file.created,77)
        XCTAssertEqual(try db!.storedContent(fileID:file.id),content)
        file.created=nil;file.isDirectory=nil;file.isPackage=nil
        try db!.upsertFiles([file],generation:3)
        XCTAssertEqual(try db!.catalogBatch().first?.file.created,77)
    }
    func testBackupIncludesWALAndCancellationCleansOnlyNewTarget() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("wumi-backup-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:dir)}
        let source=dir.appendingPathComponent("source.sqlite")
        let db=try SearchDatabase(url:source)
        try db.saveRoot(IndexedRoot(id:"fixture",path:"/fixture-offline",isOnline:false))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path+"-wal"))
        let target=dir.appendingPathComponent("target.sqlite")
        try SearchDatabase.backup(from:source,to:target)
        let reader=try SearchDatabase(url:target,readOnly:true)
        XCTAssertEqual(try reader.roots(),try db.roots())
        let cancelled=dir.appendingPathComponent("cancelled.sqlite")
        XCTAssertThrowsError(try SearchDatabase.backup(from:source,to:cancelled,cancelled:{true})) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:cancelled.path))
        XCTAssertEqual(try db.roots().count,1)
    }
}
