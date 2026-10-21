import AppKit
import DirDeskCore
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: Pasteboard

/// Reads what File Transit can take from a drag or the clipboard.
enum TransitPasteboard {
    struct Content {
        var sources: [FileTransitSource] = []
        var promises: [NSFilePromiseReceiver] = []
        var isEmpty: Bool { sources.isEmpty && promises.isEmpty }
    }

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier), NSPasteboard.PasteboardType(UTType.webP.identifier), .tiff,
    ]
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .rtf] + imageTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: acceptedTypes) != nil
    }

    /// File Transit only references or copies what is dropped, so it never asks the source to move (a move would
    /// cut dragged text out of its document or move a file away). Drags out of the shelf itself are refused.
    static func dropOperation(for info: NSDraggingInfo) -> NSDragOperation {
        guard !(info.draggingSource is TransitTileView), canRead(info.draggingPasteboard) else { return [] }
        let mask = info.draggingSourceOperationMask
        for operation in [NSDragOperation.copy, .generic, .link] where mask.contains(operation) { return operation }
        return []
    }

    /// Files win over promised files, which win over links, images and text.
    static func read(_ pasteboard: NSPasteboard) -> Content {
        var content = Content()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            content.sources = urls.map { .file($0) }
            return content
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            content.promises = promises
            return content
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let source = source(from: item) { content.sources.append(source) }
        }
        return content
    }

    private static func source(from item: NSPasteboardItem) -> FileTransitSource? {
        if let string = item.string(forType: .URL), let url = URL(string: string), !url.isFileURL, url.scheme != nil {
            return .link(url, title: item.string(forType: urlNameType))
        }
        for type in imageTypes {
            if let data = item.data(forType: type) { return .image(data, typeIdentifier: type.rawValue, name: nil) }
        }
        if let string = item.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), url.host != nil,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return .link(url, title: nil)
            }
            return .text(string)
        }
        if let rtf = item.data(forType: .rtf), let text = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string {
            return .text(text)
        }
        return nil
    }
}

// MARK: Thumbnails and icons

/// Quick Look thumbnails (or icons) for shelf tiles, generated off the main thread and cached.
@MainActor
final class TransitThumbnails {
    static let shared = TransitThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var lastImage: [String: NSImage] = [:]

