import AppKit
import Combine
import DirDeskCore
import Quartz
import UniformTypeIdentifiers

/// File Transit (the Staging tab of Floating Files) for the app. It publishes the Core shelf for SwiftUI and
/// runs the Core service on a serial queue, so saving, importing, exporting and every look at the files
/// happen off the main thread.
@MainActor
final class FileTransitStore: ObservableObject {
    static let shared = FileTransitStore()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
        var isSticky = false
    }

    struct ExportProgress: Equatable {
        var completed: Int
        var total: Int
    }

    struct FileInfo: Equatable {
        var exists: Bool
        var byteCount: Int64?
    }

    @Published private(set) var items: [FileTransitItem] = []
    @Published private(set) var stacks: [FileTransitStack] = []
    @Published private(set) var canRestore = false
    @Published private(set) var isReadOnly = false
    @Published private(set) var notice: Notice?
    @Published private(set) var exportProgress: ExportProgress?
    /// Whether each record's file is there, and its size; filled in off the main thread.
    @Published private(set) var fileInfo: [UUID: FileInfo] = [:]
    /// Stacks shown item by item.
    @Published var expandedStacks: Set<UUID> = []
    /// Selected tiles: record IDs, or stack IDs for collapsed stacks.
    @Published var selection: Set<UUID> = []
    @Published var isDropTargeted = false

    let managedRoot: URL
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.file-transit", qos: .userInitiated)
    private let box = ServiceBox()
    private var stickyNotice: Notice?
    private var pendingLoadMessage: String?
    private var noticeExpiry: DispatchWorkItem?
    private var exportCancel: OperationCenter.CancelFlag?
    /// The shelf's AppKit container: first responder for keys, Quick Look and drops.
    weak var shelfView: TransitShelfContainerView?
    /// Files the Quick Look panel shows.
    private(set) var previewURLs: [URL] = []

    private final class ServiceBox: @unchecked Sendable {
        var service: FileTransitService?
    }

    private init(rootURL: URL = FileTransitRepository.defaultRootURL) {
        self.rootURL = rootURL
        managedRoot = FileTransitRepository(rootURL: rootURL).managedRootURL
        let naming = FileTransitNaming(text: L("Dropped Text"), image: L("Dropped Image"), file: L("Dropped File"), link: L("Web Link"))
        let box = self.box
        queue.async {
            let service = FileTransitService(repository: FileTransitRepository(rootURL: rootURL), naming: naming)
            box.service = service
            var legacy = FileTransitChange()
            if service.startedWithoutDocument, let records = Self.legacyRecords() {
                legacy = service.adoptLegacyRecords(records)
                if !legacy.saveFailed { UserDefaults.standard.removeObject(forKey: DefaultsKey.fileTransit) }
            }
            let shelf = service.shelf, readOnly = service.isReadOnly, loadNotice = service.loadNotice
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(shelf, readOnly: readOnly)
                    self.showLoadNotice(loadNotice)
                    self.report(legacy)
                }
            }
        }
    }

    /// Records saved by the first DirDesk builds (a plain array under `DefaultsKey.fileTransit`).
    nonisolated private static func legacyRecords() -> [FileTransitItem]? {
        struct Legacy: Decodable {
            var id: UUID
            var url: URL
            var kind: String
            var stackID: UUID
            var isLocked: Bool
            var addedAt: Date
            var displayName: String
        }
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.fileTransit),
              let records = try? JSONDecoder().decode([Legacy].self, from: data) else { return nil }
        return records.filter(\.url.isFileURL).map {
            FileTransitItem(id: $0.id, kind: $0.kind == "directory" ? .directory : .file, stackID: $0.stackID, isLocked: $0.isLocked,
                            addedAt: $0.addedAt, name: $0.displayName.isEmpty ? $0.url.lastPathComponent : $0.displayName,
                            originalPath: $0.url.standardizedFileURL.path)
        }
    }

    /// Waits until pending changes are saved (the app is quitting).
    func flush() {
        queue.sync {}
    }

    // MARK: Running operations

    /// Runs `work` on the File Transit queue, then publishes the shelf and reports what happened.
    private func perform(_ work: @escaping @Sendable (FileTransitService) -> FileTransitChange) {
        let box = self.box
        queue.async {
            guard let service = box.service else { return }
            let change = work(service)
            let shelf = service.shelf, readOnly = service.isReadOnly
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(shelf, readOnly: readOnly)
                    self.report(change)
                }
            }
        }
    }

    private func apply(_ shelf: FileTransitShelf, readOnly: Bool) {
        let known = Set(items.map(\.id))
        if items != shelf.items {
            items = shelf.items
            stacks = shelf.stacks
        }
        if canRestore != shelf.canRestore { canRestore = shelf.canRestore }
        if isReadOnly != readOnly { isReadOnly = readOnly }
        let ids = Set(shelf.items.map(\.id))
        let groups = Set(stacks.filter(\.isGroup).map(\.id))
        let keptSelection = selection.filter { ids.contains($0) || groups.contains($0) }
        if keptSelection != selection { selection = keptSelection }
        let keptExpanded = expandedStacks.intersection(groups)
        if keptExpanded != expandedStacks { expandedStacks = keptExpanded }
        let keptInfo = fileInfo.filter { ids.contains($0.key) }
        if keptInfo.count != fileInfo.count { fileInfo = keptInfo }
        let fresh = shelf.items.filter { !known.contains($0.id) }
        if !fresh.isEmpty { refreshFileInfo(fresh) }
    }

    // MARK: Messages

    static func message(for error: FileTransitError) -> String {
        switch error {
        case .shelfFull: L("File Transit has reached its item limit. Remove items to make room.")
        case .managedStorageFull: L("There is no room left for imported content. Remove some dropped text, images, or links first.")
        case .importLimitExceeded: L("This item is too large to import into File Transit.")
        case .unsupportedItem: L("File Transit can’t hold this kind of item.")
        case .importFailed: L("Importing an item into File Transit failed.")
        case .itemMissing: L("That item has already left File Transit.")
        case .stackMissing: L("That stack has already left File Transit.")
        case .nothingToRestore: L("Nothing was removed recently.")
        case .readOnly: Self.readOnlyMessage
        }
    }

    private static var readOnlyMessage: String {
        L("A newer Wumi version saved this File Transit data. It is kept as is, so File Transit is read-only here.")
    }

    /// Load problems are reported once the shelf is on screen, so the message is not missed while it is hidden.
    private func showLoadNotice(_ notice: FileTransitService.LoadNotice?) {
        switch notice {
        case .unreadableDataReplaced?:
            pendingLoadMessage = L("File Transit started empty because its saved data could not be read.")
        case .newerVersion?:
            stickyNotice = Notice(message: Self.readOnlyMessage, isError: true, isSticky: true)
            self.notice = stickyNotice
        case .invalidRecordsDropped?:
            pendingLoadMessage = L("Some File Transit records were damaged and have been left out.")
        case nil:
            break
        }
        if shelfView?.window?.isVisible == true { shelfDidAppear() }
    }

    /// Called when the Staging tab is shown.
    func shelfDidAppear() {
        if let message = pendingLoadMessage {
            pendingLoadMessage = nil
            ApplicationErrorLog.shared.record(message: message, source: .fileTransit)
            show(Notice(message: message, isError: true), duration: nil)
        }
        refreshFileInfo()
    }

    private func report(_ change: FileTransitChange) {
        if let failure = change.failures.first {
            if !change.added.isEmpty {
                showError(L("Part of the drop could not be added to File Transit."))
            } else {
                showError(Self.message(for: failure))
            }
        } else if change.saveFailed {
            showError(L("Saving File Transit failed."))
        }
    }

    func showStatus(_ message: String) {
        show(Notice(message: message, isError: false), duration: 4)
    }

    func showError(_ message: String) {
        ApplicationErrorLog.shared.record(message: message, source: .fileTransit)
        show(Notice(message: message, isError: true), duration: 8)
    }

    /// Shows a notice; it goes away after `duration` seconds, or stays until closed when `duration` is nil.
    private func show(_ notice: Notice, duration: TimeInterval?) {
        noticeExpiry?.cancel()
        self.notice = notice
        guard let duration else { return }
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.notice?.id == notice.id else { return }
                self.notice = self.stickyNotice
            }
        }
        noticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: expiry)
    }

    func dismissNotice() {
        noticeExpiry?.cancel()
        notice = stickyNotice
    }

    // MARK: Adding

    /// Adds files and folders where they are (menus, Lightning Search, the open panel).
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        add(sources: urls.map { .file($0) })
    }

    func add(sources: [FileTransitSource], stackID: UUID? = nil) {
        guard !sources.isEmpty else { return }
        perform { $0.add(sources, stackID: stackID) }
    }

    /// Takes in a drop, a paste or a drop on the menu bar icon: files and folders are referenced, promised files,
    /// text, images and links are imported into managed storage. Returns false when nothing could be taken.
    @discardableResult
    func importPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard !isReadOnly else {
            showError(Self.readOnlyMessage)
            return false
        }
        let content = TransitPasteboard.read(pasteboard)
        guard !content.isEmpty else {
            showError(Self.message(for: .unsupportedItem))
            return false
        }
        let stack = UUID()
        add(sources: content.sources, stackID: stack)
        if !content.promises.isEmpty { receive(content.promises, stackID: stack) }
        return true
    }

    /// Receives promised files (Photos, Mail attachments, images from browsers) into the incoming folder; each file
    /// joins the drop's stack once it has arrived.
    private func receive(_ receivers: [NSFilePromiseReceiver], stackID: UUID) {
        let repository = FileTransitRepository(rootURL: rootURL)
        let operations = OperationQueue()
        operations.qualityOfService = .userInitiated
        for receiver in receivers {
            guard let folder = try? repository.makeIncomingFolder() else {
                showError(Self.message(for: .importFailed))
                continue
            }
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: operations) { [weak self] url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if error != nil {
                            self.showError(Self.message(for: .importFailed))
                        } else {
                            self.add(sources: [.receivedFile(url)], stackID: stackID)
                        }
                    }
                }
            }
        }
    }

    func presentAddPanel() {
        guard !isReadOnly else { return showError(Self.readOnlyMessage) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = L("Add to File Transit")
        panel.message = L("Select files or folders to add to File Transit.")
        panel.prompt = L("Add")
        present(panel) { [weak self] urls in self?.add(urls) }
    }

    /// Shows an open panel as a sheet on the Floating Files window when it is open, otherwise as a modal panel.
    private func present(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
        if let window = shelfView?.window, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { completion(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            completion(panel.urls)
        }
    }

    // MARK: Removing, locking, stacks

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        perform { $0.remove(ids) }
    }

    func removeStack(_ stackID: UUID) {
        perform { $0.removeStack(stackID) }
    }

    func toggleLock(_ id: UUID) {
        perform { $0.toggleLock(id) }
    }

    func setLocked(_ ids: Set<UUID>, _ locked: Bool) {
        guard !ids.isEmpty else { return }
        perform { $0.setLocked(ids, locked: locked) }
    }

    func clearUnlocked() {
        perform { $0.clearUnlocked() }
    }

    func restoreRecentlyRemoved() {
        perform { $0.restoreRecentlyRemoved() }
    }

    func separate(_ stackID: UUID) {
        expandedStacks.remove(stackID)
        perform { $0.separate(stackID) }
    }

    func toggleExpanded(_ stackID: UUID) {
        if expandedStacks.contains(stackID) {
            expandedStacks.remove(stackID)
            if stacks.contains(where: { $0.id == stackID }) { selection = [stackID] }
        } else {
            expandedStacks.insert(stackID)
            selection = []
        }
    }

    // MARK: Lookups

    /// Records in shelf order.
    func records(_ ids: [UUID]) -> [FileTransitItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    func stack(_ id: UUID) -> FileTransitStack? {
        stacks.first { $0.id == id }
    }

    func fileURL(_ item: FileTransitItem) -> URL? {
        item.fileURL(managedRoot: managedRoot)
    }

    /// Record IDs for tile IDs (a stack ID stands for all of its records).
    func recordIDs(forTiles tiles: Set<UUID>) -> [UUID] {
        items.filter { tiles.contains($0.id) || tiles.contains($0.stackID) }.map(\.id)
    }

    /// Cards in display order: a stack card, followed by its records' cards while it is expanded.
    var visibleTileIDs: [UUID] {
        stacks.flatMap { stack -> [UUID] in
            guard stack.isGroup else { return stack.items.map(\.id) }
            return [stack.id] + (expandedStacks.contains(stack.id) ? stack.items.map(\.id) : [])
        }
    }

    var selectedRecordIDs: [UUID] { recordIDs(forTiles: selection) }

    /// Looks at each record's file off the main thread (protected folders must not be touched on the main thread).
    func refreshFileInfo(_ records: [FileTransitItem]? = nil) {
        let root = managedRoot
        let targets = (records ?? items).map { ($0.id, $0.fileURL(managedRoot: root), $0.isManaged ? $0.managedByteCount : nil) }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var info: [UUID: FileInfo] = [:]
            for (id, url, managedBytes) in targets {
                var status = stat()
                guard let url, lstat(url.path, &status) == 0 else {
                    // Only a file that is really gone counts as missing (not one macOS keeps DirDesk from reading).
                    info[id] = FileInfo(exists: !(url == nil || errno == ENOENT || errno == ENOTDIR), byteCount: nil)
                    continue
                }
                let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
                info[id] = FileInfo(exists: true, byteCount: isFolder ? managedBytes : Int64(status.st_size))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let current = Set(self.items.map(\.id))
                    var merged = self.fileInfo
                    for (id, value) in info where current.contains(id) { merged[id] = value }
                    if merged != self.fileInfo { self.fileInfo = merged }
                }
            }
        }
    }

    // MARK: Opening, previewing, sharing

    func open(_ id: UUID) {
        guard let record = records([id]).first else { return showError(Self.message(for: .itemMissing)) }
        if fileInfo[id]?.exists == false, record.kind != .link {
            return showError(L("The file for this item can’t be found."))
        }
        if record.kind == .link, let link = record.linkURL {
            NSWorkspace.shared.open(link)
        } else if let url = fileURL(record) {
            if record.kind == .directory, record.originalPath != nil {
                FloatingFilesController.shared.showInMainWindow(url: url, select: false)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showInDirDesk(_ id: UUID) {
        guard let record = records([id]).first, let url = fileURL(record), record.originalPath != nil else { return }
        FloatingFilesController.shared.showInMainWindow(url: url, select: true)
    }

    func revealInFinder(_ ids: [UUID]) {
        let urls = records(ids).filter { $0.originalPath != nil }.compactMap(fileURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Space / Quick Look: shows the records' files in the Quick Look panel, or closes it when it is open.
    func toggleQuickLook(_ ids: [UUID]) {
        let urls = records(ids).compactMap(fileURL)
        guard !urls.isEmpty, let view = shelfView, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible, urls == previewURLs {
            panel.orderOut(nil)
            return
        }
        previewURLs = urls
        view.window?.makeFirstResponder(view)
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Shows the share menu next to `view`, or at the pointer in the shelf when no view is given.
    func share(_ ids: [UUID], from view: NSView? = nil) {
        guard let anchor = view ?? shelfView else { return }
        let pointer = anchor.window.map { anchor.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let rect = view == nil ? NSRect(origin: pointer ?? .zero, size: NSSize(width: 1, height: 1)) : anchor.bounds
        let records = self.records(ids)
        guard !records.isEmpty else { return showError(Self.message(for: .itemMissing)) }
        let root = managedRoot
        DispatchQueue.global(qos: .userInitiated).async {
            var shareable: [URL] = []
            var missing = 0
            for record in records {
                if record.kind == .link, let link = record.linkURL {
                    shareable.append(link)
                    continue
                }
                var status = stat()
                guard let url = record.fileURL(managedRoot: root), lstat(url.path, &status) == 0 else {
                    missing += 1
                    continue
                }
                shareable.append(url)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !shareable.isEmpty else {
                        return self.showError(L("These items can’t be shared because their files are missing."))
                    }
                    if missing > 0 { self.showError(L("Items whose files are missing were left out of sharing.")) }
                    guard anchor.window != nil else { return }
                    NSSharingServicePicker(items: shareable).show(relativeTo: rect, of: anchor, preferredEdge: .minY)
                }
            }
        }
    }

    // MARK: Clipboard

    /// One record: its file plus its text, image or address, so it pastes as a file in Finder and as content
    /// elsewhere. Several records: their files.
    func copyToClipboard(_ ids: [UUID]) {
        let records = self.records(ids)
        guard !records.isEmpty else { return showError(Self.message(for: .itemMissing)) }
        let root = managedRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let payloads = records.map { TransitClipboardPayload(record: $0, managedRoot: root, includeContent: records.count == 1) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let written = !payloads.isEmpty && pasteboard.writeObjects(payloads.map(\.pasteboardItem))
                    if !written { self.showError(L("Copying to the Clipboard failed.")) }
                }
            }
        }
    }

    func copyAll() {
        copyToClipboard(items.map(\.id))
    }

    // MARK: Export

    /// The folder shown in the active pane of the frontmost DirDesk window.
    var exportHereFolder: URL? {
        for window in NSApp.orderedWindows where window.isVisible || window.isMiniaturized {
            if let controller = window.windowController as? WorkspaceController {
                return controller.model.activePane.currentDirectory
            }
        }
        return FloatingFilesController.shared.appDelegate?.activeController?.model.activePane.currentDirectory
    }

    func exportHere(_ ids: [UUID]) {
        guard let folder = exportHereFolder else {
            return showError(L("Open a folder in a Wumi window to export there."))
        }
        export(ids, to: folder, clearAfterwards: false)
    }

    /// "Choose Export Destination…", "Export this item…" and "Export & Clear…".
    func chooseDestinationAndExport(_ ids: [UUID], clearAfterwards: Bool) {
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Choose Export Destination")
        panel.message = L("Pick a folder to receive copies of the File Transit items.")
        panel.prompt = L("Export")
        present(panel) { [weak self] urls in
            guard let folder = urls.first else { return }
            self?.export(ids, to: folder, clearAfterwards: clearAfterwards)
        }
    }

    /// Copies records into `folder` off the main thread. With `clearAfterwards`, exported records that are not
    /// locked leave the shelf (they stay restorable).
    func export(_ ids: [UUID], to folder: URL, clearAfterwards: Bool) {
        guard exportProgress == nil else { return showError(L("Another export is still running.")) }
        let records = self.records(ids)
        guard !records.isEmpty else { return showError(Self.message(for: .itemMissing)) }
        let flag = OperationCenter.CancelFlag()
        exportCancel = flag
        exportProgress = ExportProgress(completed: 0, total: records.count)
        let root = managedRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let report = FileTransitExporter.export(records, managedRoot: root, to: folder, isCancelled: { flag.isCancelled }, progress: { done, total in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if self.exportProgress != nil { self.exportProgress = ExportProgress(completed: done, total: total) } }
                }
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishExport(report, total: records.count, clearAfterwards: clearAfterwards) }
            }
        }
    }

    func cancelExport() {
        exportCancel?.cancel()
    }

    private func finishExport(_ report: FileTransitExportReport, total: Int, clearAfterwards: Bool) {
        exportProgress = nil
        exportCancel = nil
        let exported = report.exportedIDs.count
        if report.wasCancelled {
            showStatus(L("Export cancelled"))
        } else if !report.failures.isEmpty {
            showError(LF("Not exported: %lld of %lld", Int64(report.failures.count), Int64(total)))
        } else {
            showStatus(exported == 1 ? L("Exported 1 item") : LF("Exported %lld items", Int64(exported)))
        }
        if clearAfterwards, exported > 0 {
            let ids = report.exportedIDs
            perform { $0.completeTransfer(of: ids) }
        }
    }

    // MARK: Dragging out

    /// Prepares temporary clones for a drag off the main thread.
    func prepareDrag(_ ids: [UUID], completion: @escaping (FileTransitDragPreparation) -> Void) {
        let records = self.records(ids)
        let root = managedRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let preparation = FileTransitDragPreparer.prepare(records, managedRoot: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(preparation) }
            }
        }
    }

    func reportDragPreparation(_ preparation: FileTransitDragPreparation) {
        if preparation.files.isEmpty {
            showError(L("None of these items could be readied for dragging."))
        } else if !preparation.unavailableIDs.isEmpty {
            showError(L("Some items could not be readied for dragging and were left out."))
        }
    }

    /// The originals stay where they are either way. A move drop takes the dragged, unlocked records off the shelf
    /// (they stay restorable); a copy drop keeps them. A cancelled drag deletes its clones at once; otherwise they are
    /// kept for six hours — a destination may copy in the background or open the file in place — and a clone that
    /// was edited meanwhile is never deleted.
    func finishDrag(_ preparation: FileTransitDragPreparation, operation: NSDragOperation) {
        if operation.contains(.move), preparation.allowsMove {
            let moved = Set(preparation.files.map(\.itemID))
            perform { $0.completeTransfer(of: moved) }
        }
        let delay: TimeInterval = operation.isEmpty ? 0 : 6 * 3600
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            FileTransitDragPreparer.discard(preparation)
        }
    }
}

/// What "Copy item to Clipboard" writes for one record; built off the main thread.
struct TransitClipboardPayload {
    var fileURL: URL?
    var text: String?
    var webURL: URL?
    var imageData: Data?
    var imageType: String?

    init(record: FileTransitItem, managedRoot: URL, includeContent: Bool) {
        fileURL = record.fileURL(managedRoot: managedRoot)
        guard includeContent else { return }
        switch record.kind {
        case .link:
            webURL = record.linkURL
        case .text:
            if let url = fileURL, record.managedByteCount <= 8 << 20 { text = try? String(contentsOf: url, encoding: .utf8) }
        case .image:
            if let url = fileURL, record.managedByteCount <= 64 << 20, let data = try? Data(contentsOf: url) {
                imageData = data
                imageType = record.contentType
            }
        case .file, .directory:
            break
        }
    }

    @MainActor var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        if let webURL {
            item.setString(webURL.absoluteString, forType: .URL)
            item.setString(webURL.absoluteString, forType: .string)
        } else if let text {
            item.setString(text, forType: .string)
        }
        if let imageData, let imageType { item.setData(imageData, forType: NSPasteboard.PasteboardType(imageType)) }
        return item
    }
}
