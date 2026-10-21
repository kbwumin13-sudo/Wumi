import Foundation

public enum FolderSyncDirection: String, Codable, CaseIterable, Sendable {
    /// Copy new and changed items from left to right. Nothing is ever deleted.
    case updateRight
    case updateLeft
    /// Two-way: changes flow both ways; changes that cannot be ordered become conflicts.
    case updateBoth
}

/// `automatic` lets each disk decide whether "A" and "a" are the same name; `sensitive` always treats them as different.
public enum FolderSyncCaseSensitivity: String, Codable, CaseIterable, Sendable {
    case automatic, sensitive
}

public enum FolderSyncFilterKind: String, Codable, CaseIterable, Sendable {
    case include, exclude
}

public enum FolderSyncFilterTarget: String, Codable, CaseIterable, Sendable {
    case fileName, fileExtension, relativePath
}

/// One filter row. `*` matches any run of characters (including "/") and `?` exactly one; matching is case-insensitive
/// and covers the whole target. Extension patterns are written without the dot.
///
/// Excludes always win. When any include rule exists, a file must match one of them; include rules do not apply to
/// folders, which are kept only to hold included files. An exclude that matches a folder skips everything inside it.
public struct FolderSyncFilterRule: Codable, Equatable, Hashable, Sendable {
    public var kind: FolderSyncFilterKind
    public var target: FolderSyncFilterTarget
    public var pattern: String

    public init(kind: FolderSyncFilterKind, target: FolderSyncFilterTarget, pattern: String) {
        self.kind = kind
        self.target = target
        self.pattern = pattern
    }

    /// Whether the pattern matches the item at `relativePath`, ignoring `kind`. An empty pattern matches nothing.
    public func matches(relativePath: String) -> Bool {
        FolderSyncFilterSet.Compiled(self)?.matches(FolderSyncFilterSet.Targets(relativePath)) ?? false
    }
}

public enum FolderSyncScheduleFrequency: String, Codable, CaseIterable, Sendable {
    case off, daily, weekly, monthly
}

public struct FolderSyncSchedule: Codable, Equatable, Sendable {
    public var frequency: FolderSyncScheduleFrequency
    public var hour: Int
    public var minute: Int
    /// 1–7 in `Calendar` numbering (1 is Sunday); used by weekly schedules.
    public var weekday: Int
    /// 1–31; a month without that day runs on its last day. Used by monthly schedules.
    public var dayOfMonth: Int

    public init(frequency: FolderSyncScheduleFrequency = .off, hour: Int = 9, minute: Int = 0, weekday: Int = 2, dayOfMonth: Int = 1) {
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
    }

    public static let off = FolderSyncSchedule()

    /// The first scheduled time strictly after `date`, or nil when the schedule is off. Out-of-range fields are clamped.
    public func nextRunDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let hour = min(max(hour, 0), 23)
        let minute = min(max(minute, 0), 59)
        switch frequency {
        case .off:
            return nil
        case .daily:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
        case .weekly:
            let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: min(max(weekday, 1), 7))
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
        case .monthly:
            // The next run is in the month of `date` or in the one after it.
            guard var month = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
            for _ in 0..<2 {
                guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
                var components = calendar.dateComponents([.year, .month], from: month)
                components.day = min(max(dayOfMonth, 1), days.upperBound - 1)
                components.hour = hour
                components.minute = minute
                components.second = 0
                if let candidate = calendar.date(from: components), candidate > date { return candidate }
                guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { return nil }
                month = next
            }
            return nil
        }
    }
}

