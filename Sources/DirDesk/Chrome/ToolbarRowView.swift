import AppKit
import DirDeskCore
import SwiftUI

/// Toolbar row: configurable commands on the left, layout/inspector/search on the right.
struct ToolbarRowView: View {
    @ObservedObject var model: WorkspaceModel
    let controller: WorkspaceController

    var body: some View {
        ToolbarRowContent(model: model, pane: model.activePane, controller: controller)
    }
}

extension ToolbarRowView {
    /// Names the original uses in "Customize Tool Order and Visibility".
    static func customizationTitle(_ command: ToolbarCommand) -> String {
        switch command {
        case .viewMode: L("View Mode")
        case .copyPath: L("Copy Absolute Path")
        case .openFolder: L("Go to Folder…")
        case .externalTools: L("Open in External Tool")
        case .airDrop: L("AirDrop")
        case .folderSync: L("Run Folder Sync…")
        default: title(command)
        }
    }

    /// The colored toolbar glyph of a command, for lists outside the toolbar.
    static func glyph(_ command: ToolbarCommand) -> ToolbarGlyph {
        switch command {
        case .viewMode: .symbol("square.grid.2x2", .secondary)
        case .paneLayout: .symbol("square.split.2x2", ToolbarGlyph.purple)
        case .newFolder: .newFolder
        case .newFile: .newFile
        case .search: .symbol("magnifyingglass", ToolbarGlyph.blue)
        case .terminal: .terminal
        case .inspector: .symbol("sidebar.right", ToolbarGlyph.blue)
        case .openFolder: .goToFolder
        case .sort: .symbol("arrow.up.arrow.down", ToolbarGlyph.teal)
        case .foldersFirst: .symbol("folder.fill", ToolbarGlyph.blue)
        case .grouping: .grouping
        case .externalTools: .share
        case .quickLook: .symbol("eye", ToolbarGlyph.purple)
        case .copyPath: .copyPath
        case .revealInFinder: .finder
        case .hiddenFiles: .symbol("eye.slash", ToolbarGlyph.purple)
        case .airDrop: .symbol("airplay.audio", ToolbarGlyph.blue)
        case .folderSync: .folderSync
        }
    }

    /// Commands drawn as an icon in the toolbar row (the layout chooser and inspector sit in the right-hand group).
    static func hasSlot(_ command: ToolbarCommand) -> Bool {
        command != .paneLayout && command != .inspector
    }

    static func symbol(_ command: ToolbarCommand) -> String {
        switch command {
        case .viewMode: "list.bullet"
        case .paneLayout: "square.split.2x2"
        case .newFolder: "folder.badge.plus"
        case .newFile: "doc.badge.plus"
        case .search: "magnifyingglass"
        case .terminal: "terminal"
        case .inspector: "sidebar.right"
        case .openFolder: "folder"
        case .sort: "arrow.up.arrow.down"
        case .foldersFirst: "folder.fill"
        case .grouping: "rectangle.3.group"
        case .externalTools: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .copyPath: "link"
        case .revealInFinder: "macwindow"
        case .hiddenFiles: "eye.slash"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .folderSync: "arrow.triangle.2.circlepath"
        }
    }

    static func identifier(_ command: ToolbarCommand) -> String {
        switch command {
        case .viewMode: "Toolbar.ViewMode"
        case .paneLayout: "Toolbar.LayoutChooser"
        case .newFolder: "Toolbar.NewFolder"
        case .newFile: "Toolbar.NewFile"
        case .search: "Toolbar.Search"
        case .terminal: "Toolbar.Terminal"
        case .inspector: "Toolbar.Inspector"
        case .sort: "Toolbar.Sort"
        case .foldersFirst: "Toolbar.Sort.FoldersAtTop"
        case .grouping: "Toolbar.Grouping"
        case .externalTools: "Toolbar.ExternalTools"
        case .copyPath: "Toolbar.CopyPath"
        case .openFolder: "Toolbar.OpenFolder"
        case .hiddenFiles: "Toolbar.HiddenFiles"
        case .airDrop: "Toolbar.AirDrop"
        case .folderSync: "Toolbar.FolderSync"
        case .quickLook: "Toolbar.QuickLook"
        case .revealInFinder: "Toolbar.RevealInFinder"
        }
    }

    static func title(_ command: ToolbarCommand) -> String {
        switch command {
        case .viewMode: L("View")
        case .paneLayout: L("Pane Layout")
        case .newFolder: L("New Folder")
        case .newFile: L("New File")
        case .search: L("Search")
        case .terminal: L("Open in Terminal")
        case .inspector: L("Inspector")
        case .openFolder: L("Open Folder")
        case .sort: L("Sort")
        case .foldersFirst: L("Folders First")
        case .grouping: L("File Grouping")
        case .externalTools: L("External Tools")
        case .quickLook: L("Quick Look")
        case .copyPath: L("Copy Path")
        case .revealInFinder: L("Reveal in Finder")
        case .hiddenFiles: L("Show Hidden Files")
        case .airDrop: L("Send with AirDrop")
        case .folderSync: L("Folder Sync")
        }
    }
}