    private init() {
        cache.countLimit = 800
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)|\(Int(size))" as NSString
    }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    /// The last thumbnail made for `url`, whatever its size (drag images).
    func cachedAnySize(_ url: URL) -> NSImage? {
        lastImage[url.path]
    }

    /// Content thumbnails for images, movies and PDFs; the file's icon (custom icons included) for everything else,
    /// like the original's cards.
    func image(for url: URL, size: CGFloat, preferThumbnail: Bool) async -> NSImage? {
        if let cached = cached(url, size: size) { return cached }
        let types: QLThumbnailGenerator.Request.RepresentationTypes = preferThumbnail ? .all : .icon
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: types)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key(url, size))
        if lastImage.count > 600 { lastImage.removeAll() }
        lastImage[url.path] = image
        return image
    }

    static func prefersThumbnail(_ item: FileTransitItem) -> Bool {
        if item.kind == .image { return true }
        guard let identifier = item.contentType, let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    /// Icon chosen from the record's type alone, so drawing a tile never reads the file.
    static func placeholder(for item: FileTransitItem) -> NSImage {
        if item.kind == .directory { return NSWorkspace.shared.icon(for: .folder) }
        if let identifier = item.contentType, let type = UTType(identifier) { return NSWorkspace.shared.icon(for: type) }
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

// MARK: Shelf container

/// AppKit container around the shelf's SwiftUI content. It is the drop target for the whole shelf, the first
/// responder for its keyboard commands (Space, Delete, Return, Escape, ⌘A, ⌘C, ⌘V) and the Quick Look controller.
final class TransitShelfContainerView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let store: FileTransitStore

    init(store: FileTransitStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes(TransitPasteboard.acceptedTypes)
        store.shelfView = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ content: NSView) {
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Clicks on empty shelf space arrive here through the responder chain: they clear the selection and still
    /// move the window, like the rest of its background.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        store.selection = []
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        store.selection = []
        return store.shelfMenu()
    }

    // Dropping files, promised files, text, images and links.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { store.isDropTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { store.isDropTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store.isDropTargeted = false
        return store.importPasteboard(sender.draggingPasteboard)
    }

    private func evaluate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = store.isReadOnly ? [] : TransitPasteboard.dropOperation(for: sender)
        let targeted = !operation.isEmpty
        if store.isDropTargeted != targeted { store.isDropTargeted = targeted }
        return operation
    }

    // Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: // Space
            store.toggleQuickLook(store.selectedRecordIDs)
        case 51, 117: // Delete, Forward Delete
            removeSelection()
        case 36, 76: // Return, Enter
            if let first = store.selection.first(where: { id in store.items.contains { $0.id == id } }) {
                store.open(first)
            } else if let stack = store.selection.first {
                store.toggleExpanded(stack)
            }
        case 53: // Escape
            if store.selection.isEmpty { super.keyDown(with: event) } else { store.selection = [] }
        default:
            super.keyDown(with: event)
        }
    }

    private func removeSelection() {
        let ids = Set(store.selectedRecordIDs)
        guard !ids.isEmpty else { return NSSound.beep() }
        store.remove(ids)
    }

    @objc func copy(_ sender: Any?) {
        store.copyToClipboard(store.selectedRecordIDs)
    }

    @objc func paste(_ sender: Any?) {
        store.importPasteboard(.general)
    }

    @objc func delete(_ sender: Any?) {
        removeSelection()
    }

    @objc override func selectAll(_ sender: Any?) {
        store.selection = Set(store.visibleTileIDs)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !store.selection.isEmpty
        case #selector(delete(_:)): return !store.selection.isEmpty && !store.isReadOnly
        case #selector(paste(_:)): return !store.isReadOnly && TransitPasteboard.canRead(.general)
        case #selector(selectAll(_:)): return !store.items.isEmpty
        default: return true
        }
    }

    // Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { store.previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            store.previewURLs.indices.contains(index) ? store.previewURLs[index] as NSURL : nil
        }
    }
}

// MARK: Cards

/// Mouse handling laid over a card's icon and name: selection, double-click, context menu and dragging out.
final class TransitTileView: NSView, NSDraggingSource {
    enum Role {
        /// A single record (alone or inside an expanded stack).
        case item
        /// A stack of records dropped together.
        case stack
    }

