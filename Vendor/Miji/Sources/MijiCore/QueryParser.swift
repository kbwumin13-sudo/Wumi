import Foundation

/// A deliberately small query language. Every value is a literal substring;
/// quotes group a phrase and never expose SQLite's MATCH grammar.
public enum QueryField: String, Sendable {
    case text, ext, kind, path
}

public struct QueryTerm: Equatable, Sendable {
    public let field: QueryField
    public let value: String
    public let isExcluded: Bool
}

public struct ParsedQuery: Sendable {
    public let terms: [QueryTerm]
}

public enum QueryParser {
    public static func parse(_ query: String) -> ParsedQuery {
        let chars = Array(query)
        var index = 0
        var terms: [QueryTerm] = []
        while index < chars.count {
            while index < chars.count && chars[index].isWhitespace { index += 1 }
            guard index < chars.count else { break }
            var excluded = false
            if chars[index] == "-", index + 1 < chars.count, !chars[index + 1].isWhitespace {
                excluded = true
                index += 1
            }
            var token = ""
            var quoted = false
            // Only an unquoted, known prefix is an operator. "ext:pdf" is text.
            var field: QueryField = .text
            var prefixResolved = false
            while index < chars.count {
                let char = chars[index]
                if char == "\\", index + 1 < chars.count,
                   chars[index + 1] == "\"" || chars[index + 1] == "\\" {
                    token.append(chars[index + 1])
                    index += 2
                    continue
                }
                if char == "\"" {
                    quoted.toggle()
                    prefixResolved = true
                    index += 1
                    continue
                }
                if !quoted && char.isWhitespace { break }
                if !quoted && !prefixResolved && char == ":" {
                    if let recognized = QueryField(rawValue: token.lowercased()), recognized != .text {
                        field = recognized
                        token = ""
                    } else { token.append(char) }
                    prefixResolved = true
                } else { token.append(char) }
                index += 1
            }
            if !token.isEmpty {
                var value = normalize(token)
                if field == .ext && value.hasPrefix(".") { value.removeFirst() }
                if !value.isEmpty { terms.append(QueryTerm(field: field, value: value, isExcluded: excluded)) }
            }
        }
        return ParsedQuery(terms: terms)
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    static func kindValue(_ value: String) -> String {
        let aliases: [String: FileKind] = [
            "文档": .document, "文件夹": .folder, "目录": .folder,
            "图片": .image, "图像": .image, "音频": .audio,
            "视频": .video, "压缩包": .archive, "应用": .application, "代码": .code, "其他": .other
        ]
        return aliases[value]?.rawValue ?? value
    }

    /// FTS5 trigram counts Unicode scalars. Control characters (including NUL)
    /// use the exact-substring fallback instead of SQLite's query parser.
    static func trigramLiteral(_ value: String) -> String? {
        guard value.unicodeScalars.count >= 3,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
