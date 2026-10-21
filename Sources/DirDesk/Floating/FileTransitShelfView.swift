import AppKit
import DirDeskCore
import SwiftUI

/// The Staging tab of Floating Files: File Transit's shelf. An AppKit container hosts the SwiftUI content so the
/// whole area, cards included, accepts drops and keyboard commands.
struct FloatingStagingView: NSViewRepresentable {
    let controller: FloatingFilesController

    func makeNSView(context: Context) -> TransitShelfContainerView {
        let container = TransitShelfContainerView(store: .shared)
        let hosting = NSHostingView(rootView: TransitShelfContent())
        hosting.sizingOptions = []
        container.embed(hosting)
        return container
    }

    func updateNSView(_ nsView: TransitShelfContainerView, context: Context) {}
}

/// One row of the shelf list.
private enum TransitShelfRow: Identifiable {
    case item(FileTransitItem, nested: Bool)
    case stack(FileTransitStack, expanded: Bool)

    var id: String {
        switch self {
        case .item(let item, _): "item-\(item.id.uuidString)"
        case .stack(let stack, _): "stack-\(stack.id.uuidString)"
        }
    }
}

/// Shelf layout after the original (reference 11-中转舱与浮窗/staging-with-2-files): one rounded card per record or
/// stack with its icon, name, "kind · size · added" and six buttons; an action row (Copy All, Export & Clear, Clear
/// Unlocked Items) above the status row (count, list icon size, Add files or folders).
struct TransitShelfContent: View {
    @ObservedObject var store = FileTransitStore.shared
    @AppStorage("dirdesk-file-transit-thumbnail-scale-v1") private var scale = 0.67

