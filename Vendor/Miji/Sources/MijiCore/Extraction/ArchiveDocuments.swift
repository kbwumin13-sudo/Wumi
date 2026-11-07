import Foundation

struct ArchiveEntry {
    let name: String
    let size: Int
}

/// Read the central directory ourselves before invoking unzip. Listing with `unzip -l`
/// would not reliably describe hostile filenames or enforce the expansion budget.
final class BoundedArchive {
    let url: URL
    let entries: [ArchiveEntry]
    private let context: ExtractionContext
    private var outputBytes = 0

    init(url: URL, context: ExtractionContext) throws {
        self.url = url; self.context = context
        let data = try boundedFileData(url, limit: ExtractionLimits.inputBytes, context: context)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw ContentExtractionError.invalidDocument("ZIP 目录缺失") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(offset) == 0x06054b50 && offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end else { throw ContentExtractionError.invalidDocument("ZIP 目录损坏") }
        let count = u16(end + 10), directoryBytes = u32(end + 12), start = u32(end + 16)
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == count,
              count != 0xffff, start != 0xffffffff, directoryBytes != 0xffffffff else {
            throw ContentExtractionError.invalidDocument("不支持分卷或 ZIP64 文档")
        }
        guard count <= ExtractionLimits.archiveEntries else { throw ContentExtractionError.resourceLimit("ZIP 条目超过 10000") }
        guard start <= end, directoryBytes <= end - start else { throw ContentExtractionError.invalidDocument("ZIP 目录越界") }
        let directoryEnd = start + directoryBytes
        var position = start, expanded = 0, names = Set<String>(), found: [ArchiveEntry] = []
        for _ in 0..<count {
            try context.check()
            guard position + 46 <= directoryEnd, u32(position) == 0x02014b50 else {
                throw ContentExtractionError.invalidDocument("ZIP 条目目录损坏")
            }
            let flags = u16(position + 8), method = u16(position + 10)
            let size = u32(position + 24), nameBytes = u16(position + 28)
            let extraBytes = u16(position + 30), commentBytes = u16(position + 32)
            let next = position + 46 + nameBytes + extraBytes + commentBytes
            guard next <= directoryEnd, u16(position + 34) == 0 else { throw ContentExtractionError.invalidDocument("ZIP 条目越界") }
            guard flags & 1 == 0 else { throw ContentExtractionError.invalidDocument("文档 ZIP 已加密") }
            guard method == 0 || method == 8 else { throw ContentExtractionError.invalidDocument("ZIP 压缩方式不受支持") }
            guard size <= ExtractionLimits.memberBytes, expanded <= ExtractionLimits.expandedBytes - size else {
                throw ContentExtractionError.resourceLimit("ZIP 单条目超过 32 MiB 或累计解压体积超过 128 MiB")
            }
            let bytes = data.subdata(in: (position + 46)..<(position + 46 + nameBytes))
            guard let name = String(data: bytes, encoding: .utf8), !name.isEmpty,
                  !name.contains("\0"), !name.contains("\\"), !name.hasPrefix("/"), !name.hasPrefix("-"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  names.insert(name).inserted else { throw ContentExtractionError.invalidDocument("ZIP 路径无效、重复或不是 UTF-8") }
            expanded += size; found.append(ArchiveEntry(name: name, size: size)); position = next
        }
        entries = found
    }

    func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }

    func read(_ name: String) throws -> Data {
        try context.check()
        guard let entry = entries.first(where: { $0.name == name }) else { throw ContentExtractionError.invalidDocument("ZIP 缺少 \(name)") }
        guard outputBytes <= ExtractionLimits.expandedBytes - entry.size else {
            throw ContentExtractionError.resourceLimit("累计读取的解压内容超过 128 MiB")
        }
        // Info-ZIP treats member arguments as glob patterns, even without a shell.
        let pattern = name.map { char -> String in
            switch char { case "*": return "[*]"; case "?": return "[?]"; case "[": return "[[]"; default: return String(char) }
        }.joined()
        let output = try runExtractionProcess("/usr/bin/unzip", arguments: ["-p", url.path, pattern], limit: entry.size, context: context)
        guard output.data.count == entry.size else { throw ContentExtractionError.invalidDocument("ZIP 解压尺寸与目录不符") }
        outputBytes += output.data.count
        return output.data
    }
}

final class DocumentXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [DocumentXMLNode] = []
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [DocumentXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    func first(_ name: String) -> DocumentXMLNode? { children.first { $0.name == name } }
    var allText: String { text + children.map(\.allText).joined() }
}

