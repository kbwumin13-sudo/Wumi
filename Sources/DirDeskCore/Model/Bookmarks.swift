import Foundation

/// Hierarchical bookmark library (folders and targets), stored as `dirdesk-bookmarks-v2`.
public struct BookmarkLibrary: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumDepth = 64
    public static let maximumNodes = 5000

    public enum BuiltInRole: String, Codable, Sendable {
        case defaultFolder
    }

    public enum TargetKind: String, Codable, Sendable {
        case folder, file
    }

    public struct Target: Codable, Equatable, Sendable {
        public var url: URL
        public var kind: TargetKind
        public init(url: URL, kind: TargetKind) {
            self.url = url
            self.kind = kind
        }
    }

    public enum Payload: Codable, Equatable, Sendable {
        case folder
        case target(Target)

        private enum CodingKeys: String, CodingKey { case folder, target }
        private struct Empty: Codable {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let target = try c.decodeIfPresent(Target.self, forKey: .target) {
                self = .target(target)
            } else {
                self = .folder
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .folder: try c.encode(Empty(), forKey: .folder)
            case .target(let target): try c.encode(target, forKey: .target)
            }
        }
    }

    public struct Node: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var parentID: UUID?
        public var title: String
        public var order: Int
        public var payload: Payload
        public var builtInRole: BuiltInRole?

        public var isFolder: Bool { if case .folder = payload { return true } else { return false } }
        public var target: Target? { if case .target(let t) = payload { return t } else { return nil } }
    }

    public enum LibraryError: Error, Equatable {
        case emptyTitle, nodeNotFound, parentNotFound, parentIsNotFolder, cyclicParentage, maximumDepthExceeded, tooManyNodes
    }

    public var nodes: [Node]
    public var schemaVersion: Int = BookmarkLibrary.schemaVersion

    public init(nodes: [Node]) {
        self.nodes = nodes
    }

    /// Stored title of the built-in folder; the app shows it localized until the user renames the folder.
    public static let defaultFolderTitle = "Default"

    public static var initial: BookmarkLibrary {
        BookmarkLibrary(nodes: [Node(id: UUID(), parentID: nil, title: defaultFolderTitle, order: 0, payload: .folder, builtInRole: .defaultFolder)])
    }

    public var defaultFolder: Node? { nodes.first { $0.builtInRole == .defaultFolder } }

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }

    public func children(of parent: UUID?) -> [Node] {
        nodes.filter { $0.parentID == parent }.sorted { $0.order < $1.order }
    }

    public var roots: [Node] { children(of: nil) }

    /// Folders in outline order with their depth, leaving out `excluded` and everything inside it (a folder cannot
    /// move into itself). Feeds the "Move to" menus and the Add Bookmark location list.
    public func folderOutline(excluding excluded: UUID? = nil) -> [(node: Node, depth: Int)] {
        var result: [(node: Node, depth: Int)] = []
        func visit(_ parent: UUID?, depth: Int) {
            for node in children(of: parent) where node.isFolder && node.id != excluded {
                result.append((node, depth))
                if depth < Self.maximumDepth { visit(node.id, depth: depth + 1) }
            }
        }
        visit(nil, depth: 0)
        return result
    }

    func depth(of id: UUID) -> Int {
        var depth = 0
        var current = node(id)?.parentID
        while let parent = current {
            depth += 1
            current = node(parent)?.parentID
            if depth > Self.maximumDepth + 1 { break }
        }
        return depth
    }

    /// Adds a node at the end of `parent` (nil = top level).
    @discardableResult
    public mutating func add(title: String, payload: Payload, parent: UUID?) throws -> Node {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyTitle }
        guard nodes.count < Self.maximumNodes else { throw LibraryError.tooManyNodes }
        if let parent {
            guard let parentNode = node(parent) else { throw LibraryError.parentNotFound }
            guard parentNode.isFolder else { throw LibraryError.parentIsNotFolder }
            guard depth(of: parent) + 1 < Self.maximumDepth else { throw LibraryError.maximumDepthExceeded }
        }
        let order = (children(of: parent).map(\.order).max() ?? -1) + 1
        let new = Node(id: UUID(), parentID: parent, title: trimmed, order: order, payload: payload, builtInRole: nil)
        nodes.append(new)
        return new
    }

    public mutating func rename(_ id: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyTitle }
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw LibraryError.nodeNotFound }
        nodes[index].title = trimmed
    }

    public mutating func updateTarget(_ id: UUID, url: URL) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }), var target = nodes[index].target else { throw LibraryError.nodeNotFound }
        target.url = url
        nodes[index].payload = .target(target)
    }

    /// Removes a node and all of its descendants. The built-in default folder cannot be removed.
    public mutating func remove(_ id: UUID) {
        guard node(id)?.builtInRole == nil else { return }
        var doomed: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for node in nodes where node.parentID.map(doomed.contains) == true && !doomed.contains(node.id) {
                doomed.insert(node.id)
                changed = true
            }
        }
        nodes.removeAll { doomed.contains($0.id) }
    }

    /// Moves a node under `parent` at `index` among its siblings.
    public mutating func move(_ id: UUID, to parent: UUID?, index: Int) throws {
        guard let moving = node(id) else { throw LibraryError.nodeNotFound }
        if let parent {
            guard let parentNode = node(parent) else { throw LibraryError.parentNotFound }
            guard parentNode.isFolder else { throw LibraryError.parentIsNotFolder }
            var current: UUID? = parent
            while let candidate = current {
                if candidate == id { throw LibraryError.cyclicParentage }
                current = node(candidate)?.parentID
            }
        }
        var siblings = children(of: parent).filter { $0.id != id }
        var updated = moving
        updated.parentID = parent
        siblings.insert(updated, at: max(0, min(index, siblings.count)))
        for (order, sibling) in siblings.enumerated() {
            if let i = nodes.firstIndex(where: { $0.id == sibling.id }) {
                nodes[i].parentID = parent
                nodes[i].order = order
            }
        }
    }

    public func contains(url: URL) -> Bool {
        nodes.contains { $0.target?.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// All target nodes depth-first, for search in the overflow browser.
    public func allTargets() -> [Node] {
        var result: [Node] = []
        func walk(_ parent: UUID?) {
            for child in children(of: parent) {
                if child.isFolder { walk(child.id) } else { result.append(child) }
            }
        }
        walk(nil)
        return result
    }
}

/// Sidebar Common Paths entry. Encoded like the original (`{"builtIn":{"_0":"desktop"}}`, `{"folder":{"url":…,"title":…}}`).
public enum CommonPathEntry: Codable, Equatable, Hashable, Sendable {
    case builtIn(String)
    case folder(url: URL, title: String)

    public static let defaults: [CommonPathEntry] = [.builtIn("applications"), .builtIn("desktop"), .builtIn("downloads")]
    public static let builtInOptions = ["applications", "desktop", "downloads", "documents", "movies", "music", "pictures", "home"]
    public static let maximumCount = 256

    public var url: URL {
        switch self {
        case .folder(let url, _): return url
        case .builtIn(let name):
            let fm = FileManager.default
            switch name {
            case "applications": return URL(fileURLWithPath: "/Applications", isDirectory: true)
            case "desktop": return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            case "downloads": return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            case "documents": return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            case "movies": return fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            case "music": return fm.urls(for: .musicDirectory, in: .userDomainMask)[0]
            case "pictures": return fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            default: return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            }
        }
    }
}

/// Recently visited folders and opened files, newest first.
public struct RecentActivityRecord: Codable, Equatable, Sendable {
    public var url: URL
    public var accessedAt: Date

    public init(url: URL, accessedAt: Date) {
        self.url = url
        self.accessedAt = accessedAt
    }

    public static let maximumCount = 200

    public static func recording(_ url: URL, in records: [RecentActivityRecord], now: Date = Date()) -> [RecentActivityRecord] {
        var list = records.filter { $0.url.standardizedFileURL != url.standardizedFileURL }
        list.insert(RecentActivityRecord(url: url, accessedAt: now), at: 0)
        return Array(list.prefix(maximumCount))
    }
}
