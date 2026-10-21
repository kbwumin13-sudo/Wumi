import Foundation

/// UserDefaults keys. The original uses the same names with a `dirdeck-` prefix.
public enum DefaultsKey {
    public static let efficiencyConfiguration = "dirdesk-efficiency-configuration-v1"
    public static let bookmarks = "dirdesk-bookmarks-v2"
    public static let commonPaths = "dirdesk-common-paths-v1"
    public static let fileFloating = "dirdesk-file-floating-v1"
    public static let fileTransit = "dirdesk-file-transit-v1"
    public static let recentActivity = "dirdesk-recent-activity-v1"
    public static let windowGeometry = "dirdesk-window-geometry-v1"
    public static let savedNetworkLocations = "dirdesk-saved-network-locations-v1"
    public static let recentNetworkServers = "dirdesk-recent-network-servers-v1"
    public static let startupLastPath = "dirdesk-startup-last-path-v1"
    public static let startupLocationMode = "dirdesk-startup-location-mode-v1"
    public static let startupFixedPath = "dirdesk-startup-fixed-path-v1"
    public static let appLanguage = "dirdesk-app-language-v1"
    public static let folderDisplay = "dirdesk-folder-display-v1"
    public static let rememberFolderDisplay = "dirdesk-remember-folder-display-v1"
    public static let defaultSortKey = "dirdesk-default-sort-key-v1"
    public static let defaultSortAscending = "dirdesk-default-sort-ascending-v1"
    public static let foldersFirst = "dirdesk-folders-first-v1"
    public static let inspectorWidth = "dirdesk-inspector-width-v1"
    public static let blankDoubleClickAction = "dirdesk-blank-double-click-action-v1"
    public static let openPathChildrenOnHover = "dirdesk-open-path-children-on-hover-v1"
    public static let operationErrorSound = "dirdesk-operation-error-sound-v1"
    public static let batchRenamePresets = "dirdesk-batch-rename-presets-v1"
    public static let batchRenameLog = "dirdesk-batch-rename-log-v1"
    public static let hiddenFinderTags = "dirdesk-hidden-finder-tags-v2"
    public static let finderTagColorOverrides = "dirdesk-finder-tag-color-overrides-v1"
    public static let createdSidebarTags = "dirdesk-created-sidebar-tags-v1"
    public static let finderFavoritesOnboarding = "dirdesk-finder-favorites-onboarding-v1"
    public static let bookmarkManagerShowsPaths = "dirdesk-bookmark-manager-shows-paths"
    public static let initialLayout = "dirdesk-initial-layout-v2"
    /// Sidebar sections the user collapsed; kept across launches (the original keeps a collapsed Locations section
    /// collapsed even though its default-expanded list includes it).
    public static let sidebarCollapsedSections = "dirdesk-sidebar-collapsed-sections-v1"
}

public enum PersistenceError: Error, Equatable {
    case corrupt(String)
    case encodingFailed(String)
}

/// JSON value stored under one UserDefaults key. Corrupt data falls back to the default and is reported.
public final class PersistenceStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let key: String
    private let defaults: UserDefaults
    private let fallback: @Sendable () -> Value

    public init(key: String, defaults: UserDefaults = .standard, fallback: @escaping @Sendable () -> Value) {
        self.key = key
        self.defaults = defaults
        self.fallback = fallback
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Returns the stored value, or the default plus an error when stored data cannot be decoded.
    public func load() -> (value: Value, error: PersistenceError?) {
        guard let data = defaults.data(forKey: key) else { return (fallback(), nil) }
        do {
            return (try JSONDecoder().decode(Value.self, from: data), nil)
        } catch {
            return (fallback(), .corrupt(String(describing: error)))
        }
    }

    public func save(_ value: Value) throws {
        do {
            defaults.set(try Self.encoder.encode(value), forKey: key)
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
    }

    public func remove() {
        defaults.removeObject(forKey: key)
    }
}
