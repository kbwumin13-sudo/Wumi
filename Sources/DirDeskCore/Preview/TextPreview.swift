import Foundation

/// Decodes text files for preview: BOM sniffing, strict UTF-8, then GB18030, Big5, Shift JIS and
/// Windows-1252, rejecting a candidate when more than 1% of its characters are control characters.
public enum TextPreviewDecoder {
    public struct Decoded: Sendable {
        public var text: String
        public var encodingName: String
        public var lineCount: Int
        public var truncated: Bool
    }

    public static let defaultLimit = 512 * 1024

    public static func decode(url: URL, limit: Int = defaultLimit) -> Decoded? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let truncated = data.count > limit
        return decode(data: truncated ? data.prefix(limit) : data, truncated: truncated)
    }

    public static func decode(data: Data, truncated: Bool = false) -> Decoded? {
        let bytes = [UInt8](data.prefix(4))
        let boms: [([UInt8], String.Encoding, String)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian, "UTF-32 BE"), ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian, "UTF-32 LE"),
            ([0xEF, 0xBB, 0xBF], .utf8, "UTF-8"), ([0xFE, 0xFF], .utf16BigEndian, "UTF-16 BE"), ([0xFF, 0xFE], .utf16LittleEndian, "UTF-16 LE"),
        ]
        for (bom, encoding, name) in boms where bytes.starts(with: bom) {
            if let text = String(data: data.dropFirst(bom.count), encoding: encoding) {
                return Decoded(text: text, encodingName: name, lineCount: lineCount(text), truncated: truncated)
            }
        }
        var trimmed = data
        // A truncated read may cut a multi-byte UTF-8 sequence; drop up to three trailing bytes.
        for _ in 0..<4 {
            if let text = String(data: trimmed, encoding: .utf8) {
                return Decoded(text: text, encodingName: "UTF-8", lineCount: lineCount(text), truncated: truncated)
            }
            guard truncated, !trimmed.isEmpty else { break }
            trimmed = trimmed.dropLast()
        }
        let candidates: [(String.Encoding, String)] = [
            (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632)), "GB 18030"),
            (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0A03)), "Big5"),
            (.shiftJIS, "Shift JIS"),
            (.windowsCP1252, "Windows-1252"),
        ]
        for (encoding, name) in candidates {
            guard let text = String(data: data, encoding: encoding), !text.isEmpty else { continue }
            if controlRatio(text) <= 0.01 {
                return Decoded(text: text, encodingName: name, lineCount: lineCount(text), truncated: truncated)
            }
        }
        return nil
    }

    static func controlRatio(_ text: String) -> Double {
        var controls = 0, total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.properties.generalCategory == .control && !"\n\r\t\u{0C}".unicodeScalars.contains(scalar) { controls += 1 }
        }
        return total == 0 ? 0 : Double(controls) / Double(total)
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Markdown split into the block types the preview renders natively.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case plantUML(PlantUMLDiagram)
    case rule
}

/// Minimal PlantUML model: sequence messages or relationship edges between named participants.
public struct PlantUMLDiagram: Equatable, Sendable {
    public struct Edge: Equatable, Sendable {
        public var from: String
        public var to: String
        public var label: String
        public var dashed: Bool
    }

    public enum Kind: Equatable, Sendable { case sequence, relationship }
    public var kind: Kind
    public var participants: [String]
    public var edges: [Edge]

    public static func parse(_ source: String) -> PlantUMLDiagram {
        var participants: [String] = []
        var edges: [Edge] = []
        var relationship = false
        func add(_ name: String) { if !participants.contains(name) { participants.append(name) } }
        let arrow = try! NSRegularExpression(pattern: #"^\s*"?([^"\-<>.:]+?)"?\s*([-.]+>|<[-.]+|-+|\.+|--\|>|\*--|o--)\s*"?([^":]+?)"?\s*(?::\s*(.*))?$"#)
        for raw in source.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("@") || line.hasPrefix("'") || line.hasPrefix("skinparam") || line.hasPrefix("title") { continue }
            if let match = line.range(of: #"^(participant|actor|class|interface|entity|component|database)\s+"?([^"]+)"?"#, options: .regularExpression) {
                let words = line[match].split(separator: " ", maxSplits: 1)
                if words.count == 2 {
                    add(words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
                    if ["class", "interface", "entity", "component", "database"].contains(String(words[0])) { relationship = true }
                }
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = arrow.firstMatch(in: line, range: range),
                  let a = Range(m.range(at: 1), in: line), let op = Range(m.range(at: 2), in: line), let b = Range(m.range(at: 3), in: line) else { continue }
            let symbol = String(line[op])
            var from = line[a].trimmingCharacters(in: .whitespaces)
            var to = line[b].trimmingCharacters(in: .whitespaces)
            if symbol.hasPrefix("<") { swap(&from, &to) }
            let label = Range(m.range(at: 4), in: line).map { String(line[$0]) } ?? ""
            if !symbol.contains(">") && !symbol.contains("<") { relationship = true }
            add(from)
            add(to)
            edges.append(Edge(from: from, to: to, label: label, dashed: symbol.contains("--") || symbol.contains(".")))
        }
        return PlantUMLDiagram(kind: relationship ? .relationship : .sequence, participants: participants, edges: edges)
    }
}

public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()
                let code = body.joined(separator: "\n")
                if language.lowercased() == "plantuml" || language.lowercased() == "puml" || code.contains("@startuml") {
                    blocks.append(.plantUML(PlantUMLDiagram.parse(code)))
                } else {
                    blocks.append(.code(language: language.isEmpty ? nil : language, text: code))
                }
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if let level = trimmed.prefix(while: { $0 == "#" }).count as Int?, (1...6).contains(level), trimmed.dropFirst(level).first == " " {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
                    quote.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines = lines.dropFirst()
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }
            if trimmed.hasPrefix("|"), let separator = lines.first?.trimmingCharacters(in: .whitespaces), separator.hasPrefix("|"), separator.contains("-") {
                flush()
                lines = lines.dropFirst()
                func cells(_ row: String) -> [String] {
                    row.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
                var rows: [[String]] = []
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|") {
                    rows.append(cells(next))
                    lines = lines.dropFirst()
                }
                blocks.append(.table(header: cells(trimmed), rows: rows))
                continue
            }
            let bullet = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression)
            let number = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression)
            if bullet != nil || number != nil {
                // Lists render flat, as in the original: nested items of the same kind join the list, and a
                // (nested) run of the other kind starts a list of its own.
                flush()
                let ordered = number != nil
                var items = [String(trimmed[(bullet ?? number)!.upperBound...])]
                let pattern = ordered ? #"^\d+[.)]\s+"# : #"^[-*+]\s+"#
                while let next = lines.first {
                    let t = next.trimmingCharacters(in: .whitespaces)
                    guard let r = t.range(of: pattern, options: .regularExpression) else { break }
                    items.append(String(t[r.upperBound...]))
                    lines = lines.dropFirst()
                }
                blocks.append(ordered ? .orderedList(items) : .unorderedList(items))
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }
}
