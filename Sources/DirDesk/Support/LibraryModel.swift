import AppKit
import Combine
import DirDeskCore

/// Shared navigation libraries: bookmarks, Common Paths and recent activity.
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    @Published private(set) var bookmarks: BookmarkLibrary
    @Published private(set) var commonPaths: [CommonPathEntry]
    @Published private(set) var recent: [RecentActivityRecord]
    @Published var lastError: String?

    private let bookmarkStore = PersistenceStore<BookmarkLibrary>(key: DefaultsKey.bookmarks) { .initial }
    private let commonPathStore = PersistenceStore<[CommonPathEntry]>(key: DefaultsKey.commonPaths) { CommonPathEntry.defaults }
    private let recentStore = PersistenceStore<[RecentActivityRecord]>(key: DefaultsKey.recentActivity) { [] }

    private init() {
        var loadedBookmarks = bookmarkStore.load().value
        if loadedBookmarks.defaultFolder == nil {
            loadedBookmarks.nodes.insert(BookmarkLibrary.initial.nodes[0], at: 0)
        }
        bookmarks = loadedBookmarks
        commonPaths = commonPathStore.load().value
        recent = recentStore.load().value
    }

    // MARK: Bookmarks

    func mutateBookmarks(_ change: (inout BookmarkLibrary) throws -> Void) {
        var copy = bookmarks
        do {
            try change(&copy)
            bookmarks = copy
            try bookmarkStore.save(copy)
        } catch let error as BookmarkLibrary.LibraryError {
            lastError = Self.message(error)
            NSSound.beep()
        } catch {
            lastError = L("Bookmarks could not be saved. Check available storage and try again.")
        }
    }

    /// Adds bookmarks to `parent` (the default folder when nil), or to the Bookmarks Bar itself with `toBar`.
    /// URLs that are already bookmarked are skipped. `titles` overrides the display names, index by index.
    func addBookmarks(_ urls: [URL], to parent: UUID? = nil, titles: [String]? = nil, toBar: Bool = false) {
        let destination = toBar ? nil : (parent ?? bookmarks.defaultFolder?.id)
        mutateBookmarks { library in
            for (index, url) in urls.enumerated() where !library.contains(url: url) {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let kind: BookmarkLibrary.TargetKind = isDirectory.boolValue ? .folder : .file
                let title = titles.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? PathUtilities.displayName(for: url)
                try library.add(title: title, payload: .target(.init(url: url, kind: kind)), parent: destination)
            }
        }
    }

    func addBookmarkFolder(named name: String, parent: UUID?) {
        mutateBookmarks { try $0.add(title: name, payload: .folder, parent: parent) }
    }

    static func message(_ error: BookmarkLibrary.LibraryError) -> String {
        switch error {
        case .emptyTitle: L("A bookmark name cannot be empty.")
        case .cyclicParentage: L("A bookmark folder cannot be moved into itself or one of its subfolders.")
        case .maximumDepthExceeded: L("Bookmark folders can be nested up to 64 levels.")
        case .tooManyNodes: L("The bookmark library has reached its item limit.")
        case .nodeNotFound: L("The selected bookmark no longer exists.")
        case .parentNotFound, .parentIsNotFolder: L("The destination bookmark folder is no longer available.")
        }
    }

    // MARK: Common Paths

    func addCommonPath(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastError = L("Only folders can be added to Common Paths.")
            return
        }
        guard !commonPaths.contains(where: { $0.url.hasSamePath(as: url) }) else {
            lastError = L("Already in Common Paths")
            return
        }
        guard commonPaths.count < CommonPathEntry.maximumCount else {
            lastError = L("You have reached the Common Paths limit.")
            return
        }
        commonPaths.append(.folder(url: url, title: PathUtilities.displayName(for: url)))
        saveCommonPaths()
    }

    func addBuiltInCommonPath(_ name: String) {
        guard !commonPaths.contains(.builtIn(name)) else { return }
        commonPaths.append(.builtIn(name))
        saveCommonPaths()
    }

    func removeCommonPath(_ entry: CommonPathEntry) {
        commonPaths.removeAll { $0 == entry }
        saveCommonPaths()
    }

    func moveCommonPath(from source: IndexSet, to destination: Int) {
        commonPaths.move(fromOffsets: source, toOffset: destination)
        saveCommonPaths()
    }

    private func saveCommonPaths() {
        do { try commonPathStore.save(commonPaths) } catch { lastError = L("Common Paths could not be saved.") }
    }

    // MARK: Recent

    func recordVisit(_ url: URL) {
        recent = RecentActivityRecord.recording(url, in: recent)
        try? recentStore.save(recent)
    }

    func clearRecent() {
        recent = []
        try? recentStore.save(recent)
    }
}

extension BookmarkLibrary.Node {
    /// The built-in folder is stored as "Default" and shown in the interface language until the user renames it.
    var displayTitle: String {
        builtInRole == .defaultFolder && title == BookmarkLibrary.defaultFolderTitle ? L("Default") : title
    }
}
