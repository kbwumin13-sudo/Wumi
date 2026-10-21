import Foundation

/// Finder's iCloud Drive root combines CloudDocs with the visible application document containers.
/// The URLs remain the real Documents directories, so opening, copying and dragging use real files.
public enum ICloudDriveDirectory {
    public static func isRoot(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return url.lastPathComponent == "com~apple~CloudDocs"
            && url.deletingLastPathComponent().lastPathComponent == "Mobile Documents"
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library"
    }

    public static func root(forApplicationDocuments url: URL) -> URL? {
        let url = url.standardizedFileURL
        guard url.lastPathComponent == "Documents" else { return nil }
        let container = url.deletingLastPathComponent()
        guard container.lastPathComponent != "com~apple~CloudDocs" else { return nil }
        let root = container.deletingLastPathComponent().appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        return isRoot(root) ? root : nil
    }

    /// The user-facing parent of an application folder is the combined Drive root.
    public static func browsingParent(of url: URL) -> URL {
        root(forApplicationDocuments: url) ?? url.deletingLastPathComponent()
    }

    /// Read only the containers macOS exposes in Finder. Hidden app-data containers stay out of this view.
    static func applicationFolders(in root: URL, isCancelled: () -> Bool) -> [FileItem] {
        let keys = Set(DirectoryLoader.resourceKeys + [.localizedNameKey, .ubiquitousItemContainerDisplayNameKey])
        guard let containers = try? FileManager.default.contentsOfDirectory(
            at: root.deletingLastPathComponent(), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }
        var items: [FileItem] = []
        for container in containers {
            if isCancelled() { break }
            guard container.standardizedFileURL.path != root.standardizedFileURL.path,
                  let values = try? container.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isHidden != true, values.isSymbolicLink != true else { continue }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            guard let documentValues = try? documents.resourceValues(forKeys: keys), documentValues.isDirectory == true else { continue }
            var item = DirectoryLoader.makeItem(url: documents, values: documentValues)
            item.name = values.ubiquitousItemContainerDisplayName ?? values.localizedName ?? container.lastPathComponent
            item.presentationRole = .navigationAlias
            DisplayNameCache.shared.set(item.name, for: documents.standardizedFileURL.path)
            items.append(item)
        }
        return items
    }
}