private final class DocumentXMLDelegate: NSObject, XMLParserDelegate {
    let context: ExtractionContext
    var root: DocumentXMLNode?
    var stack: [DocumentXMLNode] = []
    var failure: Error?
    var nodes = 0
    init(context: ExtractionContext) { self.context = context }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        do { try context.check() } catch { failure = error; parser.abortParsing(); return }
        nodes += 1
        guard stack.count < 128, nodes <= 250_000 else {
            failure = ContentExtractionError.resourceLimit("XML 深度或节点数量过大"); parser.abortParsing(); return
        }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = DocumentXMLNode(name: name, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        do { try context.check() } catch { failure = error; parser.abortParsing(); return }
        stack.last?.text.append(string)
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { stack.last?.text.append(text) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = ContentExtractionError.invalidDocument("XML 自定义实体不受支持"); parser.abortParsing()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

func parseDocumentXML(_ data: Data, context: ExtractionContext) throws -> DocumentXMLNode {
    try context.check()
    let delegate = DocumentXMLDelegate(context: context)
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    let parsed = parser.parse()
    if let failure = delegate.failure { throw failure }
    guard parsed, let root = delegate.root else { throw ContentExtractionError.invalidDocument("XML 格式错误：\(parser.parserError?.localizedDescription ?? "根节点缺失")") }
    return root
}

private func officeParagraph(_ node: DocumentXMLNode) -> String {
    switch node.name {
    case "t": return node.allText
    case "tab": return "\t"
    case "br", "cr": return "\n"
    case "del", "delText": return "" // Deleted revision text should not become current content.
    default: return node.children.map(officeParagraph).joined()
    }
}

private func wordBlocks(_ node: DocumentXMLNode) -> String {
    switch node.name {
    case "p": return officeParagraph(node) + "\n"
    case "tc": return node.children.map(wordBlocks).joined().trimmingCharacters(in: .newlines) + "\t"
    case "tr": return node.children.map(wordBlocks).joined().trimmingCharacters(in: CharacterSet(charactersIn: "\t")) + "\n"
    default: return node.children.map(wordBlocks).joined()
    }
}

private struct OfficeRelationship {
    let target: String
    let type: String
}

/// URI paths inside a ZIP are independent of the host filesystem. NSString's
/// standardizingPath can leave `..` in relative, nonexistent filesystem paths.
private func resolveArchivePath(base: String, reference: String) -> String? {
    let fragmentless = String(reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    let decoded = fragmentless.removingPercentEncoding ?? fragmentless
    guard !decoded.isEmpty, !decoded.contains(":"), !decoded.contains("\\"), !decoded.contains("\0") else { return nil }
    var components = decoded.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
    for part in decoded.split(separator: "/") {
        if part == "." { continue }
        if part == ".." {
            guard !components.isEmpty else { return nil }
            components.removeLast()
        } else { components.append(String(part)) }
    }
    return components.isEmpty ? nil : components.joined(separator: "/")
}

private func officeRelationships(_ archive: BoundedArchive, part: String, context: ExtractionContext) throws -> [String: OfficeRelationship] {
    let directory = (part as NSString).deletingLastPathComponent
    let filename = (part as NSString).lastPathComponent
    let relationPath = (directory.isEmpty ? "" : directory + "/") + "_rels/" + filename + ".rels"
    guard archive.contains(relationPath) else { return [:] }
    let root = try parseDocumentXML(archive.read(relationPath), context: context)
    var relationships: [String: OfficeRelationship] = [:]
    for relation in root.descendants("Relationship") {
        guard relation.attributes["TargetMode"] != "External", let id = relation.attributes["Id"],
              let target = relation.attributes["Target"], let type = relation.attributes["Type"] else { continue }
        guard let resolved = resolveArchivePath(base: directory, reference: target) else { continue }
        relationships[id] = OfficeRelationship(target: resolved, type: type)
    }
    return relationships
}

private func orderedOfficeParts(_ archive: BoundedArchive, main: String, reference: String, type: String,
                                fallbackPattern: String, context: ExtractionContext) throws -> [ArchiveEntry] {
    if archive.contains(main) {
        let root = try parseDocumentXML(archive.read(main), context: context)
        let references = root.descendants(reference)
        if !references.isEmpty {
            let relationships = try officeRelationships(archive, part: main, context: context)
            return references.compactMap { node in
                let referenceID = node.attributes["r:id"] ?? node.attributes.first(where: { $0.key.hasSuffix(":id") })?.value
                guard let id = referenceID, let relation = relationships[id], relation.type.hasSuffix("/" + type),
                      let entry = archive.entries.first(where: { $0.name == relation.target }) else {
                    context.warn("Office 阅读顺序的部分文档关系缺失，相关内容未提取"); return nil
                }
                return entry
            }
        }
    }
    return archive.entries.filter { $0.name.range(of: fallbackPattern, options: .regularExpression) != nil }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func extractOffice(_ archive: BoundedArchive, ext: String, context: ExtractionContext) throws -> Int {
    if ext == "docx" {
        let root = try parseDocumentXML(archive.read("word/document.xml"), context: context)
        context.append(wordBlocks(root))
        for entry in archive.entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if context.isFull { break }
            if entry.name.hasPrefix("word/"), entry.name.hasSuffix(".xml"),
               ["header", "footer", "footnotes", "endnotes"].contains(where: { entry.name.dropFirst(5).hasPrefix($0) }) {
                context.append(wordBlocks(try parseDocumentXML(archive.read(entry.name), context: context)))
            }
        }
        return 0
    }
    if ext == "pptx" {
        let slides = try orderedOfficeParts(archive, main: "ppt/presentation.xml", reference: "sldId", type: "slide",
                                           fallbackPattern: #"^ppt/slides/slide[0-9]+\.xml$"#, context: context)
        guard !slides.isEmpty else { throw ContentExtractionError.invalidDocument("PPTX 没有幻灯片") }
        for slide in slides {
            try context.check()
            if context.isFull { break }
            let root = try parseDocumentXML(archive.read(slide.name), context: context)
            context.append(root.descendants("p").map(officeParagraph).joined(separator: "\n"), separator: "\n\n")
            let relations = try officeRelationships(archive, part: slide.name, context: context)
            let relatedNote = relations.values.first { $0.type.hasSuffix("/notesSlide") }?.target
            let conventional = slide.name.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil
                ? slide.name.replacingOccurrences(of: "slides/slide", with: "notesSlides/notesSlide") : nil
            let note = relatedNote ?? conventional
            if let note, archive.contains(note) {
                let noteRoot = try parseDocumentXML(archive.read(note), context: context)
                context.append(noteRoot.descendants("p").map(officeParagraph).joined(separator: "\n"))
            } else if relatedNote != nil {
                context.warn("PPTX 备注关系指向缺失文件，部分备注未提取")
            }
        }
        return slides.count
    }
    // Excel rich shared strings, inline strings, cached formula values, and sparse cells.
    var shared: [String] = []
    if archive.contains("xl/sharedStrings.xml") {
        let root = try parseDocumentXML(archive.read("xl/sharedStrings.xml"), context: context)
        shared = root.descendants("si").map { $0.descendants("t").map(\.allText).joined() }
    }
    let sheets = try orderedOfficeParts(archive, main: "xl/workbook.xml", reference: "sheet", type: "worksheet",
                                       fallbackPattern: #"^xl/worksheets/sheet[0-9]+\.xml$"#, context: context)
    guard !sheets.isEmpty else { throw ContentExtractionError.invalidDocument("XLSX 没有工作表") }
    for sheet in sheets {
        try context.check()
        if context.isFull { break }
        let root = try parseDocumentXML(archive.read(sheet.name), context: context)
        var firstRow = true
        for row in root.descendants("row") {
            try context.check()
            if context.isFull { break }
            var cells: [String] = [], previousColumn = 0
            for cell in row.children where cell.name == "c" {
                let reference = cell.attributes["r"] ?? ""
                let letters = reference.prefix(while: { $0.isASCII && $0.isLetter })
                guard letters.count <= 3, letters.allSatisfy({ $0 >= "A" && $0 <= "Z" }) else {
                    throw ContentExtractionError.invalidDocument("Excel 列坐标无效")
                }
                let column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
                guard column <= 16_384, column == 0 || column > previousColumn else { throw ContentExtractionError.invalidDocument("Excel 列坐标无效或顺序错误") }
                if column > previousColumn + 1 { cells.append(contentsOf: repeatElement("", count: column - previousColumn - 1)) }
                let value = cell.first("v")?.allText ?? ""
                switch cell.attributes["t"] {
                case "s":
                    if let index = Int(value), shared.indices.contains(index) { cells.append(shared[index]) }
                    else { cells.append(""); context.warn("Excel 共享字符串引用无效，部分单元格未提取") }
                case "inlineStr": cells.append(cell.descendants("t").map(\.allText).joined())
                case "b": cells.append(value == "1" ? "TRUE" : "FALSE")
                default:
                    cells.append(value)
                    if value.isEmpty && cell.first("f") != nil { context.warn("Excel 公式缺少缓存值，未计算公式") }
                }
                previousColumn = column > 0 ? column : previousColumn + 1
            }
            context.append(cells.joined(separator: "\t"), separator: firstRow ? "\n\n" : "\n")
            firstRow = false
        }
    }
    return sheets.count
}

func extractEPUB(_ archive: BoundedArchive, context: ExtractionContext) throws -> Int {
    let container = try parseDocumentXML(archive.read("META-INF/container.xml"), context: context)
    guard let path = container.descendants("rootfile").first?.attributes["full-path"] else {
        throw ContentExtractionError.invalidDocument("EPUB 缺少书籍目录")
    }
    let package = try parseDocumentXML(archive.read(path), context: context)
    let base = (path as NSString).deletingLastPathComponent
    let items = Dictionary(package.descendants("item").compactMap { item -> (String, String)? in
        guard let id = item.attributes["id"], let href = item.attributes["href"] else { return nil }
        return (id, href)
    }, uniquingKeysWith: { first, _ in first })
    var pages = 0
    for reference in package.descendants("itemref") {
        try context.check()
        if context.isFull { break }
        guard let id = reference.attributes["idref"], let href = items[id] else { context.warn("EPUB 阅读顺序引用缺失，部分章节未提取"); continue }
        guard let resolved = resolveArchivePath(base: base, reference: href) else { context.warn("EPUB 外部资源或无效路径未读取"); continue }
        guard archive.contains(resolved) else { context.warn("EPUB 章节缺失：\(resolved)"); continue }
        let html = try decodeDocumentText(archive.read(resolved), context: context)
        context.append(HTMLTextExtractor.text(html), separator: "\n\n"); pages += 1
    }
    return pages
}
