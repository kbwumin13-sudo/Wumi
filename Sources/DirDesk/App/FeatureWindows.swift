import AppKit
import DirDeskCore
import SwiftUI

/// Creates and reuses the app's secondary windows.
@MainActor
final class FeatureWindows {
    weak var appDelegate: AppDelegate?
    private var settingsWindow: NSWindow?
    private var languageObserver: NSObjectProtocol?
    private var infoWindows: [String: NSWindow] = [:]
    private var singletons: [String: NSWindow] = [:]
    let settingsNavigation = SettingsNavigation()

    private func makeWindow<V: View>(_ view: V, title: String, size: NSSize, style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable],
                                     identifier: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.center()
        return window
    }

    private func singleton<V: View>(_ key: String, title: String, size: NSSize, style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable],
                                    view: () -> V) {
        if let existing = singletons[key], existing.isVisible || existing.isMiniaturized {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(view(), title: title, size: size, style: style, identifier: "DirDesk.\(key)")
        singletons[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings(section: String?) {
        if let section { settingsNavigation.select(identifier: section) }
        if settingsWindow == nil {
            let window = makeWindow(SettingsView(navigation: settingsNavigation), title: LF("%@ Settings", "Wumi"),
                                    size: NSSize(width: 900, height: 772), style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    identifier: "DirDesk.Settings")
            // A plain transparent title bar: since macOS 26 its title sits left, after the window buttons at (9, 9),
            // exactly where the original's settings window shows it (a toolbar would move both down and right).
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 760, height: 520)
            window.setFrameAutosaveName("DirDesk.SettingsWindow")
            settingsWindow = window
            languageObserver = NotificationCenter.default.addObserver(forName: .dirDeskLanguageChanged, object: nil, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window?.title = LF("%@ Settings", "Wumi") }
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        activateApp()
    }

    func showInfo(for item: FileItem) {
        if let window = infoWindows[item.url.path] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Like the original: a fixed-size floating utility panel (430 × 544 with its title bar) titled "Info — name".
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = LF("Info — %@", item.name)
        window.contentView = NSHostingView(rootView: GetInfoView(item: item))
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("DirDesk.Info")
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.titlebarSeparatorStyle = .none
        window.center()
        infoWindows[item.url.path] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.infoWindows[item.url.path] = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Ordinary search is Miji's original panel, including Wumi's folder context.
    func showLightningSearch(scope: URL?, controller: WorkspaceController?) {
        GlobalSearchController.shared.show(scope: scope)
    }

    /// The existing condition editor remains available from Miji's filter menu.
    func showAdvancedSearch(scope: URL?, controller: WorkspaceController?) {
        let workspace = controller?.model.activeTab.panes.compactMap(\.currentDirectory) ?? []
        LightningSearchPresenter.show(scope: scope, workspace: workspace) { [weak self] url, reveal in
            guard reveal else {
                FileOpenRouter.open(url)
                return
            }
            FileOpenRouter.reveal(url, preferred: self?.appDelegate?.activeController)
        }
    }

    /// Batch Rename is a sheet on the workspace window, like the original.
    func showBatchRename(_ items: [FileItem], controller: WorkspaceController) {
        BatchRenameSheet.present(items, controller: controller)
    }

    /// Like the original: a 920 × 684 pt floating utility panel titled "Manage Bookmarks" (close and zoom only) that
    /// stays on screen while another app is in front.
    func showBookmarkManager(controller: WorkspaceController?) {
        if let existing = singletons["BookmarkManager"], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // 684 pt tall with its 24 pt utility title bar.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("Manage Bookmarks")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 720, height: 480)
        panel.identifier = NSUserInterfaceItemIdentifier("DirDesk.BookmarkManager")
        panel.contentView = NSHostingView(rootView: BookmarkManagerView(controller: { [weak self, weak controller] in
            self?.appDelegate?.activeController ?? controller
        }, close: { [weak panel] in panel?.close() }))
        panel.center()
        singletons["BookmarkManager"] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func importFinderFavorites(controller: WorkspaceController) {
        singleton("FinderFavorites", title: L("Import Finder Favorites…"), size: NSSize(width: 560, height: 480)) {
            FinderFavoritesImportView { [weak self] in self?.singletons["FinderFavorites"]?.close() }
        }
    }

    func showWorkspaceManager(controller: WorkspaceController?) {
        singleton("WorkspaceManager", title: L("Manage Workspaces…"), size: NSSize(width: 600, height: 440)) {
            WorkspaceManagerView(locate: { [weak self] id in
                guard let delegate = self?.appDelegate else { return false }
                for candidate in delegate.controllers {
                    if let tab = candidate.model.tabs.first(where: { $0.namedWorkspaceID == id }) {
                        candidate.model.selectTab(tab.id)
                        candidate.window?.makeKeyAndOrderFront(nil)
                        return true
                    }
                }
                return false
            }, open: { [weak self] id in
                (self?.appDelegate?.activeController ?? controller)?.openNamedWorkspace(id)
            })
        }
    }

    func showConnectToServer(controller: WorkspaceController) {
        // A sheet on the workspace window, as in the original.
        controller.presentConnectToServer()
    }

    func showFileTransit() {
        FloatingFilesController.shared.toggle()
    }

    /// Image, metadata and PDF tools (folder tools run directly in `WorkspaceController.runBuiltInTool`).
    func showBuiltInTool(_ tool: BuiltInToolID, items: [FileItem], controller: WorkspaceController) {
        BuiltInToolPresenter.present(tool, items: items, controller: controller)
    }
}
