import Foundation

/// Changes only the public.folder rows in Launch Services' documented preference form.
public enum FolderHandlerPreferences {
    public static func folderEntries(in handlers: [[String: Any]]) -> [[String: Any]] {
        handlers.filter { ($0["LSHandlerContentType"] as? String) == "public.folder" }
    }
    public static func requesting(_ bundleID: String, in handlers: [[String: Any]]) -> [[String: Any]] {
        handlers.filter { ($0["LSHandlerContentType"] as? String) != "public.folder" } +
            [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": bundleID]]
    }
    public static func restoring(_ previous: [[String: Any]], replacing bundleID: String,
                                 in handlers: [[String: Any]]) -> [[String: Any]] {
        func isOurs(_ row: [String: Any]) -> Bool {
            (row["LSHandlerContentType"] as? String) == "public.folder" &&
                ["LSHandlerRoleAll", "LSHandlerRoleViewer", "LSHandlerRoleEditor", "LSHandlerRoleShell"].contains {
                    (row[$0] as? String)?.caseInsensitiveCompare(bundleID) == .orderedSame
                }
        }
        guard handlers.contains(where: isOurs) else { return handlers }
        let remaining = handlers.filter { !isOurs($0) }
        // A different app may have become the user's choice after Wumi was configured.
        return folderEntries(in: remaining).isEmpty ? remaining + previous : remaining
    }
}
