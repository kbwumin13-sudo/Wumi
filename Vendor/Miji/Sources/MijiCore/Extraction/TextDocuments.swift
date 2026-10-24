import Foundation
import CoreFoundation

struct ImportedDocumentText {
    let text: String
    let pages: Int
}

enum SystemDocumentImporter {
    /// `-t` imports the current local file without updating Spotlight. A unique output
    /// directory prevents an old result from ever being mistaken for this invocation.
    static func extract(_ url: URL, context: ExtractionContext) throws -> ImportedDocumentText {
        try context.check()
        _ = try localFileSize(url, allowDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MijiImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputFile = temporary.appendingPathComponent("attributes.plist")
        let output = try runExtractionProcess("/usr/bin/mdimport", arguments: ["-t", "-o", outputFile.path, url.path],
                                             limit: 256 * 1024, context: context, timeout: 30,
                                             outputFile: outputFile, outputFileLimit: ExtractionLimits.inputBytes)
        let diagnostics = (String(data: output.data, encoding: .utf8) ?? "") + output.diagnostics
        if !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.warn("系统即时导入诊断：\(diagnostics.prefix(1000))")
        }
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw ContentExtractionError.invalidDocument("系统即时导入未生成属性 plist")
        }
        let data = try boundedFileData(outputFile, limit: ExtractionLimits.inputBytes, context: context)
        return try parse(data, context: context)
    }

    static func parse(_ data: Data, context: ExtractionContext) throws -> ImportedDocumentText {
        try context.check()
        guard data.count <= ExtractionLimits.inputBytes else { throw ContentExtractionError.resourceLimit("系统导入 plist 输出超过 64 MiB") }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw ContentExtractionError.invalidDocument("系统即时导入属性 plist 无法解析") }
        guard let attributes = object as? [String: Any] else {
            throw ContentExtractionError.invalidDocument("系统即时导入属性不是字典")
        }
        let rawText = attributes["kMDItemTextContent"]
        if rawText != nil && !(rawText is String) && !(rawText is NSNull) {
            throw ContentExtractionError.invalidDocument("系统即时导入正文属性不是字符串")
        }
        let text = rawText as? String ?? ""
        let validText = ["<null>", "(null)"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) ? "" : text
        let rawPages = (attributes["kMDItemNumberOfPages"] as? NSNumber)?.intValue
            ?? (attributes["kMDItemNumberOfPages"] as? String).flatMap(Int.init) ?? 0
        try context.check()
        return ImportedDocumentText(text: validText, pages: max(0, rawPages))
    }
}

func decodeDocumentText(_ data: Data, context: ExtractionContext, truncated: Bool = false) throws -> String {
    if data.isEmpty { return "" }
    let bytes = [UInt8](data.prefix(4))
    let encoding: String.Encoding?
    let bom: Int
    if bytes.starts(with: [0xff, 0xfe, 0, 0]) { encoding = .utf32LittleEndian; bom = 4 }
    else if bytes.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32BigEndian; bom = 4 }
    else if bytes.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian; bom = 2 }
    else if bytes.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian; bom = 2 }
    else if bytes.starts(with: [0xef, 0xbb, 0xbf]) { encoding = .utf8; bom = 3 }
    else { encoding = nil; bom = 0 }
    let payload = data.dropFirst(bom)
    if let encoding {
        if let value = String(data: payload, encoding: encoding) { return value }
        if truncated {
            for removed in 1...4 where payload.count >= removed {
                if let value = String(data: payload.dropLast(removed), encoding: encoding) { return value }
            }
        }
        throw ContentExtractionError.invalidDocument("文字编码与 BOM 不符")
    }
    // BOM-less UTF-16 is common in exports. A NUL pattern distinguishes it from GB18030.
    if payload.count >= 4 && payload.contains(0) {
        let sample = Array(payload.prefix(1024))
        let evenZeros = sample.enumerated().filter { $0.offset % 2 == 0 && $0.element == 0 }.count
        let oddZeros = sample.enumerated().filter { $0.offset % 2 == 1 && $0.element == 0 }.count
        let candidates: [String.Encoding] = evenZeros > oddZeros ? [.utf16BigEndian, .utf16LittleEndian] : [.utf16LittleEndian, .utf16BigEndian]
        let aligned = truncated && payload.count % 2 != 0 ? payload.dropLast() : payload
        for candidate in candidates {
            if let value = String(data: aligned, encoding: candidate), !value.contains("\0") {
                context.warn("文字编码按无 BOM UTF-16 推断"); return value
            }
        }
        throw ContentExtractionError.invalidDocument("文件包含二进制 NUL，不能作为纯文字读取")
    }
    if let value = String(data: payload, encoding: .utf8) { return value }
    if truncated {
        for removed in 1...3 where payload.count >= removed {
            if let value = String(data: payload.dropLast(removed), encoding: .utf8) { return value }
        }
    }
    for cfEncoding in [CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue),
                       CFStringEncoding(CFStringEncodings.big5.rawValue),
                       CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)] {
        let candidate = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        if let value = String(data: payload, encoding: candidate) {
            context.warn("文字使用推断的传统编码，建议保存为 UTF-8"); return value
        }
    }
    if let value = String(data: payload, encoding: .windowsCP1252) {
        context.warn("文字编码按 Windows-1252 推断"); return value
    }
    throw ContentExtractionError.invalidDocument("无法识别文字编码")
}

