import AppKit
import Combine
import DirDeskCore
import Quartz
import SwiftUI

/// Icon view, and the filmstrip of the image (gallery) view.
@MainActor
final class FileGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    let pane: PaneRuntime
    weak var handler: BrowserActionHandler?
    let gallery: Bool
    let collectionView = FileCollectionView()
    private let scrollView = NSScrollView()
    private var items: [FileItem] = []
    private var sections: [(title: String?, items: [FileItem])] = []
    private var cancellables: Set<AnyCancellable> = []
    private var applyingSelection = false
    private var springTimer: Timer?
    private var springTarget: URL?
    private var sizesEnabled = true
    var allowsSpringLoading = true

    /// Spring-loaded folders: hovering a drag over a folder opens it after the configured delay.
    private func scheduleSpringLoad(_ folder: FileItem) {
        guard allowsSpringLoading else { return }
        guard springTarget != folder.url else { return }
        springTimer?.invalidate()
        springTarget = folder.url
        springTimer = Timer.scheduledTimer(withTimeInterval: AppModel.shared.preferences.dragHoverExpansionDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.allowsSpringLoading, self.springTarget == folder.url else { return }
                self.springTarget = nil
                self.pane.open(folder.url)
            }
        }
    }

    init(pane: PaneRuntime, handler: BrowserActionHandler?, gallery: Bool) {
        self.pane = pane
        self.handler = handler
        self.gallery = gallery
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let layout = gallery ? NSCollectionViewFlowLayout() : LeftAlignedFlowLayout()
        layout.scrollDirection = gallery ? .horizontal : .vertical
        // Icon grid metrics from the original: 62 pt cells on an 84.5 pt pitch, rows 100 pt apart, the first cell
        // 15 pt from the pane's left edge and 14 pt from its top.
        // The gallery strip: 112 × 104 pt cells on a 120 pt pitch, 10 pt from the left and 14 pt from the top.
        layout.minimumInteritemSpacing = gallery ? 8 : 22.5
        layout.minimumLineSpacing = gallery ? 8 : 16
        layout.sectionInset = gallery ? NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10) : NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        layout.headerReferenceSize = .zero
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        collectionView.register(FileGridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: FileGridHeader.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.owner = self
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = !gallery
        scrollView.hasHorizontalScroller = gallery
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
        pane.$rows.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &cancellables)
        pane.$selectedIDs.receive(on: RunLoop.main).sink { [weak self] ids in self?.applySelection(ids) }.store(in: &cancellables)
        pane.$hasPendingSelection.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] pending in
            if !pending { self?.selectGalleryDefaultIfNeeded() }
        }.store(in: &cancellables)
        pane.$viewConfiguration.receive(on: RunLoop.main).sink { [weak self] _ in self?.collectionView.collectionViewLayout?.invalidateLayout() }.store(in: &cancellables)
        AppModel.shared.$configuration.receive(on: RunLoop.main).sink { [weak self] _ in
            // Reloading drops the selection; put the pane's back.
            guard let self else { return }
            self.collectionView.reloadData()
            self.applySelection(self.pane.selectedIDs)
        }.store(in: &cancellables)
    }

    private func reload() {
        if gallery || pane.viewConfiguration.groupingMode == .none {
            items = pane.displayItems
            sections = [(nil, items)]
        } else {
            sections = pane.groups.map { ($0.isLiteral ? $0.title : L($0.title), $0.items) }
            items = sections.flatMap(\.items)
        }
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.headerReferenceSize = sections.count > 1 || sections.first?.title != nil ? NSSize(width: 100, height: 26) : .zero
        }
        collectionView.reloadData()
        selectGalleryDefaultIfNeeded()
        applySelection(pane.selectedIDs)
    }

    private func selectGalleryDefaultIfNeeded() {
        // Let restored/pending selections finish before choosing the gallery's default item.
        if gallery, pane.loadState == .loaded, !pane.hasPendingSelection,
           pane.selectedIDs.isEmpty, let first = items.first {
            pane.selectedIDs = [first.id]
        }
    }

    /// Default icon cells match the original: a 58 × 44 pt thumbnail box, one name line and the size underneath,
    /// in a 62 pt wide cell.
    var cellSize: NSSize {
        if gallery { return NSSize(width: 112, height: 104) }
        return NSSize(width: iconSize + 4, height: iconBoxHeight + 40)
    }

    private var iconBoxHeight: CGFloat { (iconSize * 44 / 58).rounded() }

    private var iconSize: CGFloat {
        58 * pane.viewConfiguration.gridThumbnailScale * AppModel.shared.preferences.iconGridScale
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    /// Logical size; directory totals arrive from the shared background metadata scan.
    static func detailText(for item: FileItem) -> String {
        FolderSizes.text(item, state: nil, unit: AppModel.shared.preferences.fileSizeUnit)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath) as! FileGridItem
        let item = sections[indexPath.section].items[indexPath.item]
        cell.configure(item: item, iconSize: gallery ? 75 : iconSize, iconHeight: gallery ? 56 : iconBoxHeight, showsName: true,
                       truncation: AppModel.shared.preferences.filenameTruncation, sizeText: Self.detailText(for: item),
                       filledSelection: gallery, measuresSize: sizesEnabled,
                       measuredSize: { [weak pane] state in pane?.recordDirectorySize(item, state: state) })
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? FileGridItem)?.stopSizeObservation()
    }

    func stopSizeRequests() {
        setSizeRequestsEnabled(false)
    }

    func setSizeRequestsEnabled(_ enabled: Bool) {
        guard enabled != sizesEnabled else { return }
        sizesEnabled = enabled
        guard isViewLoaded else { return }
        for item in collectionView.visibleItems() { (item as? FileGridItem)?.stopSizeObservation() }
        if enabled { reload() }
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: FileGridHeader.identifier, for: indexPath) as! FileGridHeader
        header.label.stringValue = sections[indexPath.section].title ?? ""
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize { cellSize }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }

    private func syncSelection() {
        guard !applyingSelection else { return }
        pane.selectedIDs = Set(collectionView.selectionIndexPaths.compactMap { item(at: $0)?.id })
        handler?.activate(pane: pane)
    }

    private func applySelection(_ ids: Set<FileIdentity>) {
        var paths = Set<IndexPath>()
        for (s, section) in sections.enumerated() {
            for (i, item) in section.items.enumerated() where ids.contains(item.id) { paths.insert(IndexPath(item: i, section: s)) }
        }
        guard paths != collectionView.selectionIndexPaths else { return }
        applyingSelection = true
        collectionView.selectionIndexPaths = paths
        if let first = paths.min() { collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        applyingSelection = false
    }

    func item(at indexPath: IndexPath) -> FileItem? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    func selectedItems() -> [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { item(at: $0) }
    }

    func openSelection() {
        let selected = selectedItems()
        if !selected.isEmpty { handler?.open(selected, in: pane, newTab: false) }
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath)?.url as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let urls = FileListController.fileURLs(from: draggingInfo), let destination = dropDestination(proposedDropIndexPath.pointee as IndexPath, proposedDropOperation.pointee) else { return [] }
        if proposedDropOperation.pointee == .before { proposedDropOperation.pointee = .on }
        if proposedDropOperation.pointee == .on, let folder = item(at: proposedDropIndexPath.pointee as IndexPath), folder.isBrowsableFolder {
            scheduleSpringLoad(folder)
        } else {
            springTimer?.invalidate()
            springTarget = nil
        }
        let operation = FileListController.allowsDrop(urls, into: destination)
            ? FileListController.dropOperation(for: urls, destination: destination, info: draggingInfo) : []
        DragFeedbackPanel.shared.update(operation: operation, destination: destination)
        return operation
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        DragFeedbackPanel.shared.hide()
        guard let urls = FileListController.fileURLs(from: draggingInfo), let destination = dropDestination(indexPath, dropOperation) else { return false }
        return handler?.acceptDrop(urls, into: destination, operation: FileListController.dropOperation(for: urls, destination: destination, info: draggingInfo), in: pane) ?? false
    }

    private func dropDestination(_ indexPath: IndexPath, _ operation: NSCollectionView.DropOperation) -> URL? {
        if operation == .on, let item = item(at: indexPath), item.isBrowsableFolder { return item.url }
        return pane.currentDirectory
    }
}

