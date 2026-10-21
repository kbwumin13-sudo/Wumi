import AppKit
import DirDeskCore
import SwiftUI

/// Pane navigation bar: history buttons, breadcrumb with subfolder popovers, path editing, copy and reload.
struct PathBarView: View {
    @ObservedObject var pane: PaneRuntime
    let controller: WorkspaceController
    /// Close button shown in multi-pane layouts (`Pane.Close.<id>`).
    var close: (() -> Void)? = nil
    @State private var editing = false
    @State private var hoveringField = false
    @State private var editText = ""
    @State private var editError: String?
    @StateObject private var crumbPopover = CrumbPopoverState()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        // Measured on the original: 30 pt button slots, 13 pt glyphs, crumbs 12.75 pt after the up button.
        HStack(spacing: 0) {
            navButton("chevron.left", L("Back"), enabled: pane.history.canGoBack) { pane.goBack() }
            navButton("chevron.right", L("Forward"), enabled: pane.history.canGoForward) { pane.goForward() }
            navButton("chevron.up", L("Up One Level"), enabled: pane.canGoUp) { pane.goUp() }
                .padding(.trailing, 4)
            if editing {
                TextField(L("Enter a file or folder path."), text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(commitEdit)
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { editing = false } }
                    .popover(isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
                        Text(editError ?? "").padding(10).font(.system(size: 12))
                    }
            } else {
                // Breadcrumbs and the copy button share one field that outlines on hover, as in the original.
                HStack(spacing: 2) {
                    // Crumbs take the room they need first; only when the pane is too narrow do they shorten.
                    breadcrumb.layoutPriority(1)
                    Spacer(minLength: 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1, perform: beginEdit)
                        .accessibilityIdentifier("Path.EditSurface")
                        .accessibilityLabel(L("Edit Path"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { beginEdit() }
                    // Tag and recent views have no folder to copy; the original shows only Reload there.
                    if pane.currentDirectory != nil {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 16).padding(.trailing, -4)
                        navButton("doc.on.doc", L("Copy Folder Path"), enabled: true, size: 11.5, primary: true) {
                            controller.copyPaths([pane.currentDirectory].compactMap { $0 }, folderOnly: true)
                        }
                    }
                }
                .padding(.leading, 4)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(hoveringField ? 0.7 : 0), lineWidth: 1))
                .onHover { hoveringField = $0 }
                .layoutPriority(-1)
            }
            navButton("arrow.clockwise", L("Reload"), enabled: true) { pane.reload() }
            if let close {
                navButton("xmark", L("Close Pane"), enabled: true, action: close)
                    .accessibilityIdentifier("Pane.Close.\(pane.id.uuidString)")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 5)
        .frame(height: 39)
        .onReceive(NotificationCenter.default.publisher(for: .dirDeskEditPath)) { note in
            if (note.object as? UUID) == pane.id { beginEdit() }
        }
    }

    private func navButton(_ symbol: String, _ title: String, enabled: Bool, size: CGFloat = 13, primary: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? (primary ? .primary : .secondary) : .tertiary)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var breadcrumb: some View {
        switch pane.destination {
        case .directory(let url), .allSubfiles(let url):
            let crumbs = Self.crumbs(for: url)
            // Narrow panes shorten the names ("Dir…", "01-…") rather than scrolling, as the original does; the
            // current folder keeps its name longest.
            HStack(spacing: 0) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    CrumbButton(url: crumb, isLast: index == crumbs.count - 1, index: index, pane: pane, popover: crumbPopover)
                }
            }
            .clipped()
        case .recent(let filter):
            RecentRangeControl(pane: pane, filter: filter)
        case .tag(let name):
            // A tag view shows its location as "tag:Name" after a blue tag icon, as in the original.
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                Text("tag:" + name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LF("Tag location %@", name))
        case nil:
            EmptyView()
        }
    }

    /// Breadcrumb starts below the home folder for paths inside it, otherwise at the volume root.
    static func crumbs(for url: URL) -> [URL] {
        let all = PathUtilities.ancestors(of: url)
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(home + "/"), let index = all.firstIndex(where: { $0.path == home }) {
            return Array(all[(index + 1)...])
        }
        return all
    }

    private func beginEdit() {
        editText = pane.currentDirectory?.path ?? ""
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitEdit() {
        do {
            let url = try PathUtilities.resolveExisting(editText)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            // Packages (apps, bundles) count as files, as in the original: their folder opens with them selected.
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            if isDirectory.boolValue && !isPackage {
                pane.open(url)
            } else {
                pane.open(url.deletingLastPathComponent())
                pane.select(urls: [url])
            }
            editing = false
        } catch PathResolutionError.empty {
            editError = L("Enter a file or folder path.")
        } catch PathResolutionError.notAbsolute {
            editError = L("Enter an absolute file or folder path.")
        } catch PathResolutionError.unsupportedVariable(let name) {
            editError = LF("Unsupported environment variable: %@", name)
        } catch PathResolutionError.doesNotExist(let path) {
            editError = LF("The path does not exist: %@", path)
        } catch {
            editError = L("The path could not be opened.")
        }
    }
}

/// Which breadcrumb shows its subfolder popover; only one is open at a time.
@MainActor
private final class CrumbPopoverState: ObservableObject {
    @Published private(set) var openIndex: Int?
    private var pendingHover: DispatchWorkItem?

