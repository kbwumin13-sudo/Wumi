import Foundation

/// Parses Lightning Search expressions.
///
/// - Whitespace or `AND` combine conditions; `OR` or `|` match either; `NOT` or a leading `!` excludes.
///   Parentheses group. Priority: NOT, then OR, then AND (`a b|c` is `a AND (b OR c)`).
/// - English double quotes protect spaces and operators; wildcards stay active inside quotes.
/// - `name:value` filters take their value immediately after the colon; semicolons list alternatives.
/// - `case:` makes the following item (or, standing alone, the whole query) case-sensitive; `nocase:` the opposite.
///
/// The parser is lenient while the user is typing: dangling operators are ignored, an unterminated quote
/// runs to the end and a missing closing parenthesis is implied. Unknown filters and invalid values throw.
public enum LightningQueryParser {
    public static func parse(_ text: String) throws -> LightningQuery {
        var parser = Parser(tokens: tokenize(Array(text)))
        let root = try parser.parseSequence() ?? .everything
        if let global = parser.globalCase { return .matchCase(global, root) }
        return root
    }

    // MARK: Tokens

    fileprivate struct Token {
        enum Kind { case word, and, or, not, open, close }
        var kind: Kind
        var raw: String
        var start: Int
        var end: Int
    }

    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            switch character {
            case "(":
                tokens.append(Token(kind: .open, raw: "(", start: index, end: index + 1))
                depth += 1
                index += 1
                continue
            case ")" where depth > 0:
                tokens.append(Token(kind: .close, raw: ")", start: index, end: index + 1))
                depth -= 1
                index += 1
                continue
            case "|":
                tokens.append(Token(kind: .or, raw: "|", start: index, end: index + 1))
                index += 1
                continue
            case "!":
                tokens.append(Token(kind: .not, raw: "!", start: index, end: index + 1))
                index += 1
                continue
            default:
                break
            }
            let start = index
            var raw = ""
            var inQuote = false
            var localDepth = 0
            while index < characters.count {
                let next = characters[index]
                if inQuote {
                    if next == "\"" { inQuote = false }
                    raw.append(next)
                    index += 1
                    continue
                }
                if next == "\"" {
                    inQuote = true
                } else if next.isWhitespace {
                    break
                } else if next == "|" {
                    // Regular expressions keep their alternation unquoted: regex:^(a|b)$
                    if !raw.lowercased().hasPrefix("regex:") { break }
                } else if next == "(" {
                    if isModifier(raw) { break }
                    localDepth += 1
                } else if next == ")" {
                    if localDepth > 0 {
                        localDepth -= 1
                    } else if depth > 0 {
                        break
                    }
                }
                raw.append(next)
                index += 1
            }
            let kind: Token.Kind
            switch raw {
            case "AND": kind = .and
            case "OR": kind = .or
            case "NOT": kind = .not
            default: kind = .word
            }
            tokens.append(Token(kind: kind, raw: raw, start: start, end: index))
        }
        return tokens
    }

    private static func isModifier(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered == "case:" || lowered == "nocase:"
    }

    // MARK: Grammar

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var globalCase: Bool?

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var peek: Token? { position < tokens.count ? tokens[position] : nil }

        /// AND level: juxtaposition or `AND`, up to a closing parenthesis.
        mutating func parseSequence() throws -> LightningQuery? {
            var items: [LightningQuery] = []
            while let token = peek, token.kind != .close {
                if token.kind == .and || token.kind == .or {
                    position += 1
                    continue
                }
                if let item = try parseAlternatives() { items.append(item) }
            }
            return Self.combine(items, or: false)
        }

        /// OR level.
        mutating func parseAlternatives() throws -> LightningQuery? {
            var items: [LightningQuery] = []
            if let first = try parseNegation() { items.append(first) }
            while peek?.kind == .or {
                position += 1
                if let next = try parseNegation() { items.append(next) }
            }
            return Self.combine(items, or: true)
        }

        /// NOT level; `NOT NOT a` is `a`.
        mutating func parseNegation() throws -> LightningQuery? {
            guard peek?.kind == .not else { return try parsePrimary() }
            position += 1
            guard let inner = try parseNegation() else { return nil }
            if case let .not(nested) = inner { return nested }
            return .not(inner)
        }

        mutating func parsePrimary() throws -> LightningQuery? {
            guard let token = peek else { return nil }
            switch token.kind {
            case .open:
                position += 1
                let inner = try parseSequence()
                if peek?.kind == .close { position += 1 }
                return inner
            case .word:
                position += 1
                return try word(token)
            case .and, .or, .not, .close:
                return nil
            }
        }

        mutating func word(_ token: Token) throws -> LightningQuery? {
            if let (name, value) = LightningQueryParser.splitFilter(token.raw), ["case", "nocase"].contains(name.lowercased()) {
                let sensitive = name.lowercased() == "case"
                if !value.isEmpty {
                    let nested = Token(kind: .word, raw: value, start: token.start + name.count + 1, end: token.end)
                    return try word(nested).map { .matchCase(sensitive, $0) }
                }
                if let next = peek, next.kind == .open, next.start == token.end {
                    return try parsePrimary().map { .matchCase(sensitive, $0) }
                }
                globalCase = sensitive
                return nil
            }
            return try LightningQueryParser.node(for: token)
        }

        static func combine(_ items: [LightningQuery], or: Bool) -> LightningQuery? {
            switch items.count {
            case 0: return nil
            case 1: return items[0]
            default: return or ? .or(items) : .and(items)
            }
        }
    }

    // MARK: Words and filters

    /// `letters:` at the start of an unquoted word introduces a filter.
    static func splitFilter(_ raw: String) -> (name: String, value: String)? {
        guard let colon = raw.firstIndex(of: ":"), colon > raw.startIndex else { return nil }
        let name = raw[raw.startIndex..<colon]
        guard name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (String(name), String(raw[raw.index(after: colon)...]))
    }

    fileprivate static func node(for token: Token) throws -> LightningQuery? {
        guard let (name, value) = splitFilter(token.raw) else {
            let text = unquote(token.raw)
            return text.isEmpty ? nil : .term(LightningTerm(text))
        }
        func fail(_ message: String) -> LightningSyntaxError {
            LightningSyntaxError(message: message, fragment: token.raw, offset: token.start)
        }
        let alternatives = splitAlternatives(value)
        switch name.lowercased() {
        case "ext":
            let extensions = alternatives.map { $0.drop { $0 == "." }.lowercased() }.filter { !$0.isEmpty }
            return .filter(.extension(extensions))
        case "type":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            return .filter(.type(try alternatives.map {
                guard let type = LightningFileType.named($0) else { throw fail(LightningSyntaxError.unknownType) }
                return type
            }))
        case "folder", "file":
            let text = unquote(value)
            let term = text.isEmpty ? nil : LightningTerm(text)
            return .filter(name.lowercased() == "folder" ? .folder(term) : .file(term))
        case "name":
            let text = unquote(value)
            guard !text.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            return .filter(.name(LightningTerm(text)))
        case "size":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            return .filter(.size(try alternatives.map { try sizeCondition($0, fail) }))
        case "dm", "datemodified", "dc", "datecreated":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            let conditions = try alternatives.map { try dateCondition($0, fail) }
            let modified = ["dm", "datemodified"].contains(name.lowercased())
            return .filter(modified ? .dateModified(conditions) : .dateCreated(conditions))
        case "in", "infolder", "parent", "nosubfolders":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            let folders = try alternatives.map { folder -> String in
                guard folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/") else {
                    throw fail(LightningSyntaxError.invalidFolder)
                }
                return folder
            }
            return .filter(name.lowercased() == "nosubfolders" ? .noSubfolders(folders) : .inFolder(folders))
        case "regex":
            let pattern = unquote(value)
            guard !pattern.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw fail(LightningSyntaxError.invalidRegularExpression)
            }
            return .filter(.regex(pattern))
        case "content":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            return .filter(.content(alternatives))
        case "tag":
            return .filter(.tag(alternatives))
        case "tagexact":
            guard !alternatives.isEmpty else { throw fail(LightningSyntaxError.missingValue) }
            return .filter(.tagExact(alternatives))
        case "audio", "video", "doc", "exe", "pic", "zip":
            let type = LightningFileType.named(name)!
            let text = unquote(value)
            let filter = LightningQuery.filter(.type([type]))
            return text.isEmpty ? filter : .and([filter, .term(LightningTerm(text))])
        default:
            throw LightningSyntaxError(message: LightningSyntaxError.unknownFilter, fragment: name, offset: token.start)
        }
    }

    static func unquote(_ raw: String) -> String {
        raw.contains("\"") ? raw.filter { $0 != "\"" } : raw
    }

    /// Splits on semicolons outside quotes and drops empty alternatives.
    static func splitAlternatives(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        for character in raw {
            if character == "\"" {
                inQuote.toggle()
            } else if character == ";", !inQuote {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    private static func comparisonPrefix(_ text: String) -> (LightningComparison, String)? {
        for (prefix, comparison) in [(">=", LightningComparison.greaterOrEqual), ("<=", .lessOrEqual), ("!=", .notEqual),
                                     (">", .greater), ("<", .less), ("=", .equal)] where text.hasPrefix(prefix) {
            return (comparison, String(text.dropFirst(prefix.count)))
        }
        return nil
    }

    // MARK: Sizes

    private static func sizeCondition(_ text: String, _ fail: (String) -> LightningSyntaxError) throws -> LightningSizeCondition {
        if let named = LightningSizeClass.named(text) { return .named(named) }
        if let range = text.range(of: "..") {
            let lowerText = String(text[..<range.lowerBound]), upperText = String(text[range.upperBound...])
            guard !(lowerText.isEmpty && upperText.isEmpty) else { throw fail(LightningSyntaxError.invalidSize) }
            let lower = try lowerText.isEmpty ? nil : byteCount(lowerText, fail)
            let upper = try upperText.isEmpty ? nil : byteCount(upperText, fail)
            if let lower, let upper, upper < lower { throw fail(LightningSyntaxError.reversedRange) }
            return .range(lower, upper)
        }
        if let (comparison, rest) = comparisonPrefix(text) {
            return .compare(comparison, try byteCount(rest, fail))
        }
        return .compare(.equal, try byteCount(text, fail))
    }

    /// Decimal units B, KB, MB, GB, TB, PB (1 KB = 1000 bytes); KiB, MiB… are binary.
    static func byteCount(_ text: String) -> Int64? {
        let lowered = text.lowercased()
        let number = lowered.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = lowered.dropFirst(number.count)
        guard !number.isEmpty, let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "", "b", "byte", "bytes": multiplier = 1
        case "k", "kb", "kilobyte", "kilobytes": multiplier = 1e3
        case "m", "mb", "megabyte", "megabytes": multiplier = 1e6
        case "g", "gb", "gigabyte", "gigabytes": multiplier = 1e9
        case "t", "tb", "terabyte", "terabytes": multiplier = 1e12
        case "p", "pb", "petabyte", "petabytes": multiplier = 1e15
        case "kib", "kibibyte", "kibibytes": multiplier = 1024
        case "mib", "mebibyte", "mebibytes": multiplier = 1_048_576
        case "gib", "gibibyte", "gibibytes": multiplier = 1_073_741_824
        case "tib", "tebibyte", "tebibytes": multiplier = 1_099_511_627_776
        case "pib", "pebibyte", "pebibytes": multiplier = 1_125_899_906_842_624
        default: return nil
        }
        let bytes = (value * multiplier).rounded()
        guard bytes < 9.2e18 else { return nil }
        return Int64(bytes)
    }

    private static func byteCount(_ text: String, _ fail: (String) -> LightningSyntaxError) throws -> Int64 {
        guard let value = byteCount(text) else { throw fail(LightningSyntaxError.invalidSize) }
        return value
    }

    // MARK: Dates

    private static func dateCondition(_ text: String, _ fail: (String) -> LightningSyntaxError) throws -> LightningDateCondition {
        if let range = text.range(of: "..") {
            let lowerText = String(text[..<range.lowerBound]), upperText = String(text[range.upperBound...])
            guard !(lowerText.isEmpty && upperText.isEmpty) else { throw fail(LightningSyntaxError.invalidDate) }
            let lower = try lowerText.isEmpty ? nil : dateValue(lowerText, fail)
            let upper = try upperText.isEmpty ? nil : dateValue(upperText, fail)
            if let lower, let upper, lower.isAbsolute, upper.isAbsolute {
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let now = Date()
                if upper.interval(now: now, calendar: utc).upperBound <= lower.interval(now: now, calendar: utc).lowerBound {
                    throw fail(LightningSyntaxError.reversedRange)
                }
            }
            return .range(lower, upper)
        }
        if let (comparison, rest) = comparisonPrefix(text) {
            return .compare(comparison, try dateValue(rest, fail))
        }
        return .compare(.equal, try dateValue(text, fail))
    }

    private static func dateValue(_ text: String, _ fail: (String) -> LightningSyntaxError) throws -> LightningDateValue {
        guard let value = dateValue(text) else { throw fail(LightningSyntaxError.invalidDate) }
        return value
    }

    /// Keywords, or `YYYY-MM-DD`, `YYYY/MM/DD`, `YYYY.MM.DD`, `YYYYMMDD`, `YYYY-MM` and `YYYY`.
    static func dateValue(_ text: String) -> LightningDateValue? {
        if let keyword = LightningDateValue.keyword(text) { return keyword }
        let separator: Character = text.first(where: { $0 == "-" || $0 == "/" || $0 == "." }) ?? "-"
        let groups = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        var year: Int?, month: Int?, day: Int?
        switch groups.count {
        case 1 where groups[0].count == 8:
            let digits = Array(groups[0])
            year = Int(String(digits[0..<4])); month = Int(String(digits[4..<6])); day = Int(String(digits[6..<8]))
        case 1 where groups[0].count == 4:
            year = Int(groups[0])
        case 2 where groups[0].count == 4 && groups[1].count <= 2:
            year = Int(groups[0]); month = Int(groups[1])
        case 3 where groups[0].count == 4 && groups[1].count <= 2 && groups[2].count <= 2:
            year = Int(groups[0]); month = Int(groups[1]); day = Int(groups[2])
        default:
            return nil
        }
        guard let year, year >= 1 else { return nil }
        guard let month else { return .year(year) }
        guard (1...12).contains(month) else { return nil }
        guard let day else { return .month(year: year, month: month) }
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day)
        guard day >= 1, components.isValidDate else { return nil }
        return .day(year: year, month: month, day: day)
    }
}
