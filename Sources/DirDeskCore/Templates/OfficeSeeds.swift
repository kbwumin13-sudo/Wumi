import Foundation
import zlib

/// Minimal ZIP writer (stored entries) used to build Office template packages in memory.
public struct StoredZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    public mutating func add(_ name: String, _ contents: Data) {
        let nameData = Data(name.utf8)
        let crc = contents.withUnsafeBytes { buffer -> UInt32 in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count)))
        }
        let offset = UInt32(data.count)
        let dosTime: UInt16 = 0, dosDate: UInt16 = 0x5A21 // 2025-01-01
        var local = Data()
        local += Self.le32(0x0403_4b50) + Self.le16(20) + Self.le16(0x0800) + Self.le16(0) + Self.le16(dosTime) + Self.le16(dosDate)
        local += Self.le32(crc) + Self.le32(UInt32(contents.count)) + Self.le32(UInt32(contents.count))
        local += Self.le16(UInt16(nameData.count)) + Self.le16(0) + nameData
        data += local + contents
        var entry = Data()
        entry += Self.le32(0x0201_4b50) + Self.le16(20) + Self.le16(20) + Self.le16(0x0800) + Self.le16(0) + Self.le16(dosTime) + Self.le16(dosDate)
        entry += Self.le32(crc) + Self.le32(UInt32(contents.count)) + Self.le32(UInt32(contents.count))
        entry += Self.le16(UInt16(nameData.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le32(0) + Self.le32(offset)
        entry += nameData
        central += entry
        count += 1
    }

    public mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    public func finish() -> Data {
        var end = Data()
        end += Self.le32(0x0605_4b50) + Self.le16(0) + Self.le16(0) + Self.le16(count) + Self.le16(count)
        end += Self.le32(UInt32(central.count)) + Self.le32(UInt32(data.count)) + Self.le16(0)
        return data + central + end
    }
}

/// Empty Word, Excel and PowerPoint documents assembled from minimal OOXML parts.
public enum OfficeSeeds {
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let relsType = "application/vnd.openxmlformats-package.relationships+xml"
    static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func contentTypes(_ overrides: [(String, String)]) -> String {
        xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"\(relsType)\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined() + "</Types>"
    }

    static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        xmlHeader + "<Relationships xmlns=\"\(relNS)\">"
            + items.map { "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\($0.target)\"/>" }.joined() + "</Relationships>"
    }

    public static func seed(for kind: BuiltInFileTemplateKind) -> Data? {
        switch kind {
        case .wordDocument: word
        case .excelSpreadsheet: excel
        case .powerPointPresentation: powerPoint
        default: nil
        }
    }

    public static var word: Data {
        var zip = StoredZipWriter()
        zip.add("[Content_Types].xml", contentTypes([("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")]))
        zip.add("_rels/.rels", relationships([("rId1", officeDocument, "word/document.xml")]))
        zip.add("word/document.xml", xmlHeader + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p/><w:sectPr/></w:body></w:document>")
        return zip.finish()
    }

    public static var excel: Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        var zip = StoredZipWriter()
        zip.add("[Content_Types].xml", contentTypes([
            ("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
            ("/xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"),
        ]))
        zip.add("_rels/.rels", relationships([("rId1", officeDocument, "xl/workbook.xml")]))
        zip.add("xl/workbook.xml", xmlHeader + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(r)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", relationships([("rId1", "\(r)/worksheet", "worksheets/sheet1.xml")]))
        zip.add("xl/worksheets/sheet1.xml", xmlHeader + "<worksheet xmlns=\"\(main)\"><sheetData/></worksheet>")
        return zip.finish()
    }

    public static var powerPoint: Data {
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let tree = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "44546A"), ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"),
                      ("accent3", "A5A5A5"), ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"6350\">\(solid)</a:ln>"
        let theme = xmlHeader + "<a:theme xmlns:a=\"\(a)\" name=\"Wumi\"><a:themeElements>"
            + "<a:clrScheme name=\"Wumi\">" + colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined() + "</a:clrScheme>"
            + "<a:fontScheme name=\"Wumi\"><a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
            + "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
            + "<a:fmtScheme name=\"Wumi\"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        let clrMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        var zip = StoredZipWriter()
        zip.add("[Content_Types].xml", contentTypes([
            ("/ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"),
            ("/ppt/slides/slide1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
        ]))
        zip.add("_rels/.rels", relationships([("rId1", officeDocument, "ppt/presentation.xml")]))
        zip.add("ppt/presentation.xml", xmlHeader + "<p:presentation xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\">"
            + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
            + "<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst>"
            + "<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        zip.add("ppt/_rels/presentation.xml.rels", relationships([
            ("rId1", "\(r)/slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", "\(r)/slide", "slides/slide1.xml"),
            ("rId3", "\(r)/theme", "theme/theme1.xml"),
        ]))
        zip.add("ppt/slides/slide1.xml", xmlHeader + "<p:sld xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\">\(tree)</p:sld>")
        zip.add("ppt/slides/_rels/slide1.xml.rels", relationships([("rId1", "\(r)/slideLayout", "../slideLayouts/slideLayout1.xml")]))
        zip.add("ppt/slideMasters/slideMaster1.xml", xmlHeader + "<p:sldMaster xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\">\(tree)\(clrMap)"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>")
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships([
            ("rId1", "\(r)/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "\(r)/theme", "../theme/theme1.xml"),
        ]))
        zip.add("ppt/slideLayouts/slideLayout1.xml", xmlHeader + "<p:sldLayout xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\" type=\"blank\">\(tree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships([("rId1", "\(r)/slideMaster", "../slideMasters/slideMaster1.xml")]))
        zip.add("ppt/theme/theme1.xml", theme)
        return zip.finish()
    }
}
