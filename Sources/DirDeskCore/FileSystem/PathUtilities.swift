import Foundation

public enum PathResolutionError: Error, Equatable {
    case empty
    case notAbsolute(String)
    case unsupportedVariable(String)
    case doesNotExist(String)
}

public enum PathUtilities {
    /// Expands a leading `~`, `$VAR` and `${VAR}`. Unknown variables are errors.
    public static func expand(_ input: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory()) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PathResolutionError.empty }
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
            text = url.path
        }
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst(1)
        }
        let pattern = try! NSRegularExpression(pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}|\\$([A-Za-z_][A-Za-z0-9_]*)")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            let nameRange = Range(match.range(at: 1), in: text) ?? Range(match.range(at: 2), in: text)!
            let name = String(text[nameRange])
            let value: String? = name == "HOME" ? home : environment[name]
            guard let value else { throw PathResolutionError.unsupportedVariable(name) }
            result += text[last..<range.lowerBound] + value
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    /// Resolves user input to an existing absolute path.
    public static func resolveExisting(_ input: String) throws -> URL {
        let expanded = try expand(input)
        guard expanded.hasPrefix("/") else { throw PathResolutionError.notAbsolute(expanded) }
        let standardized = (expanded as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardized) else { throw PathResolutionError.doesNotExist(standardized) }
        return URL(fileURLWithPath: standardized)
    }

    /// Ancestors from the volume root to `url`, for breadcrumb display.
    public static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.insert(current, at: 0)
            let parent = ICloudDriveDirectory.browsingParent(of: current)
            if parent.path == current.path || current.path == "/" { break }
            current = parent
        }
        return result
    }

    /// Cached localized display name; falls back to the last path component until `prefetchDisplayNames` ran.
    /// Never touches the file system, so it is safe on the main thread for protected folders.
    public static func displayName(for url: URL) -> String {
        DisplayNameCache.shared.name(for: url.standardizedFileURL.path)
    }

    /// Resolves and caches display names (call off the main thread; may trigger privacy prompts).
    public static func prefetchDisplayNames(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !DisplayNameCache.shared.has(path) else { continue }
            let name: String
            if path == "/" {
                name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
            } else {
                name = FileManager.default.displayName(atPath: path)
            }
            DisplayNameCache.shared.set(name, for: path)
        }
    }
}

final class DisplayNameCache: @unchecked Sendable {
    static let shared = DisplayNameCache()
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func has(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names[path] != nil
    }

    func set(_ name: String, for path: String) {
        lock.lock(); names[path] = name; lock.unlock()
    }

    func name(for path: String) -> String {
        lock.lock(); let cached = names[path]; lock.unlock()
        if let cached { return cached }
        if path == "/" { return "Macintosh HD" }
        return (path as NSString).lastPathComponent
    }
}

public extension URL {
    /// Same location regardless of a trailing slash (folder URLs from directory listings end with one, URLs built
    /// with `appendingPathComponent` do not) or `.`/`..` components.
    func hasSamePath(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}
