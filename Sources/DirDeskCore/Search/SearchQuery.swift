import Foundation

// In-pane ("normal") search query model. Field and comparison raw values follow the
// original SearchField / SearchComparison enums (docs/recon/05 §2, §4.A).

/// Metadata fields the in-pane search understands. Raw values are the advanced-syntax field names.
public enum SearchField: String, Codable, CaseIterable, Sendable {
    case name, ext, kind, tag, size, modified
}

public enum SearchComparison: String, Codable, CaseIterable, Sendable {
    case contains, equal, isPresent, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual, wildcard, regularExpression
}

/// One condition of an in-pane search. Every token of a query must match (logical AND).
public struct SearchToken: Equatable, Sendable {
    public var field: SearchField
    public var comparison: SearchComparison
    /// The value as typed, quotes removed. Sizes and dates stay textual and are interpreted when matching.
    public var value: String
    public var isNegated: Bool
    /// Character offsets of the whole token (including `-` and the field name) in the query text.
    public var sourceRange: Range<Int>

    public init(field: SearchField, comparison: SearchComparison, value: String, isNegated: Bool = false,
                sourceRange: Range<Int> = 0..<0) {
        self.field = field
        self.comparison = comparison
        self.value = value
        self.isNegated = isNegated
        self.sourceRange = sourceRange
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var tokens: [SearchToken]

    public init(tokens: [SearchToken] = []) {
        self.tokens = tokens
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

/// A parse error. `offset` counts Characters from the start of the query text.
public struct SearchSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public var fragment: String
    public var offset: Int
    public var message: String

    public init(fragment: String, offset: Int, message: String) {
        self.fragment = fragment
        self.offset = offset
        self.message = message
    }

    public static let unknownField = "Unknown field"
    public static let unterminatedQuote = "Unterminated quote"
    public static let missingValue = "Missing value"
    public static let invalidRegularExpression = "Invalid regular expression."
    public static let invalidSize = "Enter a nonnegative file size."
    public static let invalidDate = "Enter a date as YYYY-MM-DD."

    public var description: String { "\(message) at \(offset): \(fragment)" }
}

/// Parses the four in-pane input modes into tokens.
///
/// Advanced syntax: `field:value` with the `SearchField` names, `>= <= > < =` right after the colon,
/// a leading `-` negates, double quotes group spaces, an unquoted `*` or `?` makes a wildcard token and
/// `field:*` tests that the field has a value. Bare words search names.
public enum SearchQueryParser {
    public static func parse(_ text: String, mode: SearchInputMode) throws -> SearchQuery {
        let characters = Array(text)
        switch mode {
        case .keyword:
            return SearchQuery(tokens: words(characters).map {
                SearchToken(field: .name, comparison: .contains, value: $0.text, sourceRange: $0.range)
            })
        case .wildcard:
            guard let (value, range) = trimmed(characters) else { return SearchQuery() }
            return SearchQuery(tokens: [SearchToken(field: .name, comparison: .wildcard, value: value, sourceRange: range)])
        case .regularExpression:
            guard let (value, range) = trimmed(characters) else { return SearchQuery() }
            guard (try? NSRegularExpression(pattern: value)) != nil else {
                throw SearchSyntaxError(fragment: value, offset: range.lowerBound, message: SearchSyntaxError.invalidRegularExpression)
            }
            return SearchQuery(tokens: [SearchToken(field: .name, comparison: .regularExpression, value: value, sourceRange: range)])
        case .advanced:
            return try parseAdvanced(characters)
        }
    }

    private static func words(_ characters: [Character]) -> [(text: String, range: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            let start = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            if index > start { result.append((String(characters[start..<index]), start..<index)) }
        }
        return result
    }

    private static func trimmed(_ characters: [Character]) -> (String, Range<Int>)? {
        guard let first = characters.firstIndex(where: { !$0.isWhitespace }),
              let last = characters.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return (String(characters[first...last]), first..<(last + 1))
    }

    private static func parseAdvanced(_ characters: [Character]) throws -> SearchQuery {
        var tokens: [SearchToken] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let start = index
            var negated = false
            if characters[index] == "-", index + 1 < characters.count, !characters[index + 1].isWhitespace {
                negated = true
                index += 1
            }
            // `letters:` introduces a field; anything else is a bare name term.
            var field: SearchField?
            var scan = index
            while scan < characters.count, characters[scan].isASCII, characters[scan].isLetter { scan += 1 }
            if scan > index, scan < characters.count, characters[scan] == ":" {
                let name = String(characters[index..<scan])
                guard let known = SearchField(rawValue: name.lowercased()) else {
                    throw SearchSyntaxError(fragment: name, offset: index, message: SearchSyntaxError.unknownField)
                }
                field = known
                index = scan + 1
            }
            var comparison: SearchComparison?
            if field != nil {
                comparison = readOperator(characters, &index, numeric: field == .size || field == .modified)
            }
            let value = try readValue(characters, &index)
            let range = start..<index
            let fragment = String(characters[range])
            guard !value.text.isEmpty else {
                throw SearchSyntaxError(fragment: fragment, offset: start, message: SearchSyntaxError.missingValue)
            }
            let resolvedField = field ?? .name
            var resolved = comparison ?? defaultComparison(for: resolvedField)
            if comparison == nil {
                if value.text == "*", value.hasUnquotedWildcard {
                    resolved = .isPresent
                } else if value.hasUnquotedWildcard, resolvedField != .size, resolvedField != .modified {
                    resolved = .wildcard
                }
            }
            let token = SearchToken(field: resolvedField, comparison: resolved, value: resolved == .isPresent ? "" : value.text,
                                    isNegated: negated, sourceRange: range)
            try validate(token, fragment: fragment)
            tokens.append(token)
        }
        return SearchQuery(tokens: tokens)
    }

    private static func defaultComparison(for field: SearchField) -> SearchComparison {
        switch field {
        case .name, .tag: .contains
        case .ext, .kind, .size, .modified: .equal
        }
    }

    private static func readOperator(_ characters: [Character], _ index: inout Int, numeric: Bool) -> SearchComparison? {
        func next(_ offset: Int) -> Character? { index + offset < characters.count ? characters[index + offset] : nil }
        guard let first = next(0) else { return nil }
        if numeric {
            if first == ">", next(1) == "=" { index += 2; return .greaterThanOrEqual }
            if first == "<", next(1) == "=" { index += 2; return .lessThanOrEqual }
            if first == ">" { index += 1; return .greaterThan }
            if first == "<" { index += 1; return .lessThan }
        }
        if first == "=" { index += 1; return .equal }
        return nil
    }

    private struct Value {
        var text = ""
        var hasUnquotedWildcard = false
    }

    private static func readValue(_ characters: [Character], _ index: inout Int) throws -> Value {
        var value = Value()
        while index < characters.count, !characters[index].isWhitespace {
            let character = characters[index]
            if character == "\"" {
                guard let close = characters[(index + 1)...].firstIndex(of: "\"") else {
                    throw SearchSyntaxError(fragment: String(characters[index...]), offset: index,
                                            message: SearchSyntaxError.unterminatedQuote)
                }
                value.text += String(characters[(index + 1)..<close])
                index = close + 1
                continue
            }
            if character == "*" || character == "?" { value.hasUnquotedWildcard = true }
            value.text.append(character)
            index += 1
        }
        return value
    }

    private static func validate(_ token: SearchToken, fragment: String) throws {
        guard token.comparison != .isPresent else { return }
        switch token.field {
        case .size:
            if SearchValueParser.byteCount(token.value) == nil {
                throw SearchSyntaxError(fragment: fragment, offset: token.sourceRange.lowerBound, message: SearchSyntaxError.invalidSize)
            }
        case .modified:
            if SearchValueParser.dateInterval(token.value, now: Date(), calendar: Calendar(identifier: .gregorian)) == nil {
                throw SearchSyntaxError(fragment: fragment, offset: token.sourceRange.lowerBound, message: SearchSyntaxError.invalidDate)
            }
        default:
            break
        }
    }
}

/// Value grammar shared by the in-pane matcher.
public enum SearchValueParser {
    /// `12`, `1.5MB`, `300 kb`: decimal units B, KB, MB, GB, TB (1 KB = 1000 bytes); KiB… are binary.
    public static func byteCount(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let numberPart = trimmed.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        guard let number = Double(numberPart), number >= 0, number.isFinite else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "b": 1, "byte": 1, "bytes": 1,
            "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12,
            "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        let bytes = (number * multiplier).rounded()
        guard bytes < 9.2e18 else { return nil }
        return Int64(bytes)
    }

    /// `today`, `yesterday`, `this-week` or `yyyy-MM-dd` as a half-open day range in `calendar`.
    public static func dateInterval(_ text: String, now: Date, calendar: Calendar) -> Range<Date>? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "today":
            return dayRange(containing: now, calendar: calendar)
        case "yesterday":
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return dayRange(containing: day, calendar: calendar)
        case "this-week", "thisweek":
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return week.start..<week.end
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard value.count == 10, let date = formatter.date(from: value) else { return nil }
            return dayRange(containing: date, calendar: calendar)
        }
    }

    private static func dayRange(containing date: Date, calendar: Calendar) -> Range<Date>? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return start..<end
    }
}