/// A saved sync task.
public struct FolderSyncPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var leftURL: URL
    public var rightURL: URL
    public var direction: FolderSyncDirection
    public var includeHiddenItems: Bool
    /// Modification times at most this many seconds apart count as equal.
    public var modificationTimeTolerance: TimeInterval
    public var caseSensitivity: FolderSyncCaseSensitivity
    public var filters: [FolderSyncFilterRule]
    public var schedule: FolderSyncSchedule
    /// A manual run shows what will change before it syncs; when off it goes straight to the confirmation.
    /// Tasks saved before this option existed decode with it on.
    public var previewSyncDetails: Bool

    public init(id: UUID = UUID(), name: String, leftURL: URL, rightURL: URL, direction: FolderSyncDirection = .updateRight,
                includeHiddenItems: Bool = false, modificationTimeTolerance: TimeInterval = 2,
                caseSensitivity: FolderSyncCaseSensitivity = .automatic, filters: [FolderSyncFilterRule] = [],
                schedule: FolderSyncSchedule = .off, previewSyncDetails: Bool = true) {
        self.id = id
        self.name = name
        self.leftURL = leftURL
        self.rightURL = rightURL
        self.direction = direction
        self.includeHiddenItems = includeHiddenItems
        self.modificationTimeTolerance = modificationTimeTolerance
        self.caseSensitivity = caseSensitivity
        self.filters = filters
        self.schedule = schedule
        self.previewSyncDetails = previewSyncDetails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        leftURL = try container.decode(URL.self, forKey: .leftURL)
        rightURL = try container.decode(URL.self, forKey: .rightURL)
        direction = try container.decode(FolderSyncDirection.self, forKey: .direction)
        includeHiddenItems = try container.decode(Bool.self, forKey: .includeHiddenItems)
        modificationTimeTolerance = try container.decode(TimeInterval.self, forKey: .modificationTimeTolerance)
        caseSensitivity = try container.decode(FolderSyncCaseSensitivity.self, forKey: .caseSensitivity)
        filters = try container.decode([FolderSyncFilterRule].self, forKey: .filters)
        schedule = try container.decode(FolderSyncSchedule.self, forKey: .schedule)
        previewSyncDetails = try container.decodeIfPresent(Bool.self, forKey: .previewSyncDetails) ?? true
    }
}

/// What the comparison looks at: size and modification time.
public struct FolderSyncFingerprint: Codable, Equatable, Hashable, Sendable {
    public var size: Int64
    public var modificationDate: Date

    public init(size: Int64, modificationDate: Date) {
        self.size = size
        self.modificationDate = modificationDate
    }

    /// Same size, and modification times no more than `tolerance` seconds apart.
    public func matches(_ other: FolderSyncFingerprint, tolerance: TimeInterval) -> Bool {
        size == other.size && abs(modificationDate.timeIntervalSince(other.modificationDate)) <= max(tolerance, 0)
    }
}

/// Fingerprints of the files that were identical on both sides after the last run, keyed by relative path.
/// Two-way analysis uses it to tell which side changed.
public struct FolderSyncBaseline: Codable, Equatable, Sendable {
    public var entries: [String: FolderSyncFingerprint]

    public init(entries: [String: FolderSyncFingerprint] = [:]) {
        self.entries = entries
    }
}

public enum FolderSyncItemKind: String, Codable, Sendable {
    /// Symbolic links are synced as links, never followed.
    case file, directory, symbolicLink
}

/// One scanned item on one side. Folders carry size 0.
public struct FolderSyncEntry: Equatable, Sendable {
    /// Relative to that side's folder, spelled as the name is stored on that disk.
    public var relativePath: String
    public var kind: FolderSyncItemKind
    public var fingerprint: FolderSyncFingerprint

    public init(relativePath: String, kind: FolderSyncItemKind, fingerprint: FolderSyncFingerprint) {
        self.relativePath = relativePath
        self.kind = kind
        self.fingerprint = fingerprint
    }
}

public enum FolderSyncAction: String, Codable, Sendable {
    case copyToLeft, copyToRight, updateLeft, updateRight, skip, conflict
}

public enum FolderSyncConflictReason: String, Codable, Sendable {
    /// Both sides differ from the baseline fingerprint.
    case bothChanged
    /// Two-way: both sides have the file, they differ, and no baseline says which one changed.
    case differentWithoutBaseline
    /// A file on one side and a folder (or a file and a symbolic link) on the other.
    case typeMismatch
    /// Names that differ only in letter case, which a case-insensitive side cannot hold apart.
    case caseCollision
}