    /// Card icon size, 14…32 pt (26 pt at the default slider position, as in the original).
    private var iconSize: CGFloat { (14 + 18 * scale).rounded() }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if store.items.isEmpty { emptyState } else { list }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.isDropTargeted { dropHighlight }
                VStack(spacing: 6) {
                    if let notice = store.notice {
                        TransitNoticeBanner(notice: notice) { store.dismissNotice() }
                    }
                    if let progress = store.exportProgress {
                        TransitExportBanner(progress: progress) { store.cancelExport() }
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .animation(.easeOut(duration: 0.15), value: store.notice)
            }
            if !store.items.isEmpty { actionRow }
            statusRow
        }
        .onAppear { store.shelfDidAppear() }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Image(systemName: "tray").font(.system(size: 59, weight: .ultraLight))
                Image(systemName: "doc.text").font(.system(size: 34, weight: .ultraLight)).rotationEffect(.degrees(-12)).offset(x: 4, y: -28)
            }
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
            Text(L("Drag files here")).font(.system(size: 19, weight: .semibold))
                .padding(.top, 14)
                .accessibilityIdentifier("FileTransit.EmptyTitle")
            Text(L("Park files here, then drag them wherever they are needed.")).font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 12)
                .accessibilityIdentifier("FileTransit.EmptyDescription")
            Text(L("Originals are not moved.")).font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 12.5)
        }
        // The original sits the group a little below the middle of the shelf.
        .padding(.top, 40)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            .overlay(alignment: .bottom) {
                Label(L("Drop to add to File Transit"), systemImage: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, 14)
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    // MARK: List

    private var rows: [TransitShelfRow] {
        store.stacks.flatMap { stack -> [TransitShelfRow] in
            guard stack.isGroup else { return stack.items.map { .item($0, nested: false) } }
            let expanded = store.expandedStacks.contains(stack.id)
            return [.stack(stack, expanded: expanded)] + (expanded ? stack.items.map { .item($0, nested: true) } : [])
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(rows) { row in
                    switch row {
                    case .item(let item, let nested):
                        TransitItemCard(item: item, iconSize: iconSize, store: store)
                            .padding(.leading, nested ? 26 : 0)
                            .overlay(alignment: .leading) {
                                if nested {
                                    Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: 2).padding(.vertical, 4).padding(.leading, 11)
                                }
                            }
                    case .stack(let stack, let expanded):
                        TransitStackCard(stack: stack, expanded: expanded, iconSize: iconSize, store: store)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("FileTransit.Content")
    }

    // MARK: Bottom rows

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { store.copyAll() } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 14)).frame(width: 30, height: 22)
            }
            .buttonStyle(TransitBarButtonStyle())
            .help(L("Copy All"))
            .accessibilityLabel(L("Copy All"))
            .accessibilityIdentifier("FileTransit.CopyAll")
            Button { store.chooseDestinationAndExport(store.items.map(\.id), clearAfterwards: true) } label: {
                Label(L("Export & Clear"), systemImage: "square.and.arrow.up").font(.system(size: 13)).padding(.horizontal, 6).frame(height: 22)
            }
            .buttonStyle(TransitBarButtonStyle())
            .disabled(store.isReadOnly)
            .help(L("Exports every item, then removes the exported items that are not locked."))
            .accessibilityIdentifier("FileTransit.ExportAll")
            Spacer(minLength: 8)
            if store.canRestore && !store.isReadOnly {
                Button { store.restoreRecentlyRemoved() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 14)).frame(width: 30, height: 22)
                }
                .buttonStyle(TransitBarButtonStyle())
                .help(L("Restore Recently Removed"))
                .accessibilityLabel(L("Restore Recently Removed"))
                .accessibilityIdentifier("FileTransit.Restore")
            }
            Button { store.popUpShelfMenu() } label: {
                Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 30, height: 22)
            }
            .buttonStyle(TransitBarButtonStyle())
            .help(L("More Actions"))
            .accessibilityLabel(L("More Actions"))
            .accessibilityIdentifier("FileTransit.More")
            Button { store.clearUnlocked() } label: {
                Image(systemName: "trash").font(.system(size: 14)).frame(width: 30, height: 22)
            }
            .buttonStyle(TransitBarButtonStyle())
            .disabled(store.isReadOnly)
            .help(L("Clear Unlocked Items"))
            .accessibilityLabel(L("Clear Unlocked Items"))
            .accessibilityIdentifier("FileTransit.Clear")
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// Measured from the original: the count 18 pt in, the thumbnail-size slider, and on the right the restore
    /// button (always there, dimmed when there is nothing to restore) and "Add files or folders".
    private var statusRow: some View {
        HStack(spacing: 0) {
            Text(LF("%@ items", store.items.count.formatted())).font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityIdentifier("FileTransit.Count")
            Image(systemName: "photo.on.rectangle").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.leading, 14)
            Slider(value: $scale, in: 0...1).controlSize(.mini).frame(width: 112)
                .padding(.leading, 8)
                .accessibilityLabel(L("List Thumbnail Size"))
                .accessibilityIdentifier("FileFloating.ThumbnailSize")
            Spacer()
            if store.items.isEmpty {
                Button { store.restoreRecentlyRemoved() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!store.canRestore || store.isReadOnly)
                .help(L("Restore Recently Removed"))
                .accessibilityLabel(L("Restore Recently Removed"))
                .accessibilityIdentifier("FileTransit.Restore")
                .padding(.trailing, 13.5)
            }
            Button { store.presentAddPanel() } label: {
                HStack(spacing: 8.5) {
                    Image(systemName: "plus").font(.system(size: 12))
                    Text(L("Add files or folders")).font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(store.isReadOnly)
            .accessibilityIdentifier("FileTransit.Add")
        }
        .padding(.leading, 18)
        .padding(.trailing, 19)
        .frame(height: 40)
        .padding(.bottom, 5.5)
    }
}

/// Rounded, lightly filled buttons of the action row.
private struct TransitBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: Cards

/// Name as shown: text and link records drop their .txt / .webloc extension.
private func shownName(_ item: FileTransitItem) -> String {
    item.kind == .text || item.kind == .link ? (item.name as NSString).deletingPathExtension : item.name
}

/// When a record was added, e.g. "2026/10/20 4:15" (numeric date, short time), as on the original's cards.
private func addedText(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(Localizer.shared.locale))
}

private struct TransitItemCard: View {
    let item: FileTransitItem
    let iconSize: CGFloat
    @ObservedObject var store: FileTransitStore

    private var missing: Bool { store.fileInfo[item.id]?.exists == false && item.kind != .link }

    private var kindLabel: String {
        switch item.kind {
        case .text: L("Dropped Text")
        case .link: L("Web Link")
        case .directory: L("Folder")
        case .image: item.isManaged ? L("Dropped Image") : L("File")
        case .file: item.isManaged ? L("Dropped File") : L("File")
        }
    }

