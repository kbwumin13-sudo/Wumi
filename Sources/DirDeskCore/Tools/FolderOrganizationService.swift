import Foundation

/// Collect-into-folder and dissolve-folder, each recorded as a reversible transaction.
/// Name clashes use "name (n).ext" like the original's folder tools.
public enum FolderOrganizationService {
    public static let maximumItems = 10_000

    public struct Transaction: Sendable {
        public struct Move: Sendable {
            public var from: URL
            public var to: URL
        }
        public var parent: URL
        public var folder: URL
        public var moves: [Move]
        /// true when the folder was created by collect, false when it was removed by dissolve.
        public var createdFolder: Bool
    }

    public enum OrganizationError: Error {
        case tooManyItems, notAFolder
    }

    static func parenthesizedUniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for n in 2...10_000 {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    public static func collect(_ urls: [URL], into parent: URL, folderName: String) throws -> Transaction {
        guard urls.count <= maximumItems else { throw OrganizationError.tooManyItems }
        let fm = FileManager.default
        let folder = parenthesizedUniqueURL(for: parent.appendingPathComponent(folderName))
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var moves: [Transaction.Move] = []
        for url in urls {
            let target = parenthesizedUniqueURL(for: folder.appendingPathComponent(url.lastPathComponent))
            try fm.moveItem(at: url, to: target)
            moves.append(.init(from: url, to: target))
        }
        return Transaction(parent: parent, folder: folder, moves: moves, createdFolder: true)
    }

    public static func dissolve(_ folder: URL) throws -> Transaction {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw OrganizationError.notAFolder }
        let parent = folder.deletingLastPathComponent()
        let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard children.count <= maximumItems else { throw OrganizationError.tooManyItems }
        var moves: [Transaction.Move] = []
        for child in children where child.lastPathComponent != ".DS_Store" {
            let target = parenthesizedUniqueURL(for: parent.appendingPathComponent(child.lastPathComponent))
            try fm.moveItem(at: child, to: target)
            moves.append(.init(from: child, to: target))
        }
        let leftover = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if leftover.allSatisfy({ $0 == ".DS_Store" }) { try fm.removeItem(at: folder) }
        return Transaction(parent: parent, folder: folder, moves: moves, createdFolder: false)
    }

    public static func undo(_ transaction: Transaction) {
        let fm = FileManager.default
        if !transaction.createdFolder {
            try? fm.createDirectory(at: transaction.folder, withIntermediateDirectories: true)
        }
        for move in transaction.moves.reversed() where !fm.fileExists(atPath: move.from.path) {
            try? fm.moveItem(at: move.to, to: move.from)
        }
        if transaction.createdFolder, let remaining = try? fm.contentsOfDirectory(atPath: transaction.folder.path), remaining.isEmpty {
            try? fm.removeItem(at: transaction.folder)
        }
    }
}