final class FileCollectionView: NSCollectionView, QLPreviewPanelDataSource {
    weak var owner: FileGridController?

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch event.keyCode {
        case 36, 76 where flags.isEmpty:
            if AppModel.shared.preferences.enterKeyAction == .rename, owner.selectedItems().count == 1, let item = owner.selectedItems().first {
                owner.pane.renamingID = item.id
                owner.handler?.perform(.rename)
            } else {
                owner.openSelection()
            }
        case 49 where flags.isEmpty:
            if owner.handler?.previewWithSpace(owner.selectedItems(), in: owner.pane) != true, let panel = QLPreviewPanel.shared() {
                panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            }
        case 125 where flags == .command:
            owner.openSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let owner else { return }
        owner.handler?.activate(pane: owner.pane)
        let point = convert(event.locationInWindow, from: nil)
        let hit = indexPathForItem(at: point)
        if event.clickCount == 2 {
            if let hit, let item = owner.item(at: hit) {
                owner.handler?.open([item], in: owner.pane, newTab: event.modifierFlags.contains(.command))
            } else if let command = BlankSpaceDoubleClick.command {
                owner.handler?.perform(command)
            }
        } else if event.clickCount == 1, AppModel.shared.preferences.opensItemsWithSingleClick, let hit, let item = owner.item(at: hit) {
            owner.handler?.open([item], in: owner.pane, newTab: false)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(hit) {
                selectionIndexPaths = [hit]
                owner.collectionView(self, didSelectItemsAt: [hit])
            }
            return owner.handler?.contextMenu(for: owner.selectedItems(), in: owner.pane)
        }
        deselectAll(nil)
        return owner.handler?.backgroundMenu(in: owner.pane)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { owner?.selectedItems().count ?? 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard let items = owner?.selectedItems(), items.indices.contains(index) else { return nil }
            return items[index].url as NSURL
        }
    }
}