    private var sizeLabel: String? {
        if item.kind == .link { return item.linkURL?.host }
        if let bytes = store.fileInfo[item.id]?.byteCount ?? (item.isManaged ? item.managedByteCount : nil) {
            return FileSizeFormatter.string(bytes, unit: AppModel.shared.preferences.fileSizeUnit)
        }
        return nil
    }

    private var place: String { item.linkURL?.absoluteString ?? item.originalPath ?? item.name }

    var body: some View {
        let selected = store.selection.contains(item.id)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                TransitIcon(item: item, url: store.fileURL(item), size: iconSize, dimmed: missing)
                    .overlay(alignment: .bottomTrailing) {
                        if item.isLocked { TransitLockBadge().offset(x: 4, y: 3) }
                    }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(L("Drag this item out"))
                    .accessibilityIdentifier("FileTransit.DragItem.\(item.id.uuidString)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(shownName(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 0) {
                        if missing {
                            Text(L("Missing")).foregroundStyle(.orange)
                        } else {
                            Text(kindLabel)
                            if let sizeLabel {
                                Text(" · ")
                                Text(sizeLabel).accessibilityIdentifier("FileTransit.Size.\(item.id.uuidString)")
                            }
                        }
                        Text(" · ")
                        Text(addedText(item.addedAt)).accessibilityIdentifier("FileTransit.Added.\(item.id.uuidString)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(TransitTileHost(store: store, role: .item, targetID: item.id,
                                     toolTip: place + "\n" + L("Dragging out never moves the originals. A move drop takes unlocked items off the shelf; a copy drop keeps them.")))
            HStack(spacing: 2) {
                cardButton("doc.on.doc", L("Copy item to Clipboard"), id: "CopyItem") { store.copyToClipboard([item.id]) }
                cardButton("square.and.arrow.up", L("Share…"), id: "ShareItem") { store.share([item.id]) }
                cardButton("arrow.up.doc", L("Export this item…"), id: "ExportItem") { store.chooseDestinationAndExport([item.id], clearAfterwards: false) }
                cardButton("eye", L("Quick Look"), id: "PreviewItem") { store.toggleQuickLook([item.id]) }
                cardButton(item.isLocked ? "pin.fill" : "pin", item.isLocked ? L("Unlock item") : L("Lock item"), id: "LockItem",
                           tint: item.isLocked ? .orange : nil) { store.toggleLock(item.id) }
                    .disabled(store.isReadOnly)
                cardButton("xmark.circle.fill", L("Remove from File Transit"), id: "RemoveItem") { store.remove([item.id]) }
                    .disabled(store.isReadOnly)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: max(iconSize, 34) + 16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shownName(item))
        .accessibilityValue(item.isLocked ? L("Locked") : kindLabel)
        .accessibilityIdentifier("FileTransit.Item.\(item.id.uuidString)")
    }

    private func cardButton(_ symbol: String, _ title: String, id: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        TransitCardButton(symbol: symbol, title: title, tint: tint, action: action)
            .accessibilityIdentifier("FileTransit.\(id).\(item.id.uuidString)")
    }
}

private struct TransitStackCard: View {
    let stack: FileTransitStack
    let expanded: Bool
    let iconSize: CGFloat
    @ObservedObject var store: FileTransitStore

    private var ids: [UUID] { stack.items.map(\.id) }

