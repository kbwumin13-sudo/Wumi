import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// App-wide configuration shared by every window: the efficiency configuration (commands,
/// shortcuts, workspace preferences) plus app-level settings stored under separate keys.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var configuration: EfficiencyConfiguration
    @Published var configurationError: String?
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.appLanguage)
            Localizer.shared.apply(language)
            NotificationCenter.default.post(name: .dirDeskLanguageChanged, object: nil)
        }
    }

    private let store = PersistenceStore<EfficiencyConfiguration>(key: DefaultsKey.efficiencyConfiguration) { .defaults }

    var preferences: WorkspacePreferences { configuration.workspacePreferences }

    private init() {
        let loaded = store.load()
        configuration = loaded.value
        if let error = loaded.error {
            configurationError = "The saved efficiency configuration could not be read. Temporary defaults are shown."
            NSLog("DirDesk configuration decode failed: \(error)")
        }
        language = UserDefaults.standard.string(forKey: DefaultsKey.appLanguage).flatMap(AppLanguage.init) ?? .system
        applyAppearance()
    }

    func update(_ change: (inout EfficiencyConfiguration) -> Void) {
        var copy = configuration
        change(&copy)
        guard copy != configuration else { return }
        configuration = copy
        do {
            try store.save(copy)
        } catch {
            configurationError = "The efficiency configuration could not be saved."
        }
        applyAppearance()
    }

    func updatePreferences(_ change: (inout WorkspacePreferences) -> Void) {
        update { change(&$0.workspacePreferences) }
    }

    func applyAppearance() {
        switch preferences.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: App-level settings outside the efficiency configuration

    enum StartupLocationMode: String, CaseIterable {
        case desktop, fixedFolder, lastLocation
    }

    var startupLocationMode: StartupLocationMode {
        get { UserDefaults.standard.string(forKey: DefaultsKey.startupLocationMode).flatMap(StartupLocationMode.init) ?? .desktop }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.startupLocationMode); objectWillChange.send() }
    }

    var startupFixedPath: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.startupFixedPath) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.startupFixedPath); objectWillChange.send() }
    }

    var lastLocationPath: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.startupLastPath) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.startupLastPath) }
    }

    /// Folder for a brand-new window, falling back to Desktop when unavailable.
    func startupDirectory() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let candidate: String? = switch startupLocationMode {
        case .desktop: nil
        case .fixedFolder: startupFixedPath
        case .lastLocation: lastLocationPath
        }
        if let candidate {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
        }
        return desktop
    }

    var defaultViewConfiguration: ViewConfiguration {
        var configuration = ViewConfiguration()
        configuration.usesNaturalNumericSorting = preferences.usesNaturalNumericSorting
        if let key = UserDefaults.standard.string(forKey: DefaultsKey.defaultSortKey).flatMap(FileSortKey.init) {
            configuration.sortKey = key
        }
        if UserDefaults.standard.object(forKey: DefaultsKey.defaultSortAscending) != nil {
            configuration.sortAscending = UserDefaults.standard.bool(forKey: DefaultsKey.defaultSortAscending)
        }
        configuration.foldersFirst = UserDefaults.standard.bool(forKey: DefaultsKey.foldersFirst)
        return configuration
    }
}

extension Notification.Name {
    static let dirDeskLanguageChanged = Notification.Name("DirDesk.LanguageChanged")
    static let dirDeskFileDragDidBegin = Notification.Name("DirDesk.FileDragDidBegin")
    static let dirDeskFileDragDidEnd = Notification.Name("DirDesk.FileDragDidEnd")
}
