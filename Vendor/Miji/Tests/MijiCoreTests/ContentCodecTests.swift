import XCTest
import Foundation
import CSQLite
import CContentIndex
@testable import MijiCore

final class ContentCodecTests: XCTestCase {
    func testRoundTripAndRawFallback() throws {
        var state: UInt64 = 42
        let random = Data((0..<8192).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let repetitive = Data(String(repeating: "中文👩🏽‍💻 e\u{301}\0\n", count: 8192).utf8)
        for raw in [Data(), Data([0]), random, repetitive] {
            let packed = try ContentCodec.pack(raw)
            XCTAssertEqual(try ContentCodec.unpack(packed), raw)
            if raw == random || raw.isEmpty { XCTAssertEqual(packed[4], 0) }
            if raw == repetitive { XCTAssertEqual(packed[4], 1); XCTAssertLessThan(packed.count, raw.count / 4) }
            var padded = Data([0xff])
            padded.append(packed)
            XCTAssertEqual(try ContentCodec.unpack(padded.dropFirst()), raw)
        }
    }

    func testDigestKnownSHA256() {
        XCTAssertEqual(ContentCodec.digest(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRejectsCorruptionAndOversizedEnvelope() throws {
        let packed = try ContentCodec.pack(Data([0, 1, 2, 3]))
        for index in packed.indices {
            var corrupt = packed
            corrupt[index] ^= 1
            XCTAssertThrowsError(try ContentCodec.unpack(corrupt), "changed byte \(index)")
        }
        for length in 0..<packed.count { XCTAssertThrowsError(try ContentCodec.unpack(packed.prefix(length))) }
        var oversized = packed
        let length = UInt64(ContentCodec.maximumRawBytes) + 1
        for byte in 0..<8 { oversized[8 + byte] = UInt8(truncatingIfNeeded: length >> (byte * 8)) }
        XCTAssertThrowsError(try ContentCodec.unpack(oversized)) { XCTAssertEqual($0 as? ContentCodecError, .resourceLimit) }
        var trailing = packed; trailing.append(0)
        XCTAssertThrowsError(try ContentCodec.unpack(trailing))

        let compressed = try ContentCodec.pack(Data(repeating: 0x61, count: 65536))
        XCTAssertEqual(compressed[4], 1)
        for length in [48, compressed.count / 2, compressed.count - 1] {
            XCTAssertThrowsError(try ContentCodec.unpack(compressed.prefix(length)))
        }
        var corrupt = compressed; corrupt[compressed.count / 2] ^= 0xff
        XCTAssertThrowsError(try ContentCodec.unpack(corrupt))
        trailing = compressed; trailing.append(0)
        XCTAssertThrowsError(try ContentCodec.unpack(trailing))
        // Recompute transport checksum to exercise the decoder's own validation.
        func reseal(_ data: Data) -> Data {
            var result = data
            result.replaceSubrange(16..<48, with: ContentCodec.digest(Data(data.dropFirst(48))))
            return result
        }
        XCTAssertThrowsError(try ContentCodec.unpack(reseal(Data(compressed.dropLast()))))
        var invalidStream = compressed
        invalidStream.replaceSubrange(48..<52, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try ContentCodec.unpack(reseal(invalidStream)))
        for adjustment in [-1, 1] {
            var wrongLength = compressed
            let length = UInt64(65536 + adjustment)
            for byte in 0..<8 { wrongLength[8 + byte] = UInt8(truncatingIfNeeded: length >> (byte * 8)) }
            XCTAssertThrowsError(try ContentCodec.unpack(wrongLength))
        }
    }

    func testSearchableTextDecodesAndNormalizesOnlyTextAndLabels() throws {
        let content = ExtractedContent(text: "CAFÉ E\u{301}\0中文", labels: ["DOG", "👩🏽‍💻"], pages: 4, warning: "Not indexed")
        XCTAssertEqual(try ContentCodec.searchableText(ContentCodec.pack(JSONEncoder().encode(content))),
                       "café é\0中文\ndog\n👩🏽‍💻")
        XCTAssertThrowsError(try ContentCodec.searchableText(ContentCodec.pack(Data("{}".utf8))))
        XCTAssertThrowsError(try ContentCodec.searchableText(ContentCodec.pack(Data([0xff]))))
    }

    func testMatchExpressionsAreSafeAndBounded() throws {
        XCTAssertNil(ContentCodec.matchExpression(""))
        XCTAssertEqual(ContentCodec.matchExpression("\0"), "\"g00\"")
        XCTAssertEqual(ContentCodec.matchExpression("中"), "\"ge4b8ad\"")
        XCTAssertEqual(ContentCodec.matchExpression("ab"), "\"g6162\"")
        let expression = try XCTUnwrap(ContentCodec.matchExpression(String(repeating: "a\" OR : * \0😀中", count: 40)))
        let tokens = expression.components(separatedBy: " AND ")
        XCTAssertLessThanOrEqual(tokens.count, 16)
        for token in tokens {
            XCTAssertNotNil(token.range(of: "^\"g[0-9a-f]+\"$", options: .regularExpression))
            XCTAssertLessThanOrEqual(token.utf8.count, 27)
        }
    }

    func testFTSScalarSubstringsNeverMissAndExactValidationRemovesFalsePositives() throws {
        let db = try database()
        defer { sqlite3_close(db) }
        let documents = [
            "中文数学分析\0章节", "a\" OR b:* - x\ny z", "👩🏽‍💻😀🧪", "e\u{301}x\u{301}结合字符",
            "abcXbcd", "abcd", String((0..<90).map { Character(UnicodeScalar(0x4e00 + $0)!) }), ""
        ].map(QueryParser.normalize)
        for (index, document) in documents.enumerated() { try insert(document, row: index + 1, db: db) }
        for (index, document) in documents.enumerated() {
            let scalars = Array(document.unicodeScalars)
            for start in scalars.indices {
                for width in 1...min(20, scalars.count - start) {
                    var view = String.UnicodeScalarView()
                    for scalar in scalars[start..<(start + width)] { view.append(scalar) }
                    let term = String(view)
                    let candidates = try matches(term, db: db)
                    XCTAssertTrue(candidates.contains(index + 1), "missing \(term.debugDescription)")
                }
            }
        }
        let candidates = try matches("abcd", db: db)
        XCTAssertEqual(candidates, [5, 6]) // abc and bcd can occur at separate positions.
        XCTAssertEqual(candidates.filter { documents[$0 - 1].contains("abcd") }, [6])
        XCTAssertTrue(try matches("不存在", db: db).isEmpty)
        XCTAssertEqual(try matches("\0", db: db), [1])
        XCTAssertEqual(try matches("数学", db: db), [1])
    }

    func testTokenizerRejectsMalformedUTF8() throws {
        let db = try database()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "INSERT INTO grams(body) VALUES (?)", -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        for bytes: [UInt8] in [[0x80], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe4, 0xb8]] {
            sqlite3_reset(statement)
            let result = bytes.withUnsafeBytes { buffer -> Int32 in
                sqlite3_bind_text(statement, 1, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try check(result, db)
            let status = sqlite3_step(statement)
            XCTAssertTrue(status == SQLITE_ERROR || status == SQLITE_MISMATCH)
        }
    }

    private func database() throws -> OpaquePointer {
        var db: OpaquePointer?
        try check(sqlite3_open(":memory:", &db), db)
        let connection = try XCTUnwrap(db)
        do {
            try check(miji_register_tokenizer(connection), connection)
            try check(sqlite3_exec(connection, "CREATE VIRTUAL TABLE grams USING fts5(body, tokenize='miji_grams', detail=none, columnsize=0, content='')", nil, nil, nil), connection)
        } catch { sqlite3_close(connection); throw error }
        return connection
    }

    private func insert(_ text: String, row: Int, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "INSERT INTO grams(rowid,body) VALUES (?,?)", -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, Int64(row)), db)
        try bind(text, to: statement, index: 2, db: db)
        try check(sqlite3_step(statement), db, expected: SQLITE_DONE)
    }

    private func matches(_ term: String, db: OpaquePointer) throws -> [Int] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT rowid FROM grams WHERE grams MATCH ? ORDER BY rowid", -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        try bind(try XCTUnwrap(ContentCodec.matchExpression(term)), to: statement, index: 1, db: db)
        var rows: [Int] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { rows.append(Int(sqlite3_column_int64(statement, 0))); status = sqlite3_step(statement) }
        try check(status, db, expected: SQLITE_DONE)
        return rows
    }

    private func bind(_ text: String, to statement: OpaquePointer?, index: Int32, db: OpaquePointer) throws {
        // Explicit byte count preserves embedded NUL in the document.
        let bytes = Array(text.utf8) + [0]
        let status = bytes.withUnsafeBytes { buffer in
            sqlite3_bind_text(statement, index, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count - 1),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        try check(status, db)
    }

    private func check(_ status: Int32, _ db: OpaquePointer?, expected: Int32 = SQLITE_OK) throws {
        guard status == expected else { throw NSError(domain: "ContentCodecTests.SQLite", code: Int(status),
                                                     userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"]) }
    }
}