    weak var store: FileTransitStore?
    var role: Role = .item
    /// Record ID for `.item`, stack ID for `.stack`.
    var targetID = UUID()

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var isPreparing = false
    private var prepared: FileTransitDragPreparation?
    private var activePreparation: FileTransitDragPreparation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Clicks

    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        if let container = store.shelfView { window?.makeFirstResponder(container) }
        dragStarted = false
        discardPrepared()
        if event.clickCount >= 2 {
            mouseDownEvent = nil
            role == .item ? store.open(targetID) : store.toggleExpanded(targetID)
            return
        }
        mouseDownEvent = event
        let flags = event.modifierFlags
        if flags.contains(.command) {
            if store.selection.contains(targetID) { store.selection.remove(targetID) } else { store.selection.insert(targetID) }
        } else if flags.contains(.shift) {
            store.selection.insert(targetID)
        } else if !store.selection.contains(targetID) {
            store.selection = [targetID]
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        discardPrepared()
        guard !dragStarted, let down = mouseDownEvent, let store else { return }
        if down.modifierFlags.intersection([.command, .shift]).isEmpty, store.selection.count > 1 {
            store.selection = [targetID]
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let store else { return nil }
        store.selection = [targetID]
        return store.menu(for: role, targetID: targetID, anchor: self)
    }

    // Dragging out

    /// Records this card drags: the whole selection when the card is part of it, otherwise its own records.
    private func draggedRecordIDs() -> [UUID] {
        guard let store else { return [] }
        if store.selection.contains(targetID), store.selection.count > 1 {
            return store.recordIDs(forTiles: store.selection)
        }
        return role == .item ? [targetID] : store.recordIDs(forTiles: [targetID])
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !dragStarted, let store else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= 16 else { return }
        if let prepared {
            beginDrag(prepared, event: event)
            return
        }
        guard !isPreparing else { return }
        isPreparing = true
        // The clones are made off the main thread; the drag starts with the next mouse movement once they exist.
        store.prepareDrag(draggedRecordIDs()) { [weak self] preparation in
            guard let self else { return FileTransitDragPreparer.discard(preparation) }
            self.isPreparing = false
            guard self.mouseDownEvent != nil, !self.dragStarted else { return FileTransitDragPreparer.discard(preparation) }
            self.prepared = preparation
        }
    }

    private func discardPrepared() {
        if let prepared { FileTransitDragPreparer.discard(prepared) }
        prepared = nil
    }

    private func beginDrag(_ preparation: FileTransitDragPreparation, event: NSEvent) {
        guard let store else { return }
        dragStarted = true
        prepared = nil
        store.reportDragPreparation(preparation)
        guard !preparation.files.isEmpty else { return FileTransitDragPreparer.discard(preparation) }
        let point = convert(event.locationInWindow, from: nil)
        let side: CGFloat = 40
        let records = store.records(preparation.files.map(\.itemID))
        let draggingItems = preparation.files.enumerated().map { index, file -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let record = records.first { $0.id == file.itemID }
            let image = record.flatMap { store.fileURL($0) }.flatMap { TransitThumbnails.shared.cachedAnySize($0) }
                ?? record.map(TransitThumbnails.placeholder) ?? NSWorkspace.shared.icon(for: .data)
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 + offset, width: side, height: side), contents: image)
            return item
        }
        activePreparation = preparation
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    /// Move is offered only when every dragged file is a temporary clone, so no destination can take an original.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        activePreparation?.allowsMove == true ? [.copy, .move, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        guard let preparation = activePreparation else { return }
        activePreparation = nil
        if let store {
            store.finishDrag(preparation, operation: operation)
        } else {
            FileTransitDragPreparer.discard(preparation)
        }
    }
}

// MARK: Menus

extension FileTransitStore {
    func menu(for role: TransitTileView.Role, targetID: UUID, anchor: NSView) -> NSMenu? {
        switch role {
        case .item: itemMenu(targetID, anchor: anchor)
        case .stack: stackMenu(targetID, anchor: anchor)
        }
    }

