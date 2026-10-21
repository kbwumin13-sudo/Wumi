import AppKit

/// Brings DirDesk to the front, except in hidden snapshot runs (`-DirDeskSnapshotHidden YES`, see `DebugSnapshot`),
/// which must never take focus from the app the user is working in.
@MainActor
func activateApp() {
    guard !UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") else { return }
    NSApp.activate()
}
