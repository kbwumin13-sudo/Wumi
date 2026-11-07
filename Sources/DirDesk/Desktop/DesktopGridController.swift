import AppKit
import Combine
import DirDeskCore
import SwiftUI

struct DesktopGridHost: NSViewControllerRepresentable {
    let coordinator: DesktopCoordinator
    let pane: PaneRuntime
    let zoneID: String
    let screenID: String
    let standard: Bool
    func makeNSViewController(context: Context) -> DesktopGridController {
        DesktopGridController(coordinator: coordinator, pane: pane, zoneID: zoneID, screenID: screenID, standard: standard)
    }
    func updateNSViewController(_ controller: DesktopGridController, context: Context) { controller.update(standard: standard) }
    static func dismantleNSViewController(_ controller: DesktopGridController, coordinator: ()) { controller.stop() }
}

/// The ungrouped desktop uses FileGridController directly. Collection zones reuse its native cells and
/// selection/drag conventions with a projection of the same PaneRuntime, so there is no second directory scan.
@MainActor
final class DesktopGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                   NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    let coordinator: DesktopCoordinator
    let pane: PaneRuntime
    let actions: DesktopBrowserActions
    let zoneID: String
    private var standard: Bool
    private var browser: FileGridController?
    private let collection = DesktopCollectionView()
    private let scroll = NSScrollView()
    private var represented: [FileItem] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var editor: NSTextField?
    private var editingItem: FileItem?
    private var syncing = false
    init(coordinator: DesktopCoordinator, pane: PaneRuntime, zoneID: String, screenID: String, standard: Bool) {
        self.coordinator = coordinator; self.pane = pane; self.zoneID = zoneID; self.standard = standard
        actions = DesktopBrowserActions(coordinator: coordinator, pane: pane, zoneID: zoneID, screenID: screenID)
        super.init(nibName: nil, bundle: nil)
        actions.onRename = { [weak self] item in self?.beginRename(item) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView()
        let flow = LeftAlignedFlowLayout()
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        flow.itemSize = NSSize(width: 88, height: 96)
        collection.collectionViewLayout = flow
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.owner = self
        collection.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collection.setAccessibilityIdentifier("Desktop.Grid.\(zoneID)")
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        rebuildHost()
        pane.$rows.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        pane.$selectedIDs.receive(on: RunLoop.main).sink { [weak self] _ in self?.applySelection() }.store(in: &subscriptions)
        pane.$renamingID.receive(on: RunLoop.main).sink { [weak self] id in
            guard let self, let id, self.editor == nil, let item = self.pane.items.first(where: { $0.id == id }), self.owns(item) else { return }
            self.beginRename(item)
        }.store(in: &subscriptions)
        coordinator.$layout.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window,
                  let responder = self.view.window?.firstResponder as? NSView,
                  responder === self.activeCollection || responder.isDescendant(of: self.activeCollection) else { return event }
            return self.handleKey(event) ? nil : event
        }
        reload()
    }
    private var activeCollection: NSCollectionView { browser?.collectionView ?? collection }
    private func rebuildHost() {
        browser?.stopSizeRequests()
        browser?.view.removeFromSuperview()
        browser?.removeFromParent()
        browser = nil
        scroll.removeFromSuperview()
        let child: NSView
        if standard {
            let browser = FileGridController(pane: pane, handler: actions, gallery: false)
            browser.allowsSpringLoading = false
            browser.setSizeRequestsEnabled(false)
            self.browser = browser
            addChild(browser)
            child = browser.view
        } else { child = scroll }
        view.addSubview(child)
        child.frame = view.bounds
        child.autoresizingMask = [.width, .height]
    }
    func update(standard: Bool) {
        if standard != self.standard {
            cancelRename()
            self.standard = standard
            if isViewLoaded { rebuildHost() }
        }
    }
    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        subscriptions.removeAll()
        browser?.stopSizeRequests()
        collection.visibleItems().forEach { ($0 as? FileGridItem)?.stopSizeObservation() }
        cancelRename()
    }
    func owns(_ item: FileItem) -> Bool { standard || coordinator.layout.zoneID(for: item) == zoneID }
    func reload() {
        guard isViewLoaded else { return }
        represented = coordinator.items(in: zoneID)
        if !standard { collection.reloadData(); applySelection() }
    }
    private func applySelection() {
        guard !standard, !syncing else { return }
        syncing = true
        collection.selectionIndexPaths = Set(represented.enumerated().compactMap { pane.selectedIDs.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
        syncing = false
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { represented.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath) as! FileGridItem
        let item = represented[indexPath.item]
        cell.configure(item: item, iconSize: 58, iconHeight: 44, showsName: true,
                       truncation: AppModel.shared.preferences.filenameTruncation, sizeText: nil,
                       filledSelection: true, measuresSize: false)
        return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func selectionChanged() {
        guard !syncing else { return }
        syncing = true
        pane.selectedIDs = Set(collection.selectionIndexPaths.compactMap { item(at: $0)?.id })
        syncing = false
        actions.activate(pane: pane)
    }
    func item(at indexPath: IndexPath) -> FileItem? { represented.indices.contains(indexPath.item) ? represented[indexPath.item] : nil }
    func selected() -> [FileItem] { collection.selectionIndexPaths.sorted().compactMap { item(at: $0) } }
    func handleKey(_ event: NSEvent) -> Bool {
        if editor != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "a":
                if standard { pane.selectAll() }
                else { pane.selectedIDs = Set(represented.map(\.id)) }
            case "c": actions.perform(.copy)
            case "x": actions.perform(.cut)
            case "v": actions.perform(.paste)
            case "z": coordinator.desktopUndo.undo()
            case "f": actions.perform(.search)
            default:
                if event.keyCode == 51 { actions.perform(.moveToTrash) }
                else if event.keyCode == 125 { actions.perform(.openSelection) }
                else { return false }
            }
            return true
        }
        if flags == [.command, .shift], key == "z" { coordinator.desktopUndo.redo(); return true }
        if flags == [.command, .shift], key == "n" { actions.perform(.newFolder); return true }
        if flags == [.command, .option], key == "n" { actions.perform(.newFile); return true }
        if flags == [.command, .option], key == "v" { actions.perform(.pasteAndMove); return true }
        if flags.isEmpty, event.keyCode == 36 { actions.perform(.rename); return true }
        if flags.isEmpty, event.keyCode == 49 { actions.perform(.quickLook); return true }
        if flags.isEmpty, event.keyCode == 53 { pane.selectedIDs = []; return true }
        return false
    }
    private func beginRename(_ item: FileItem) {
        guard isViewLoaded, owns(item), editor == nil else { return }
        let candidates = standard ? pane.displayItems : represented
        guard let index = candidates.firstIndex(where: { $0.id == item.id }) else { return }
        let path = IndexPath(item: index, section: 0)
        let target = activeCollection
        target.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        target.layoutSubtreeIfNeeded()
        let cellFrame = target.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame ?? NSRect(x: 12, y: 12, width: 140, height: 90)
        let field = NSTextField(frame: NSRect(x: max(0, cellFrame.midX - 70), y: cellFrame.minY + 48, width: 140, height: 24))
        field.stringValue = item.name
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.target = self
        field.action = #selector(commitEditor(_:))
        field.setAccessibilityIdentifier("Desktop.RenameField")
        target.addSubview(field)
        editor = field
        editingItem = item
        view.window?.makeKey()
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    @objc private func commitEditor(_ sender: NSTextField) {
        guard let item = editingItem else { return }
        let name = sender.stringValue
        cancelRename()
        actions.commitRename(item, to: name, in: pane)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelRename(); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor, let item = editingItem else { return }
        let name = editor.stringValue
        cancelRename()
        if name != item.name { actions.commitRename(item, to: name, in: pane) }
    }
    private func cancelRename() {
        let old = editor
        let id = editingItem?.id
        editor = nil; editingItem = nil
        old?.delegate = nil
        old?.removeFromSuperview()
        if let id, pane.renamingID == id { pane.renamingID = nil }
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? { item(at: indexPath)?.url as NSURL? }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let urls = FileListController.fileURLs(from: draggingInfo), !urls.isEmpty else { return [] }
        if proposedDropOperation.pointee == .on, let folder = item(at: proposedDropIndexPath.pointee as IndexPath), folder.isBrowsableFolder {
            return urls.contains(where: { FileOperationCoordinator.isInside(folder.url, $0) }) ? [] : preferredDrop(draggingInfo)
        }
        proposedDropOperation.pointee = .before
        return .copy
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = FileListController.fileURLs(from: draggingInfo), let directory = pane.currentDirectory else { return false }
        if dropOperation == .on, let folder = item(at: indexPath), folder.isBrowsableFolder {
            return actions.acceptDrop(urls, into: folder.url, operation: preferredDrop(draggingInfo), in: pane)
        }
        return actions.acceptDrop(urls, into: directory, operation: preferredDrop(draggingInfo), in: pane)
    }
    private func preferredDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        return info.draggingSourceOperationMask.contains(.move) ? .generic : .copy
    }
}

final class DesktopCollectionView: NSCollectionView {
    weak var owner: DesktopGridController?
    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let owner else { return }
        owner.actions.activate(pane: owner.pane)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), let item = owner.item(at: path) {
            owner.actions.open([item], in: owner.pane, newTab: event.modifierFlags.contains(.command))
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        if let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(hit) { selectionIndexPaths = [hit]; owner.selectionChanged() }
            return owner.actions.contextMenu(for: owner.selected(), in: owner.pane)
        }
        deselectAll(nil)
        return owner.actions.backgroundMenu(in: owner.pane)
    }
}