    private func entry(_ title: String, _ symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, symbol: symbol, action: action)
        item.isEnabled = enabled
        return item
    }

    private func itemMenu(_ id: UUID, anchor: NSView) -> NSMenu? {
        guard let record = records([id]).first else { return nil }
        let writable = !isReadOnly
        let group = stack(record.stackID).flatMap { $0.isGroup ? $0 : nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(L("Open"), "arrow.up.forward.square") { [weak self] in self?.open(id) })
        menu.addItem(entry(L("Quick Look"), "eye") { [weak self] in self?.toggleQuickLook([id]) })
        if record.originalPath != nil {
            menu.addItem(entry(L("Show in Wumi"), "macwindow") { [weak self] in self?.showInDirDesk(id) })
            menu.addItem(entry(L("Reveal in Finder"), "folder") { [weak self] in self?.revealInFinder([id]) })
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Copy item to Clipboard"), "doc.on.doc") { [weak self] in self?.copyToClipboard([id]) })
        menu.addItem(entry(L("Export this item…"), "square.and.arrow.down") { [weak self] in
            self?.chooseDestinationAndExport([id], clearAfterwards: false)
        })
        menu.addItem(entry(L("Share…"), "square.and.arrow.up") { [weak self, weak anchor] in
            if let anchor { self?.share([id], from: anchor) }
        })
        menu.addItem(.separator())
        menu.addItem(entry(record.isLocked ? L("Unlock item") : L("Lock item"), record.isLocked ? "lock.open" : "lock", enabled: writable) { [weak self] in
            self?.toggleLock(id)
        })
        if let group {
            menu.addItem(entry(L("Separate items"), "square.split.2x2", enabled: writable) { [weak self] in self?.separate(group.id) })
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Remove from File Transit"), "xmark.circle", enabled: writable) { [weak self] in self?.remove([id]) })
        if let group {
            menu.addItem(entry(L("Remove stack from File Transit"), "xmark.square", enabled: writable) { [weak self] in
                self?.removeStack(group.id)
            })
        }
        return menu
    }

    private func stackMenu(_ id: UUID, anchor: NSView) -> NSMenu? {
        guard let stack = stack(id) else { return nil }
        let ids = stack.items.map(\.id)
        let writable = !isReadOnly
        let expanded = expandedStacks.contains(id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(expanded ? L("Hide Stack Items") : L("Show Stack Items"), expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
            [weak self] in self?.toggleExpanded(id)
        })
        menu.addItem(entry(L("Quick Look"), "eye") { [weak self] in self?.toggleQuickLook(ids) })
        menu.addItem(.separator())
        menu.addItem(entry(L("Copy to Clipboard"), "doc.on.doc") { [weak self] in self?.copyToClipboard(ids) })
        menu.addItem(entry(L("Export…"), "square.and.arrow.down") { [weak self] in
            self?.chooseDestinationAndExport(ids, clearAfterwards: false)
        })
        menu.addItem(entry(L("Share…"), "square.and.arrow.up") { [weak self, weak anchor] in
            if let anchor { self?.share(ids, from: anchor) }
        })
        menu.addItem(.separator())
        menu.addItem(entry(L("Separate items"), "square.split.2x2", enabled: writable) { [weak self] in self?.separate(id) })
        menu.addItem(entry(L("Remove stack from File Transit"), "xmark.square", enabled: writable) { [weak self] in self?.removeStack(id) })
        return menu
    }

    /// Menu for the shelf itself (right-click on empty space and the More button of the bottom bar).
    func shelfMenu() -> NSMenu {
        let writable = !isReadOnly
        let hasItems = !items.isEmpty
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(L("Add Files or Folders…"), "plus", enabled: writable) { [weak self] in self?.presentAddPanel() })
        menu.addItem(entry(L("Paste"), "doc.on.clipboard", enabled: writable && TransitPasteboard.canRead(.general)) { [weak self] in
            self?.importPasteboard(.general)
        })
        menu.addItem(.separator())
        menu.addItem(entry(L("Copy All"), "doc.on.doc", enabled: hasItems) { [weak self] in self?.copyAll() })
        let here = exportHereFolder
        let exportHere = entry(L("Export Here"), "square.and.arrow.down", enabled: hasItems && here != nil) { [weak self] in
            guard let self else { return }
            self.exportHere(self.items.map(\.id))
        }
        if let here { exportHere.toolTip = LF("Exports to “%@”", PathUtilities.displayName(for: here)) }
        menu.addItem(exportHere)
        menu.addItem(entry(L("Choose Export Destination…"), "folder.badge.plus", enabled: hasItems) { [weak self] in
            guard let self else { return }
            self.chooseDestinationAndExport(self.items.map(\.id), clearAfterwards: false)
        })
        menu.addItem(entry(L("Export & Clear…"), "tray.and.arrow.up", enabled: hasItems && writable) { [weak self] in
            guard let self else { return }
            self.chooseDestinationAndExport(self.items.map(\.id), clearAfterwards: true)
        })
        menu.addItem(.separator())
        menu.addItem(entry(L("Clear Unlocked Items"), "xmark.bin", enabled: writable && items.contains { !$0.isLocked }) { [weak self] in
            self?.clearUnlocked()
        })
        menu.addItem(entry(L("Restore Recently Removed"), "arrow.uturn.backward", enabled: writable && canRestore) { [weak self] in
            self?.restoreRecentlyRemoved()
        })
        return menu
    }

    /// The bottom bar's More button: the shelf menu at the pointer.
    func popUpShelfMenu() {
        guard let view = shelfView, let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(shelfMenu(), with: event, for: view)
    }
}