final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let cloudBadge = CloudStatusBadgeView()
    /// Finder color tags as dots on the thumbnail's upper right, as in the original's icon view.
    private let tagDots = TagDotsView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var path: String?
    private var assetRevision: UInt64 = 0
    private var sizeObservation: AnyCancellable?

    func stopSizeObservation() { sizeObservation = nil }
    private var hasContentThumbnail = false
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var iconTop: NSLayoutConstraint!
    private var labelTop: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        label.alignment = .center
        label.maximumNumberOfLines = 1
        // 12 pt names fit "image.heic" in the 62 pt cell, as in the original.
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        detail.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)
        root.addSubview(badge)
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tagDots)
        root.addSubview(label)
        root.addSubview(detail)
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cloudBadge)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 58)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 58)
        iconTop = icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4)
        labelTop = label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3)
        NSLayoutConstraint.activate([
            iconTop,
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconWidth, iconHeight,
            badge.widthAnchor.constraint(equalToConstant: 12),
            badge.heightAnchor.constraint(equalToConstant: 12),
            badge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: -2),
            badge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: -8),
            // Keep the cloud state clear of the application badge and Finder tag dots on the right.
            cloudBadge.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            cloudBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 18),
            cloudBadge.heightAnchor.constraint(equalToConstant: 14),
            tagDots.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            tagDots.topAnchor.constraint(equalTo: icon.topAnchor, constant: -2),
            labelTop,
            // Text fields inset their text by 2 pt; widen them so names use the cell's full width, as in the original.
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: 2),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -2),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: 2),
        ])
        view = root
        imageView = icon
        textField = label
    }

    private var filledSelection = false

    /// `iconHeight` gives the icon grid's wider-than-tall thumbnail box (58 × 44 pt by default); the gallery strip
    /// keeps square boxes.
    func configure(item: FileItem, iconSize: CGFloat, iconHeight boxHeight: CGFloat? = nil, showsName: Bool, truncation: FilenameTruncation,
                   sizeText: String? = nil, filledSelection: Bool = false, measuresSize: Bool = true,
                   measuredSize: ((FolderSizeState) -> Void)? = nil) {
        stopSizeObservation()
        self.filledSelection = filledSelection
        path = item.url.path
        assetRevision &+= 1
        let revision = assetRevision
        hasContentThumbnail = false
        iconWidth.constant = iconSize
        iconHeight.constant = boxHeight ?? iconSize
        iconTop.constant = filledSelection ? 6 : 0
        labelTop.constant = filledSelection ? 8 : 6.5
        let wanted = item.url.path
        icon.image = FileIcons.shared.icon(for: item) { [weak self] image in
            guard let self, self.path == wanted, self.assetRevision == revision, !self.hasContentThumbnail else { return }
            self.icon.image = image
        }
        badge.isHidden = true
        cloudBadge.configure(item.cloudStatus)
        tagDots.colors = item.tags.compactMap { TagColors.color(forTag: $0) }
        label.stringValue = item.name
        label.isHidden = !showsName
        label.lineBreakMode = switch truncation {
        case .middle: .byTruncatingMiddle
        case .tail: .byTruncatingTail
        case .head: .byTruncatingHead
        }
        label.toolTip = item.name
        detail.stringValue = sizeText ?? ""
        detail.toolTip = nil
        detail.isHidden = sizeText == nil || !showsName
        if measuresSize, showsName, sizeText != nil, FolderSizes.needsMeasurement(item) {
            sizeObservation = FolderSizes.shared.observe(item) { [weak self] state in
                guard let self, self.path == wanted, self.assetRevision == revision else { return }
                self.detail.stringValue = FolderSizes.text(item, state: state, unit: AppModel.shared.preferences.fileSizeUnit)
                self.detail.toolTip = FolderSizes.help(state)
                measuredSize?(state)
            }
        }
        view.alphaValue = item.isHidden ? 0.5 : 1
        if !item.isBrowsableFolder {
            let wanted = item.url.path
            FileIcons.shared.thumbnail(for: item, size: iconSize) { [weak self] image in
                guard let self, let image, self.path == wanted, self.assetRevision == revision else { return }
                self.hasContentThumbnail = true
                self.icon.image = image
                // A content thumbnail gets the opening app's icon as a corner badge, as in the original.
                guard showsName else { return }
                FileIcons.shared.defaultApplicationBadge(for: item) { [weak self] appIcon in
                    guard let self, let appIcon, self.path == wanted, self.assetRevision == revision else { return }
                    self.badge.image = appIcon
                    self.badge.isHidden = false
                }
            }
        }
        view.setAccessibilityLabel(cloudBadge.accessibilityLabel(forFileName: item.name))
        updateSelection()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        path = nil
        assetRevision &+= 1
        cloudBadge.configure(nil)
        view.setAccessibilityLabel(nil)
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    /// The gallery strip marks the current item with a solid accent background and white text (as the original);
    /// the icon grid uses a light tint.
    private func updateSelection() {
        if filledSelection {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
            label.textColor = isSelected ? .white : .labelColor
            detail.textColor = isSelected ? .white : .secondaryLabelColor
        } else {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            label.textColor = .labelColor
            detail.textColor = .secondaryLabelColor
        }
    }
}

