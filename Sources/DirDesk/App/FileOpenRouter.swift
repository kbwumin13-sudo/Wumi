import AppKit
import DirDeskCore

/// Resolves file actions inside Wumi before asking Launch Services to open a document.
@MainActor
enum FileOpenRouter {
    static weak var delegate: AppDelegate?

    static func reveal(_ url: URL, preferred: WorkspaceController? = nil) {
        guard let delegate else { return }
        if delegate.controllers.isEmpty { delegate.newWindow(directory: nil) }
        guard let controller = preferred ?? delegate.activeController ?? delegate.controllers.first else { return }
        controller.navigateActivePane(to: url.deletingLastPathComponent())
        controller.activePane.select(urls: [url])
        present(controller)
    }

    static func browse(_ url: URL) {
        delegate?.openExternally([url])
    }

    static func open(_ row: LightningRow) {
        guard row.isOnline else { return }
        open(row.url)
    }

    static func open(_ url: URL) {
        let target = resolvedFileURL(url)
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { browse(target) }
        else { NSWorkspace.shared.open(target) }
    }

    static func resolvedFileURL(_ url: URL) -> URL {
        let target = url.resolvingSymlinksInPath()
        if (try? target.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
            return (try? URL(resolvingAliasFileAt: target, options: .withoutUI)) ?? target
        }
        return target
    }

    static func chooseDestination(for urls: [URL], move: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = move ? L("Move Here") : L("Copy Here")
        picker.begin { response in
            guard response == .OK, let destination = picker.url, let delegate else { return }
            let controller = delegate.activeController ?? delegate.newWindow(directory: destination)
            controller.transfer(urls, to: destination, move: move)
        }
    }

    static func present(_ controller: WorkspaceController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Show Desktop may temporarily slide a normal window out of view. Raising it through
        // application activation and deminiaturization restores it without replacing the session.
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }
}