public enum FolderSyncConflictDecision: String, Codable, Sendable {
    case keepLeft, keepRight, keepBoth, skip
}

public struct FolderSyncAnalysisItem: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    /// Display path and the key for conflict decisions.
    public var relativePath: String
    public var left: FolderSyncEntry?
    public var right: FolderSyncEntry?
    public var action: FolderSyncAction
    /// Why the item is a conflict, or why a one-way run skips it (type mismatches and case collisions).
    public var conflictReason: FolderSyncConflictReason?
    /// Where the item is, or will be created, on each side. Differs from `relativePath` at most in letter case.
    public var leftPath: String
    public var rightPath: String

    public init(relativePath: String, left: FolderSyncEntry?, right: FolderSyncEntry?, action: FolderSyncAction,
                conflictReason: FolderSyncConflictReason? = nil, leftPath: String? = nil, rightPath: String? = nil) {
        self.relativePath = relativePath
        self.left = left
        self.right = right
        self.action = action
        self.conflictReason = conflictReason
        self.leftPath = leftPath ?? left?.relativePath ?? relativePath
        self.rightPath = rightPath ?? right?.relativePath ?? relativePath
    }
}

public struct FolderSyncAnalysis: Identifiable, Sendable {
    public var id: UUID
    public var preset: FolderSyncPreset
    /// The baseline the comparison used; apply carries its entries forward for items it does not sync.
    public var baseline: FolderSyncBaseline?
    public var createdAt: Date
    /// Sorted by relative path, so folders come before their contents. Folders present on both sides are omitted.
    public var items: [FolderSyncAnalysisItem]
    /// Folders below either root that could not be listed; nothing inside them is in `items`.
    public var unreadableFolders: [URL]
    public var leftIsCaseSensitive: Bool
    public var rightIsCaseSensitive: Bool

    /// Whether relative paths were paired by exact spelling rather than ignoring letter case.
    var matchesCaseSensitively: Bool {
        preset.caseSensitivity == .sensitive || (leftIsCaseSensitive && rightIsCaseSensitive)
    }

    public var copyLeftCount: Int { count(.copyToLeft) }
    public var copyRightCount: Int { count(.copyToRight) }
    public var updateCount: Int { count(.updateLeft, .updateRight) }
    public var conflictCount: Int { count(.conflict) }
    public var conflicts: [FolderSyncAnalysisItem] { items.filter { $0.action == .conflict } }
    public var hasChanges: Bool { items.contains { $0.action != .skip } }

    private func count(_ actions: FolderSyncAction...) -> Int {
        items.reduce(0) { $0 + (actions.contains($1.action) ? 1 : 0) }
    }
}

public struct FolderSyncLimits: Codable, Equatable, Sendable {
    /// Items scanned in each folder.
    public var maximumItemCount: Int

    public init(maximumItemCount: Int = 100_000) {
        self.maximumItemCount = maximumItemCount
    }

    public static let `default` = FolderSyncLimits()
}

public struct FolderSyncProgress: Sendable {
    public var processedItemCount: Int
    public var totalItemCount: Int
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var currentRelativePath: String?
}

public struct FolderSyncItemFailure: Codable, Equatable, Sendable {
    public var relativePath: String
    public var message: String
}

public enum FolderSyncRunOutcome: String, Codable, Sendable {
    case completed, completedWithIssues, cancelled, failed
}

public struct FolderSyncRunSummary: Codable, Sendable {
    public var presetID: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: FolderSyncRunOutcome
    /// Items written to each side, updates and keep-both copies included.
    public var copiedToLeftCount: Int
    public var copiedToRightCount: Int
    public var failures: [FolderSyncItemFailure]
    /// Every file known to be identical on both sides afterwards; store it for the next analysis.
    /// Items that were skipped, failed or not reached keep their previous baseline entry.
    public var baseline: FolderSyncBaseline
}

