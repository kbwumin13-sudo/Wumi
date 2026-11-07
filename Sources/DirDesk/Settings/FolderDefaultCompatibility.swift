import CoreFoundation
import DirDeskCore
import Foundation

/// The same preference form documented by ForkLift. Some macOS releases reject
/// public.folder in the handler APIs with paramErr; activation may require restart.
@MainActor
enum FolderDefaultCompatibility {
    private static let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
    private static let handlersKey = "LSHandlers" as CFString
    private static let viewerKey = "NSFileViewer" as CFString
    private static let backupKey = "dirdesk-folder-default-backup-v2"
    private static let requestedKey = "dirdesk-folder-default-request-v2"
    static var requested: Bool? { UserDefaults.standard.object(forKey: requestedKey) as? Bool }
    static func noteRequest(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: requestedKey) }
    static func isUnsupported(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSOSStatusErrorDomain && e.code == -50 { return true }
        let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSOSStatusErrorDomain && underlying?.code == -50
    }

    static func set(enabled: Bool, bundleID: String, previousHandler: String?, restoreHandler: String) -> String? {
        let defaults = UserDefaults.standard
        let oldHandlers = CFPreferencesCopyValue(handlersKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let oldViewer = CFPreferencesCopyValue(viewerKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard oldHandlers == nil || oldHandlers is [[String: Any]] else { return L("The operation could not be completed.") }
        let current = oldHandlers as? [[String: Any]] ?? []
        var backup = defaults.data(forKey: backupKey).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        }
        if enabled, backup == nil {
            var saved: [String: Any] = ["folders": FolderHandlerPreferences.folderEntries(in: current),
                                        "viewerPresent": oldViewer != nil, "handler": previousHandler ?? "com.apple.finder"]
            if let oldViewer { saved["viewer"] = oldViewer }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0) else {
                return L("The operation could not be completed.")
            }
            defaults.set(data, forKey: backupKey)
            backup = saved
        }
        let desired: [[String: Any]]
        var viewer: CFPropertyList? = oldViewer
        if enabled {
            desired = FolderHandlerPreferences.requesting(bundleID, in: current)
            viewer = bundleID as CFString
        } else {
            var folders = backup?["folders"] as? [[String: Any]] ??
                [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": restoreHandler]]
            let priorUnavailable = (backup?["handler"] as? String).map { $0 != restoreHandler } ?? false
            if priorUnavailable { folders = [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": restoreHandler]] }
            desired = FolderHandlerPreferences.restoring(folders, replacing: bundleID, in: current)
            if (oldViewer as? String)?.caseInsensitiveCompare(bundleID) == .orderedSame {
                viewer = priorUnavailable ? nil : (backup?["viewerPresent"] as? Bool == true ? backup?["viewer"] as CFPropertyList? : nil)
            }
        }
        CFPreferencesSetValue(handlersKey, desired as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(viewerKey, viewer, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let handlersSaved = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let viewerSaved = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard handlersSaved && viewerSaved else {
            CFPreferencesSetValue(handlersKey, oldHandlers, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSetValue(viewerKey, oldViewer, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            return L("The operation could not be completed.")
        }
        noteRequest(enabled)
        if !enabled { defaults.removeObject(forKey: backupKey) }
        return nil
    }
}