    func show(_ index: Int) {
        guard openIndex != index else { return }
        if openIndex == nil {
            openIndex = index
        } else {
            // Let the open popover finish closing before the next one is presented.
            openIndex = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.openIndex = index }
        }
    }

    func close(_ index: Int) {
        if openIndex == index { openIndex = nil }
    }

    /// "Show subfolders when the pointer rests on a path arrow" (Settings › Interaction).
    func hover(_ index: Int, inside: Bool, action: @escaping () -> Void) {
        pendingHover?.cancel()
        pendingHover = nil
        guard inside else { return }
        let work = DispatchWorkItem(block: action)
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

private struct CrumbButton: View {
    let url: URL
    let isLast: Bool
    let index: Int
    @ObservedObject var pane: PaneRuntime
    @ObservedObject var popover: CrumbPopoverState
    @AppStorage(DefaultsKey.openPathChildrenOnHover) private var opensOnHover = true
    @State private var hovering = false
    @State private var children: [URL] = []
    @State private var more = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                pane.open(url)
            } label: {
                Text(PathUtilities.displayName(for: url))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 28)
                    .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(url.path)
            .accessibilityIdentifier("Path.Crumb.\(index)")
            Button {
                showChildren()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                guard opensOnHover else { return }
                popover.hover(index, inside: inside) { showChildren() }
            }
            .help(L("Show Subfolders"))
            .accessibilityIdentifier("Path.Children.\(index)")
            .accessibilityLabel(LF("Show subfolders in %@", PathUtilities.displayName(for: url)))
            .popover(isPresented: Binding(get: { popover.openIndex == index }, set: { if !$0 { popover.close(index) } }),
                     arrowEdge: .bottom) {
                SubfolderList(folders: children, more: more, open: { folder in
                    popover.close(index)
                    pane.open(folder)
                }, title: PathUtilities.displayName(for: url))
            }
        }
    }

    /// Lists the subfolders off the main thread (the folder may be a protected one), then opens the popover.
    private func showChildren() {
        let folder = url
        let includeHidden = pane.viewConfiguration.showsHiddenFiles
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DirectoryLoader.subfolders(of: folder, includeHidden: includeHidden)
            }.value
            children = result.folders
            more = result.more
            popover.show(index)
        }
    }
}

/// Recent destination title with its date range (Previous 7 Days, Previous 30 Days, Custom Dates…).
private struct RecentRangeControl: View {
    @ObservedObject var pane: PaneRuntime
    let filter: RecentDateFilter
    @State private var showingCustom = false
    @State private var start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var end = Date()

    var body: some View {
        HStack(spacing: 8) {
            Label(L("Recent"), systemImage: "clock").font(.system(size: 12, weight: .semibold))
            Picker("", selection: Binding(get: { filter.period }, set: { period in
                if period == .custom {
                    showingCustom = true
                } else {
                    pane.navigate(to: .recent(.preset(period)), record: false)
                }
            })) {
                Text(L("Previous 7 Days")).tag(RecentDateFilter.Period.week)
                Text(L("Previous 30 Days")).tag(RecentDateFilter.Period.month)
                Text(L("Custom Dates…")).tag(RecentDateFilter.Period.custom)
            }
            .labelsHidden()
            .fixedSize()
            .popover(isPresented: $showingCustom) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker(L("From"), selection: $start, displayedComponents: .date)
                    DatePicker(L("Through"), selection: $end, displayedComponents: .date)
                    HStack {
                        Spacer()
                        Button(L("OK")) {
                            let calendar = Calendar.current
                            let from = calendar.startOfDay(for: min(start, end))
                            let through = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) ?? end
                            pane.navigate(to: .recent(RecentDateFilter(period: .custom, startDate: from, endDate: through)), record: false)
                            showingCustom = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .frame(width: 260)
            }
        }
    }
}

/// Subfolder popover of a breadcrumb: the folder's name as a header, then its subfolders with a › that drills
/// into the next level (original: 276 pt wide, 29 pt rows).
private struct SubfolderList: View {
    let folders: [URL]
    let more: Bool
    let open: (URL) -> Void
    var title: String = ""
    @State private var trail: [(URL, [URL], Bool)] = []

    private var current: (title: String, folders: [URL], more: Bool) {
        if let last = trail.last { return (PathUtilities.displayName(for: last.0), last.1, last.2) }
        return (title, folders, more)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !trail.isEmpty {
                    Button { trail.removeLast() } label: { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain)
                }
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(current.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if current.folders.isEmpty {
                        Text(L("No Subfolders")).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(current.folders, id: \.self) { folder in
                        HStack(spacing: 6) {
                            Button { open(folder) } label: {
                                HStack(spacing: 7) {
                                    Image(nsImage: FileIcons.shared.icon(forPath: folder.path)).resizable().frame(width: 16, height: 16)
                                    Text(PathUtilities.displayName(for: folder)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(folder.path)
                            .accessibilityIdentifier("Path.Child.\(folder.lastPathComponent)")
                            Button { drill(into: folder) } label: {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    .frame(width: 18, height: 22).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L("Show Subfolders"))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 29)
                    }
                    if current.more {
                        Text(L("More folders are not shown")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(10)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 276)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
    }

    private func drill(into folder: URL) {
        Task {
            let result = await Task.detached { DirectoryLoader.subfolders(of: folder, includeHidden: false) }.value
            trail.append((folder, result.folders, result.more))
        }
    }
}

extension Notification.Name {
    static let dirDeskEditPath = Notification.Name("DirDesk.EditPath")
}