enum HTMLTextExtractor {
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "copy": "©", "reg": "®", "trade": "™", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "times": "×", "divide": "÷", "le": "≤", "ge": "≥", "euro": "€", "yen": "¥",
        "pound": "£", "cent": "¢", "laquo": "«", "raquo": "»", "ensp": " ", "emsp": " ",
        "eacute": "é", "Eacute": "É", "agrave": "à", "uuml": "ü", "ouml": "ö", "auml": "ä"
    ]
    private static let blocks: Set<String> = ["p", "div", "section", "article", "header", "footer", "br", "hr", "li", "ul", "ol", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table"]

    /// A linear lexer avoids WebKit/main-thread requirements and never loads remote HTML resources.
    static func text(_ html: String) -> String {
        var result = "", index = html.startIndex, hidden: String?
        while index < html.endIndex {
            let char = html[index]
            if char == "<" {
                if html[index...].hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: index..<html.endIndex) { index = end.upperBound; continue }
                    break
                }
                var end = html.index(after: index), quote: Character?
                while end < html.endIndex {
                    let current = html[end]
                    if let q = quote { if current == q { quote = nil } }
                    else if current == "\"" || current == "'" { quote = current }
                    else if current == ">" { break }
                    end = html.index(after: end)
                }
                if end == html.endIndex { if hidden == nil { result.append(contentsOf: html[index...]) }; break }
                let inside = html[html.index(after: index)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                let closing = inside.hasPrefix("/")
                let tag = inside.drop(while: { $0 == "/" || $0.isWhitespace }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
                if let hiddenTag = hidden {
                    if closing && tag == hiddenTag { hidden = nil }
                } else if ["script", "style", "head"].contains(tag) && !closing {
                    hidden = tag
                } else if blocks.contains(tag) {
                    if !result.hasSuffix("\n") { result.append("\n") }
                } else if tag == "td" || tag == "th" {
                    if closing { result.append("\t") }
                }
                index = html.index(after: end); continue
            }
            if hidden != nil { index = html.index(after: index); continue }
            if char == "&" {
                let start = html.index(after: index)
                var end = start, length = 0
                while end < html.endIndex && html[end] != ";" && length < 32 && !html[end].isWhitespace {
                    end = html.index(after: end); length += 1
                }
                if end < html.endIndex && html[end] == ";" {
                    let name = String(html[start..<end])
                    var value = entities[name]
                    if name.hasPrefix("#") {
                        let hex = name.lowercased().hasPrefix("#x")
                        if let number = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                           let scalar = UnicodeScalar(number), number != 0 { value = String(scalar) }
                    }
                    if let value { result.append(value); index = html.index(after: end); continue }
                }
            }
            result.append(char); index = html.index(after: index)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
