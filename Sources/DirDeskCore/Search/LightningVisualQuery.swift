import Foundation

// Visual mode of Lightning Search: filter-bar choices plus an advanced condition builder, compiled into
// the expression language (`LightningQueryParser`). Visual values are literal: wildcards and quotes in a
// name become an escaped `regex:` instead of pattern syntax.

/// One calendar day chosen in the visual filters, written as `YYYY-MM-DD`.
public struct LightningVisualDay: Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Start of the day in `calendar`.
    public func date(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public var expressionText: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: LightningVisualDay, rhs: LightningVisualDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// What the search text is matched against ("Match": Name or File Contents).
public enum LightningVisualTextTarget: String, CaseIterable, Sendable {
    case name, contents
}

/// Choices of the Kind filter, in menu order. An item matches when it is any of the selected kinds.
public enum LightningVisualKind: String, CaseIterable, Sendable {
    case file, image, video, audio, document, pdf, spreadsheet, presentation, archive, code, application, folder

    /// The `type:` value, or nil for applications, which compile to `ext:app`.
    public var typeName: String? {
        switch self {
        case .file: "file"
        case .image: "picture"
        case .video: "video"
        case .audio: "audio"
        case .document: "doc"
        case .pdf: "pdf"
        case .spreadsheet: "spreadsheet"
        case .presentation: "presentation"
        case .archive: "archive"
        case .code: "code"
        case .application: nil
        case .folder: "folder"
        }
    }
}

/// Presets of the modification-date filter.
public enum LightningVisualDatePreset: String, CaseIterable, Sendable {
    case any, today, yesterday, pastWeek, pastMonth, thisYear, custom

    public var keyword: String? {
        switch self {
        case .any, .custom: nil
        case .today: "today"
        case .yesterday: "yesterday"
        case .pastWeek: "pastweek"
        case .pastMonth: "pastmonth"
        case .thisYear: "thisyear"
        }
    }
}

// MARK: - Advanced conditions

public enum LightningConditionValueKind: Sendable {
    case text, extensions, size, date, folder
}

public enum LightningConditionField: String, CaseIterable, Sendable {
    case name, contents, size, created, modified, `extension`, folder, tag, regex

    public var comparisons: [LightningConditionComparison] {
        switch self {
        case .name: [.contains, .equals, .starts, .ends]
        case .contents, .tag, .regex: [.contains]
        case .size: [.greater, .less, .atLeast, .atMost, .between, .equals]
        case .created, .modified: [.atLeast, .atMost, .greater, .less, .equals, .between]
        case .extension: [.equals]
        case .folder: [.descendants, .children, .directFiles]
        }
    }

    public var defaultComparison: LightningConditionComparison { comparisons[0] }

    public var valueKind: LightningConditionValueKind {
        switch self {
        case .name, .contents, .tag, .regex: .text
        case .extension: .extensions
        case .size: .size
        case .created, .modified: .date
        case .folder: .folder
        }
    }
}

/// Comparisons of the condition builder. Dates read `greater` as after, `less` as before, `atLeast` as on or
/// after and `atMost` as on or before the chosen day.
public enum LightningConditionComparison: String, CaseIterable, Sendable {
    case contains, equals, starts, ends, greater, less, atLeast, atMost, between, descendants, children, directFiles
}

/// Decimal units, as in the expression language (1 KB = 1000 bytes).
public enum LightningVisualSizeUnit: String, CaseIterable, Sendable {
    case bytes = "B", kilobytes = "KB", megabytes = "MB", gigabytes = "GB", terabytes = "TB"

    var multiplier: Double {
        switch self {
        case .bytes: 1
        case .kilobytes: 1e3
        case .megabytes: 1e6
        case .gigabytes: 1e9
        case .terabytes: 1e12
        }
    }
}

public struct LightningCondition: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Disabled conditions stay in the builder but are left out of the search.
    public var isEnabled: Bool
    /// Exclude: items matching the condition are left out.
    public var isExcluded: Bool
    public var field: LightningConditionField
    public var comparison: LightningConditionComparison
    /// Text, extensions, a number (the lower bound of a size range) or a folder path.
    public var value: String
    /// The upper bound of a size range.
    public var secondValue: String
    public var unit: LightningVisualSizeUnit
    /// The day of a date condition (the start of a date range).
    public var day: LightningVisualDay?
    /// The last day of a date range, inclusive.
    public var secondDay: LightningVisualDay?

    public init(id: UUID = UUID(), isEnabled: Bool = true, isExcluded: Bool = false, field: LightningConditionField = .name,
                comparison: LightningConditionComparison? = nil, value: String = "", secondValue: String = "",
                unit: LightningVisualSizeUnit = .megabytes, day: LightningVisualDay? = nil, secondDay: LightningVisualDay? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.isExcluded = isExcluded
        self.field = field
        self.comparison = comparison.flatMap { field.comparisons.contains($0) ? $0 : nil } ?? field.defaultComparison
        self.value = value
        self.secondValue = secondValue
        self.unit = unit
        self.day = day
        self.secondDay = secondDay
    }

    /// Switches the field, keeping the comparison and the value when they still make sense.
    /// Date fields start at `today` so the date controls never show a value the search ignores.
    public mutating func setField(_ newField: LightningConditionField, today: LightningVisualDay) {
        guard newField != field else { return }
        let previousKind = field.valueKind
        field = newField
        if !newField.comparisons.contains(comparison) { comparison = newField.defaultComparison }
        guard newField.valueKind != previousKind else { return }
        value = ""
        secondValue = ""
        if newField.valueKind == .date {
            day = day ?? today
            secondDay = secondDay ?? today
        }
    }
}

