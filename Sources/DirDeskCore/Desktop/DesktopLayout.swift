import Foundation
import UniformTypeIdentifiers

/// Coordinates are local, top-left based points; no display scale or global screen origin is persisted.
public struct DesktopRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func clamped(width availableWidth: Double, height availableHeight: Double,
                        minimumWidth: Double = 220, minimumHeight: Double = 90) -> Self {
        let aw = max(1, availableWidth.isFinite ? availableWidth : 1)
        let ah = max(1, availableHeight.isFinite ? availableHeight : 1)
        let w = min(aw, max(minimumWidth, width.isFinite ? width : minimumWidth))
        let h = min(ah, max(minimumHeight, height.isFinite ? height : minimumHeight))
        return .init(x: min(max(0, x.isFinite ? x : 0), aw - w),
                     y: min(max(0, y.isFinite ? y : 0), ah - h), width: w, height: h)
    }
}

public enum DesktopFileCategory: String, Codable, CaseIterable, Sendable {
    case folders, images, documents, audio, video, archives, applications, other
    public var titleKey: String {
        switch self {
        case .folders: "Folders"
        case .images: "Images"
        case .documents: "Documents"
        case .audio: "Audio"
        case .video: "Videos"
        case .archives: "Archives"
        case .applications: "Applications"
        case .other: "Other Files"
        }
    }
    public static func category(of item: FileItem) -> Self {
        if item.isBrowsableFolder { return .folders }
        if item.fileExtension.lowercased() == "app" { return .applications }
        if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "iso"].contains(item.fileExtension.lowercased()) { return .archives }
        if let type = item.contentType {
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation) { return .documents }
        }
        switch item.fileExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return .images
        case "txt", "md", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "rtf": return .documents
        case "mp3", "m4a", "wav", "flac": return .audio
        case "mp4", "mov", "mkv", "avi": return .video
        default: return .other
        }
    }
}

public struct DesktopZone: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var category: DesktopFileCategory?
    public var screenID: String
    public var frame: DesktopRect
    public var isCollapsed: Bool
    public var isCustom: Bool { category == nil && id != DesktopLayout.unassignedZoneID }
    public init(id: String = UUID().uuidString, title: String, category: DesktopFileCategory? = nil,
                screenID: String, frame: DesktopRect, isCollapsed: Bool = false) {
        self.id = id; self.title = title; self.category = category; self.screenID = screenID
        self.frame = frame; self.isCollapsed = isCollapsed
    }
}

public struct DesktopAssignment: Codable, Equatable, Sendable {
    public var zoneID: String
    public var lastKnownPath: String
    public init(zoneID: String, lastKnownPath: String) { self.zoneID = zoneID; self.lastKnownPath = lastKnownPath }
}

public struct DesktopSearchWidget: Codable, Equatable, Sendable {
    public var frame: DesktopRect
    public var isVisible: Bool
    public init(frame: DesktopRect, isVisible: Bool = true) { self.frame = frame; self.isVisible = isVisible }
}

/// Visual membership never creates directories or moves files. Stable device/inode identity follows renames.
public struct DesktopLayout: Codable, Equatable, Sendable {
    public static let unassignedZoneID = "desktop.all-files"
    public var version = 1
    public var automaticGrouping = true
    public var zones: [DesktopZone] = []
    public var assignments: [String: DesktopAssignment] = [:]
    public var searchWidgets: [String: DesktopSearchWidget] = [:]
    public init() {}