final class FileGridHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct FileGridRepresentable: View {
    @ObservedObject var pane: PaneRuntime
    let controller: WorkspaceController
    let gallery: Bool

    var body: some View {
        if gallery {
            VStack(spacing: 0) {
                GalleryPreview(pane: pane)
                Divider()
                GridHost(pane: pane, controller: controller, gallery: true)
                    .frame(height: 132)
            }
        } else {
            GridHost(pane: pane, controller: controller, gallery: false)
        }
    }
}

private struct GridHost: NSViewControllerRepresentable {
    let pane: PaneRuntime
    let controller: WorkspaceController
    let gallery: Bool

    func makeNSViewController(context: Context) -> FileGridController {
        let grid = FileGridController(pane: pane, handler: controller, gallery: gallery)
        controller.register(grid: grid, for: pane)
        return grid
    }

    func updateNSViewController(_ nsViewController: FileGridController, context: Context) {}

    static func dismantleNSViewController(_ controller: FileGridController, coordinator: ()) {
        controller.stopSizeRequests()
    }
}

/// Large preview of the selected (or first) item for the gallery view, with its name and kind · size underneath.
private struct GalleryPreview: View {
    @ObservedObject var pane: PaneRuntime
    @State private var folderSize: FolderSizeState?

    private struct SizeRequest: Equatable {
        let url: URL?
        let revision: Int
    }

    private var item: FileItem? {
        pane.selectedItems.first ?? pane.displayItems.first
    }

    var body: some View {
        // The preview fills the area above a dark band that holds its tools, the name and kind · size.
        VStack(spacing: 0) {
            if let item {
                PreviewContent(item: item, showsImageRotation: true)
                    .id(item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if let status = item.cloudStatus {
                            GalleryCloudBadge(status: status).frame(width: 18, height: 14)
                        }
                    }
                    Text(pane.kindText(item) + " · " + FolderSizes.text(item, state: folderSize, unit: AppModel.shared.preferences.fileSizeUnit))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 9.5)
                .padding(.bottom, 6)
                .background(Theme.chrome)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: SizeRequest(url: item?.url, revision: pane.directoryContentRevision)) {
            folderSize = nil
            guard let item, FolderSizes.needsMeasurement(item) else { return }
            for await state in FolderSizes.shared.updates(for: item) {
                guard !Task.isCancelled else { return }
                folderSize = state
            }
        }
    }
}

private struct GalleryCloudBadge: NSViewRepresentable {
    let status: FileCloudStatus

    func makeNSView(context: Context) -> CloudStatusBadgeView { CloudStatusBadgeView() }

    func updateNSView(_ nsView: CloudStatusBadgeView, context: Context) {
        nsView.configure(status)
    }
}

/// Flow layout that keeps the interitem spacing fixed and packs each row to the left, as the original's icon grid does.
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let attributes = super.layoutAttributesForElements(in: rect).map { $0.copy() as! NSCollectionViewLayoutAttributes }
        var rowTop: CGFloat = -.greatestFiniteMagnitude
        var x = sectionInset.left
        for attribute in attributes where attribute.representedElementCategory == .item {
            if abs(attribute.frame.minY - rowTop) > 1 {
                rowTop = attribute.frame.minY
                x = sectionInset.left
            }
            attribute.frame.origin.x = x
            x += attribute.frame.width + minimumInteritemSpacing
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attribute = super.layoutAttributesForItem(at: indexPath) else { return nil }
        let row = layoutAttributesForElements(in: NSRect(x: 0, y: attribute.frame.minY, width: collectionViewContentSize.width, height: attribute.frame.height))
        return row.first { $0.indexPath == indexPath } ?? attribute
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}