public enum LightningConditionNode: Identifiable, Hashable, Sendable {
    case condition(LightningCondition)
    case group(LightningConditionGroup)

    public var id: UUID {
        switch self {
        case let .condition(condition): condition.id
        case let .group(group): group.id
        }
    }
}

/// A condition group. The root group is level 1; nested groups go down to `maximumLevel`.
public struct LightningConditionGroup: Identifiable, Hashable, Sendable {
    public static let maximumConditions = 32
    public static let maximumLevel = 4

    public var id: UUID
    /// Match All (AND) or Match Any (OR).
    public var matchesAll: Bool
    /// Exclude Group: items matching the group are left out.
    public var isExcluded: Bool
    public var items: [LightningConditionNode]

    public init(id: UUID = UUID(), matchesAll: Bool = true, isExcluded: Bool = false, items: [LightningConditionNode] = []) {
        self.id = id
        self.matchesAll = matchesAll
        self.isExcluded = isExcluded
        self.items = items
    }

    /// Conditions in this group and every nested group.
    public var conditionCount: Int {
        items.reduce(0) { total, item in
            switch item {
            case .condition: total + 1
            case let .group(group): total + group.conditionCount
            }
        }
    }

    /// Enabled conditions with a value, in this group and every nested group.
    public var activeConditionCount: Int {
        items.reduce(0) { total, item in
            switch item {
            case let .condition(condition): total + (condition.isEnabled && !LightningVisualCompiler.isBlank(condition) ? 1 : 0)
            case let .group(group): total + group.activeConditionCount
            }
        }
    }

    /// 1 for a group without nested groups.
    public var depth: Int {
        1 + (items.compactMap { item -> Int? in
            if case let .group(group) = item { return group.depth }
            return nil
        }.max() ?? 0)
    }

    public var exceedsLimits: Bool {
        conditionCount > Self.maximumConditions || depth > Self.maximumLevel
    }

    // MARK: Lookup

    public func condition(id: UUID) -> LightningCondition? {
        for item in items {
            switch item {
            case let .condition(condition) where condition.id == id: return condition
            case let .group(group): if let found = group.condition(id: id) { return found }
            default: break
            }
        }
        return nil
    }

    public func group(id: UUID) -> LightningConditionGroup? {
        if self.id == id { return self }
        for case let .group(group) in items {
            if let found = group.group(id: id) { return found }
        }
        return nil
    }

    /// Nesting level of the group with `id`: 1 for this group, nil when it is not in the tree.
    public func level(ofGroup id: UUID) -> Int? {
        if self.id == id { return 1 }
        for case let .group(group) in items {
            if let level = group.level(ofGroup: id) { return level + 1 }
        }
        return nil
    }

    public func canAddCondition() -> Bool {
        conditionCount < Self.maximumConditions
    }

    /// A new group holds one empty condition, so it needs room for both.
    public func canAddGroup(to groupID: UUID) -> Bool {
        guard let level = level(ofGroup: groupID) else { return false }
        return level < Self.maximumLevel && conditionCount < Self.maximumConditions
    }