    public static func identityKey(_ item: FileItem) -> String {
        let id = item.id
        // Bulk listings provide the inode and volume but no st_dev; direct reads
        // also have st_dev. URL resource identifiers can be cached after replacement.
        if let volume = id.volumeIdentifier, let inode = id.fileSystemInode {
            return "volume-inode:\(volume.base64EncodedString()):\(inode)"
        }
        if let device = id.fileSystemDevice, let inode = id.fileSystemInode { return "inode:\(device):\(inode)" }
        if let volume = id.volumeIdentifier, let resource = id.resourceIdentifier {
            return "resource:\(volume.base64EncodedString()):\(resource.base64EncodedString())"
        }
        return "path:\(item.url.standardizedFileURL.path)"
    }
    public func zoneID(for item: FileItem) -> String {
        if let assigned = assignments[Self.identityKey(item)], let zone = zones.first(where: { $0.id == assigned.zoneID }) {
            return !automaticGrouping && zone.category != nil ? Self.unassignedZoneID : assigned.zoneID
        }
        if automaticGrouping { return "desktop.kind.\(DesktopFileCategory.category(of: item).rawValue)" }
        return Self.unassignedZoneID
    }
    @discardableResult
    public mutating func assign(_ items: [FileItem], to zoneID: String) -> Bool {
        guard zones.contains(where: { $0.id == zoneID }) else { return false }
        for item in items { assignments[Self.identityKey(item)] = .init(zoneID: zoneID, lastKnownPath: item.url.path) }
        return true
    }
    /// Called only after a successful listing. Retain absent identities for undo and temporarily unavailable files.
    public mutating func reconcile(_ items: [FileItem]) {
        for item in items {
            let key = Self.identityKey(item)
            if var assignment = assignments[key] {
                assignment.lastKnownPath = item.url.path
                assignments[key] = assignment
            }
        }
    }
    /// Explicit path-only identity migration is used after Wumi itself renamed a provider item without an inode.
    public mutating func didRename(_ old: FileItem, to new: FileItem) {
        let oldKey = Self.identityKey(old), newKey = Self.identityKey(new)
        guard var assignment = assignments[oldKey] else { return }
        assignment.lastKnownPath = new.url.path
        if oldKey != newKey { assignments.removeValue(forKey: oldKey) }
        assignments[newKey] = assignment
    }
    public mutating func removeZone(_ id: String) {
        zones.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value.zoneID != id }
    }
    public mutating func prepare(screenSizes: [String: (width: Double, height: Double)], primaryID: String) {
        guard let primary = screenSizes[primaryID] else { return }
        if !zones.contains(where: { $0.id == Self.unassignedZoneID }) {
            zones.append(.init(id: Self.unassignedZoneID, title: "Desktop Files", screenID: primaryID,
                               frame: .init(x: 20, y: 80, width: primary.width - 40, height: primary.height - 100)))
        }
        let columns = max(1, Int(primary.width / 330))
        for (index, category) in DesktopFileCategory.allCases.enumerated() {
            let id = "desktop.kind.\(category.rawValue)"
            if !zones.contains(where: { $0.id == id }) {
                zones.append(.init(id: id, title: category.titleKey, category: category, screenID: primaryID,
                                   frame: .init(x: 20 + Double(index % columns) * 325, y: 80 + Double(index / columns) * 230, width: 310, height: 215)))
            }
        }
        for index in zones.indices {
            if screenSizes[zones[index].screenID] == nil { zones[index].screenID = primaryID }
            let size = screenSizes[zones[index].screenID] ?? primary
            zones[index].frame = zones[index].frame.clamped(width: size.width, height: size.height)
        }
        for (id, size) in screenSizes {
            var widget = searchWidgets[id] ?? .init(frame: .init(x: max(0, size.width - 500), y: 80, width: 470, height: 340))
            widget.frame = widget.frame.clamped(width: size.width, height: size.height, minimumWidth: 360, minimumHeight: 180)
            searchWidgets[id] = widget
        }
    }
    public func visibleZones(on screenID: String, items: [FileItem]) -> [DesktopZone] {
        let used = Set(items.map { zoneID(for: $0) })
        return zones.filter { zone in
            guard zone.screenID == screenID else { return false }
            if zone.isCustom { return true }
            if zone.id == Self.unassignedZoneID { return !automaticGrouping || used.contains(zone.id) }
            return automaticGrouping && used.contains(zone.id)
        }
    }
}
