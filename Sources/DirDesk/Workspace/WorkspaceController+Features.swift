import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Entry in the Built-in Tools menu.
struct ToolMenuEntry {
    let tool: BuiltInToolID
    let title: String
    let action: () -> Void
}

extension WorkspaceController {
    // MARK: Archives

    func compress(_ items: [FileItem]) {
        guard let directory = activePane.currentDirectory ?? items.first?.url.deletingLastPathComponent(), !items.isEmpty else { return }
        let name = items.count == 1 ? items[0].name + ".zip" : L("Archive.zip")
        let destination = directory.appendingPathComponent(name)
        let sources = items.map(\.url)
        activePane.operationMessage = L("Compressing…")
        let activity = appDelegate?.operations.beginActivity(.compress, items: sources, destination: directory)
        let cancel = activity?.cancel
        Task.detached(priority: .userInitiated) {
            let result = Result { try ArchiveService.create(from: sources, to: destination, options: ArchiveCreationOptions(),
                                                            isCancelled: { cancel?.isCancelled ?? false }) }
            await MainActor.run {
                if let id = activity?.id { self.appDelegate?.operations.endActivity(id) }
                switch result {
                case .failure(ArchiveError.cancelled):
                    self.activePane.operationMessage = nil
                case .success(let created):
                    self.activePane.operationMessage = L("Archive Created")
                    self.activePane.reload()
                    self.activePane.select(urls: created)
                    self.registerTrashUndo(created, name: L("Compress"))
                case .failure(let error):
                    self.activePane.operationMessage = nil
                    self.presentError(Self.archiveMessage(error))
                }
                self.clearOperationMessage(after: 3)
            }
        }
    }

    /// Extracts the archive's items straight into the folder (the archive's own folder by default), like the
    /// original's double-click and Extract; the first extracted item is selected. Longer runs show the shared
    /// progress window ("Extracting…"), which stays up while an encrypted archive asks for its password.
    func extract(_ item: FileItem, to destination: URL?, password: String? = nil, activity: (id: UUID, cancel: OperationCenter.CancelFlag)? = nil) {
        let target = destination ?? item.url.deletingLastPathComponent()
        let url = item.url
        let activity = activity ?? appDelegate?.operations.beginActivity(.extract, items: [url], destination: target)
        let cancel = activity?.cancel
        let finish = { [weak self] in if let id = activity?.id { self?.appDelegate?.operations.endActivity(id) } }
        activePane.operationMessage = L("Extracting…")
        Task.detached(priority: .userInitiated) {
            let result = Result { try ArchiveService.extractMerging(url, into: target, password: password, isCancelled: { cancel?.isCancelled ?? false }) }
            await MainActor.run {
                self.activePane.operationMessage = nil
                switch result {
                case .success(let outputs):
                    finish()
                    self.refreshPanes(showing: [target])
                    if let first = outputs.first, self.activePane.currentDirectory?.hasSamePath(as: target) == true {
                        self.activePane.select(urls: [first])
                    }
                    self.registerTrashUndo(outputs, name: L("Extract"))
                case .failure(ArchiveError.encryptedArchive), .failure(ArchiveError.decryptionFailed):
                    self.askArchivePassword(for: item, retry: password != nil) { entered in
                        if let entered {
                            self.extract(item, to: destination, password: entered, activity: activity)
                        } else {
                            finish()
                        }
                    }
                case .failure(ArchiveError.cancelled):
                    finish()
                case .failure(let error):
                    finish()
                    // Like the original, a failed extraction is reported in the status bar, not in an alert.
                    ApplicationErrorLog.shared.record(message: item.name + ": " + Self.archiveMessage(error), source: .fileOperation)
                    self.activePane.operationResult = PaneRuntime.OperationResult(
                        summary: LF("Processed %lld items, %lld failed", Int64(0), Int64(1)),
                        details: [item.name + " — " + Self.archiveMessage(error)])
                }
            }
        }
    }

