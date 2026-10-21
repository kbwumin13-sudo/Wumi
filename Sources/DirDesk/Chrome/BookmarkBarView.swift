import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Bookmarks and workspace bar above the panes.
struct BookmarkBarView: View {
    @ObservedObject var library = LibraryModel.shared
    @ObservedObject var app = AppModel.shared
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var workspaces = NamedWorkspaceLibrary.shared
    let controller: WorkspaceController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingAllBookmarks = false

    var body: some View {
        let preferences = app.preferences
        HStack(spacing: 4) {
            // Same items and order as the original's bookmark actions menu.
            Menu {
                Button(L("Add Current Folder")) { controller.addBookmarkForCurrentFolder() }
                Button(L("Add Selected Items")) { controller.addBookmarksForSelection() }
                    .disabled(model.activePane.selectedIDs.isEmpty)
                Button(L("New Bookmark Folder")) { controller.newBookmarkFolder(parent: nil) }
                Button(L("Import Finder Favorites…")) { controller.importFinderFavorites() }
                    .accessibilityIdentifier("Bookmarks.ImportFinder")
                Button(L("Manage Bookmarks…")) { controller.showBookmarkManager() }
            } label: {
                Image(nsImage: BookmarkBarGlyphs.bookmark)
                    .frame(width: 9, height: 14)
                    .contentShape(Rectangle())
            }
            // A button-style menu draws the label itself, so the ribbon keeps its size and colour.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Bookmark Actions"))
            .accessibilityLabel(L("Bookmark Actions"))
            .accessibilityIdentifier("BookmarkBar.Actions")
            .padding(.trailing, 11.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(library.bookmarks.roots) { node in
                        BookmarkChip(node: node, controller: controller)
                    }
                }
            }

            Spacer(minLength: 4)

            Button { showingAllBookmarks.toggle() } label: {
                Image(systemName: "chevron.right.2").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("All Bookmarks"))
            .accessibilityLabel(L("All Bookmarks"))
            .accessibilityIdentifier("BookmarkBar.Overflow")
            .popover(isPresented: $showingAllBookmarks, arrowEdge: .bottom) {
                AllBookmarksPopover(controller: controller) { showingAllBookmarks = false }
            }

            // Saved workspaces (or a placeholder) first, then the save and manage commands, as in the original.
            Menu {
                ForEach(workspaces.workspaces) { workspace in
                    Button(workspace.name) { controller.openNamedWorkspace(workspace.id) }
                }
                if workspaces.workspaces.isEmpty {
                    Text(L("No Saved Workspaces"))
                }
                Divider()
                Button(L("Save Current Tab as Workspace…")) { controller.saveTabAsWorkspace() }
                if model.activeTab.namedWorkspaceID != nil {
                    Button(L("Save Workspace")) { controller.saveBoundWorkspace() }
                }
                Button(L("Manage Workspaces…")) { controller.showWorkspaceManager() }
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: BookmarkBarGlyphs.workspace)
                    Text(currentWorkspaceTitle).font(.system(size: 13))
                }
                .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 2.5)
            .accessibilityIdentifier("Workspaces.Menu")
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(height: 31)
        .background(Theme.bookmarkBarColor(preferences.bookmarkBarBackground, customRGB: preferences.bookmarkBarCustomRGB,
                                           dark: colorScheme == .dark))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            controller.loadURLs(from: providers) { urls in library.addBookmarks(urls) }
            return true
        }
    }

    private var currentWorkspaceTitle: String {
        if let id = model.activeTab.namedWorkspaceID, let workspace = workspaces.workspaces.first(where: { $0.id == id }) {
            return workspace.name
        }
        return L("Workspace")
    }
}

private struct BookmarkChip: View {
    let node: BookmarkLibrary.Node
    let controller: WorkspaceController
    @ObservedObject var library = LibraryModel.shared
    @State private var hovering = false

