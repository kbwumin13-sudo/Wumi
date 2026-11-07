import Foundation

/// Synchronous filesystem primitives intended for a detached task, never the UI actor.
public enum DesktopFileActions {
    public static func create(in directory: URL, name: String, contents: Data? = nil, folder: Bool) throws -> URL {
        try validate(name)
        let candidate = directory.appendingPathComponent(name)
        let destination = FileManager.default.fileExists(atPath: candidate.path) ? FileOperationCoordinator.keepBothURL(for: candidate) : candidate
        if folder { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        else { try (contents ?? Data()).write(to: destination, options: .withoutOverwriting) }
        return destination
    }
    public static func rename(_ source: URL, name: String) throws -> URL {
        try validate(name)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        if destination.path == source.path { return source }
        // moveItem reports occupied names without overwriting an unrelated item.
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
    private static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }
    public struct TrashResult: Sendable {
        public var pairs: [(original: URL, trashed: URL)] = []
        public var failures: [String] = []
        public init() {}
    }
    public static func trash(_ urls: [URL]) -> TrashResult {
        var result = TrashResult()
        for url in urls {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                if let target = trashed as URL? { result.pairs.append((url, target)) }
            } catch { result.failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        return result
    }
}
