import AppKit
import Combine

enum SearchMode: CaseIterable, Identifiable {
    case all, apps, files, clipboard

    static let categories: [Self] = [.apps, .files, .clipboard]
    var id: Self { self }
    var searchesIndex: Bool { self == .all || self == .files }
    var title: String {
        switch self {
        case .all: return "全部"
        case .apps: return "应用程序"
        case .files: return "文件"
        case .clipboard: return "剪贴板"
        }
    }
    var shortTitle: String {
        switch self {
        case .all: return "全部"
        case .apps: return "应用"
        case .files: return "文件"
        case .clipboard: return "剪贴板"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "magnifyingglass"
        case .apps: return "square.grid.2x2"
        case .files: return "folder"
        case .clipboard: return "document.on.document"
        }
    }
    var key: String {
        switch self {
        case .all: return "0"
        case .apps: return "1"
        case .files: return "2"
        case .clipboard: return "3"
        }
    }
}

/// Exact macOS Spotlight Applications categories (ordered identically to Spotlight).
enum AppCategory: String, CaseIterable, Identifiable, Sendable {
    case developerTools, social, productivityFinance, utilities, creative, entertainment, games, informationReading, other

    var id: Self { self }
    var title: String {
        switch self {
        case .developerTools: return "开发者工具"
        case .social: return "社交"
        case .productivityFinance: return "效率与财务"
        case .utilities: return "工具"
        case .creative: return "创意"
        case .entertainment: return "娱乐"
        case .games: return "游戏"
        case .informationReading: return "信息与阅读"
        case .other: return "其他"
        }
    }

    init(identifier: String) {
        let raw = identifier.split(separator: ".").last.map(String.init) ?? ""
        switch raw {
        case "developer-tools": self = .developerTools
        case "social-networking": self = .social
        case "productivity", "business", "finance": self = .productivityFinance
        case "utilities": self = .utilities
        case "graphics-design", "photography", "video", "music": self = .creative
        case "entertainment", "sports", "lifestyle", "travel", "food-and-drink": self = .entertainment
        case "games", "action-games", "adventure-games", "arcade-games", "board-games",
             "card-games", "casino-games", "dice-games", "educational-games", "family-games",
             "kids-games", "music-games", "puzzle-games", "racing-games", "role-playing-games",
             "simulation-games", "sports-games", "strategy-games", "trivia-games", "word-games":
            self = .games
        case "news", "reference", "books", "education", "weather", "navigation", "books-and-reference", "magazines-and-newspapers":
            self = .informationReading
        default: self = .other
        }
    }
}

struct InstalledApp: Identifiable, Sendable {
    static let gridColumns = 7
    let url: URL
    let title: String
    let category: AppCategory
    let searchableNames: [String]
    var id: URL { url }

    static func catalog() -> [Self] {
        let manager = FileManager.default
        let directories = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                           URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                           manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .localizedNameKey]
        var seen = Set<URL>()
        var apps: [Self] = []
        for directory in directories {
            guard let children = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in children where url.pathExtension.lowercased() == "app" {
                children.skipDescendants()
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(resolved).inserted, let bundle = Bundle(url: resolved),
                      bundle.executableURL != nil else { continue }
                let fallback = url.deletingPathExtension().lastPathComponent
                let displayed = (try? url.resourceValues(forKeys: keys))?.localizedName
                let name = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, displayed]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? fallback
                let title = name.hasSuffix(".app") && name.count > 4 ? String(name.dropLast(4)) : name
                let category = AppCategory(identifier: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? "")
                let names = [title, fallback] + (bundle.bundleIdentifier.map { [$0] } ?? [])
                let transliteration = title.applyingTransform(.mandarinToLatin, reverse: false) ?? ""
                let syllables = transliteration.split(whereSeparator: \.isWhitespace)
                let aliases = names + [syllables.joined(), String(syllables.compactMap(\.first))]
                apps.append(Self(url: resolved, title: title, category: category, searchableNames: aliases))
            }
        }
        return apps.sorted { left, right in
            let order = left.title.localizedStandardCompare(right.title)
            return order == .orderedSame ? left.url.path < right.url.path : order == .orderedAscending
        }
    }
}

enum ClipboardPayload: Equatable {
    case text(String), files([URL]), image(Data, NSPasteboard.PasteboardType)

    var byteCount: Int {
        switch self {
        case .text(let value): return value.utf8.count
        case .files(let urls): return urls.reduce(0) { $0 + $1.path.utf8.count }
        case .image(let data, _): return data.count
        }
    }

    var searchableText: String {
        switch self {
        case .text(let value): return value
        case .files(let values): return values.map(\.path).joined(separator: "\n")
        case .image: return "图片"
        }
    }

    var title: String {
        switch self {
        case .text(let value): return String(value.prefix(140))
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: "、")
        case .image: return "图片"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .files: return "doc"
        case .image: return "photo"
        }
    }

    static func read(from pasteboard: NSPasteboard) -> Self? {
        let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !(pasteboard.types ?? []).contains(where: { privateTypes.contains($0.rawValue) }) else { return nil }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.count <= 64 { return .files(urls) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty, text.utf8.count <= 256 * 1024 { return .text(text) }
        for type: NSPasteboard.PasteboardType in [.png, .tiff] {
            if let data = pasteboard.data(forType: type), !data.isEmpty, data.count <= 4 * 1024 * 1024 { return .image(data, type) }
        }
        return nil
    }

    @discardableResult
    func copy(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        switch self {
        case .text(let value): return pasteboard.setString(value, forType: .string)
        case .files(let urls): return pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .image(let data, let type): return pasteboard.setData(data, forType: type)
        }
    }
}