    var body: some View {
        Group {
            if node.isFolder {
                Menu {
                    BookmarkMenuContent(parent: node.id, controller: controller)
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button { controller.openBookmark(node) } label: { label }
                    .buttonStyle(.plain)
            }
        }
        .help(node.target?.url.path ?? node.title)
        .contextMenu { BookmarkContextMenu(node: node, controller: controller) }
        .accessibilityIdentifier("Bookmark.\(node.id.uuidString)")
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(nsImage: BookmarkBarGlyphs.icon(for: node))
            Text(node.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Context menu of a bookmark on the bar or in the sidebar. For a folder it is the original's (runtime capture
/// `ctx-bookmarkbar-item`): New Subfolder, Add Current Folder Here, Add Selected Items Here | Rename…, Move to ›
/// | Manage Bookmarks…, Delete. A bookmark offers Open in New Tab and Reveal in Finder in the first group instead.
/// The built-in folder can be renamed and moved; DirDesk keeps it from being deleted.
struct BookmarkContextMenu: View {
    let node: BookmarkLibrary.Node
    let controller: WorkspaceController
    @ObservedObject var library = LibraryModel.shared

    var body: some View {
        if node.isFolder {
            Button(L("New Subfolder")) { controller.newBookmarkFolder(parent: node.id) }
            Button(L("Add Current Folder Here")) { controller.addBookmarkForCurrentFolder(parent: node.id) }
                .disabled(controller.activePane.currentDirectory == nil)
            Button(L("Add Selected Items Here")) { library.addBookmarks(controller.selection.map(\.url), to: node.id) }
                .disabled(controller.selection.isEmpty)
        } else if let url = node.target?.url {
            Button(L("Open in New Tab")) {
                controller.newTab(directory: node.target?.kind == .folder ? url : url.deletingLastPathComponent())
            }
            Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button(L("Rename…")) { controller.renameBookmark(node) }
        Menu(L("Move to")) { BookmarkMoveMenuItems(node: node) }
        Divider()
        Button(L("Manage Bookmarks…")) { controller.showBookmarkManager() }
        Button(L("Delete")) { library.mutateBookmarks { $0.remove(node.id) } }
            .disabled(node.builtInRole != nil)
    }
}

/// Cascading menu of a bookmark folder's children.
struct BookmarkMenuContent: View {
    let parent: UUID?
    let controller: WorkspaceController
    @ObservedObject var library = LibraryModel.shared

    var body: some View {
        let children = library.bookmarks.children(of: parent)
        if children.isEmpty {
            Text(L("No bookmarks yet."))
        }
        ForEach(children) { node in
            if node.isFolder {
                Menu(node.displayTitle) {
                    BookmarkMenuContent(parent: node.id, controller: controller)
                }
            } else {
                Button(node.title) { controller.openBookmark(node) }
            }
        }
        if let parent {
            Divider()
            Button(L("Add Current Folder Here")) { controller.addBookmarkForCurrentFolder(parent: parent) }
        }
    }
}

/// "All Bookmarks" popover from the bar's » button: search field, the bookmark tree (or matches), and
/// Manage Bookmarks… at the bottom.
private struct AllBookmarksPopover: View {
    let controller: WorkspaceController
    let close: () -> Void
    @ObservedObject var library = LibraryModel.shared
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("All Bookmarks")).font(.system(size: 13, weight: .semibold))
            TextField(L("Search Bookmarks"), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        rows(parent: nil, depth: 0)
                    } else {
                        let matches = library.bookmarks.allTargets().filter {
                            $0.title.localizedCaseInsensitiveContains(query) || ($0.target?.url.path.localizedCaseInsensitiveContains(query) ?? false)
                        }
                        if matches.isEmpty {
                            Text(L("No Results")).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(matches) { node in row(node, depth: 0) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            Button(L("Manage Bookmarks…")) {
                close()
                controller.showBookmarkManager()
            }
        }
        .padding(14)
        .frame(width: 386, height: 446)
    }

    private func rows(parent: UUID?, depth: Int) -> AnyView {
        AnyView(ForEach(library.bookmarks.children(of: parent)) { node in
            if node.isFolder {
                DisclosureGroup {
                    rows(parent: node.id, depth: depth + 1)
                } label: {
                    Label(node.displayTitle, systemImage: "folder.fill")
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 2)
            } else {
                row(node, depth: depth)
            }
        })
    }

    private func row(_ node: BookmarkLibrary.Node, depth: Int) -> some View {
        Button {
            close()
            controller.openBookmark(node)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.target?.kind == .folder ? "folder" : "doc").foregroundStyle(.secondary)
                Text(node.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .help(node.target?.url.path ?? node.title)
    }
}

/// Bar glyphs with their colours baked in (menu labels render images without SwiftUI styling).
enum BookmarkBarGlyphs {
    /// Filled accent-blue bookmark ribbon with a notched end, 9 × 14 pt as in the original.
    static let bookmark: NSImage = {
        let image = NSImage(size: NSSize(width: 9, height: 14), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: 12.6))
            path.appendArc(from: NSPoint(x: 0, y: 14), to: NSPoint(x: 1.4, y: 14), radius: 1.4)
            path.line(to: NSPoint(x: 7.6, y: 14))
            path.appendArc(from: NSPoint(x: 9, y: 14), to: NSPoint(x: 9, y: 12.6), radius: 1.4)
            path.line(to: NSPoint(x: 9, y: 0))
            path.line(to: NSPoint(x: 4.5, y: 3.4))
            path.close()
            NSColor.controlAccentColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    /// An outlined monitor with two text lines on its screen, for the workspace menu.
    static let workspace: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let color = NSColor.controlAccentColor
            color.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 0.6, y: 3.6, width: 12.8, height: 9.8), xRadius: 1.6, yRadius: 1.6)
            screen.lineWidth = 1.2
            screen.stroke()
            let stand = NSBezierPath()
            stand.lineWidth = 1.2
            stand.move(to: NSPoint(x: 7, y: 3.6)); stand.line(to: NSPoint(x: 7, y: 0.9))
            stand.move(to: NSPoint(x: 3.8, y: 0.6)); stand.line(to: NSPoint(x: 10.2, y: 0.6))
            stand.stroke()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 9.4, width: 5.2, height: 1.1), xRadius: 0.5, yRadius: 0.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 6.8, width: 3.4, height: 1.1), xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    /// Bookmark folders and folder targets use the system folder icon at bar size; file bookmarks show the icon of
    /// their type (looked up by extension, so the bar never reads the files themselves).
    @MainActor
    static func icon(for node: BookmarkLibrary.Node) -> NSImage {
        let source: NSImage
        if let target = node.target, target.kind != .folder {
            source = NSWorkspace.shared.icon(for: UTType(filenameExtension: target.url.pathExtension) ?? .data)
        } else {
            source = NSImage(named: NSImage.folderName) ?? NSImage()
        }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}
