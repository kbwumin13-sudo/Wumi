import AppKit
import DirDeskCore

/// An immutable input: background derivation never reads live pane state.
struct PaneRowDerivation: Sendable {
    let items: [FileItem]
    let children: [String: [FileItem]]
    let expandedPaths: Set<String>
    let configuration: ViewConfiguration
    let searchText: String
    let locale: Locale
    let folderTitle: String
    let aliasTitle: String
    let fileTitle: String
    var directorySizes: [String: Int64] = [:]

    struct Output: Sendable {
        var displayItems: [FileItem]
        var children: [String: [FileItem]]
        var groups: [FileGroup]
        var rows: [PaneRuntime.Row]
        var visibleIDs: Set<FileIdentity>
    }

    /// Only bounded, in-memory work may run synchronously. Kind resolution and Launch Services stay off-main.
    var canRunSynchronously: Bool {
        let count = children.values.reduce(items.count) { $0 + $1.count }
        return count <= 256 && configuration.sortKey != .kind
            && configuration.groupingMode != .kind && configuration.groupingMode != .application
    }

    func build() throws -> Output {
        try Task.checkCancellation()
        let options = FileSortOptions(configuration)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var kinds: [String: String] = [:]
        func kind(_ item: FileItem) -> String {
            // The description is determined by these flags and the extension, not by a file-system lookup.
            let key = "\(item.isBrowsableFolder):\(item.isAliasFile):\(item.fileExtension)"
            if let value = kinds[key] { return value }
            let value = FileKindDescriber.describe(item, folderTitle: folderTitle, aliasTitle: aliasTitle, fileTitle: fileTitle)
            kinds[key] = value
            return value
        }
        func sortedVisible(_ list: [FileItem]) throws -> [FileItem] {
            try Task.checkCancellation()
            let visible = list.filter {
                (configuration.showsHiddenFiles || !$0.isHidden)
                    && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
            }
            let measured = directorySizes.isEmpty ? visible : visible.map { item in
                var value = item
                if item.isDirectory, !item.isSymbolicLink, let size = directorySizes[item.url.path] { value.size = size }
                return value
            }
            let sorted = FileSorter.sort(measured, options: options, kind: kind)
            try Task.checkCancellation()
            return sorted
        }
        let top = try sortedVisible(items)
        var sortedChildren: [String: [FileItem]] = [:]
        for (path, list) in children where expandedPaths.contains(path) {
            sortedChildren[path] = try sortedVisible(list)
        }
        var applicationNames: [URL: String] = [:]
        let groups: [FileGroup]
        if configuration.groupingMode == .none {
            groups = []
        } else {
            groups = FileGrouping.group(top, mode: configuration.groupingMode,
                                        pinnedPaths: options.pinnedPaths, locale: locale, kind: kind,
                                        application: { item in
                guard !Task.isCancelled, let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) else { return nil }
                if let cached = applicationNames[app] { return cached }
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                applicationNames[app] = name
                return name
            })
        }
        try Task.checkCancellation()
        var rows: [PaneRuntime.Row] = []
        var visibleIDs = Set<FileIdentity>()
        func appendTree(_ item: FileItem, depth: Int) throws {
            if rows.count % 256 == 0 { try Task.checkCancellation() }
            rows.append(.item(item, depth: depth))
            visibleIDs.insert(item.id)
            if item.isBrowsableFolder, expandedPaths.contains(item.url.path), let kids = sortedChildren[item.url.path] {
                for child in kids { try appendTree(child, depth: depth + 1) }
            }
        }
        if configuration.groupingMode == .none {
            for item in top { try appendTree(item, depth: 0) }
        } else {
            for group in groups {
                rows.append(.group(group.id, title: group.isLiteral ? group.title : L(group.title), count: group.items.count))
                for item in group.items { try appendTree(item, depth: 0) }
            }
        }
        return Output(displayItems: top, children: sortedChildren, groups: groups, rows: rows, visibleIDs: visibleIDs)
    }
}
