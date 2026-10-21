import AppKit
import DirDeskCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icon and thumbnail cache shared by all views.
@MainActor
final class FileIcons {
    static let shared = FileIcons()

    private let iconCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var pendingIcons: [String: [(NSImage) -> Void]] = [:]
    private let iconQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.kbwumin13.dirdesk.file-icons"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    init() {
        iconCache.countLimit = 4000
        thumbnailCache.countLimit = 600
    }

    /// File-type icon. Folders with custom icons and apps use their own icon; plain files share a per-type icon.
    func icon(for item: FileItem) -> NSImage {
        let customIcon = item.isPackage || item.isAliasFile || item.isSymbolicLink || (item.isBrowsableFolder && hasCustomIcon(item.url))
        let key: String = customIcon ? "path:" + item.url.path : (item.isBrowsableFolder ? "folder" : "type:" + (item.contentTypeIdentifier ?? item.fileExtension))
        if let cached = iconCache.object(forKey: key as NSString) { return cached }
        let image: NSImage
        if customIcon {
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        } else if item.isBrowsableFolder {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let type = item.contentType {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        iconCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Browser cells get a cached/type icon immediately. Path-dependent lookups, including custom-folder
    /// metadata, run off the main thread and are coalesced for cells showing the same file.
    func icon(for item: FileItem, completion: @escaping (NSImage) -> Void) -> NSImage {
        let key = "browser:\(item.url.path)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = iconCache.object(forKey: key as NSString) { return cached }
        let typeKey = item.isBrowsableFolder ? "folder" : "type:" + (item.contentTypeIdentifier ?? item.fileExtension)
        let fallback: NSImage
        if let cached = iconCache.object(forKey: typeKey as NSString) {
            fallback = cached
        } else {
            fallback = NSWorkspace.shared.icon(for: item.isBrowsableFolder ? .folder : (item.contentType ?? .data))
            iconCache.setObject(fallback, forKey: typeKey as NSString)
        }
        // Ordinary files already have their exact type icon; only path-dependent cases need a request.
        if !item.isBrowsableFolder, !item.isPackage, !item.isAliasFile, !item.isSymbolicLink, item.contentType != nil {
            return fallback
        }
        if pendingIcons[key] != nil {
            pendingIcons[key]?.append(completion)
            return fallback
        }
        pendingIcons[key] = [completion]
        iconQueue.addOperation { [weak self] in
            let custom = item.isPackage || item.isAliasFile || item.isSymbolicLink
                || (item.isBrowsableFolder && FileManager.default.fileExists(atPath: item.url.appendingPathComponent("Icon\r").path))
            let image = custom || (!item.isBrowsableFolder && item.contentType == nil)
                ? NSWorkspace.shared.icon(forFile: item.url.path) : fallback
            DispatchQueue.main.async {
                guard let self else { return }
                self.iconCache.setObject(image, forKey: key as NSString)
                let callbacks = self.pendingIcons.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        return fallback
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache.object(forKey: ("path:" + path) as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(image, forKey: ("path:" + path) as NSString)
        return image
    }

    private func hasCustomIcon(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }

    func cachedThumbnail(for item: FileItem, size: CGFloat) -> NSImage? {
        thumbnailCache.object(forKey: thumbnailKey(item, size) as NSString)
    }

    /// Asynchronous Quick Look thumbnail; completion runs on the main actor.
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat = 2, completion: @escaping (NSImage?) -> Void) {
        let key = thumbnailKey(item, size)
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            Task { @MainActor in
                if let image { self.thumbnailCache.setObject(image, forKey: key as NSString) }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    private var badgeCache: [String: NSImage] = [:]

    /// Icon of the app that opens this file type, used as the small badge on icon-view thumbnails.
    /// Looked up off the main thread and cached per content type.
    func defaultApplicationBadge(for item: FileItem, completion: @escaping (NSImage?) -> Void) {
        let key = item.contentTypeIdentifier ?? item.fileExtension
        if let cached = badgeCache[key] {
            completion(cached)
            return
        }
        let url = item.url
        Task.detached(priority: .utility) {
            let app = NSWorkspace.shared.urlForApplication(toOpen: url)
            await MainActor.run {
                guard let app else { return completion(nil) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                self.badgeCache[key] = icon
                completion(icon)
            }
        }
    }

    private func thumbnailKey(_ item: FileItem, _ size: CGFloat) -> String {
        "\(item.url.path)|\(Int(size))|\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Whether list rows should show a content thumbnail for this item under the given categories.
    static func wantsListThumbnail(_ item: FileItem, categories: [ListThumbnailCategory]) -> Bool {
        guard !item.isBrowsableFolder, let type = item.contentType else { return false }
        if type.conforms(to: .image) { return categories.contains(.images) }
        if type.conforms(to: .audiovisualContent) { return categories.contains(.multimedia) }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.identifier.hasPrefix("org.openxmlformats") || type.identifier.hasPrefix("com.microsoft") {
            return categories.contains(.documents)
        }
        return categories.contains(.other) && !type.conforms(to: .application) && !type.conforms(to: .executable)
    }
}