    static func archiveMessage(_ error: Error) -> String {
        switch error as? ArchiveError {
        case .unsupportedArchive: L("This archive format is not supported.")
        case .damagedArchive: L("This archive is damaged.")
        case .encryptedArchive: L("Encrypted archives cannot be extracted.")
        case .decryptionFailed: L("The archive could not be decrypted. Check the password and try again.")
        case .unsafeEntry: L("This archive contains an unsafe item.")
        case .tooManyEntries: L("The selection contains too many items for a standard ZIP archive.")
        case .tooLarge: L("This archive is too large to extract safely.")
        case .symbolicLinkUnsupported: L("Symbolic links cannot be added to an archive.")
        case .passwordUnsupportedForFormat: L("Password protection is available for ZIP archives only.")
        case .invalidVolumeSize: L("The split volume size is too small.")
        case .entryNotFound: L("This item is no longer in the archive.")
        case .writeFailed, .cancelled, nil: L("The archive could not be created.")
        }
    }

    /// The original's password prompt, an alert sheet: "Password", the archive name and a hint, a secure field, and
    /// Cancel / Extract, where Extract stays disabled until something is typed.
    func askArchivePassword(for item: FileItem, retry: Bool, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("Password")
        alert.informativeText = item.name + "\n\n"
            + (retry ? L("The archive could not be decrypted. Check the password and try again.") : L("Enter the archive password."))
        let extract = alert.addButton(withTitle: L("Extract"))
        alert.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        extract.isEnabled = false
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.identifier = NSUserInterfaceItemIdentifier("Archive.ExtractionPassword")
        field.setAccessibilityLabel(L("Password"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let typing = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { [weak field, weak extract] _ in
            MainActor.assumeIsolated { extract?.isEnabled = !(field?.stringValue.isEmpty ?? true) }
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            NotificationCenter.default.removeObserver(typing)
            completion(response == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func registerTrashUndo(_ urls: [URL], name: String) {
        FileOperations.registerTrashUndo(urls, name: name, undoManager: window?.undoManager)
    }

    // MARK: Built-in tools

    func builtInToolMenuItems(for items: [FileItem]) -> [ToolMenuEntry] {
        let enabled = AppModel.shared.configuration.enabledBuiltInTools
        return enabled.compactMap { tool in
            guard tool.selectionRule.accepts(count: items.count), BuiltInToolSupport.applies(tool, to: items) else { return nil }
            return ToolMenuEntry(tool: tool, title: BuiltInToolSupport.title(tool)) { [weak self] in self?.runBuiltInTool(tool, items: items) }
        }
    }

    func runBuiltInTool(_ tool: BuiltInToolID, items: [FileItem]) {
        guard !items.isEmpty else {
            presentError(L("Select at least one item."))
            return
        }
        switch tool {
        case .collectIntoFolder:
            collectIntoFolder(items)
        case .dissolveFolder:
            dissolve(items.filter(\.isBrowsableFolder))
        default:
            appDelegate?.showBuiltInTool(tool, items: items, controller: self)
        }
    }

    /// Like the reference, asks for the folder name first: the tool title, a field prefilled with
    /// "untitled folder" (selected), and Cancel / Create.
    private func collectIntoFolder(_ items: [FileItem]) {
        guard let directory = items.first?.url.deletingLastPathComponent() else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L("Move Selected Items into New Folder")
        let field = NSTextField(string: L("untitled folder"))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        let collect = { [weak self] (name: String) in
            guard let self else { return }
            do {
                let result = try FolderOrganizationService.collect(items.map(\.url), into: directory,
                                                                   folderName: try FileOperations.validateName(name))
                registerFolderUndo(result)
                activePane.reload()
                activePane.select(urls: [result.folder])
            } catch let error as FileOperations.OperationError {
                presentError(error.message)
            } catch {
                presentError(error.localizedDescription)
            }
        }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { collect(field.stringValue) }
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { collect(field.stringValue) } }
        }
    }

    private func dissolve(_ folders: [FileItem]) {
        do {
            for folder in folders {
                let result = try FolderOrganizationService.dissolve(folder.url)
                registerFolderUndo(result)
            }
            activePane.reload()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func registerFolderUndo(_ transaction: FolderOrganizationService.Transaction) {
        FileUndo.register(FileUndoStep.undoing(transaction), name: L("Built-in Tools"), undoManager: window?.undoManager)
    }

    // MARK: Windows owned by the app delegate

    func showInfo(_ items: [FileItem]) {
        for item in items.prefix(10) { appDelegate?.showInfo(for: item) }
    }

    func showBatchRename(_ items: [FileItem]) {
        guard items.allSatisfy(\.allowsRenaming) else { return }
        guard !items.isEmpty else { return }
        appDelegate?.showBatchRename(items, controller: self)
    }

    func showSettings(section: String?) { appDelegate?.showSettings(section: section) }
    func showBookmarkManager() { appDelegate?.showBookmarkManager() }
    func importFinderFavorites() { appDelegate?.importFinderFavorites(controller: self) }
    func showWorkspaceManager() { appDelegate?.showWorkspaceManager() }
    func showConnectToServer() { appDelegate?.showConnectToServer(controller: self) }
    func showFileTransit() { appDelegate?.showFileTransit() }

    func connect(to location: NetworkLocationStore.Location) {
        NetworkConnector.connect(address: location.address) { [weak self] result in
            switch result {
            case .success(let mountPoint): self?.navigateActivePane(to: mountPoint)
            case .failure(let error): self?.presentError(error.message)
            }
        }
    }
}

/// Which tools apply to which selections, and their menu titles.
enum BuiltInToolSupport {
    static func applies(_ tool: BuiltInToolID, to items: [FileItem]) -> Bool {
        func all(_ type: UTType) -> Bool { items.allSatisfy { $0.contentType?.conforms(to: type) == true } }
        switch tool.category {
        case .folders:
            return tool == .dissolveFolder ? items.allSatisfy(\.isBrowsableFolder) : true
        case .images, .metadataPrivacy:
            return all(.image)
        case .pdf:
            return all(.pdf)
        }
    }

    static func symbol(_ tool: BuiltInToolID) -> String {
        switch tool {
        case .collectIntoFolder: "folder.badge.plus"
        case .dissolveFolder: "folder.badge.minus"
        case .imageRotateLeft: "rotate.left"
        case .imageRotateRight: "rotate.right"
        case .imageCrop: "crop"
        case .imageConvert: "arrow.triangle.2.circlepath"
        case .imageCompress: "arrow.down.right.and.arrow.up.left"
        case .imageWatermark: "text.below.photo"
        case .imageRemoveBackground: "person.crop.rectangle"
        case .imagesCreatePDF: "doc.richtext"
        case .imageViewLocation: "mappin.and.ellipse"
        case .imageRemoveLocationMetadata: "location.slash"
        case .pdfSplit: "rectangle.split.1x2"
        case .pdfExtractPages: "doc.on.doc"
        case .pdfMerge: "square.3.layers.3d"
        case .pdfRotatePages: "rotate.right"
        case .pdfCompress: "arrow.down.doc"
        case .pdfExportImages: "photo.stack"
        }
    }

    static func title(_ tool: BuiltInToolID) -> String {
        switch tool {
        case .collectIntoFolder: L("Move Selected Items into New Folder")
        case .dissolveFolder: L("Dissolve Folder")
        case .imageRotateLeft: L("Rotate Left")
        case .imageRotateRight: L("Rotate Right")
        case .imageCrop: L("Crop Image")
        case .imageConvert: L("Convert Image")
        case .imageCompress: L("Compress Image")
        case .imageWatermark: L("Add Watermark")
        case .imageRemoveBackground: L("Remove Background")
        case .imagesCreatePDF: L("Create PDF")
        case .imageViewLocation: L("View Photo Location")
        case .imageRemoveLocationMetadata: L("Remove Location Metadata")
        case .pdfSplit: L("Split PDF")
        case .pdfExtractPages: L("Extract PDF Pages")
        case .pdfMerge: L("Merge PDFs")
        case .pdfRotatePages: L("Rotate PDF Pages")
        case .pdfCompress: L("Compress PDF")
        case .pdfExportImages: L("Export PDF Pages as Images")
        }
    }
}
