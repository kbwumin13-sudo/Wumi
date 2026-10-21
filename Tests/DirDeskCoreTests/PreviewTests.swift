import XCTest
@testable import DirDeskCore

final class PreviewTests: XCTestCase {
    func testTextDecodingOrder() throws {
        XCTAssertEqual(TextPreviewDecoder.decode(data: Data("hello".utf8))?.encodingName, "UTF-8")
        let gb = try XCTUnwrap("中文 GB18030 编码文本".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))))
        let decoded = try XCTUnwrap(TextPreviewDecoder.decode(data: gb))
        XCTAssertEqual(decoded.encodingName, "GB 18030")
        XCTAssertEqual(decoded.text, "中文 GB18030 编码文本")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("abc".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(TextPreviewDecoder.decode(data: utf16)?.encodingName, "UTF-16 LE")
        XCTAssertEqual(TextPreviewDecoder.decode(data: Data("a\nb\nc".utf8))?.lineCount, 3)
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        # Title

        Text **bold**.

        - one
        - two

        > quoted

        | A | B |
        | --- | ---: |
        | 1 | 2 |

        ```swift
        print(1)
        ```

        ```plantuml
        @startuml
        Alice -> Bob: Request
        Bob --> Alice: Response
        @enduml
        ```

        ---
        """)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Title"))
        XCTAssertTrue(blocks.contains(.unorderedList(["one", "two"])))
        XCTAssertTrue(blocks.contains(.quote("quoted")))
        XCTAssertTrue(blocks.contains(.table(header: ["A", "B"], rows: [["1", "2"]])))
        XCTAssertTrue(blocks.contains(.code(language: "swift", text: "print(1)")))
        XCTAssertEqual(blocks.last, .rule)
        guard case .plantUML(let diagram)? = blocks.first(where: { if case .plantUML = $0 { true } else { false } }) else {
            return XCTFail("missing PlantUML block")
        }
        XCTAssertEqual(diagram.kind, .sequence)
        XCTAssertEqual(diagram.participants, ["Alice", "Bob"])
        XCTAssertEqual(diagram.edges.count, 2)
        XCTAssertEqual(diagram.edges[1].dashed, true)
        XCTAssertEqual(diagram.edges[0].label, "Request")
    }

    /// A nested numbered list under a bullet list becomes a list of its own, both flat.
    func testNestedListOfTheOtherKindStartsItsOwnList() {
        let blocks = MarkdownBlockParser.parse("""
        - first
        - second
          1. sub one
          2. sub two
        """)
        XCTAssertEqual(blocks, [.unorderedList(["first", "second"]), .orderedList(["sub one", "sub two"])])
    }
}
