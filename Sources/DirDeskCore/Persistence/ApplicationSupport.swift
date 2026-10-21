import Foundation

/// The Application Support folder DirDesk keeps its files in (`DirDesk/...` below it). A test copy of the app can
/// point it elsewhere with the `DirDeskApplicationSupport` default (`-DirDeskApplicationSupport <path>`), so it never
/// touches the real window sessions, workspaces or file transit data.
public enum ApplicationSupport {
    public static var directory: URL {
        if let override = UserDefaults.standard.string(forKey: "DirDeskApplicationSupport"), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