    var body: some View {
        let selected = store.selection.contains(stack.id)
        HStack(spacing: 10) {
            Button { store.toggleExpanded(stack.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(expanded ? L("Hide Stack Items") : L("Show Stack Items"))
            .accessibilityLabel(expanded ? L("Hide Stack Items") : L("Show Stack Items"))
            .accessibilityIdentifier("FileTransit.StackPreview.\(stack.id.uuidString)")
            HStack(spacing: 10) {
                ZStack {
                    ForEach(Array(stack.items.prefix(3).enumerated()).reversed(), id: \.element.id) { index, item in
                        TransitIcon(item: item, url: store.fileURL(item), size: iconSize * 0.86, dimmed: false)
                            .offset(x: CGFloat(index) * 4 - 4, y: CGFloat(index) * -3 + 3)
                    }
                }
                .frame(width: iconSize + 6, height: iconSize)
                .overlay(alignment: .topTrailing) {
                    Text(stack.items.count.formatted())
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 7, y: -6)
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(L("Drag this stack out"))
                .accessibilityIdentifier("FileTransit.DragStack.\(stack.id.uuidString)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(LF("%lld items", Int64(stack.items.count))).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 0) {
                        Text(stack.items.map(shownName).joined(separator: ", ")).truncationMode(.tail)
                            .accessibilityIdentifier("FileTransit.StackSummary.\(stack.id.uuidString)")
                        Text(" · ")
                        Text(addedText(stack.items.map(\.addedAt).min() ?? Date()))
                            .fixedSize()
                            .accessibilityIdentifier("FileTransit.Added.\(stack.id.uuidString)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(TransitTileHost(store: store, role: .stack, targetID: stack.id,
                                     toolTip: L("Drag this stack out") + "\n" + stack.items.map(shownName).joined(separator: "\n")))
            HStack(spacing: 2) {
                cardButton("doc.on.doc", L("Copy to Clipboard"), id: "CopyStack") { store.copyToClipboard(ids) }
                cardButton("square.and.arrow.up", L("Share…"), id: "ShareStack") { store.share(ids) }
                cardButton("arrow.up.doc", L("Export…"), id: "ExportStack") { store.chooseDestinationAndExport(ids, clearAfterwards: false) }
                cardButton("eye", L("Quick Look"), id: "PreviewStack") { store.toggleQuickLook(ids) }
                cardButton("square.split.1x2", L("Separate items"), id: "FlattenStack") { store.separate(stack.id) }
                    .disabled(store.isReadOnly)
                cardButton("xmark.circle.fill", L("Remove stack from File Transit"), id: "RemoveStack") { store.removeStack(stack.id) }
                    .disabled(store.isReadOnly)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: max(iconSize, 34) + 16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LF("%lld items", Int64(stack.items.count)))
        .accessibilityIdentifier("FileTransit.Stack.\(stack.id.uuidString)")
    }

    private func cardButton(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        TransitCardButton(symbol: symbol, title: title, tint: nil, action: action)
            .accessibilityIdentifier("FileTransit.\(id).\(stack.id.uuidString)")
    }
}

private struct TransitCardButton: View {
    let symbol: String
    let title: String
    let tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(isEnabled ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.4)))
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct TransitLockBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Color.orange))
            .accessibilityHidden(true)
    }
}

/// Icon of a record: links get a link glyph; images a Quick Look thumbnail; everything else its file icon.
private struct TransitIcon: View {
    let item: FileTransitItem
    let url: URL?
    let size: CGFloat
    let dimmed: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if item.kind == .link {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(nsColor: .systemTeal), Color(nsColor: .systemBlue)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "link").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
                    .frame(width: size * 0.86, height: size * 0.86)
            } else {
                Image(nsImage: image ?? url.flatMap { TransitThumbnails.shared.cached($0, size: size) } ?? TransitThumbnails.placeholder(for: item))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.4 : 1)
        .task(id: "\(url?.path ?? "")|\(Int(size))") {
            guard item.kind != .link, let url else { return }
            image = await TransitThumbnails.shared.image(for: url, size: size, preferThumbnail: TransitThumbnails.prefersThumbnail(item))
        }
    }
}

// MARK: Banners

private struct TransitNoticeBanner: View {
    let notice: FileTransitStore.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            Text(notice.message).font(.system(size: 12)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !notice.isSticky {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Close"))
                    .accessibilityLabel(L("Close"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("FileTransit.Notice")
    }
}

private struct TransitExportBanner: View {
    let progress: FileTransitStore.ExportProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Exporting…")).font(.system(size: 12))
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))).frame(width: 140)
            Text("\(progress.completed)/\(progress.total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            Button(L("Cancel"), action: cancel).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FileTransit.ExportProgress")
    }
}

// MARK: AppKit bridge

/// The AppKit layer over a card's icon and name: click, double-click, context menu and dragging out.
private struct TransitTileHost: NSViewRepresentable {
    let store: FileTransitStore
    let role: TransitTileView.Role
    let targetID: UUID
    let toolTip: String

    func makeNSView(context: Context) -> TransitTileView {
        let view = TransitTileView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: TransitTileView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TransitTileView) {
        view.store = store
        view.role = role
        view.targetID = targetID
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}
