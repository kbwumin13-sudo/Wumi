import AppKit
import Combine
import DirDeskCore

/// Mounted volumes shown under Locations, refreshed on mount and unmount notifications.
@MainActor
final class VolumeMonitor: ObservableObject {
    static let shared = VolumeMonitor()

    struct Volume: Equatable {
        var url: URL
        var name: String
        var isNetwork: Bool
        var isEjectable: Bool
        var isRemovable: Bool
    }

    @Published private(set) var volumes: [Volume] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false,
                  values.volumeIsRootFileSystem != true, url.path.hasPrefix("/Volumes/") else { return nil }
            return Volume(url: url, name: values.volumeName ?? url.lastPathComponent, isNetwork: values.volumeIsLocal == false,
                          isEjectable: values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false || values.volumeIsInternal == false,
                          isRemovable: values.volumeIsRemovable == true)
        }
    }
}

/// Finder tags shown in the sidebar, the Tags submenu and Lightning Search.
///
/// Order, as in the original: tags that items on this Mac carry (found with one bounded Spotlight query; Finder's
/// favorite order first, then by name), tags created in DirDesk, then the remaining Finder favorites (the seven
/// color tags by default). Hidden tags are left out.
@MainActor
final class FinderTagCatalog: ObservableObject {
    static let shared = FinderTagCatalog()

    struct Tag: Equatable {
        var name: String
        var label: Int?
    }

    /// Finder label numbers in Finder's order: red, orange, yellow, green, blue, purple, gray.
    static let colorOrder = [6, 7, 5, 2, 4, 3, 1]
    private static let englishColorNames = [1: "Gray", 2: "Green", 3: "Purple", 4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange"]

    @Published private(set) var tags: [Tag] = []
    private var inUse: [String: Int] = [:]
    private var discovering = false
    private var discoverAgain = false
    private var activationObserver: NSObjectProtocol?

    private init() {
        reload()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in FinderTagCatalog.shared.discover() }
        }
    }

    /// Rebuilds the list from what is known now and looks for tags in use again.
    func reload() {
        rebuild()
        discover()
    }

    private func rebuild() {
        let names = FinderTagOrdering.order(inUse: inUse.keys,
                                            created: UserDefaults.standard.stringArray(forKey: DefaultsKey.createdSidebarTags) ?? [],
                                            favorites: Self.finderFavorites(),
                                            hidden: Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.hiddenFinderTags) ?? []))
        let result = names.map { Tag(name: $0, label: Self.label(for: $0)) }
        if result != tags { tags = result }
    }

    /// One discovery at a time; a request made while one runs starts another when it ends.
    private func discover() {
        guard !discovering else {
            discoverAgain = true
            return
        }
        discovering = true
        Task.detached(priority: .utility) {
            let found = try? SpotlightQuery.tagsInUse()
            await MainActor.run {
                let catalog = FinderTagCatalog.shared
                if let found { catalog.inUse = found }
                catalog.rebuild()
                catalog.discovering = false
                if catalog.discoverAgain {
                    catalog.discoverAgain = false
                    catalog.discover()
                }
            }
        }
    }

    /// Tags on files changed. Spotlight needs a moment to index them before they can be found.
    func tagsChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { FinderTagCatalog.shared.discover() }
    }

    func create(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var created = UserDefaults.standard.stringArray(forKey: DefaultsKey.createdSidebarTags) ?? []
        if !created.contains(trimmed) { created.append(trimmed) }
        UserDefaults.standard.set(created, forKey: DefaultsKey.createdSidebarTags)
        var hidden = UserDefaults.standard.stringArray(forKey: DefaultsKey.hiddenFinderTags) ?? []
        if hidden.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            hidden.removeAll { $0.lowercased() == trimmed.lowercased() }
            UserDefaults.standard.set(hidden, forKey: DefaultsKey.hiddenFinderTags)
        }
        reload()
    }

    /// Removes the tag from DirDesk's lists. Files keep their tags; Finder's own tag list is not changed. Like the
    /// original, the hidden list records the lowercased name (runtime capture 2026-10-20).
    func delete(_ name: String) {
        var created = UserDefaults.standard.stringArray(forKey: DefaultsKey.createdSidebarTags) ?? []
        created.removeAll { $0 == name }
        UserDefaults.standard.set(created, forKey: DefaultsKey.createdSidebarTags)
        var hidden = UserDefaults.standard.stringArray(forKey: DefaultsKey.hiddenFinderTags) ?? []
        if !hidden.contains(name.lowercased()) { hidden.append(name.lowercased()) }
        UserDefaults.standard.set(hidden, forKey: DefaultsKey.hiddenFinderTags)
        SidebarTagColors.set(nil, for: name)
        rebuild()
    }

    func setColor(_ label: Int?, for name: String) {
        SidebarTagColors.set(label, for: name)
        rebuild()
    }

    /// The color DirDesk shows for a tag: a color picked in DirDesk, otherwise the color of a Finder color tag.
    static func label(for name: String) -> Int? {
        if let override = SidebarTagColors.label(for: name) { return override == 0 ? nil : override }
        return colorLabel(named: name)
    }

    /// Finder label number of a color tag name (localized like Finder, or English), nil for other tags.
    static func colorLabel(named name: String) -> Int? {
        let labels = NSWorkspace.shared.fileLabels
        for number in 1...7 {
            if labels.indices.contains(number), labels[number].caseInsensitiveCompare(name) == .orderedSame { return number }
            if englishColorNames[number]?.caseInsensitiveCompare(name) == .orderedSame { return number }
        }
        return nil
    }

    /// Finder's favorite tags (Finder › Settings › Tags), or the seven color tags when Finder has none saved.
    private static func finderFavorites() -> [String] {
        let stored = (UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String])?.filter { !$0.isEmpty }
        if let stored, !stored.isEmpty { return stored }
        let labels = NSWorkspace.shared.fileLabels
        return colorOrder.compactMap { labels.indices.contains($0) ? labels[$0] : englishColorNames[$0] }
    }
}