struct ClipboardEntry: Identifiable {
    let id = UUID()
    let payload: ClipboardPayload
    let date = Date()
}

@MainActor
final class BrowseContent: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var runningURLs: [URL] = []
    @Published private(set) var loadingApps = false
    @Published var appCategory: AppCategory? { didSet { appSelection = nil } }
    @Published var appSelection: URL?
    @Published private(set) var history: [ClipboardEntry] = []
    @Published private(set) var recordingClipboard = false
    @Published var clipboardSelection: UUID?
    private var clipboardTimer: AnyCancellable?
    private var changeCount = 0
    private let pasteboard: NSPasteboard?

    init(pasteboard: NSPasteboard? = nil) { self.pasteboard = pasteboard }

    func loadApps() {
        guard !loadingApps else { return }
        runningURLs = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL }
        loadingApps = true
        Task {
            apps = await Task.detached(priority: .userInitiated) { InstalledApp.catalog() }.value
            if let appCategory, !appCategories.contains(appCategory) { self.appCategory = nil }
            loadingApps = false
        }
    }

    var appCategories: [AppCategory] {
        let available = Set(apps.map(\.category))
        return AppCategory.allCases.filter { available.contains($0) }
    }

    func appSections(query: String) -> (running: [InstalledApp], others: [InstalledApp]) {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = apps.filter { app in
            (appCategory == nil || app.category == appCategory) &&
                terms.allSatisfy { term in app.searchableNames.contains { $0.localizedStandardContains(term) } }
        }
        guard terms.isEmpty, appCategory == nil else { return ([], filtered) }
        let byURL = Dictionary(uniqueKeysWithValues: filtered.map { ($0.url, $0) })
        let running = Array(runningURLs.compactMap { byURL[$0] }.prefix(InstalledApp.gridColumns))
        let runningSet = Set(running.map(\.url))
        return (running, filtered.filter { !runningSet.contains($0.url) })
    }

    func visibleApps(query: String) -> [InstalledApp] {
        let sections = appSections(query: query)
        return sections.running + sections.others
    }

    func visibleClipboard(query: String) -> [ClipboardEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return history.filter { entry in terms.allSatisfy { entry.payload.searchableText.localizedStandardContains($0) } }
    }

    func queryChanged() {
        appSelection = nil
        clipboardSelection = nil
    }

    func moveApps(_ step: Int, query: String) {
        let sections = appSections(query: query)
        let ordered = sections.running + sections.others
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == appSelection }
        var next = self.nextIndex(current: current, count: ordered.count, by: step)
        if let current, step == InstalledApp.gridColumns, current < sections.running.count {
            let column = current % step
            if !sections.others.isEmpty {
                next = sections.running.count + min(column, sections.others.count - 1)
            }
        } else if let current, step == -InstalledApp.gridColumns, !sections.running.isEmpty,
                  current >= sections.running.count, current - sections.running.count < -step {
            next = min(sections.running.count - 1, current - sections.running.count)
        }
        appSelection = ordered[next].id
    }

    func moveClipboard(_ step: Int, query: String) {
        let entries = visibleClipboard(query: query)
        guard !entries.isEmpty else { return }
        let next = nextIndex(current: entries.firstIndex { $0.id == clipboardSelection }, count: entries.count, by: step)
        clipboardSelection = entries[next].id
    }

    private func nextIndex(current: Int?, count: Int, by step: Int) -> Int {
        guard let current else { return step > 0 ? 0 : count - 1 }
        return min(max(0, current + step), count - 1)
    }

    func setClipboardRecording(_ enabled: Bool) {
        guard recordingClipboard != enabled else { return }
        recordingClipboard = enabled
        clipboardTimer = nil
        guard enabled else { return }
        changeCount = (pasteboard ?? .general).changeCount
        clipboardTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func checkClipboard() {
        guard recordingClipboard else { return }
        let pasteboard = self.pasteboard ?? .general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let payload = ClipboardPayload.read(from: pasteboard) else { return }
        history.removeAll { $0.payload == payload }
        history.insert(ClipboardEntry(payload: payload), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        var bytes = history.reduce(0) { $0 + $1.payload.byteCount }
        while bytes > 16 * 1024 * 1024 { bytes -= history.removeLast().payload.byteCount }
        if let clipboardSelection, !history.contains(where: { $0.id == clipboardSelection }) { self.clipboardSelection = nil }
    }

    func clearClipboardHistory() {
        history = []
        clipboardSelection = nil
    }

    @discardableResult
    func copyClipboardEntry(_ entry: ClipboardEntry) -> Bool {
        let pasteboard = self.pasteboard ?? .general
        let copied = entry.payload.copy(to: pasteboard)
        changeCount = pasteboard.changeCount
        return copied
    }
}

enum BrowseAppIcon {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let defaultAppCache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if let icon = cache.object(forKey: url as NSURL) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url as NSURL)
        return icon
    }

    /// Small default-app badge for Spotlight-style file thumbnails.
    static func defaultAppBadge(forFilePath path: String, fileExtension: String) -> NSImage? {
        let key = (fileExtension.isEmpty ? path : fileExtension.lowercased()) as NSString
        if let cached = defaultAppCache.object(forKey: key) { return cached }
        let fileURL = URL(fileURLWithPath: path)
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 20, height: 20)
        defaultAppCache.setObject(icon, forKey: key)
        return icon
    }
}
