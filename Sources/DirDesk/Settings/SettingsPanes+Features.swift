import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Archives

struct ArchiveSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Archive Browsing")) {
                RowStack {
                    SettingsRow(L("Largest archive to browse without extracting"),
                                detail: L("Archives larger than this have to be extracted before you can look inside.")) {
                        HStack(spacing: 8) {
                            Text(LF("%lld MB", Int64(app.preferences.archiveDirectBrowseSizeLimitMB)))
                                .font(.system(size: 13))
                                .monospacedDigit()
                            Stepper(L("Largest archive to browse without extracting"), value: pref(\.archiveDirectBrowseSizeLimitMB), in: 64...8192, step: 64)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
    }
}

// MARK: Preview

struct SuperPreviewSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Preview")) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(L("Preview archive contents"), isOn: pref(\.previewsArchives))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("Settings.Preference.previewsArchives")
                    Toggle(L("Preview folder contents"), isOn: pref(\.previewsFolders))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("Settings.Preference.previewsFolders")
                    Toggle(L("Show Git badges and status"), isOn: pref(\.showsGitStatus))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("Settings.Preference.showsGitStatus")
                    Text(L("Marks Git changes in file views and in previews."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: Floating ball

struct FloatingBallSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let p = app.preferences
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard(L("Floating Ball")) {
                RowStack {
                    CheckRow(L("Floating Ball"),
                             detail: L("Shows a floating ball in the middle of the right edge of every pane."),
                             isOn: pref(\.showsQuickCapsule))
                    SettingsRow(L("Transparency"), detail: L("At 0 the ball is solid; higher values make it more see-through.")) {
                        HStack(spacing: 14) {
                            Slider(value: pref(\.floatingBallTransparency), in: 0...0.8, step: 0.05) { Text(L("Transparency")) }
                                .labelsHidden()
                                .frame(width: 180)
                                .accessibilityIdentifier("Settings.FloatingBall.Transparency")
                            Text(LF("%lld%%", Int64((p.floatingBallTransparency * 100).rounded())))
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                    SettingsRow(L("Double-click action"), detail: L("What a double-click on the floating ball does in its pane.")) {
                        Picker(L("Double-click action"), selection: pref(\.floatingBallDoubleClickAction)) {
                            ForEach(FloatingBallAction.allCases, id: \.self) { action in
                                Label(Self.title(action), systemImage: Self.symbol(action)).tag(action)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                        .accessibilityIdentifier("Settings.FloatingBall.DoubleClick")
                    }
                    CheckRow(L("Show floating ball buttons on hover"),
                             detail: L("Point at the ball to bring up its buttons. When off, you can still double-click the ball or right-click it for the menu."),
                             isOn: pref(\.expandsFloatingBallOnHover))
                }
            }
            SettingsCard(L("Floating ball buttons")) {
                Text(L("Check the buttons to show and arrange their order. Whole-folder actions include hidden items only when the pane shows hidden items."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // 30 pt rows, as in the original's list.
                VStack(alignment: .leading, spacing: 5.5) {
                    ForEach(Array(p.floatingBallActionOrder.enumerated()), id: \.element) { index, action in
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(action))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Toggle(Self.title(action), isOn: Binding(get: { app.preferences.enabledFloatingBallActions.contains(action) }, set: { on in
                                app.updatePreferences { p in
                                    if on { if !p.enabledFloatingBallActions.contains(action) { p.enabledFloatingBallActions.append(action) } }
                                    else { p.enabledFloatingBallActions.removeAll { $0 == action } }
                                }
                            }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("Settings.FloatingBall.Action.\(action.rawValue)")
                            Spacer()
                            MoveButtons(canMoveUp: index > 0, canMoveDown: index < p.floatingBallActionOrder.count - 1) { move(index, $0) }
                        }
                        .font(.system(size: 13))
                    }
                }
            }
        }
    }

    /// Titles shown in Settings (the original's list uses "Select All" and "Reload" here).
    static func title(_ action: FloatingBallAction) -> String {
        switch action {
        case .back: L("Back")
        case .forward: L("Forward")
        case .up: L("Go Up")
        case .selectAll: L("Select All")
        case .compressAll: L("Compress Selected Items")
        case .collectAll: L("Collect Selected Items into New Folder")
        case .compressFolder: L("Compress All Items in Current Folder")
        case .collectFolder: L("Collect All Items in Current Folder into New Folder")
        case .refresh: L("Reload")
        case .copyPath: L("Copy Folder Path")
        }
    }

    static func symbol(_ action: FloatingBallAction) -> String {
        switch action {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .up: "arrow.up"
        case .selectAll: "checkmark.square"
        case .compressAll: "archivebox"
        case .collectAll: "folder.badge.plus"
        case .compressFolder: "archivebox.fill"
        case .collectFolder: "folder.fill.badge.plus"
        case .refresh: "arrow.clockwise"
        case .copyPath: "link"
        }
    }

    private func move(_ index: Int, _ offset: Int) {
        app.updatePreferences { p in
            let target = index + offset
            guard p.floatingBallActionOrder.indices.contains(index), p.floatingBallActionOrder.indices.contains(target) else { return }
            p.floatingBallActionOrder.swapAt(index, target)
        }
    }
}

// MARK: Floating Files

struct FileTransitSettings: View {
    @ObservedObject var app = AppModel.shared
    @State private var showsSettingsSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Floating Files")) {
                Button(L("File Floating Settings")) { showsSettingsSheet = true }
                    .accessibilityIdentifier("Settings.FileTransit.Settings")
                RowStack {
                    CheckRow(L("Open Floating Files from the chosen trigger position"),
                             detail: L("Move the pointer, or files you are dragging, to the position chosen below to open Floating Files. When off, the menu bar icon and the keyboard shortcut still open it."),
                             isOn: pref(\.enablesFileTransitIsland))
                    CheckRow(L("Show the Floating Files icon in the menu bar"),
                             detail: L("Click the icon in the menu bar to open Floating Files, or drop files onto it."),
                             isOn: pref(\.showsFileTransitMenuBarItem))
                    PopupRow(L("Floating Files trigger position"),
                             detail: L("Open Floating Files from the top of the screen or from the middle of its left or right edge."),
                             selection: pref(\.fileTransitDockEdge),
                             options: [(.top, L("Top")), (.left, L("Left")), (.right, L("Right"))])
                    SettingsRow(L("Floating window background opacity"),
                                detail: L("Higher values make the Floating Files background more solid. When Reduce Transparency is on in macOS, this has no effect and text and buttons stay legible.")) {
                        HStack(spacing: 14) {
                            Slider(value: pref(\.fileTransitPanelOpacity), in: 0.4...1, step: 0.05) { Text(L("Floating window background opacity")) }
                                .labelsHidden()
                                .frame(width: 180)
                                .accessibilityIdentifier("Settings.FileTransit.Opacity.Slider")
                            Text(LF("%lld%%", Int64((app.preferences.fileTransitPanelOpacity * 100).rounded())))
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showsSettingsSheet) {
            FloatingFilesSettingsSheet(done: { showsSettingsSheet = false })
        }
    }
}

// MARK: New file templates

struct TemplateSettings: View {
    @ObservedObject var app = AppModel.shared
    @State private var selection: UUID?
    @State private var addedMessage: String?

    var body: some View {
        let templates = app.configuration.fileTemplates.sorted { $0.sortOrder < $1.sortOrder }
        let selected = templates.first { $0.id == selection } ?? templates.first
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("New File Templates")).font(.system(size: 13, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L("Add Template")) { add() }
                    .accessibilityIdentifier("Templates.Add")
            }
            Text(L("Pick a template to edit its name, default file name, and starting contents."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if templates.isEmpty {
                Text(L("No file templates configured")).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(templates) { template in
                        TemplateTile(template: template, selected: template.id == selected?.id) {
                            selection = template.id
                            addedMessage = nil
                        }
                    }
                }
            }
            if let selected, let index = templates.firstIndex(where: { $0.id == selected.id }) {
                TemplateEditor(stored: selected, canMoveUp: index > 0, canMoveDown: index < templates.count - 1,
                               notice: addedMessage, move: { move(selected.id, by: $0) }, remove: { remove(selected.id) })
                    .id(selected.id)
                    .padding(.top, 6)
            }
        }
    }

    private func add() {
        // Stored as the localization key, like the built-in names, so it follows the app language until renamed.
        let template = NewFileTemplate(name: "Custom Template", fileNamePattern: "Untitled.txt",
                                       sortOrder: (app.configuration.fileTemplates.map(\.sortOrder).max() ?? -1) + 1)
        app.update { $0.fileTemplates.append(template) }
        selection = template.id
        addedMessage = L("Template added. Edit it, then choose Save Template.")
    }

    private func move(_ id: UUID, by offset: Int) {
        app.update { c in
            var sorted = c.fileTemplates.sorted { $0.sortOrder < $1.sortOrder }
            guard let index = sorted.firstIndex(where: { $0.id == id }), sorted.indices.contains(index + offset) else { return }
            sorted.swapAt(index, index + offset)
            for i in sorted.indices { sorted[i].sortOrder = i }
            c.fileTemplates = sorted
        }
    }

    private func remove(_ id: UUID) {
        app.update { $0.fileTemplates.removeAll { $0.id == id } }
        selection = nil
        addedMessage = nil
    }
}

/// Icon for a template: its emoji when set, otherwise a colored symbol for the built-in kind.
private struct TemplateGlyph: View {
    let template: NewFileTemplate
    let size: CGFloat

    var body: some View {
        if let emoji = template.emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size * 0.8)).frame(width: size, height: size)
        } else {
            let style = Self.style(template.builtInKind)
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(style.color)
                .frame(width: size, height: size)
        }
    }

    static func style(_ kind: BuiltInFileTemplateKind?) -> (symbol: String, color: Color) {
        switch kind {
        case .markdown: ("doc.text", Color(red: 0.87, green: 0.24, blue: 0.95))
        case .plainText: ("doc.plaintext", Color(red: 0.45, green: 0.48, blue: 1.0))
        case .jsonFile: ("curlybraces.square", .orange)
        case .wordDocument: ("doc.richtext", .blue)
        case .excelSpreadsheet: ("tablecells", .green)
        case .powerPointPresentation: ("rectangle.on.rectangle", .red)
        case .csvSpreadsheet: ("tablecells.badge.ellipsis", .teal)
        case .pagesDocument: ("doc.richtext", .orange)
        case .keynotePresentation: ("rectangle.on.rectangle", .blue)
        case .numbersSpreadsheet: ("tablecells", .green)
        case nil: ("doc", .secondary)
        }
    }
}

private struct TemplateTile: View {
    let template: NewFileTemplate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TemplateGlyph(template: template, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(template.name)).font(.system(size: 14)).lineLimit(1)
                    Text(template.fileNamePattern).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if template.isDefault {
                    Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.015)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(template.name) + ", " + template.fileNamePattern)
        .accessibilityIdentifier("Template.\(template.id.uuidString).Select")
    }
}

/// Editor card below the template grid. Edits stay local until "Save Template"; the star, arrows
/// and trash act immediately, like the original.
private struct TemplateEditor: View {
    let stored: NewFileTemplate
    let canMoveUp: Bool
    let canMoveDown: Bool
    let notice: String?
    let move: (Int) -> Void
    let remove: () -> Void
    @ObservedObject var app = AppModel.shared
    @State private var draft: NewFileTemplate
    @State private var message: String?
    @State private var showsIconEditor = false

    init(stored: NewFileTemplate, canMoveUp: Bool, canMoveDown: Bool, notice: String?, move: @escaping (Int) -> Void, remove: @escaping () -> Void) {
        self.stored = stored
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.notice = notice
        self.move = move
        self.remove = remove
        _draft = State(initialValue: stored)
    }

    private var isEdited: Bool {
        draft.name != stored.name || draft.emoji != stored.emoji || draft.fileNamePattern != stored.fileNamePattern
            || draft.dateFormat != stored.dateFormat || draft.datePosition != stored.datePosition
            || draft.contents != stored.contents || draft.contentData != stored.contentData
    }

    private var usesTextContents: Bool {
        draft.contentData == nil && (draft.builtInKind.map { OfficeSeeds.seed(for: $0) == nil } ?? true)
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: 10) {
                TemplateGlyph(template: draft, size: 20)
                Button { setDefault() } label: { Image(systemName: stored.isDefault ? "star.fill" : "star") }
                    .buttonStyle(.borderless)
                    .help(L("Use as Default Template"))
                    .accessibilityLabel(L("Use as Default Template"))
                Text(L(stored.name)).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Spacer()
                MoveButtons(canMoveUp: canMoveUp, canMoveDown: canMoveDown, move: move)
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("Remove Template"))
                    .accessibilityLabel(L("Remove Template"))
            }
            .padding(.bottom, 4)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text(L("Template Name")).font(.system(size: 13))
                    TextField(L("Template Name"), text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("Template.\(stored.id.uuidString).Name")
                }
                GridRow {
                    Text(L("Template Icon")).font(.system(size: 13))
                    Button(draft.emoji.flatMap { $0.isEmpty ? nil : $0 } ?? L("Default Icon")) { showsIconEditor = true }
                        .accessibilityIdentifier("Template.\(stored.id.uuidString).Icon")
                        .popover(isPresented: $showsIconEditor, arrowEdge: .bottom) { iconEditor }
                }
                GridRow {
                    Text(L("Default File Name")).font(.system(size: 13))
                    TextField(L("Default File Name"), text: $draft.fileNamePattern)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("Template.\(stored.id.uuidString).FileName")
                }
            }
            Toggle(L("Add Date or Time"), isOn: Binding(get: { draft.dateFormat != nil }, set: { on in
                draft.dateFormat = on ? (draft.dateFormat ?? "yyyy-MM-dd") : nil
            }))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("Template.\(stored.id.uuidString).AddDate")
            if draft.dateFormat != nil {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(L("Date Format")).font(.system(size: 13))
                        TextField(L("Date Format"), text: Binding(get: { draft.dateFormat ?? "" }, set: { draft.dateFormat = $0 }), prompt: Text("yyyy-MM-dd"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    GridRow {
                        Text(L("Date Position")).font(.system(size: 13))
                        Picker(L("Date Position"), selection: $draft.datePosition) {
                            Text(L("Before File Name")).tag(TemplateDatePosition.beforeName)
                            Text(L("After File Name (Before Extension)")).tag(TemplateDatePosition.afterName)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.leading, 20)
                Text(L("yyyy = year, MM = month, dd = day, HH = hour, mm = minute, ss = second. Example: MM-dd-HHmm."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            HStack(spacing: 10) {
                Text(L("Preview")).font(.system(size: 13, weight: .semibold))
                Text(TemplateRenderer.fileName(for: draft)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            Text(L("Initial contents (optional)")).font(.system(size: 12, weight: .semibold))
            if usesTextContents {
                TextEditor(text: $draft.contents)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(alignment: .topLeading) {
                        if draft.contents.isEmpty {
                            Text(L("Initial contents (optional)"))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("Template.\(stored.id.uuidString).Contents")
            } else if draft.contentData != nil {
                HStack {
                    Text(L("The imported file provides the contents of each new file.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Use Text Content")) { draft.contentData = nil }
                }
            } else {
                Text(L("New files from this template start as an empty document of this type."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button(L("Choose Initial Content File…")) { chooseContent() }
            Divider()
            HStack {
                if let text = message ?? notice {
                    Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Save Template")) { save() }
                    .disabled(!isEdited)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var iconEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Template Icon")).font(.system(size: 13, weight: .semibold))
            TextField(L("Template Icon"), text: Binding(get: { draft.emoji ?? "" }, set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                draft.emoji = trimmed.isEmpty ? nil : String(trimmed.prefix(2))
            }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
            HStack {
                Button(L("Default Icon")) { draft.emoji = nil; showsIconEditor = false }
                Spacer()
                Button(L("Done")) { showsIconEditor = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    /// Built-in names are localization keys; show the localized name and keep the key unless the user renames it.
    private var nameBinding: Binding<String> {
        Binding(get: { L(draft.name) }, set: { value in draft.name = value == L(stored.name) ? stored.name : value })
    }

    private func setDefault() {
        app.update { c in
            for index in c.fileTemplates.indices { c.fileTemplates[index].isDefault = c.fileTemplates[index].id == stored.id }
        }
    }

    private func chooseContent() {
        let panel = NSOpenPanel()
        panel.message = L("Choose a file to use as this template's contents.")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 4 << 20 else {
            message = L("Template content must be 4 MB or smaller.")
            return
        }
        draft.contentData = data
        if draft.fileNamePattern.hasPrefix("Untitled."), !url.pathExtension.isEmpty { draft.fileNamePattern = "Untitled." + url.pathExtension }
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { message = L("Enter a template name."); return }
        guard (try? FileOperations.validateName(TemplateRenderer.fileName(for: draft))) != nil else { message = L("The file template is invalid."); return }
        let edited = draft
        app.update { configuration in
            guard let index = configuration.fileTemplates.firstIndex(where: { $0.id == edited.id }) else { return }
            var template = configuration.fileTemplates[index]
            template.name = edited.name
            template.emoji = edited.emoji
            template.fileNamePattern = edited.fileNamePattern
            template.dateFormat = edited.dateFormat
            template.datePosition = edited.datePosition
            template.contents = edited.contents
            template.contentData = edited.contentData
            configuration.fileTemplates[index] = template
        }
        message = L("Template saved.")
    }
}

// MARK: External tools

struct ExternalToolSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let tools = app.configuration.externalTools.sorted { $0.sortOrder < $1.sortOrder }
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("External Tools")) {
                Text(L("Choose the apps that open a terminal or edit files. Each type keeps its own default app."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                if tools.isEmpty {
                    Text(L("No external tools configured")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    // Rows sit close together, as in the original (a hairline only between several tools).
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Divider() }
                        ExternalToolEditor(stored: tool, canMoveUp: index > 0, canMoveDown: index < tools.count - 1,
                                           move: { move(tool.id, by: $0) })
                            .id(tool.id)
                    }
                }
                Button(L("Add Tool…")) { add() }
            }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        app.update { c in
            var sorted = c.externalTools.sorted { $0.sortOrder < $1.sortOrder }
            guard let index = sorted.firstIndex(where: { $0.id == id }), sorted.indices.contains(index + offset) else { return }
            sorted.swapAt(index, index + offset)
            for i in sorted.indices { sorted[i].sortOrder = i }
            c.externalTools = sorted
        }
    }

    private func add() {
        guard let url = ExternalToolEditor.chooseApplication() else { return }
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let kind: ExternalToolKind = ExternalToolEditor.looksLikeTerminal(bundle?.bundleIdentifier) ? .terminal : .editor
        app.update { c in
            let hasDefault = c.externalTools.contains { $0.kind == kind && $0.isDefault }
            c.externalTools.append(ExternalTool(name: name, bundleIdentifier: bundle?.bundleIdentifier, applicationPath: url.path, kind: kind,
                                                isDefault: !hasDefault, sortOrder: (c.externalTools.map(\.sortOrder).max() ?? -1) + 1))
        }
    }
}

/// One tool: default star, name, type, reorder and remove on top; application path with "Choose…" below.
/// Name, type and application are saved with "Save Tool".
private struct ExternalToolEditor: View {
    let stored: ExternalTool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    @ObservedObject var app = AppModel.shared
    @State private var draft: ExternalTool
    @State private var message: String?

    init(stored: ExternalTool, canMoveUp: Bool, canMoveDown: Bool, move: @escaping (Int) -> Void) {
        self.stored = stored
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.move = move
        _draft = State(initialValue: stored)
    }

    private var isEdited: Bool {
        draft.name != stored.name || draft.kind != stored.kind || draft.applicationPath != stored.applicationPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { setDefault() } label: { Image(systemName: stored.isDefault ? "star.fill" : "star") }
                    .buttonStyle(.borderless)
                    .help(L("Use as Default Tool"))
                    .accessibilityLabel(L("Use as Default Tool"))
                TextField(L("Name"), text: Binding(get: { L(draft.name) }, set: { value in
                    draft.name = value == L(stored.name) ? stored.name : value
                }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                Picker(L("Tool Type"), selection: $draft.kind) {
                    Text(L("Terminal")).tag(ExternalToolKind.terminal)
                    Text(L("Editor")).tag(ExternalToolKind.editor)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                MoveButtons(canMoveUp: canMoveUp, canMoveDown: canMoveDown, move: move)
                Button { app.update { $0.externalTools.removeAll { $0.id == stored.id } } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("Remove Tool"))
                    .accessibilityLabel(L("Remove Tool"))
                    .accessibilityIdentifier("ExternalTool.\(stored.id.uuidString).Remove")
            }
            HStack(spacing: 10) {
                Text(draft.applicationPath)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(L("Choose…")) { choose() }
            }
            HStack {
                if let message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Save Tool")) { save() }.disabled(!isEdited)
            }
        }
    }

    private func setDefault() {
        app.update { c in
            for index in c.externalTools.indices where c.externalTools[index].kind == stored.kind {
                c.externalTools[index].isDefault = c.externalTools[index].id == stored.id
            }
        }
    }

    private func choose() {
        guard let url = Self.chooseApplication() else { return }
        draft.applicationPath = url.path
        draft.bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        message = nil
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { message = L("Enter a tool name."); return }
        guard !draft.applicationPath.isEmpty else { message = L("Choose an application before saving this tool."); return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: draft.applicationPath, isDirectory: &isDirectory), isDirectory.boolValue,
              draft.applicationPath.hasSuffix(".app") else {
            message = L("The selected application is missing or is not a valid Mac app.")
            return
        }
        let edited = draft
        app.update { c in
            guard let index = c.externalTools.firstIndex(where: { $0.id == edited.id }) else { return }
            var tool = c.externalTools[index]
            let kindChanged = tool.kind != edited.kind
            tool.name = edited.name
            tool.kind = edited.kind
            tool.applicationPath = edited.applicationPath
            tool.bundleIdentifier = edited.bundleIdentifier
            if kindChanged { tool.isDefault = !c.externalTools.contains { $0.kind == edited.kind && $0.isDefault && $0.id != edited.id } }
            c.externalTools[index] = tool
            // Every kind that still has tools keeps exactly one default.
            for kind in ExternalToolKind.allCases {
                let indices = c.externalTools.indices.filter { c.externalTools[$0].kind == kind }
                if !indices.isEmpty, !indices.contains(where: { c.externalTools[$0].isDefault }) { c.externalTools[indices[0]].isDefault = true }
            }
        }
        message = L("External tool saved.")
    }

    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = L("Choose a Mac app to use for this external tool.")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func looksLikeTerminal(_ bundleIdentifier: String?) -> Bool {
        let id = bundleIdentifier?.lowercased() ?? ""
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby"].contains { id.contains($0) }
    }
}

// MARK: Built-in tools

struct BuiltInToolSettings: View {
    @ObservedObject var app = AppModel.shared
    @State private var query = ""

    var body: some View {
        let matches = BuiltInToolID.allCases.filter(isMatch)
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Pick the file tools that show up in the context menu."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(L("Search tools or extensions"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("BuiltInTools.Search")
            if matches.isEmpty {
                Text(L("No Matching Tools")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(BuiltInToolCategory.allCases, id: \.self) { category in
                let tools = matches.filter { $0.category == category }
                if !tools.isEmpty {
                    SettingsCard(Self.categoryTitle(category)) {
                        RowStack {
                            ForEach(tools, id: \.self) { tool in toolRow(tool) }
                        }
                    }
                }
            }
        }
    }

    private func isMatch(_ tool: BuiltInToolID) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [Self.title(tool), Self.summary(tool), Self.categoryTitle(tool.category)].contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private func toolRow(_ tool: BuiltInToolID) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: BuiltInToolSupport.symbol(tool))
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(tool)).font(.system(size: 13, weight: .semibold))
                Text(Self.summary(tool) + " " + Self.output(tool))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 270, alignment: .leading)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Toggle(Self.title(tool), isOn: Binding(get: { app.configuration.enabledBuiltInTools.contains(tool) }, set: { on in
                    app.update { c in
                        if on { if !c.enabledBuiltInTools.contains(tool) { c.enabledBuiltInTools.append(tool) } }
                        else { c.enabledBuiltInTools.removeAll { $0 == tool } }
                    }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("BuiltInTools.Enabled.\(tool.rawValue)")
                Text(Self.formats(tool)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Label(L("Available on this Mac"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
    }

    static func categoryTitle(_ category: BuiltInToolCategory) -> String {
        switch category {
        case .images: L("Images")
        case .folders: L("Folders")
        case .pdf: L("PDF")
        case .metadataPrivacy: L("Metadata & Privacy")
        }
    }

    /// Settings title; the folder tool is called "Move Selected Items into New Folder" on this page in the original.
    static func title(_ tool: BuiltInToolID) -> String {
        tool == .collectIntoFolder ? L("Move Selected Items into New Folder") : BuiltInToolSupport.title(tool)
    }

    static func formats(_ tool: BuiltInToolID) -> String {
        switch tool.category {
        case .images, .metadataPrivacy: L("JPG · PNG · HEIC · TIFF · other images")
        case .folders: L("Files and folders")
        case .pdf: L("PDF")
        }
    }

    static func summary(_ tool: BuiltInToolID) -> String {
        switch tool {
        case .imageRotateLeft: L("Saves a copy turned to the left and keeps the image metadata.")
        case .imageRotateRight: L("Saves a copy turned to the right and keeps the image metadata.")
        case .imageCrop: L("Crops one image to a rectangle you draw and saves the result as a copy.")
        case .imageConvert: L("Converts images to JPEG, PNG, HEIC, or TIFF.")
        case .imageCompress: L("Lowers image quality or dimensions and previews the result before saving.")
        case .imageWatermark: L("Stamps centered or tiled text on images with a live preview.")
        case .imageRemoveBackground: L("Finds the subject on this Mac and saves it as a transparent PNG.")
        case .imagesCreatePDF: L("Combines the selected images into one PDF in the order they are shown.")
        case .collectIntoFolder: L("Puts the selected items into a new folder; Undo moves them back.")
        case .dissolveFolder: L("Moves a folder's contents up one level, keeping both items when names clash; Undo brings the folder back.")
        case .pdfSplit: L("Splits a PDF by page ranges, pages per file, or number of files.")
        case .pdfExtractPages: L("Copies the pages you choose into a new PDF.")
        case .pdfMerge: L("Joins PDFs in the order they are selected and shown.")
        case .pdfRotatePages: L("Rotates the chosen pages or the whole document and saves a new PDF.")
        case .pdfCompress: L("Shrinks the images embedded in a PDF and leaves the original untouched.")
        case .pdfExportImages: L("Saves every page as a numbered PNG or JPEG image.")
        case .imageViewLocation: L("Reads the coordinates stored in a photo without going online and lets you copy them.")
        case .imageRemoveLocationMetadata: L("Saves a copy with the embedded location data removed.")
        }
    }

    static func output(_ tool: BuiltInToolID) -> String {
        switch tool {
        case .imageRotateLeft, .imageRotateRight: L("Output: a rotated copy next to the original.")
        case .imageCrop: L("Output: a cropped copy next to the original.")
        case .imageConvert: L("Output: a converted copy next to the original.")
        case .imageCompress: L("Output: a compressed copy next to the original.")
        case .imageWatermark: L("Output: a watermarked copy next to the original.")
        case .imageRemoveBackground: L("Output: a transparent PNG next to the original.")
        case .imagesCreatePDF: L("Output: one PDF in the same folder, in selection order.")
        case .collectIntoFolder, .dissolveFolder: L("Moves the original items and never overwrites existing ones.")
        case .pdfSplit: L("Output: several PDFs in the same folder with names that do not collide.")
        case .pdfExtractPages: L("Output: a PDF of the extracted pages next to the original.")
        case .pdfMerge: L("Output: a merged PDF in the same folder.")
        case .pdfRotatePages: L("Output: a rotated PDF copy next to the original.")
        case .pdfCompress: L("Output: a compressed PDF copy next to the original.")
        case .pdfExportImages: L("Output: one folder beside the PDF that holds every page image.")
        case .imageViewLocation: L("Read-only; no file is written.")
        case .imageRemoveLocationMetadata: L("Output: a cleaned copy next to the original.")
        }
    }
}

// MARK: Context menu

struct ContextMenuSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let enabled = app.configuration.contextMenuCommands
        let available = ContextMenuCommand.allCases.filter { !enabled.contains($0) }
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Context Menu")) {
                RowStack {
                    SettingsRow(L("Context menu presets"),
                                detail: L("Applying a preset brings back its actions and their order. You can still change them afterwards.")) {
                        HStack(spacing: 10) {
                            Button(L("Wumi Default")) { app.update { $0.contextMenuCommands = ContextMenuCommand.defaultPreset } }
                                .accessibilityIdentifier("ContextMenu.Template.Default")
                            Button(L("Finder Style")) { app.update { $0.contextMenuCommands = ContextMenuCommand.finderStylePreset } }
                                .accessibilityIdentifier("ContextMenu.Template.Finder")
                        }
                    }
                    CheckRow(L("Show context menu icons"),
                             detail: L("Shows an icon beside each action in the context menu."),
                             isOn: pref(\.showsContextMenuIcons))
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("Current menu items"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            ForEach(Array(enabled.enumerated()), id: \.element) { index, command in
                                currentRow(command, index: index, count: enabled.count)
                            }
                        }
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("Available actions"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 6)
                            ForEach(available, id: \.self) { command in
                                HStack(spacing: 10) {
                                    Image(systemName: command.isSeparator ? "minus" : "line.3.horizontal")
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 16)
                                    Text(Self.title(command))
                                    Spacer()
                                    Button { app.update { $0.contextMenuCommands.append(command) } } label: { Image(systemName: "plus.circle") }
                                        .buttonStyle(.borderless)
                                        .help(L("Add"))
                                        .accessibilityLabel(L("Add"))
                                }
                                .font(.system(size: 13))
                                .frame(height: 28)
                                .draggable(command.rawValue)
                            }
                        }
                        .padding(.leading, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func currentRow(_ command: ContextMenuCommand, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.isSeparator ? "minus" : "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityLabel(L("Drag to Reorder"))
            Text(Self.title(command))
            Spacer()
            MoveButtons(canMoveUp: index > 0, canMoveDown: index < count - 1) { move(index, $0) }
            Button { app.update { $0.contextMenuCommands.removeAll { $0 == command } } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(L("Remove Context Menu Action"))
                .accessibilityLabel(L("Remove Context Menu Action"))
                .accessibilityIdentifier("ContextMenu.Remove.\(command.rawValue)")
        }
        .font(.system(size: 13))
        .frame(height: 28)
        .contentShape(Rectangle())
        .draggable(command.rawValue)
        .dropDestination(for: String.self) { items, _ in
            insert(items.first, before: command)
        }
    }

    static func title(_ command: ContextMenuCommand) -> String {
        command.isSeparator ? L("Separator") : ContextMenuTitles.title(command)
    }

    private func move(_ index: Int, _ offset: Int) {
        app.update { c in
            let target = index + offset
            guard c.contextMenuCommands.indices.contains(index), c.contextMenuCommands.indices.contains(target) else { return }
            c.contextMenuCommands.swapAt(index, target)
        }
    }

    /// Drop handler: moves a current item, or adds an available one, in front of `target`.
    private func insert(_ raw: String?, before target: ContextMenuCommand) -> Bool {
        guard let raw, let command = ContextMenuCommand(rawValue: raw), command != target else { return false }
        app.update { c in
            c.contextMenuCommands.removeAll { $0 == command }
            let index = c.contextMenuCommands.firstIndex(of: target) ?? c.contextMenuCommands.count
            c.contextMenuCommands.insert(command, at: index)
        }
        return true
    }
}

enum ContextMenuTitles {
    static func title(_ command: ContextMenuCommand) -> String {
        switch command {
        case .open: L("Open")
        case .openWith: L("Open With")
        case .openTerminal: L("Open in Terminal")
        case .openEditor: L("Open in Editor")
        case .openInNewTab: L("Open in New Tab")
        case .quickLook: L("Quick Look")
        case .getInfo: L("Get Info")
        case .rename: L("Rename")
        case .builtInTools: L("Built-in Tools")
        case .compress: L("Create Archive")
        case .extract: L("Extract")
        case .extractTo: L("Extract To")
        case .duplicate: L("Duplicate")
        case .makeAlias: L("Make Alias")
        case .invertSelection: L("Invert Selection")
        case .cut: L("Cut")
        case .copy: L("Copy")
        case .copyTo: L("Copy To")
        case .share: L("Share")
        case .tags: L("Tags")
        case .sendTo: L("Send To")
        case .copyPath: L("Copy Absolute Path")
        case .reveal: L("Reveal in Finder")
        case .bookmarks: L("Bookmarks")
        case .checksum: L("Calculate SHA-256")
        case .batchRename: L("Batch Rename")
        case .paneTransfer: L("Copy or Move to Pane")
        case .trash: L("Move to Trash")
        case .separatorOpen, .separatorEdit, .separatorLocation, .separatorDestructive: L("Separator")
        }
    }
}

// MARK: About

struct AboutSettings: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard(L("Version")) {
                Text("Wumi \(version) (\(build))")
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("Settings.About.VersionInfo")
            }
            SettingsCard(L("License")) {
                Label(L("Independent implementation for personal use. All features are available; there is no trial or subscription."),
                      systemImage: "checkmark.seal")
                    .font(.system(size: 13))
                    .accessibilityIdentifier("Settings.About.License")
            }
            SettingsCard(L("Support")) {
                Text(L("When you report a problem, include the version information below."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button(L("Copy Version Information")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Wumi \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                }
                .accessibilityIdentifier("Settings.About.CopyVersion")
            }
        }
    }
}