/// Observe one active pane, without constructing several complete candidate toolbars.
private struct ToolbarRowContent: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var app = AppModel.shared
    @ObservedObject var pane: PaneRuntime
    let controller: WorkspaceController
    @State private var showingLayouts = false

    var body: some View {
        GeometryReader { geometry in
            let preferences = app.preferences
            let layout = presentation(width: geometry.size.width, labels: preferences.showsToolbarLabels)
            HStack(spacing: 0) {
                HStack(spacing: ToolbarPresentation.spacing) {
                    ForEach(layout.visible, id: \.command) { item in
                        commandView(item.command, colored: preferences.usesColoredToolbarIcons,
                                    labels: item.command == .sort || item.command == .grouping
                                        ? layout.expandedStates.contains(item.command) : preferences.showsToolbarLabels)
                            .frame(width: item.width, height: 32)
                    }
                }
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 18)
                    .padding(.horizontal, 8)
                moreMenu(overflow: layout.overflow).frame(width: 32, height: 32)
                Spacer(minLength: ToolbarPresentation.trailingGap)
                HStack(spacing: 2) {
                    layoutButton
                    if model.activeTab.panes.count > 1 { splitIntoTabsButton }
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 16)
                    inspectorButton
                }
                .frame(width: ToolbarPresentation.utilityWidth(split: model.activeTab.panes.count > 1))
                searchField(expanded: layout.searchWidth > ToolbarPresentation.iconWidth)
                    .frame(width: layout.searchWidth, height: 32)
                    .padding(.leading, ToolbarPresentation.trailingGap)
            }
            .padding(.horizontal, ToolbarPresentation.horizontalInset)
            .frame(width: geometry.size.width, height: 47)
            .font(.system(size: 12))
            .controlSize(.regular)
        }
        .frame(height: 47)
    }

    private var sortKeyTitle: String {
        SortMenuContent.title(pane.viewConfiguration.sortKey)
    }

    private var sortTitle: String {
        sortKeyTitle + (pane.viewConfiguration.sortAscending ? " ↑" : " ↓")
    }

    private var sortHelp: String {
        L("Sort") + ": " + sortKeyTitle + ", " + L(pane.viewConfiguration.sortAscending ? "Ascending" : "Descending")
    }

    private var groupingTitle: String {
        GroupingMenuContent.title(pane.viewConfiguration.groupingMode)
    }

    private var groupingHelp: String { L("File Grouping") + ": " + groupingTitle }

    private func presentation(width: CGFloat, labels: Bool) -> ToolbarPresentation {
        let items = app.configuration.toolbarCommands.filter(ToolbarRowView.hasSlot).map { command in
            let state = command == .sort || command == .grouping
            let title: String
            switch command {
            case .sort: title = sortTitle
            case .grouping: title = groupingTitle
            case .copyPath: title = L("Copy Absolute Path")
            case .hiddenFiles: title = moreTitle(command)
            default: title = ToolbarRowView.title(command)
            }
            // Same font as the label, plus icon, spacing, padding and conservative AppKit menu insets.
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
            let expanded = max(ToolbarPresentation.iconWidth, textWidth + 49)
            let compact: CGFloat = command == .viewMode ? ToolbarPresentation.viewModeWidth
                : labels && !state ? expanded : ToolbarPresentation.iconWidth
            return ToolbarPresentation.Item(command: command, width: compact, expandedWidth: expanded)
        }
        return ToolbarPresentation(width: width, items: items, split: model.activeTab.panes.count > 1)
    }

    @ViewBuilder
    private func commandView(_ command: ToolbarCommand, colored: Bool, labels: Bool) -> some View {
        switch command {
        case .viewMode:
            ViewModePicker(pane: pane)
        case .paneLayout:
            EmptyView()
        case .newFolder:
            NeedsFolder(pane: pane) {
                ToolbarIconButton(glyph: .newFolder, colored: colored, title: L("New Folder"), showsTitle: labels,
                                  identifier: "Toolbar.NewFolder") { controller.perform(.newFolder) }
            }
        case .newFile:
            NeedsFolder(pane: pane) {
                Menu {
                    NewFileMenuContent(controller: controller)
                } label: {
                    ToolbarIconLabel(glyph: .newFile, colored: colored, title: L("New File"), showsTitle: labels, isMenu: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(L("New File"))
                .accessibilityLabel(L("New File"))
                .accessibilityIdentifier("Toolbar.NewFile")
            }
        case .search:
            ToolbarIconButton(glyph: .symbol("magnifyingglass", ToolbarGlyph.blue), colored: colored, title: L("Search"), showsTitle: labels, identifier: "Toolbar.Search") {
                controller.perform(.search)
            }
        case .terminal:
            NeedsFolder(pane: pane) {
                ToolbarIconButton(glyph: .terminal, colored: colored, title: L("Open in Terminal"), showsTitle: labels,
                                  identifier: "Toolbar.Terminal") { controller.perform(.openTerminal) }
            }
        case .inspector:
            EmptyView()
        case .openFolder:
            ToolbarIconButton(glyph: .symbol("folder", ToolbarGlyph.blue), colored: colored, title: L("Open Folder"), showsTitle: labels,
                              identifier: "Toolbar.OpenFolder") { controller.chooseFolderToOpen() }
        case .sort:
            Menu { SortMenuContent(pane: pane, controller: controller) } label: {
                ToolbarIconLabel(glyph: .symbol("arrow.up.arrow.down", ToolbarGlyph.teal), colored: colored,
                                 title: sortTitle, showsTitle: labels, isMenu: true)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help(sortHelp).accessibilityLabel(sortHelp).accessibilityValue(sortHelp)
            .accessibilityIdentifier("Toolbar.Sort")
        case .foldersFirst:
            ToolbarIconButton(glyph: .symbol(pane.viewConfiguration.foldersFirst ? "folder.fill" : "folder", ToolbarGlyph.blue), colored: colored,
                              title: L("Folders First"), showsTitle: labels, identifier: "Toolbar.Sort.FoldersAtTop") {
                pane.viewConfiguration.foldersFirst.toggle()
            }
        case .grouping:
            Menu { GroupingMenuContent(pane: pane) } label: {
                ToolbarIconLabel(glyph: .grouping, colored: colored, title: groupingTitle, showsTitle: labels, isMenu: true)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help(groupingHelp).accessibilityLabel(groupingHelp).accessibilityValue(groupingTitle)
            .accessibilityIdentifier("Toolbar.Grouping")
        case .externalTools:
            ToolbarIconButton(glyph: .symbol("arrow.up.forward.app", .orange), colored: colored, title: L("External Tools"), showsTitle: labels,
                              identifier: "Toolbar.ExternalTools") { controller.perform(.openEditor) }
        case .quickLook:
            ToolbarIconButton(glyph: .symbol("eye", ToolbarGlyph.blue), colored: colored, title: L("Quick Look"), showsTitle: labels, identifier: "Toolbar.QuickLook") {
                controller.perform(.quickLook)
            }
        case .copyPath:
            ToolbarIconButton(glyph: .copyPath, colored: colored, title: L("Copy Absolute Path"), showsTitle: labels,
                              identifier: "Toolbar.CopyPath") { controller.perform(.copyPath) }
        case .revealInFinder:
            ToolbarIconButton(glyph: .symbol("macwindow", ToolbarGlyph.blue), colored: colored, title: L("Reveal in Finder"), showsTitle: labels,
                              identifier: "Toolbar.RevealInFinder") { controller.revealInFinder() }
        case .hiddenFiles:
            ToolbarIconButton(glyph: .symbol(pane.viewConfiguration.showsHiddenFiles ? "eye" : "eye.slash", ToolbarGlyph.blue), colored: colored,
                              title: pane.viewConfiguration.showsHiddenFiles ? L("Hide Hidden Files") : L("Show Hidden Files"),
                              showsTitle: labels, identifier: "Toolbar.HiddenFiles") {
                pane.viewConfiguration.showsHiddenFiles.toggle()
            }
        case .airDrop:
            ToolbarIconButton(glyph: .symbol("dot.radiowaves.left.and.right", ToolbarGlyph.blue), colored: colored, title: L("Send with AirDrop"),
                              showsTitle: labels, identifier: "Toolbar.AirDrop") { controller.shareAirDrop() }
        case .folderSync:
            ToolbarIconButton(glyph: .symbol("arrow.triangle.2.circlepath", .green), colored: colored, title: L("Folder Sync"),
                              showsTitle: labels, identifier: "Toolbar.FolderSync") { controller.showFolderSync() }
        }
    }

    /// Overflow keeps the user's order and full submenus. Unconfigured tools follow it.
    private func moreMenu(overflow: [ToolbarCommand]) -> some View {
        Menu {
            Button { controller.newTab() } label: { Label(L("New Tab"), systemImage: "plus.square.on.square") }
                .accessibilityIdentifier("Tabs.New")
            Divider()
            let shown = Set(app.configuration.toolbarCommands)
            let fixed: Set<ToolbarCommand> = [.paneLayout, .search, .inspector]
            let unconfigured = ToolbarCommand.allCases.filter { !shown.contains($0) && !fixed.contains($0) }
            ForEach(overflow + unconfigured, id: \.self) { command in
                overflowCommand(command)
            }
            // The configured button opens the default editor; keep the full tool chooser reachable too.
            if shown.contains(.externalTools) && !overflow.contains(.externalTools) {
                overflowCommand(.externalTools)
            }
            Divider()
            Button(L("Customize Tool Order and Visibility…")) { controller.showToolbarCustomization() }
                .accessibilityIdentifier("Toolbar.Customize")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L("More Tools"))
        .accessibilityLabel(L("More Tools"))
        .accessibilityIdentifier("Toolbar.More")
    }

    @ViewBuilder
    private func overflowCommand(_ command: ToolbarCommand) -> some View {
        switch command {
        case .viewMode:
            Menu {
                ViewModeMenuContent(pane: pane)
            } label: { Label(L("View Mode"), systemImage: ToolbarRowView.symbol(command)) }
            .accessibilityIdentifier("Toolbar.ViewMode")
        case .sort:
            Menu {
                SortMenuContent(pane: pane, controller: controller)
            } label: { Label(sortHelp, systemImage: ToolbarRowView.symbol(command)) }
            .help(sortHelp).accessibilityLabel(sortHelp).accessibilityIdentifier("Toolbar.Sort")
        case .grouping:
            Menu {
                GroupingMenuContent(pane: pane)
            } label: { Label(groupingHelp, systemImage: ToolbarRowView.symbol(command)) }
            .help(groupingHelp).accessibilityLabel(groupingHelp).accessibilityIdentifier("Toolbar.Grouping")
        case .newFile:
            Menu {
                NewFileMenuContent(controller: controller)
            } label: { Label(L("New File"), systemImage: ToolbarRowView.symbol(command)) }
            .disabled(pane.currentDirectory == nil)
            .accessibilityIdentifier("Toolbar.NewFile")
        case .foldersFirst:
            Toggle(L("Folders First"), isOn: Binding(get: { pane.viewConfiguration.foldersFirst },
                                                    set: { pane.viewConfiguration.foldersFirst = $0 }))
                .accessibilityIdentifier("Toolbar.Sort.FoldersAtTop")
        case .externalTools:
            Menu {
                ForEach(app.configuration.externalTools.sorted { $0.sortOrder < $1.sortOrder }) { tool in
                    Button(L(tool.name)) { controller.openWith(tool: tool) }
                }
            } label: { Label(L("Open in External Tool"), systemImage: ToolbarRowView.symbol(command)) }
            .accessibilityIdentifier("Toolbar.ExternalTools")
        default:
            Button { controller.performToolbar(command) } label: {
                Label(moreTitle(command), systemImage: ToolbarRowView.symbol(command))
            }
            .disabled((command == .newFolder || command == .terminal) && pane.currentDirectory == nil)
            .accessibilityIdentifier(ToolbarRowView.identifier(command))
        }
    }

    private func moreTitle(_ command: ToolbarCommand) -> String {
        switch command {
        case .openFolder: L("Go to Folder…")
        case .hiddenFiles: pane.viewConfiguration.showsHiddenFiles ? L("Hide Hidden Files") : L("Show Hidden Files")
        case .folderSync: L("Run Folder Sync…")
        default: ToolbarRowView.title(command)
        }
    }

    /// Opens the layout chooser: a popover with a 4 × 3 grid of layout thumbnails (reference toolbar-layout-chooser).
    private var layoutButton: some View {
        Button { showingLayouts.toggle() } label: {
            Image(systemName: "square.split.2x2")
                .font(.system(size: 17))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(app.preferences.usesColoredToolbarIcons ? ToolbarGlyph.blue : Color.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L("Pane Layout"))
        .accessibilityLabel(L("Pane Layout"))
        .accessibilityIdentifier("Toolbar.LayoutChooser")
        .popover(isPresented: $showingLayouts, arrowEdge: .bottom) {
            PaneLayoutChooser(current: model.activeTab.layout) { layout in
                showingLayouts = false
                controller.setLayout(layout)
            }
        }
    }

    /// Shown while the tab is split: moves every pane but the first into its own tab.
    private var splitIntoTabsButton: some View {
        Button { controller.splitPanesIntoTabs() } label: {
            SplitIntoTabsGlyph(colored: app.preferences.usesColoredToolbarIcons)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L("Dissolve Split View and Open in New Tabs"))
        .accessibilityIdentifier("Toolbar.SplitPanesIntoTabs")
        .accessibilityLabel(L("Dissolve Split View and Open in New Tabs"))
    }

    private var inspectorButton: some View {
        Button {
            controller.perform(.toggleInspector)
        } label: {
            Image(systemName: model.inspectorVisible ? "inset.filled.lefthalf.righthalf.rectangle" : "rectangle.split.2x1")
                .font(.system(size: 17))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(model.inspectorVisible ? Color.accentColor : Color.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(model.inspectorVisible ? L("Hide Side Preview") : L("Show Side Preview"))
        .accessibilityIdentifier("Toolbar.Inspector")
        .accessibilityLabel(L("Inspector"))
        .accessibilityValue(model.inspectorVisible ? L("Hide Side Preview") : L("Show Side Preview"))
        .accessibilityAddTraits(model.inspectorVisible ? .isSelected : [])
    }

    private func searchField(expanded: Bool) -> some View {
        Button {
            controller.perform(.search)
        } label: {
            HStack(spacing: expanded ? 8 : 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(app.preferences.usesColoredToolbarIcons ? ToolbarGlyph.blue : Color.primary)
                if expanded {
                    Text(L("Miji Search")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("⌘F").font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(width: expanded ? 200 : 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L("Miji Search"))
        .accessibilityLabel(L("Miji Search"))
        .accessibilityIdentifier("Toolbar.Search.Field")
    }
}

/// Monochrome mode uses native template symbols directly. The optional colored artwork is retained.
enum ToolbarGlyph {
    case newFolder, newFile, terminal, copyPath, grouping, goToFolder, finder, folderSync, share
    case symbol(String, Color)

    /// The original's blue glyphs are the accent color (#007AFF with the default accent).
    static var blue: Color { Color(nsColor: .controlAccentColor) }
    static let teal = Color(red: 0.12, green: 0.66, blue: 0.62)
    static let purple = Color(red: 0.56, green: 0.43, blue: 0.96)
    static let side: CGFloat = 17

    @ViewBuilder
    func view(colored: Bool) -> some View {
        if colored {
            Image(nsImage: image(colored: true))
        } else {
            Image(systemName: symbolName)
                .renderingMode(.template)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
        }
    }

    private var symbolName: String {
        switch self {
        case .newFolder: "folder.badge.plus"
        case .newFile: "doc.badge.plus"
        case .terminal: "terminal"
        case .copyPath: "link"
        case .grouping: "rectangle.3.group"
        case .goToFolder: "folder"
        case .finder: "macwindow"
        case .folderSync: "arrow.triangle.2.circlepath"
        case .share: "arrow.up.forward.app"
        case .symbol(let name, _): name
        }
    }

    func image(colored: Bool) -> NSImage {
        guard colored else {
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
            symbol.isTemplate = true
            return symbol
        }
        switch self {
        case .newFolder:
            return Self.addBadged(NSImage(named: NSImage.folderName) ?? NSImage(), contentRect: NSRect(x: -0.5, y: 1.5, width: 16, height: 16))
        case .newFile:
            return Self.addBadged(NSWorkspace.shared.icon(for: .plainText), contentRect: NSRect(x: -1.5, y: 0.5, width: 17, height: 17))
        case .terminal:
            return Self.terminalTile()
        case .copyPath:
            return Self.copyPathGlyph(color: .controlAccentColor)
        case .grouping:
            return Self.groupingGlyph(color: NSColor(Self.purple))
        // The original's More items: a blue folder with an arrow, the Finder icon and a green folder with sync arrows.
        case .goToFolder:
            return Self.folderGlyph(tint: nil, overlay: "arrow.right")
        case .finder:
            return Self.iconGlyph(NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"))
        case .share:
            return Self.shareGlyph(color: .controlAccentColor)
        case .folderSync:
            return Self.folderGlyph(tint: NSColor(srgbRed: 0.33, green: 0.62, blue: 0.53, alpha: 1), overlay: "arrow.triangle.2.circlepath")
        case .symbol(let name, let tint):
            return Self.symbolImage(name, color: NSColor(tint))
        }
    }

    /// An SF Symbol in `color`, fitted to the 17 pt square without cropping its arrowheads or other overhangs.
    static func symbolImage(_ name: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let symbol else { return false }
            // The whole symbol image: a symbol's alignment rectangle only spans the cap height, so drawing from it
            // would crop taller glyphs such as square.and.arrow.up.
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A full-color system icon with a green "+" disc in a light ring at the lower right.
    static func addBadged(_ icon: NSImage, contentRect: NSRect) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: contentRect)
            let disc = NSRect(x: rect.maxX - 9, y: 0, width: 9, height: 9)
            NSColor(white: 0.96, alpha: 1).setFill()
            NSBezierPath(ovalIn: disc).fill()
            NSColor(srgbRed: 0.20, green: 0.70, blue: 0.36, alpha: 1).setFill()
            NSBezierPath(ovalIn: disc.insetBy(dx: 1, dy: 1)).fill()
            let plus = NSBezierPath()
            plus.lineWidth = 1.3
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: disc.midX - 2.2, y: disc.midY)); plus.line(to: NSPoint(x: disc.midX + 2.2, y: disc.midY))
            plus.move(to: NSPoint(x: disc.midX, y: disc.midY - 2.2)); plus.line(to: NSPoint(x: disc.midX, y: disc.midY + 2.2))
            NSColor.white.setStroke()
            plus.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The system folder icon, optionally recolored, with a white symbol on its body.
    static func folderGlyph(tint: NSColor?, overlay: String) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let folder = NSImage(named: NSImage.folderName) ?? NSImage()
            folder.draw(in: NSRect(x: -0.5, y: 0, width: 18, height: 18))
            if let tint {
                // Paint over the folder's own pixels only, keeping a little of its shading.
                NSGraphicsContext.current?.compositingOperation = .sourceAtop
                tint.withAlphaComponent(0.88).setFill()
                rect.fill(using: .sourceAtop)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))
            if let mark = NSImage(systemSymbolName: overlay, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = mark.size
                mark.draw(in: NSRect(x: (rect.width - size.width) / 2, y: 6.6 - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// An open tray with an arrow leaving it upwards, as wide as the 17 pt square (the original's "Open in External
    /// Tool" glyph is squarer than the SF Symbol).
    static func shareGlyph(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            color.setStroke()
            let tray = NSBezierPath()
            tray.lineWidth = 1.3
            tray.lineCapStyle = .round
            tray.lineJoinStyle = .round
            tray.move(to: NSPoint(x: 5.6, y: 10.4))
            tray.line(to: NSPoint(x: 3.6, y: 10.4))
            tray.appendArc(from: NSPoint(x: 1.2, y: 10.4), to: NSPoint(x: 1.2, y: 8), radius: 2.4)
            tray.line(to: NSPoint(x: 1.2, y: 3.4))
            tray.appendArc(from: NSPoint(x: 1.2, y: 1.0), to: NSPoint(x: 3.6, y: 1.0), radius: 2.4)
            tray.line(to: NSPoint(x: 13.4, y: 1.0))
            tray.appendArc(from: NSPoint(x: 15.8, y: 1.0), to: NSPoint(x: 15.8, y: 3.4), radius: 2.4)
            tray.line(to: NSPoint(x: 15.8, y: 8))
            tray.appendArc(from: NSPoint(x: 15.8, y: 10.4), to: NSPoint(x: 13.4, y: 10.4), radius: 2.4)
            tray.line(to: NSPoint(x: 11.4, y: 10.4))
            tray.stroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.3
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 8.5, y: 5.2)); arrow.line(to: NSPoint(x: 8.5, y: 15.9))
            arrow.move(to: NSPoint(x: 5.2, y: 12.7)); arrow.line(to: NSPoint(x: 8.5, y: 16)); arrow.line(to: NSPoint(x: 11.8, y: 12.7))
            arrow.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A full-color icon (an app's) fitted to the 17 pt square.
    static func iconGlyph(_ icon: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Dark rounded tile with a light rim and a ">_" prompt.
    static func terminalTile() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let tile = NSRect(x: 0.5, y: 1, width: rect.width - 1, height: rect.height - 2)
            let path = NSBezierPath(roundedRect: tile, xRadius: 3.5, yRadius: 3.5)
            NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.23, blue: 0.27, alpha: 1),
                       ending: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1))?.draw(in: path, angle: -90)
            NSColor(white: 0.62, alpha: 1).setStroke()
            path.lineWidth = 0.8
            path.stroke()
            let prompt = NSBezierPath()
            prompt.lineWidth = 1.4
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.move(to: NSPoint(x: 3.8, y: 11.5)); prompt.line(to: NSPoint(x: 6.6, y: 9.4)); prompt.line(to: NSPoint(x: 3.8, y: 7.3))
            prompt.move(to: NSPoint(x: 8.2, y: 5.6)); prompt.line(to: NSPoint(x: 12.4, y: 5.6))
            NSColor.white.setStroke()
            prompt.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Two small cells stacked on the left and a tall one on the right, filling the 17 pt square.
    static func groupingGlyph(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            color.setStroke()
            for rect in [NSRect(x: 1, y: 9.6, width: 6.2, height: 6.4), NSRect(x: 1, y: 1, width: 6.2, height: 6.4),
                         NSRect(x: 9.8, y: 1, width: 6.2, height: 15)] {
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.8, yRadius: 1.8)
                path.lineWidth = 1.4
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Two overlapping pages, the front one (lower left) carrying a chain link.
    static func copyPathGlyph(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            color.setStroke()
            let back = NSBezierPath()
            back.lineWidth = 1.3
            back.move(to: NSPoint(x: 5.2, y: 15.7)); back.line(to: NSPoint(x: 13.4, y: 15.7))
            back.appendArc(from: NSPoint(x: 16.2, y: 15.7), to: NSPoint(x: 16.2, y: 12.9), radius: 2.6)
            back.line(to: NSPoint(x: 16.2, y: 4.8))
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 0.9, y: 0.9, width: 12.2, height: 12.2), xRadius: 2.6, yRadius: 2.6)
            front.lineWidth = 1.3
            front.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .semibold).applying(.init(paletteColors: [color]))
            if let link = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = link.size
                link.draw(in: NSRect(x: 7 - size.width / 2, y: 7 - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Commands that act on the pane's folder are unavailable in tag and recent views, as in the original.
private struct NeedsFolder<Content: View>: View {
    @ObservedObject var pane: PaneRuntime
    @ViewBuilder let content: Content

    var body: some View {
        let available = pane.currentDirectory != nil
        content.disabled(!available).opacity(available ? 1 : 0.4)
    }
}

struct ToolbarSeparator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1, height: 20).padding(.horizontal, 2)
    }
}

/// A command label; native menus supply their own horizontal insets.
struct ToolbarIconLabel: View {
    let glyph: ToolbarGlyph
    let colored: Bool
    let title: String
    let showsTitle: Bool
    var isMenu = false

    var body: some View {
        HStack(spacing: 6) {
            glyph.view(colored: colored)
                .frame(width: 17, height: 17)
            if showsTitle {
                Text(title).font(.system(size: 12)).foregroundStyle(.primary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, isMenu ? 0 : 7)
        .frame(height: isMenu ? 24 : 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct ToolbarIconButton: View {
    let glyph: ToolbarGlyph
    let colored: Bool
    let title: String
    let showsTitle: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarIconLabel(glyph: glyph, colored: colored, title: title, showsTitle: showsTitle)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

/// The native segmented picker supplies keyboard navigation, focus and selection appearance.
struct ViewModePicker: View {
    @ObservedObject var pane: PaneRuntime

    static let modes: [(BrowserViewMode, String, String)] = [
        (.icons, "square.grid.2x2", "Icon View"), (.list, "list.bullet", "List View"),
        (.columns, "rectangle.split.3x1", "Column View"), (.images, "rectangle.bottomthird.inset.filled", "Gallery View"),
    ]

    var body: some View {
        Picker(L("View Mode"), selection: $pane.viewConfiguration.mode) {
            ForEach(Self.modes, id: \.0) { mode, symbol, title in
                Image(systemName: symbol)
                    .help(L(title))
                    .accessibilityLabel(L(title))
                    .accessibilityIdentifier("Toolbar.ViewMode.\(mode.rawValue)")
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .frame(width: ToolbarPresentation.viewModeWidth)
        .help(L(Self.modes.first { $0.0 == pane.viewConfiguration.mode }?.2 ?? "View Mode"))
        .accessibilityLabel(L("View Mode"))
        .accessibilityValue(L(Self.modes.first { $0.0 == pane.viewConfiguration.mode }?.2 ?? "View Mode"))
        .accessibilityIdentifier("Toolbar.ViewMode")
    }
}

/// Preserve all four choices if the configured picker is hidden or overflows.
private struct ViewModeMenuContent: View {
    @ObservedObject var pane: PaneRuntime

    var body: some View {
        ForEach(ViewModePicker.modes, id: \.0) { mode, symbol, title in
            Toggle(isOn: Binding(get: { pane.viewConfiguration.mode == mode },
                                 set: { _ in pane.viewConfiguration.mode = mode })) {
                Label(L(title), systemImage: symbol)
            }
            .help(L(title))
            .accessibilityLabel(L(title))
            .accessibilityIdentifier("Toolbar.ViewMode.\(mode.rawValue)")
        }
    }
}

/// Sort menu in the original's order: keys, direction plus "Configure Default Sorting…", then the two switches.
struct SortMenuContent: View {
    @ObservedObject var pane: PaneRuntime
    var controller: WorkspaceController? = nil
    @AppStorage(DefaultsKey.rememberFolderDisplay) private var remembersFolderDisplay = false

    static let keys: [(FileSortKey, String)] = [
        (.name, "Name"), (.modificationDate, "Modified"), (.addedDate, "Added"), (.kind, "Kind"), (.size, "Size"),
        (.creationDate, "Date Created"), (.lastOpenedDate, "Date Last Opened"), (.tags, "Tags"), (.fileExtension, "File Extension"),
    ]

    static func title(_ key: FileSortKey) -> String {
        L(keys.first { $0.0 == key }?.1 ?? "Name")
    }

    var body: some View {
        ForEach(Self.keys, id: \.0) { key, title in
            Toggle(L(title), isOn: Binding(get: { pane.viewConfiguration.sortKey == key }, set: { _ in pane.viewConfiguration.sortKey = key }))
        }
        Divider()
        Toggle(L("Ascending"), isOn: Binding(get: { pane.viewConfiguration.sortAscending }, set: { _ in pane.viewConfiguration.sortAscending = true }))
        Toggle(L("Descending"), isOn: Binding(get: { !pane.viewConfiguration.sortAscending }, set: { _ in pane.viewConfiguration.sortAscending = false }))
        Button(L("Configure Default Sorting…")) { controller?.showSettings(section: "general") }
        Divider()
        Toggle(L("Keep Folders at Top"), isOn: Binding(get: { pane.viewConfiguration.foldersFirst }, set: { pane.viewConfiguration.foldersFirst = $0 }))
            .accessibilityIdentifier("Toolbar.Sort.FoldersAtTop")
        Toggle(L("Remember folder sorting and grouping"), isOn: $remembersFolderDisplay)
            .accessibilityIdentifier("Toolbar.Sort.RememberFolderDisplay")
    }
}

struct GroupingMenuContent: View {
    @ObservedObject var pane: PaneRuntime

    static let modes: [(FileGroupingMode, String)] = [
        (.none, "No Grouping"), (.kind, "Kind"), (.application, "Application"), (.lastOpened, "Last Opened"),
        (.added, "Added"), (.modified, "Modified"), (.created, "Created"), (.size, "Size"), (.tags, "Tags"),
        (.fileExtension, "File Extension"),
    ]

    static func title(_ mode: FileGroupingMode) -> String {
        L(modes.first { $0.0 == mode }?.1 ?? "No Grouping")
    }

    var body: some View {
        ForEach(Self.modes, id: \.0) { mode, title in
            Toggle(L(title), isOn: Binding(get: { pane.viewConfiguration.groupingMode == mode }, set: { _ in pane.viewConfiguration.groupingMode = mode }))
        }
    }
}

struct NewFileMenuContent: View {
    @ObservedObject var app = AppModel.shared
    let controller: WorkspaceController

    var body: some View {
        ForEach(app.configuration.fileTemplates.sorted { $0.sortOrder < $1.sortOrder }) { template in
            Button { controller.createFile(from: template) } label: {
                if let icon = WorkspaceController.templateIcon(template.builtInKind) {
                    Label { Text((template.emoji.map { "\($0) " } ?? "") + L(template.name)) } icon: { Image(nsImage: icon) }
                } else {
                    Text((template.emoji.map { "\($0) " } ?? "") + L(template.name))
                }
            }
            .accessibilityIdentifier("NewFile.Template.\(template.builtInKind?.rawValue ?? template.id.uuidString)")
        }
        Divider()
        Button { controller.showSettings(section: "newFiles") } label: { Label(L("Add More Formats…"), systemImage: "gearshape") }
            .accessibilityIdentifier("NewFile.AddMoreFormats")
    }
}

enum PaneLayoutNames {
    static func title(_ layout: PaneLayout) -> String {
        switch layout {
        case .single: L("Single Pane")
        case .twoColumns: L("Two Columns")
        case .twoRows: L("Two Rows")
        case .threeColumns: L("Three Columns")
        case .threeRows: L("Three Rows")
        case .oneLeftTwoRight: L("One Left, Two Right")
        case .twoLeftOneRight: L("Two Left, One Right")
        case .oneTopTwoBottom: L("One Top, Two Bottom")
        case .twoTopOneBottom: L("Two Top, One Bottom")
        case .fourGrid: L("Four Panes")
        case .oneLeftThreeRight: L("One Left, Three Right")
        case .threeLeftOneRight: L("Three Left, One Right")
        }
    }

    static func symbol(_ layout: PaneLayout) -> String {
        switch layout {
        case .single: "rectangle"
        case .twoColumns: "rectangle.split.2x1"
        case .twoRows: "rectangle.split.1x2"
        case .threeColumns: "rectangle.split.3x1"
        case .threeRows: "rectangle.split.1x2"
        case .oneLeftTwoRight, .twoLeftOneRight, .oneLeftThreeRight, .threeLeftOneRight: "rectangle.split.2x1"
        case .oneTopTwoBottom, .twoTopOneBottom: "rectangle.split.1x2"
        case .fourGrid: "rectangle.split.2x2"
        }
    }
}

/// Three filled cells and an × in the fourth: "dissolve the split".
struct SplitIntoTabsGlyph: View {
    var colored = true
    private var tint: Color { colored ? ToolbarGlyph.blue : .primary }

    var body: some View {
        Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
            GridRow {
                RoundedRectangle(cornerRadius: 1.5).fill(tint)
                RoundedRectangle(cornerRadius: 1.5).fill(tint)
            }
            GridRow {
                RoundedRectangle(cornerRadius: 1.5).fill(tint)
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(tint)
            }
        }
        .frame(width: 15, height: 15)
    }
}

/// Grid of the 12 pane layouts with schematic thumbnails; the current one is outlined in the accent colour.
struct PaneLayoutChooser: View {
    let current: PaneLayout
    let choose: (PaneLayout) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Pane Layout")).font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 4), spacing: 8) {
                ForEach(PaneLayout.allCases, id: \.self) { layout in
                    let selected = layout == current
                    Button { choose(layout) } label: {
                        VStack(spacing: 5) {
                            PaneLayoutThumbnail(layout: layout, highlighted: selected).frame(width: 52, height: 34)
                            Text(PaneLayoutNames.title(layout)).font(.system(size: 11)).lineLimit(1)
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .frame(width: 70, height: 62)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(PaneLayoutNames.title(layout))
                    .accessibilityIdentifier("PaneLayout.Option.\(layout.rawValue)")
                    .accessibilityLabel(PaneLayoutNames.title(layout))
                }
            }
            .accessibilityIdentifier("PaneLayout.Chooser")
        }
        .padding(14)
    }
}

struct PaneLayoutThumbnail: View {
    let layout: PaneLayout
    var highlighted = false

    /// Pane rectangles in unit coordinates.
    static func cells(_ layout: PaneLayout) -> [CGRect] {
        let third = 1.0 / 3
        switch layout {
        case .single: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .twoColumns: return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .twoRows: return [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .threeColumns: return (0..<3).map { CGRect(x: Double($0) * third, y: 0, width: third, height: 1) }
        case .threeRows: return (0..<3).map { CGRect(x: 0, y: Double($0) * third, width: 1, height: third) }
        case .oneLeftTwoRight:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .twoLeftOneRight:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .oneTopTwoBottom:
            return [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .twoTopOneBottom:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .fourGrid:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .oneLeftThreeRight:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1)] + (0..<3).map { CGRect(x: 0.5, y: Double($0) * third, width: 0.5, height: third) }
        case .threeLeftOneRight:
            return (0..<3).map { CGRect(x: 0, y: Double($0) * third, width: 0.5, height: third) } + [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(Self.cells(layout).enumerated()), id: \.offset) { _, cell in
                let rect = CGRect(x: cell.minX * proxy.size.width, y: cell.minY * proxy.size.height,
                                  width: cell.width * proxy.size.width, height: cell.height * proxy.size.height).insetBy(dx: 1.5, dy: 1.5)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(highlighted ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
