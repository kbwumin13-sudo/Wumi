import Foundation

/// Date range for the Recent destination.
public struct RecentDateFilter: Codable, Hashable, Sendable {
    public enum Period: String, Codable, CaseIterable, Sendable {
        case week, month, custom
    }

    public var period: Period
    public var startDate: Date
    public var endDate: Date

    public init(period: Period, startDate: Date, endDate: Date) {
        self.period = period
        self.startDate = startDate
        self.endDate = endDate
    }

    public static func preset(_ period: Period, now: Date = Date()) -> RecentDateFilter {
        RecentDateFilter(period: period, startDate: now, endDate: now)
    }

    /// Effective lower bound for preset periods; custom ranges use the stored dates.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch period {
        case .week:
            DateInterval(start: calendar.date(byAdding: .day, value: -7, to: now) ?? now, end: now)
        case .month:
            DateInterval(start: calendar.date(byAdding: .day, value: -30, to: now) ?? now, end: now)
        case .custom:
            DateInterval(start: min(startDate, endDate), end: max(startDate, endDate))
        }
    }
}

/// Where a pane is pointed. Encoded with a `kind` discriminator like the original session files.
public enum PaneDestination: Hashable, Sendable {
    case directory(URL)
    case recent(RecentDateFilter)
    case tag(String)
    case allSubfiles(URL)

    public var directoryURL: URL? {
        switch self {
        case .directory(let url), .allSubfiles(let url): url
        case .recent, .tag: nil
        }
    }
}

extension PaneDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, directory, recent, tag, allSubfiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "recent": self = .recent(try c.decode(RecentDateFilter.self, forKey: .recent))
        case "tag": self = .tag(try c.decode(String.self, forKey: .tag))
        case "allSubfiles": self = .allSubfiles(try c.decode(URL.self, forKey: .allSubfiles))
        default: self = .directory(try c.decode(URL.self, forKey: .directory))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let url):
            try c.encode("directory", forKey: .kind)
            try c.encode(url, forKey: .directory)
        case .recent(let filter):
            try c.encode("recent", forKey: .kind)
            try c.encode(filter, forKey: .recent)
        case .tag(let name):
            try c.encode("tag", forKey: .kind)
            try c.encode(name, forKey: .tag)
        case .allSubfiles(let url):
            try c.encode("allSubfiles", forKey: .kind)
            try c.encode(url, forKey: .allSubfiles)
        }
    }
}

/// Back/forward stack of one pane.
public struct NavigationHistory: Codable, Equatable, Sendable {
    public var entries: [PaneDestination]
    public var currentIndex: Int

    public static let maximumEntries = 100

    public init(entries: [PaneDestination], currentIndex: Int) {
        self.entries = entries
        self.currentIndex = min(max(currentIndex, 0), max(entries.count - 1, 0))
    }

    public init(start: PaneDestination) {
        self.init(entries: [start], currentIndex: 0)
    }

    public var current: PaneDestination? { entries.indices.contains(currentIndex) ? entries[currentIndex] : nil }
    public var canGoBack: Bool { currentIndex > 0 }
    public var canGoForward: Bool { currentIndex < entries.count - 1 }

    /// Pushes a destination, discarding the forward stack. Re-visiting the current entry is a no-op.
    public mutating func visit(_ destination: PaneDestination) {
        if current == destination { return }
        if canGoForward { entries.removeSubrange((currentIndex + 1)...) }
        entries.append(destination)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        currentIndex = entries.count - 1
    }

    public mutating func goBack() -> PaneDestination? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return current
    }

    public mutating func goForward() -> PaneDestination? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return current
    }
}

/// Persisted state of one browser pane.
public struct BrowserPaneState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var history: NavigationHistory
    public var viewConfiguration: ViewConfiguration
    public var searchText: String
    public var searchMode: SearchInputMode
    public var searchRecursively: Bool
    public var selectedIdentities: [FileIdentity]
    public var expandedPaths: [String]
    /// Grouping and folders-first used by folders without remembered rules (nil in sessions saved before it existed).
    public var folderDisplayBaseline: FolderDisplayBaseline?
    /// Path of the first visible item, so a restored pane opens scrolled where it was (the original's `scrollAnchor`).
    public var scrollAnchor: String?

    public init(id: UUID = UUID(), destination: PaneDestination, viewConfiguration: ViewConfiguration = ViewConfiguration()) {
        self.id = id
        self.history = NavigationHistory(start: destination)
        self.viewConfiguration = viewConfiguration
        self.searchText = ""
        self.searchMode = .keyword
        self.searchRecursively = true
        self.selectedIdentities = []
        self.expandedPaths = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        history = try c.decode(NavigationHistory.self, forKey: .history)
        viewConfiguration = try c.decodeIfPresent(ViewConfiguration.self, forKey: .viewConfiguration) ?? ViewConfiguration()
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        searchMode = try c.decodeIfPresent(SearchInputMode.self, forKey: .searchMode) ?? .keyword
        searchRecursively = try c.decodeIfPresent(Bool.self, forKey: .searchRecursively) ?? true
        selectedIdentities = try c.decodeIfPresent([FileIdentity].self, forKey: .selectedIdentities) ?? []
        expandedPaths = try c.decodeIfPresent([String].self, forKey: .expandedPaths) ?? []
        folderDisplayBaseline = try? c.decodeIfPresent(FolderDisplayBaseline.self, forKey: .folderDisplayBaseline)
        scrollAnchor = try? c.decodeIfPresent(String.self, forKey: .scrollAnchor)
    }
}

/// One tab: a pane layout plus its panes.
public struct WorkspaceTab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var customTitle: String?
    public var layout: PaneLayout
    public var panes: [BrowserPaneState]
    public var activePaneID: UUID
    public var splitRatios: [Double]
    public var isPinned: Bool
    public var namedWorkspaceID: UUID?

    public init(id: UUID = UUID(), pane: BrowserPaneState) {
        self.id = id
        self.title = ""
        self.customTitle = nil
        self.layout = .single
        self.panes = [pane]
        self.activePaneID = pane.id
        self.splitRatios = []
        self.isPinned = false
        self.namedWorkspaceID = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        layout = try c.decodeIfPresent(PaneLayout.self, forKey: .layout) ?? .single
        panes = try c.decode([BrowserPaneState].self, forKey: .panes)
        activePaneID = try c.decodeIfPresent(UUID.self, forKey: .activePaneID) ?? panes.first?.id ?? UUID()
        splitRatios = try c.decodeIfPresent([Double].self, forKey: .splitRatios) ?? []
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        namedWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .namedWorkspaceID)
    }
}

/// Everything needed to restore one window.
public struct WindowSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [WorkspaceTab]
    public var activeTabID: UUID
    public var inspectorVisible: Bool
    public var closedTabs: [WorkspaceTab]

    public static let maximumTabs = 50
    public static let maximumClosedTabs = 20

    public init(id: UUID = UUID(), tabs: [WorkspaceTab], activeTabID: UUID, inspectorVisible: Bool = true) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.inspectorVisible = inspectorVisible
        self.closedTabs = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tabs = try c.decode([WorkspaceTab].self, forKey: .tabs)
        activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID) ?? tabs.first?.id ?? UUID()
        inspectorVisible = try c.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? true
        closedTabs = try c.decodeIfPresent([WorkspaceTab].self, forKey: .closedTabs) ?? []
    }
}
