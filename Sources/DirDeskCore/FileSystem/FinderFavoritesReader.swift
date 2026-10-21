import Foundation

/// Reads Finder's sidebar favorites (`com.apple.LSSharedFileList.FavoriteItems.sfl3/.sfl4`).
/// The file is a keyed archive whose `items` carry bookmark data; only folders are returned.
public enum FinderFavoritesReader {
    public struct Favorite: Hashable, Sendable {
        public var url: URL
        public var name: String
    }

    public enum ReadError: Error {
        case unreadable, invalidFormat
    }

    public static var defaultFileURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.sharedfilelist", isDirectory: true)
        for name in ["com.apple.LSSharedFileList.FavoriteItems.sfl4", "com.apple.LSSharedFileList.FavoriteItems.sfl3"] {
            let url = base.appendingPathComponent(name)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func read(_ url: URL) throws -> [Favorite] {
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            throw ReadError.invalidFormat
        }
        unarchiver.requiresSecureCoding = false
        guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary,
              let items = root["items"] as? [NSDictionary] else { throw ReadError.invalidFormat }
        var result: [Favorite] = []
        for item in items {
            guard let bookmark = item["Bookmark"] as? Data else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                  resolved.isFileURL else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            result.append(Favorite(url: resolved, name: FileManager.default.displayName(atPath: resolved.path)))
        }
        return result
    }

    /// Standard places DirDesk already shows in the sidebar; imports skip them.
    public static func isBuiltInLocation(_ url: URL) -> Bool {
        let fm = FileManager.default
        let builtIns: [URL] = [
            fm.urls(for: .desktopDirectory, in: .userDomainMask)[0], fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0], URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()), fm.urls(for: .moviesDirectory, in: .userDomainMask)[0],
            fm.urls(for: .musicDirectory, in: .userDomainMask)[0], fm.urls(for: .picturesDirectory, in: .userDomainMask)[0],
        ]
        let path = url.standardizedFileURL.path
        return builtIns.contains { $0.standardizedFileURL.path == path } || path.contains("/Mobile Documents/com~apple~CloudDocs")
    }
}
