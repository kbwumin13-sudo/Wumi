import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// "Add Bookmark" sheet opened by the Add Bookmark command (⌘D) and the "Add Current Folder" menu items: the item's
/// icon on a tile, a name (one item) or the number of items, and the bookmark folder to add to, chosen with radio rows
/// whose first entry is the Bookmarks Bar. Nothing is chosen at first, so Done stays disabled until a location is
/// picked. Metrics follow the original's sheet (runtime capture 2026-10-20, 480 × 350 pt).
struct BookmarkAddSheet: View {
    let urls: [URL]
    let finish: () -> Void
    @ObservedObject private var library = LibraryModel.shared
    @State private var name: String
    /// The chosen location; nil until the user picks one.
    @State private var destination: Destination?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    enum Destination: Equatable {
        case bar
        case folder(UUID)
    }

    init(urls: [URL], finish: @escaping () -> Void) {
        self.urls = urls
        self.finish = finish
        _name = State(initialValue: urls.count == 1 ? PathUtilities.displayName(for: urls[0]) : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                iconTile
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Add Bookmark")).font(.system(size: 17, weight: .bold))
                    if urls.count > 1 {
                        Text(LF("%lld items selected", Int64(urls.count))).font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    if urls.count == 1 {
                        HStack(spacing: 0) {
                            Text(L("Name")).font(.system(size: 13)).frame(width: 58, alignment: .leading)
                            TextField("", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .frame(width: 284)
                                .focused($nameFocused)
                                .accessibilityLabel(L("Name"))
                                .accessibilityIdentifier("BookmarkAdd.Name")
                        }
                        .padding(.top, 8)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Select Bookmark Location"))
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityIdentifier("BookmarkAdd.LocationLabel")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                row(title: L("Bookmarks Bar"), destination: .bar, depth: 0)
                                    .accessibilityIdentifier("BookmarkAdd.Destination.Root")
                                ForEach(folderRows, id: \.node.id) { entry in
                                    row(title: entry.node.displayTitle,
                                        destination: .folder(entry.node.id), depth: entry.depth)
                                        .accessibilityIdentifier("BookmarkAdd.Destination.\(entry.node.id.uuidString)")
                                }
                            }
                        }
                        .frame(width: 280, height: 180)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("BookmarkAdd.Destination")
                    }
                    .padding(.leading, 60)
                    .padding(.top, 8)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 136)
                    .padding(.top, 6)
                    .accessibilityIdentifier("BookmarkAdd.Error")
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel"), action: finish).keyboardShortcut(.cancelAction)
                Button(L("Done"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil)
                    .accessibilityIdentifier("BookmarkAdd.Done")
            }
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 23, trailing: 24))
        .frame(width: 480)
        // The name field starts focused with its text selected, as in the original.
        .onAppear { if urls.count == 1 { nameFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BookmarkAdd.Sheet")
    }

    /// The item's icon (a bookmark ribbon for several items) with an alias arrow, on a 64 pt tile.
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06))
            if urls.count == 1 {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Color(white: 0.12)))
                            .offset(x: -1, y: 1)
                    }
            } else {
                Image(systemName: "bookmark.fill").font(.system(size: 28)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 64, height: 64)
    }

    /// Folders and files by type (no file reads, so protected folders never prompt).
    private var icon: NSImage {
        guard let url = urls.first else { return NSImage() }
        if url.hasDirectoryPath { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    /// Bookmark folders in tree order with their depth, so the list reads like an outline.
    private var folderRows: [(node: BookmarkLibrary.Node, depth: Int)] { library.bookmarks.folderOutline() }

    /// A 34 pt row: radio circle, icon, title.
    private func row(title: String, destination target: Destination, depth: Int) -> some View {
        let selected = destination == target
        return Button {
            destination = target
        } label: {
            HStack(spacing: 0) {
                ZStack {
                    if selected {
                        Circle().fill(Color.accentColor)
                        Circle().fill(Color.white).frame(width: 5, height: 5)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                    }
                }
                .frame(width: 13, height: 13)
                Group {
                    if target == .bar {
                        Image(systemName: "bookmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 18)
                .padding(.leading, 7)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.leading, 9 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if urls.count == 1, trimmed.isEmpty {
            error = L("A bookmark name cannot be empty.")
            return
        }
        let unique = Set(urls.map { $0.standardizedFileURL })
        guard unique.count == urls.count else {
            error = L("The bookmark selection contains the same item more than once.")
            return
        }
        guard let destination else { return }
        var folder: UUID?
        if case .folder(let id) = destination {
            guard library.bookmarks.node(id) != nil else {
                error = L("The destination bookmark folder is no longer available.")
                return
            }
            folder = id
        }
        library.addBookmarks(urls, to: folder, titles: urls.count == 1 ? [trimmed] : nil, toBar: destination == .bar)
        if let message = library.lastError {
            error = message
            library.lastError = nil
            return
        }
        finish()
    }
}

extension WorkspaceController {
    /// The Add Bookmark command: the selection, or the current folder when nothing is selected.
    /// Add Bookmark sheet for `urls`, or for the selection (the current folder when nothing is selected).
    func presentBookmarkAdd(urls explicitURLs: [URL]? = nil) {
        let urls = explicitURLs ?? (selection.isEmpty ? (activePane.currentDirectory.map { [$0] } ?? []) : selection.map(\.url))
        guard !urls.isEmpty, let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: BookmarkAddSheet(urls: urls) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }
}