/// Saved network locations (smb/afp/nfs/ftp/WebDAV), stored as `dirdesk-saved-network-locations-v1`.
@MainActor
final class NetworkLocationStore: ObservableObject {
    static let shared = NetworkLocationStore()

    enum ProtocolKind: String, Codable, CaseIterable {
        case smb, afp, nfs, https, http, ftp
    }

    struct Location: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var address: String
        var protocolKind: ProtocolKind
    }

    @Published private(set) var locations: [Location] = []
    private let store = PersistenceStore<[Location]>(key: DefaultsKey.savedNetworkLocations) { [] }

    private init() { locations = store.load().value }

    func add(_ location: Location) {
        locations.append(location)
        try? store.save(locations)
    }

    func remove(_ id: UUID) {
        locations.removeAll { $0.id == id }
        try? store.save(locations)
    }
}

/// Named workspaces: a saved tab (panes, layout, folders) with a dynamic or static save mode.
@MainActor
final class NamedWorkspaceLibrary: ObservableObject {
    static let shared = NamedWorkspaceLibrary()

    enum SaveMode: String, Codable, CaseIterable {
        case dynamic, `static`
    }

    struct Workspace: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var saveMode: SaveMode
        var tab: WorkspaceTab
        var updatedAt: Date
    }

    enum LibraryError: Error {
        case invalidName, duplicateName, missingWorkspace
    }

    @Published private(set) var workspaces: [Workspace] = []
    private let url: URL

    private init() {
        let base = ApplicationSupport.directory.appendingPathComponent("DirDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("NamedWorkspaces.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = decoded
        }
    }

    private func persist() {
        if let data = try? PersistenceStore<[Workspace]>.encoder.encode(workspaces) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func validate(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(trimmed.count), !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    @discardableResult
    func create(name: String, mode: SaveMode, tab: WorkspaceTab) throws -> Workspace {
        guard let valid = Self.validate(name) else { throw LibraryError.invalidName }
        guard !workspaces.contains(where: { $0.name.caseInsensitiveCompare(valid) == .orderedSame }) else { throw LibraryError.duplicateName }
        let workspace = Workspace(id: UUID(), name: valid, saveMode: mode, tab: tab, updatedAt: Date())
        workspaces.append(workspace)
        persist()
        return workspace
    }

    func update(_ id: UUID, tab: WorkspaceTab) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].tab = tab
        workspaces[index].updatedAt = Date()
        persist()
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let valid = Self.validate(name) else { throw LibraryError.invalidName }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingWorkspace }
        guard !workspaces.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(valid) == .orderedSame }) else { throw LibraryError.duplicateName }
        workspaces[index].name = valid
        persist()
    }

    func setMode(_ id: UUID, mode: SaveMode) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].saveMode = mode
        persist()
    }

    func duplicate(_ id: UUID) {
        guard let original = workspaces.first(where: { $0.id == id }) else { return }
        var name = original.name + " 2"
        var n = 2
        while workspaces.contains(where: { $0.name == name }) {
            n += 1
            name = original.name + " \(n)"
        }
        workspaces.append(Workspace(id: UUID(), name: name, saveMode: original.saveMode, tab: original.tab, updatedAt: Date()))
        persist()
    }

    func delete(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }
}