    // MARK: Editing

    /// Appends `condition` to the group with `groupID`. Returns false at the condition limit.
    @discardableResult
    public mutating func addCondition(_ condition: LightningCondition = LightningCondition(), to groupID: UUID) -> Bool {
        guard canAddCondition() else { return false }
        return updateGroup(id: groupID) { $0.items.append(.condition(condition)) }
    }

    /// Appends a group with one empty condition. Returns the new group's id, or nil at a limit.
    @discardableResult
    public mutating func addGroup(to groupID: UUID, matchesAll: Bool = true) -> UUID? {
        guard canAddGroup(to: groupID) else { return nil }
        let group = LightningConditionGroup(matchesAll: matchesAll, items: [.condition(LightningCondition())])
        return updateGroup(id: groupID) { $0.items.append(.group(group)) } ? group.id : nil
    }

    /// Removes the condition or group with `id` from anywhere in the tree.
    @discardableResult
    public mutating func removeItem(id: UUID) -> Bool {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            return true
        }
        for index in items.indices {
            guard case var .group(group) = items[index] else { continue }
            if group.removeItem(id: id) {
                items[index] = .group(group)
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func updateCondition(id: UUID, _ change: (inout LightningCondition) -> Void) -> Bool {
        for index in items.indices {
            switch items[index] {
            case var .condition(condition) where condition.id == id:
                change(&condition)
                condition.id = id
                items[index] = .condition(condition)
                return true
            case var .group(group):
                if group.updateCondition(id: id, change) {
                    items[index] = .group(group)
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    @discardableResult
    public mutating func updateGroup(id: UUID, _ change: (inout LightningConditionGroup) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            self.id = id
            return true
        }
        for index in items.indices {
            guard case var .group(group) = items[index] else { continue }
            if group.updateGroup(id: id, change) {
                items[index] = .group(group)
                return true
            }
        }
        return false
    }
}

// MARK: - Visual query

public struct LightningVisualIssue: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case emptyCondition, missingComparison, invalidSize, invalidDate, reversedRange, invalidRegularExpression, invalidFolder
        case tooManyConditions
    }

    public var kind: Kind
    /// The condition the issue belongs to; nil for the filter bar and for limits.
    public var conditionID: UUID?

    public init(_ kind: Kind, conditionID: UUID? = nil) {
        self.kind = kind
        self.conditionID = conditionID
    }
}

public struct LightningVisualCompilation: Equatable, Sendable {
    /// The equivalent Lightning Search expression; empty when nothing restricts the search.
    public var expression: String
    /// Problems with conditions that were left out of `expression`.
    public var issues: [LightningVisualIssue]

    public init(expression: String = "", issues: [LightningVisualIssue] = []) {
        self.expression = expression
        self.issues = issues
    }
}

public struct LightningVisualQuery: Hashable, Sendable {
    /// Search words; each one must appear in the name (or the file contents). Double quotes keep a phrase together.
    public var text: String
    public var textTarget: LightningVisualTextTarget
    /// Kind filter; any selected kind matches.
    public var kinds: Set<LightningVisualKind>
    /// Modification-date filter.
    public var date: LightningVisualDatePreset
    /// Bounds of a custom date range, both inclusive; either may be missing.
    public var customStart: LightningVisualDay?
    public var customEnd: LightningVisualDay?
    /// Finder tags, compared by their whole names; any selected tag matches.
    public var tags: [String]
    /// Case sensitivity of the whole visual search. It is not part of the compiled expression: the caller
    /// passes it to the engine.
    public var matchCase: Bool
    /// Advanced conditions, combined with the filters above.
    public var conditions: LightningConditionGroup

    public init(text: String = "") {
        self.text = text
        textTarget = .name
        kinds = []
        date = .any
        customStart = nil
        customEnd = nil
        tags = []
        matchCase = false
        conditions = LightningConditionGroup()
    }

    /// Whether any filter differs from its default. The search text is not a filter.
    public var hasFilters: Bool {
        textTarget != .name || !kinds.isEmpty || date != .any || !tags.isEmpty || matchCase
            || !conditions.items.isEmpty || !conditions.matchesAll || conditions.isExcluded
    }

    /// Reset Filters: every filter and condition back to its default; the search text stays.
    public mutating func resetFilters() {
        self = LightningVisualQuery(text: text)
    }

    public func compile(homeDirectory: String = NSHomeDirectory()) -> LightningVisualCompilation {
        LightningVisualCompiler(homeDirectory: homeDirectory).compile(self)
    }
}

// MARK: - Compiler

/// Expression tree used while compiling; rendering adds the parentheses the parser needs
/// (OR binds tighter than AND) plus some for readability.
indirect enum LightningExpressionNode: Equatable {
    case atom(String)
    case and([LightningExpressionNode])
    case or([LightningExpressionNode])
    case not(LightningExpressionNode)

    static func all(_ nodes: [LightningExpressionNode]) -> LightningExpressionNode? {
        nodes.count > 1 ? .and(nodes) : nodes.first
    }

    static func any(_ nodes: [LightningExpressionNode]) -> LightningExpressionNode? {
        nodes.count > 1 ? .or(nodes) : nodes.first
    }

    var isCompound: Bool {
        switch self {
        case .atom, .not: false
        case let .and(nodes), let .or(nodes): nodes.count > 1
        }
    }

    var rendered: String {
        switch self {
        case let .atom(text):
            return text
        case let .and(nodes):
            return nodes.map(\.nested).joined(separator: " ")
        case let .or(nodes):
            return nodes.map(\.nested).joined(separator: " OR ")
        case let .not(node):
            if case let .not(inner) = node { return inner.rendered }
            return "NOT " + node.nested
        }
    }

    /// Rendering inside another node: compound children are parenthesized.
    private var nested: String { isCompound ? "(" + rendered + ")" : rendered }
}

struct LightningVisualCompiler {
    let homeDirectory: String

    func compile(_ query: LightningVisualQuery) -> LightningVisualCompilation {
        var issues: [LightningVisualIssue] = []
        var parts: [LightningExpressionNode] = []
        for word in Self.words(query.text) {
            switch query.textTarget {
            case .name:
                if let node = Self.nameNode(word, .contains) { parts.append(node) }
            case .contents:
                let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(.atom("content:" + Self.quoted(text))) }
            }
        }
        let selected = LightningVisualKind.allCases.filter(query.kinds.contains)
        var kinds: [LightningExpressionNode] = []
        let types = selected.compactMap(\.typeName)
        if !types.isEmpty { kinds.append(.atom("type:" + types.joined(separator: ";"))) }
        if selected.contains(.application) { kinds.append(.atom("ext:app")) }
        if let node = LightningExpressionNode.any(kinds) { parts.append(node) }
        let dateFilter = "dm:"
        if let keyword = query.date.keyword {
            parts.append(.atom(dateFilter + keyword))
        } else if query.date == .custom {
            switch (query.customStart, query.customEnd) {
            case let (start?, end?):
                if end < start {
                    issues.append(LightningVisualIssue(.reversedRange))
                } else {
                    parts.append(.atom(dateFilter + start.expressionText + ".." + end.expressionText))
                }
            case let (start?, nil):
                parts.append(.atom(dateFilter + ">=" + start.expressionText))
            case let (nil, end?):
                parts.append(.atom(dateFilter + "<=" + end.expressionText))
            case (nil, nil):
                break
            }
        }
        let tags = query.tags.map(Self.cleanedAlternative).filter { !$0.isEmpty }
        if !tags.isEmpty { parts.append(.atom("tagexact:" + tags.map(Self.quoted).joined(separator: ";"))) }
        if query.conditions.exceedsLimits { issues.append(LightningVisualIssue(.tooManyConditions)) }
        if let node = groupNode(query.conditions, issues: &issues) {
            // The root group is ANDed with the filter bar, so a Match All root needs no parentheses.
            if case let .and(nodes) = node { parts += nodes } else { parts.append(node) }
        }
        let expression = LightningExpressionNode.all(parts)?.rendered ?? ""
        return LightningVisualCompilation(expression: expression, issues: issues)
    }

    private func groupNode(_ group: LightningConditionGroup, issues: inout [LightningVisualIssue]) -> LightningExpressionNode? {
        var nodes: [LightningExpressionNode] = []
        for item in group.items {
            switch item {
            case let .condition(condition):
                guard condition.isEnabled else { continue }
                switch conditionNode(condition) {
                case let .node(node): nodes.append(condition.isExcluded ? .not(node) : node)
                case let .issue(kind): issues.append(LightningVisualIssue(kind, conditionID: condition.id))
                }
            case let .group(nested):
                if let node = groupNode(nested, issues: &issues) { nodes.append(node) }
            }
        }
        guard let combined = group.matchesAll ? LightningExpressionNode.all(nodes) : LightningExpressionNode.any(nodes) else { return nil }
        return group.isExcluded ? .not(combined) : combined
    }

    private enum ConditionOutcome {
        case node(LightningExpressionNode)
        case issue(LightningVisualIssue.Kind)
    }

    private func conditionNode(_ condition: LightningCondition) -> ConditionOutcome {
        func issue(_ kind: LightningVisualIssue.Kind) -> ConditionOutcome { .issue(kind) }
        guard condition.field.comparisons.contains(condition.comparison) else { return issue(.missingComparison) }
        if Self.isBlank(condition) { return issue(.emptyCondition) }
        let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch condition.field {
        case .name:
            guard let node = Self.nameNode(value, condition.comparison) else { return issue(.emptyCondition) }
            return .node(node)
        case .contents:
            let text = value.replacingOccurrences(of: "\"", with: "")
            guard !text.isEmpty else { return issue(.emptyCondition) }
            return .node(.atom("content:" + Self.quoted(text)))
        case .tag:
            let values = value.split(separator: ";").map { Self.cleanedAlternative(String($0)) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return issue(.emptyCondition) }
            return .node(.atom("tag:" + values.map(Self.quoted).joined(separator: ";")))
        case .regex:
            guard (try? NSRegularExpression(pattern: value)) != nil else { return issue(.invalidRegularExpression) }
            return .node(.atom("regex:" + Self.quoted(Self.regexWithoutQuotes(value))))
        case .extension:
            let separators = CharacterSet(charactersIn: ";,").union(.whitespacesAndNewlines)
            let names = value.components(separatedBy: separators)
                .map { Self.cleanedAlternative(String($0.drop { $0 == "." })).lowercased() }
                .filter { !$0.isEmpty }
            guard !names.isEmpty else { return issue(.emptyCondition) }
            return .node(.atom("ext:" + names.map(Self.quoted).joined(separator: ";")))
        case .size:
            guard let lower = Self.sizeText(value, unit: condition.unit) else { return issue(.invalidSize) }
            switch condition.comparison {
            case .greater: return .node(.atom("size:>" + lower.text))
            case .less: return .node(.atom("size:<" + lower.text))
            case .atLeast: return .node(.atom("size:>=" + lower.text))
            case .atMost: return .node(.atom("size:<=" + lower.text))
            case .equals: return .node(.atom("size:" + lower.text))
            case .between:
                guard let upper = Self.sizeText(condition.secondValue, unit: condition.unit) else { return issue(.invalidSize) }
                guard upper.bytes >= lower.bytes else { return issue(.reversedRange) }
                return .node(.atom("size:" + lower.text + ".." + upper.text))
            default:
                return issue(.missingComparison)
            }
        case .created, .modified:
            let filter = condition.field == .modified ? "dm:" : "dc:"
            guard let day = condition.day, Self.isValid(day) else { return issue(.invalidDate) }
            switch condition.comparison {
            case .equals: return .node(.atom(filter + day.expressionText))
            case .greater: return .node(.atom(filter + ">" + day.expressionText))
            case .less: return .node(.atom(filter + "<" + day.expressionText))
            case .atLeast: return .node(.atom(filter + ">=" + day.expressionText))
            case .atMost: return .node(.atom(filter + "<=" + day.expressionText))
            case .between:
                guard let end = condition.secondDay, Self.isValid(end) else { return issue(.invalidDate) }
                guard end >= day else { return issue(.reversedRange) }
                return .node(.atom(filter + day.expressionText + ".." + end.expressionText))
            default:
                return issue(.missingComparison)
            }
        case .folder:
            guard let path = Self.folderPath(value) else { return issue(.invalidFolder) }
            let folder = Self.quoted(path)
            switch condition.comparison {
            case .descendants:
                return .node(.atom("infolder:" + folder))
            case .children:
                return .node(.atom("nosubfolders:" + folder))
            case .directFiles:
                // The folder itself (a path term of whole-name segments) and the files directly inside it.
                let files = LightningExpressionNode.and([.atom("nosubfolders:" + folder), .atom("file:")])
                let expanded = path == "~" ? homeDirectory : path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
                guard expanded != "/", expanded.hasPrefix("/") else { return .node(files) }
                return .node(.or([.atom(Self.quoted(expanded + "/")), files]))
            default:
                return issue(.missingComparison)
            }
        }
    }

    // MARK: Values

    /// A condition without the values its comparison needs. Date conditions always have a day in the
    /// builder, so they are never blank.
    static func isBlank(_ condition: LightningCondition) -> Bool {
        switch condition.field.valueKind {
        case .text, .extensions, .folder:
            return condition.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .size:
            let first = condition.value.trimmingCharacters(in: .whitespaces).isEmpty
            let second = condition.secondValue.trimmingCharacters(in: .whitespaces).isEmpty
            return first || (condition.comparison == .between && second)
        case .date:
            return condition.day == nil || (condition.comparison == .between && condition.secondDay == nil)
        }
    }

    /// Splits search text on whitespace; double quotes keep phrases together and are not part of the words.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuote = false
        for character in text {
            if character == "\"" {
                inQuote.toggle()
            } else if character.isWhitespace, !inQuote {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// A literal name condition. Slashes keep their path meaning; wildcard characters and quotes, which the
    /// expression language cannot write literally, fall back to an escaped regular expression.
    static func nameNode(_ raw: String, _ comparison: LightningConditionComparison) -> LightningExpressionNode? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("/") {
            let text = value.replacingOccurrences(of: "\"", with: "")
            let core = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !core.isEmpty else { return nil }
            switch comparison {
            case .equals: return .atom(quoted("/" + core + "/"))
            case .starts: return .atom(quoted("/" + core))
            case .ends: return .atom(quoted(core + "/"))
            default: return .atom(quoted(text))
            }
        }
        if value.contains(where: { $0 == "*" || $0 == "?" || $0 == "\"" }) {
            let escaped = regexWithoutQuotes(NSRegularExpression.escapedPattern(for: value))
            let pattern: String
            switch comparison {
            case .equals: pattern = "^" + escaped + "$"
            case .starts: pattern = "^" + escaped
            case .ends: pattern = escaped + "$"
            default: pattern = escaped
            }
            return .atom("regex:" + quoted(pattern))
        }
        switch comparison {
        case .equals: return .atom(quoted("/" + value + "/"))
        case .starts: return .atom(quoted("/" + value))
        case .ends: return .atom(quoted(value + "/"))
        default: return .atom(quoted(value))
        }
    }

    /// Quotes cannot appear inside quoted values; regular expressions spell them `\x22` instead.
    static func regexWithoutQuotes(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: "\\\"", with: "\\x22").replacingOccurrences(of: "\"", with: "\\x22")
    }

    private static let plainCharacters: CharacterSet = {
        var set = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
        set.insert(charactersIn: "_-.~@#+,%&'$/")
        return set
    }()

    /// Quotes values that would otherwise be read as operators, filters, groups or alternatives.
    static func quoted(_ value: String) -> String {
        let plain = !value.isEmpty && !["AND", "OR", "NOT"].contains(value)
            && value.unicodeScalars.allSatisfy { plainCharacters.contains($0) }
        return plain ? value : "\"" + value + "\""
    }

    /// One alternative of a semicolon list: no quotes, no semicolons, no surrounding whitespace.
    static func cleanedAlternative(_ value: String) -> String {
        value.filter { $0 != "\"" && $0 != ";" }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `12`, `1.5` or `1,5` with a unit, as size-filter text and bytes.
    static func sizeText(_ raw: String, unit: LightningVisualSizeUnit) -> (text: String, bytes: Double)? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1, let number = Double(text), number.isFinite, number >= 0,
              number * unit.multiplier < 9e18 else { return nil }
        var digits: String
        if number == number.rounded() {
            digits = String(Int64(number))
        } else {
            digits = String(format: "%.6f", number)
            while digits.hasSuffix("0") { digits.removeLast() }
            if digits.hasSuffix(".") { digits.removeLast() }
        }
        return (digits + unit.rawValue, number * unit.multiplier)
    }

    /// An absolute path or a `~` path without trailing slashes; nil for anything else.
    static func folderPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("\""), path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func isValid(_ day: LightningVisualDay) -> Bool {
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), year: day.year, month: day.month, day: day.day)
        return day.year >= 1 && day.year <= 9999 && components.isValidDate
    }
}
