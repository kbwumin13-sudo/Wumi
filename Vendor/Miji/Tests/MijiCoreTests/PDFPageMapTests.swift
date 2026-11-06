import XCTest
import Foundation
import CoreText
import PDFKit
@testable import MijiCore

final class PDFPageMapTests: XCTestCase {
    private func slice(_ range: ContentPageRange, in content: ExtractedContent) throws -> String {
        let bytes = Array(content.text.utf8)
        XCTAssertGreaterThan(range.page, 0)
        XCTAssertGreaterThanOrEqual(range.utf8Offset, 0)
        XCTAssertLessThanOrEqual(range.utf8Offset + range.utf8Length, bytes.count)
        return try XCTUnwrap(String(bytes: bytes[range.utf8Offset..<(range.utf8Offset + range.utf8Length)], encoding: .utf8))
    }

    func testLegacyJSONHasNoPageMapAndKeepsIdenticalBody() throws {
        let json = Data(#"{"text":"数学\n\n分析","labels":[],"pages":2,"warning":null}"#.utf8)
        let decoded = try JSONDecoder().decode(ExtractedContent.self, from: json)
        XCTAssertNil(decoded.pageRanges)
        XCTAssertEqual(decoded.text, "数学\n\n分析")
        XCTAssertEqual(try JSONDecoder().decode(ExtractedContent.self, from: json), decoded)
    }

    func testPageMapRoundTripsThroughCodec() throws {
        let content = ExtractedContent(text: "数学\n\nalpha", pages: 3,
                                       pageRanges: [.init(page: 1, utf8Offset: 0, utf8Length: 6),
                                                    .init(page: 3, utf8Offset: 8, utf8Length: 5)])
        let raw = try JSONEncoder().encode(content)
        let restored = try JSONDecoder().decode(ExtractedContent.self, from: ContentCodec.unpack(ContentCodec.pack(raw)))
        XCTAssertEqual(restored, content)
        XCTAssertEqual(try slice(try XCTUnwrap(restored.pageRanges?.last), in: restored), "alpha")
    }

    func testEmptyPagesAndUnicodeExcludeSeparators() throws {
        let context = ExtractionContext(cancelled: { false })
        context.appendPage("数学😀e\u{301}", page: 1)
        context.appendPage("", page: 2)
        context.appendPage("下一页", page: 3)
        let content = context.result(pages: 3)
        let ranges = try XCTUnwrap(content.pageRanges)
        XCTAssertEqual(ranges.map(\.page), [1, 3])
        XCTAssertEqual(try ranges.map { try slice($0, in: content) }, ["数学😀e\u{301}", "下一页"])
        XCTAssertEqual(content.text, "数学😀e\u{301}\n\n下一页")
        XCTAssertEqual(ranges[1].utf8Offset, ranges[0].utf8Length + 2)
    }

    func testTruncationRecordsOnlyCompleteUTF8BodyBytes() throws {
        let context = ExtractionContext(cancelled: { false })
        context.appendPage(String(repeating: "x", count: ExtractionLimits.textBytes - 7), page: 1)
        // Two separator bytes, then 3-byte 中; 4-byte 😀 cannot fit into the last 2 bytes.
        context.appendPage("中😀尾", page: 2)
        context.appendPage("must not appear", page: 3)
        let content = context.result(pages: 3)
        let ranges = try XCTUnwrap(content.pageRanges)
        XCTAssertEqual(ranges.map(\.page), [1, 2])
        XCTAssertEqual(ranges[1].utf8Length, 3)
        XCTAssertEqual(try slice(ranges[1], in: content), "中")
        XCTAssertEqual(content.text.utf8.count, ExtractionLimits.textBytes - 2)
        XCTAssertTrue(content.warning?.contains("截断") == true)
    }

    func testSeparatorOnlyTruncationProducesNoFalsePageEntry() throws {
        let context = ExtractionContext(cancelled: { false })
        context.appendPage(String(repeating: "a", count: ExtractionLimits.textBytes - 1), page: 1)
        context.appendPage("中", page: 2)
        let content = context.result(pages: 2)
        XCTAssertEqual(content.pageRanges?.map(\.page), [1])
        XCTAssertEqual(content.text.utf8.count, ExtractionLimits.textBytes)
    }

    func testPDFExtractionPreservesOriginalPageNumbersAcrossBlankPage() throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 300)
        let drawing = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in ["First page 数学", "", "Third page 分析"] {
            drawing.beginPDFPage(nil)
            drawing.textMatrix = .identity
            drawing.textPosition = CGPoint(x: 30, y: 180)
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), drawing)
            drawing.endPDFPage()
        }
        drawing.closePDF()
        let context = ExtractionContext(cancelled: { false })
        let pages = try extractPDF(data as Data, options: ExtractionOptions(ocrPDF: false), context: context)
        let content = context.result(pages: pages)
        let ranges = try XCTUnwrap(content.pageRanges)
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(ranges.map(\.page), [1, 3])
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for range in ranges {
            XCTAssertEqual(try slice(range, in: content), document.page(at: range.page - 1)?.string)
        }
        XCTAssertTrue(content.text.contains("数学"))
        XCTAssertTrue(content.text.contains("分析"))
    }
}