public enum FolderSyncError: Error, Equatable, Sendable {
    case invalidName
    case folderMissing(URL)
    case folderUnreadable(URL)
    case folderNotWritable(URL)
    case sameFolder
    case nestedFolders
    case scanLimitExceeded
    case insufficientSpace(needed: Int64, available: Int64)
    case staleAnalysis
    case unresolvedConflicts

    public var message: String {
        switch self {
        case .invalidName: "Enter a name for this sync preset."
        case .folderMissing(let url): "The folder could not be found: \(url.path)"
        case .folderUnreadable(let url): "The folder could not be read. Check its permissions and connection: \(url.path)"
        case .folderNotWritable(let url): "The folder is not writable: \(url.path)"
        case .sameFolder: "Choose two different folders."
        case .nestedFolders: "One sync folder cannot be inside the other."
        case .scanLimitExceeded: "This folder contains too many items to sync safely."
        case .insufficientSpace(let needed, let available):
            "There is not enough free space to complete this sync: \(needed) bytes are needed and \(available) are available."
        case .staleAnalysis: "The folder contents changed. Review the updated preview before syncing."
        case .unresolvedConflicts: "Choose how to handle every conflict before syncing."
        }
    }
}

/// Compiled filter rules.
struct FolderSyncFilterSet {
    /// The three strings a rule can look at, NFC-normalized and lowercased.
    struct Targets {
        let name: [Character]
        let fileExtension: [Character]
        let path: [Character]

        init(_ relativePath: String) {
            let path = relativePath.precomposedStringWithCanonicalMapping.lowercased()
            let name = (path as NSString).lastPathComponent
            self.path = Array(path)
            self.name = Array(name)
            fileExtension = Array((name as NSString).pathExtension)
        }
    }

    struct Compiled {
        let target: FolderSyncFilterTarget
        let pattern: [Character]

        /// nil for a rule with nothing to match, which is treated as incomplete and ignored.
        init?(_ rule: FolderSyncFilterRule) {
            var pattern = rule.pattern.precomposedStringWithCanonicalMapping.lowercased()
            switch rule.target {
            case .fileName: break
            case .fileExtension: if pattern.hasPrefix(".") { pattern.removeFirst() }
            case .relativePath: pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            guard !pattern.isEmpty else { return nil }
            target = rule.target
            self.pattern = Array(pattern)
        }

        func matches(_ targets: Targets) -> Bool {
            switch target {
            case .fileName: FolderSyncFilterSet.wildcardMatches(pattern, targets.name)
            case .fileExtension: FolderSyncFilterSet.wildcardMatches(pattern, targets.fileExtension)
            case .relativePath: FolderSyncFilterSet.wildcardMatches(pattern, targets.path)
            }
        }
    }

    private let includes: [Compiled]
    private let excludes: [Compiled]

    init(_ rules: [FolderSyncFilterRule]) {
        includes = rules.filter { $0.kind == .include }.compactMap(Compiled.init)
        excludes = rules.filter { $0.kind == .exclude }.compactMap(Compiled.init)
    }

    var hasIncludeRules: Bool { !includes.isEmpty }

    /// Whether the scan keeps the item. Include rules only apply to files.
    func admits(_ relativePath: String, isDirectory: Bool) -> Bool {
        guard !excludes.isEmpty || (hasIncludeRules && !isDirectory) else { return true }
        let targets = Targets(relativePath)
        if excludes.contains(where: { $0.matches(targets) }) { return false }
        return isDirectory || includes.isEmpty || includes.contains { $0.matches(targets) }
    }

    /// Greedy wildcard match with backtracking to the last `*`.
    static func wildcardMatches(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var star = -1, resume = 0
        while t < text.count {
            if p < pattern.count && pattern[p] == "*" {
                star = p
                resume = t
                p += 1
            } else if p < pattern.count && (pattern[p] == "?" || pattern[p] == text[t]) {
                p += 1
                t += 1
            } else if star >= 0 {
                p = star + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
