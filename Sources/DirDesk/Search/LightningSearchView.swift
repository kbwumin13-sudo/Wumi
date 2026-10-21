import AppKit
import DirDeskCore
import SwiftUI

/// Content of a Lightning Search window: the search box, one row of filters (or the Search Expression
/// options), the results and a status line.
struct LightningSearchView: View {
    @ObservedObject var model: LightningSearchModel
    @ObservedObject private var service: LightningSearchService
    @ObservedObject private var app = AppModel.shared

    init(model: LightningSearchModel) {
        self.model = model
        _service = ObservedObject(wrappedValue: model.service)
    }

    var body: some View {
        VStack(spacing: 0) {
            LightningSearchHeader(model: model)
                .padding(.horizontal, 11.5)
                .padding(.top, 9.5)
            if model.mode == .visual {
                LightningFilterBar(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 9.5)
                    .padding(.bottom, 10)
            } else {
                LightningExpressionBar(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 7.5)
                    .padding(.bottom, 8)
            }
            LightningMessageLines(model: model)
            if model.usedIncompleteIndex, model.scope != .computer, !model.rows.isEmpty {
                LightningNoticeBanner(text: L("Results come from a direct scan of the folder while the search index is being built. They refresh when the index is ready."))
            }
            ZStack {
                LightningResultsTable(model: model)
                LightningEmptyState(model: model, service: service)
            }
            Divider()
            LightningStatusBar(model: model, service: service)
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $model.showsHelp) {
            LightningSearchHelpSheet(model: model)
        }
        .id(app.language)
    }
}

// MARK: - Search box

/// The large search box: lightning magnifier, field, Visual / Search Expression, help and pin.
struct LightningSearchHeader: View {
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        HStack(spacing: 0) {
            LightningSearchIcon()
                .padding(.leading, 16)
            LightningQueryField(text: Binding(get: { model.fieldText }, set: { model.fieldText = $0 }),
                                placeholder: placeholder,
                                focus: model.focus,
                                onSubmit: { model.scheduleSearch(immediately: true) },
                                onMoveDown: { model.focus.focusResults() })
                .frame(maxWidth: .infinity)
                .padding(.leading, 11)
                .padding(.trailing, 12)
            Picker(L("Search Mode"), selection: Binding(get: { model.mode }, set: { model.requestMode($0) })) {
                Text(L("Visual")).tag(LightningSearchModel.Mode.visual)
                Text(L("Search Expression")).tag(LightningSearchModel.Mode.expression)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: modeControlWidth)
            .id(model.modeControlRevision)
            .accessibilityIdentifier("LightningSearch.Mode")
            Button {
                model.helpTab = .basics
                model.showsHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 12.5, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Search Expression Help"))
            .accessibilityLabel(L("Search Expression Help"))
            .padding(.leading, 11.5)
            Toggle(isOn: $model.isPinned) {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .frame(width: 13)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(L("Pinned, the window stays in front even while you use another app. Unpinned, clicking anywhere outside it closes it."))
            .accessibilityLabel(L("Keep Search on Top"))
            .accessibilityIdentifier("LightningSearch.Pin")
            .padding(.leading, 11.5)
            .padding(.trailing, 14)
        }
        .frame(height: 53)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 1))
    }

    private var placeholder: String {
        if model.mode == .expression { return L("Search Expression") }
        return model.visual.textTarget == .contents ? L("Search File Contents") : L("Search File Names")
    }

    /// Two equal segments, 177 points in Chinese; wider when a language needs it.
    private var modeControlWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = [L("Visual"), L("Search Expression")].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(177, 2 * (widest.rounded(.up) + 23))
    }
}

/// A magnifying glass with a lightning bolt in its lens, drawn from system symbols.
struct LightningSearchIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
                .offset(x: 6.9, y: 5.4)
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The search field. AppKit-backed so Return, Down Arrow and initial focus behave like a native search box;
/// it has no border of its own because the surrounding box draws one.
struct LightningQueryField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focus: LightningSearchFocus
    let onSubmit: () -> Void
    let onMoveDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LightningSearchTextField {
        let field = LightningSearchTextField()
        field.focusOwner = focus
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 16)
        field.setAccessibilityIdentifier("GlobalQuickSearch.Field")
        field.stringValue = text
        apply(to: field)
        return field
    }

    func updateNSView(_ field: LightningSearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        apply(to: field)
    }

    private func apply(to field: NSTextField) {
        if field.placeholderString != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
            field.placeholderString = placeholder
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LightningQueryField

        init(_ parent: LightningQueryField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field.stringValue != parent.text else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)) {
                parent.onMoveDown()
                return true
            }
            return false
        }
    }
}

final class LightningSearchTextField: NSTextField {
    weak var focusOwner: LightningSearchFocus?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusOwner?.fieldDidMoveToWindow(self) }
    }
}

// MARK: - Visual filters

/// Match, Scope, Kind, Tags and Modified on the left; Advanced Search and Reset Filters on the right.
struct LightningFilterBar: View {
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        HStack(spacing: 8) {
            Picker(L("Match"), selection: $model.visual.textTarget) {
                Text(L("Name")).tag(LightningVisualTextTarget.name)
                Text(L("File Contents")).tag(LightningVisualTextTarget.contents)
            }
            .labelsHidden()
            .fixedSize()
            .help(model.visual.textTarget == .name ? L("Search File Names") : L("Search File Contents"))
            .accessibilityIdentifier("LightningSearch.Match")
            Menu {
                ForEach(model.scopeChoices, id: \.self) { choice in
                    Button(Self.title(choice)) { model.scope = choice }
                }
                Button(L("Choose Folder…")) { model.chooseFolders() }
            } label: {
                Text(model.scopeTitle)
            }
            .fixedSize()
            .help(L("This Computer looks through every indexed folder Wumi is allowed to read. A folder scope also looks inside its subfolders."))
            .accessibilityIdentifier("LightningSearch.Scope")
            LightningFilterButton(title: LF("Type: %@", kindSummary)) { toggle(.kinds) }
                .popover(isPresented: popoverBinding(.kinds), arrowEdge: .bottom) {
                    LightningKindsPopover(kinds: $model.visual.kinds)
                }
                .accessibilityIdentifier("LightningSearch.Kinds")
            LightningFilterButton(title: LF("Tags: %@", tagSummary)) { toggle(.tags) }
                .popover(isPresented: popoverBinding(.tags), arrowEdge: .bottom) {
                    LightningTagsPopover(tags: $model.visual.tags)
                }
                .accessibilityIdentifier("LightningSearch.Tags")
            Menu {
                ForEach(Self.datePresets, id: \.self) { preset in
                    Button(Self.title(preset)) { choose(preset) }
                }
            } label: {
                Text(LF("Modified: %@", dateSummary))
            }
            .fixedSize()
            .popover(isPresented: popoverBinding(.customDates), arrowEdge: .bottom) {
                LightningCustomDatesPopover(model: model)
            }
            .accessibilityIdentifier("LightningSearch.Modified")
            Spacer(minLength: 8)
            Button(L("Advanced Search")) { model.showsAdvanced.toggle() }
                .accessibilityIdentifier("LightningSearch.Advanced")
            // Gray while every filter is at its default (clicking it then changes nothing), blue once there is
            // something to reset.
            Button(L("Reset Filters")) { model.resetFilters() }
                .buttonStyle(.plain)
                .foregroundStyle(model.visual.hasFilters ? Color.accentColor : Color.secondary)
        }
        .frame(height: 24)
    }

    static let datePresets: [LightningVisualDatePreset] = [.any, .today, .yesterday, .pastWeek, .pastMonth, .thisYear, .custom]

    static func title(_ choice: LightningSearchModel.ScopeChoice) -> String {
        switch choice {
        case .computer: L("This Computer")
        case .currentFolder: L("Current Folder")
        case .workspace: L("Current Workspace")
        case .selected: L("Choose Folder…")
        }
    }

    static func title(_ preset: LightningVisualDatePreset) -> String {
        switch preset {
        case .any: L("Any Time")
        case .today: L("Today")
        case .yesterday: L("Yesterday")
        case .pastWeek: L("Past Week")
        case .pastMonth: L("Past Month")
        case .thisYear: L("This Year")
        case .custom: L("Custom Date…")
        }
    }

    static func title(_ kind: LightningVisualKind) -> String {
        switch kind {
        case .file: L("Files")
        case .image: L("Images")
        case .video: L("Video")
        case .audio: L("Audio")
        case .document: L("Documents")
        case .pdf: L("PDF")
        case .spreadsheet: L("Spreadsheets")
        case .presentation: L("Presentations")
        case .archive: L("Archives")
        case .code: L("Code")
        case .application: L("Applications")
        case .folder: L("Folders")
        }
    }

    /// "Any", one kind, or the first kind and how many more.
    private var kindSummary: String {
        let selected = LightningVisualKind.allCases.filter(model.visual.kinds.contains)
        guard let first = selected.first else { return L("Any") }
        return selected.count == 1 ? Self.title(first) : Self.title(first) + " +" + String(selected.count - 1)
    }

    private var tagSummary: String {
        let tags = model.visual.tags
        guard let first = tags.first else { return L("Any") }
        return tags.count == 1 ? first : first + " +" + String(tags.count - 1)
    }

    private var dateSummary: String {
        let visual = model.visual
        guard visual.date == .custom else { return Self.title(visual.date) }
        let start = visual.customStart.map(Self.dayText) ?? "…"
        let end = visual.customEnd.map(Self.dayText) ?? "…"
        return start + " – " + end
    }

    static func dayText(_ day: LightningVisualDay) -> String {
        guard let date = day.date() else { return day.expressionText }
        let formatter = DateFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMdd")
        return formatter.string(from: date)
    }

    private func choose(_ preset: LightningVisualDatePreset) {
        var visual = model.visual
        visual.date = preset
        if preset == .custom {
            let calendar = Calendar.current
            let now = Date()
            visual.customEnd = visual.customEnd ?? LightningVisualDay(now, calendar: calendar)
            visual.customStart = visual.customStart
                ?? LightningVisualDay(calendar.date(byAdding: .month, value: -1, to: now) ?? now, calendar: calendar)
        }
        model.visual = visual
        if preset == .custom { model.presentedPopover = .customDates }
    }

    private func toggle(_ popover: LightningSearchModel.FilterPopover) {
        model.presentedPopover = model.presentedPopover == popover ? nil : popover
    }

    private func popoverBinding(_ popover: LightningSearchModel.FilterPopover) -> Binding<Bool> {
        Binding(get: { model.presentedPopover == popover }, set: { shown in
            if shown {
                model.presentedPopover = popover
            } else if model.presentedPopover == popover {
                model.presentedPopover = nil
            }
        })
    }
}

/// A bordered button that looks like the filter menus next to it: title and a down chevron.
struct LightningFilterButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// Kind: multiple choice, any selected kind matches.
struct LightningKindsPopover: View {
    @Binding var kinds: Set<LightningVisualKind>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Type"))
                .font(.system(size: 13, weight: .semibold))
                .frame(height: 16)
                .padding(.bottom, 4.5)
            ForEach(LightningVisualKind.allCases, id: \.self) { kind in
                Toggle(LightningFilterBar.title(kind), isOn: binding(kind))
                    .toggleStyle(.checkbox)
                    .frame(height: 25)
            }
            Divider()
                .padding(.top, 4)
            Text(L("Matches any selected type."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 7.5)
            Button(L("Clear")) { kinds = [] }
                .padding(.top, 7.5)
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
    }

    private func binding(_ kind: LightningVisualKind) -> Binding<Bool> {
        Binding(get: { kinds.contains(kind) }, set: { on in
            if on { kinds.insert(kind) } else { kinds.remove(kind) }
        })
    }
}

/// Tags: a searchable list of Finder tags; any checked tag matches by its whole name.
struct LightningTagsPopover: View {
    @Binding var tags: [String]
    @ObservedObject private var catalog = FinderTagCatalog.shared
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Tags"))
                .font(.system(size: 13, weight: .semibold))
                .frame(height: 16)
                .padding(.bottom, 8)
            TextField(L("Find a Tag"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .padding(.bottom, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices, id: \.name) { choice in
                        Toggle(isOn: binding(choice.name)) {
                            HStack(spacing: 8) {
                                LightningTagDot(color: choice.color)
                                Text(choice.name).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .frame(height: 25)
                    }
                    if choices.isEmpty {
                        Text(L("No Tags Found"))
                            .foregroundStyle(.secondary)
                            .frame(height: 25)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(max(choices.count, 1)) * 25, 200))
            Text(L("Lists items carrying any checked tag; names have to match exactly."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 25)
            Button(L("Clear")) { tags = [] }
                .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 310, alignment: .leading)
    }

    private struct Choice {
        let name: String
        let color: NSColor?
    }

    /// Finder label numbers in Finder's order: red, orange, yellow, green, blue, purple, gray.
    private static let colorOrder = [6, 7, 5, 2, 4, 3, 1]

    /// Finder's tags (color tags in Finder's order, then the others) plus selected names that are not among
    /// them, filtered by the search text.
    private var choices: [Choice] {
        let ordered = catalog.tags.enumerated().sorted { lhs, rhs in
            let left = lhs.element.label.flatMap(Self.colorOrder.firstIndex(of:)) ?? Self.colorOrder.count + lhs.offset
            let right = rhs.element.label.flatMap(Self.colorOrder.firstIndex(of:)) ?? Self.colorOrder.count + rhs.offset
            return left < right
        }.map(\.element)
        var result = ordered.map { Choice(name: $0.name, color: Theme.finderTagColor($0.label ?? SidebarTagColors.label(for: $0.name))) }
        for tag in tags where !result.contains(where: { $0.name == tag }) {
            result.append(Choice(name: tag, color: Theme.finderTagColor(SidebarTagColors.label(for: tag))))
        }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(get: { tags.contains(name) }, set: { on in
            if on {
                if !tags.contains(name) { tags.append(name) }
            } else {
                tags.removeAll { $0 == name }
            }
        })
    }
}

/// A Finder tag's color dot; tags without a color get an empty ring.
struct LightningTagDot: View {
    let color: NSColor?

    var body: some View {
        if let color {
            Circle().fill(Color(nsColor: color)).frame(width: 10, height: 10)
        } else {
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
    }
}

/// Custom Date…: a modification-date range, both days included.
struct LightningCustomDatesPopover: View {
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Date Range")).font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text(L("From"))
                    DatePicker("", selection: dayBinding(\.customStart), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                GridRow {
                    Text(L("Through"))
                    DatePicker("", selection: dayBinding(\.customEnd), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }
        }
        .padding(16)
    }

    private func dayBinding(_ keyPath: WritableKeyPath<LightningVisualQuery, LightningVisualDay?>) -> Binding<Date> {
        Binding(get: { model.visual[keyPath: keyPath]?.date() ?? Date() },
                set: { model.visual[keyPath: keyPath] = LightningVisualDay($0) })
    }
}

// MARK: - Search Expression options

/// Search Expression mode: Match Case on the left, the expression help on the right.
struct LightningExpressionBar: View {
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.expressionMatchCase) {
                Text(L("Match Case")).font(.system(size: 10, weight: .medium))
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            Button(L("Search Expression")) {
                model.helpTab = .basics
                model.showsHelp = true
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Messages

/// Problems that stop or limit the search, in red under the filters: syntax errors, incomplete conditions,
/// unavailable folders.
struct LightningMessageLines: View {
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        let lines = messages
        if !lines.isEmpty || syntaxError != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let error = syntaxError {
                    LightningSyntaxErrorView(error: error, source: model.syntaxErrorSource)
                }
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, -2)
            .padding(.bottom, 8)
        }
    }

    private var syntaxError: LightningSyntaxError? {
        model.mode == .expression ? model.syntaxError : nil
    }

    private var messages: [String] {
        var lines: [String] = []
        if model.isSearchBlocked {
            var seen: [String] = []
            for issue in model.compiled.issues {
                let message = LightningStatusText.issueMessage(issue.kind)
                if !seen.contains(message) { seen.append(message) }
            }
            lines += seen.map { LF("Search Unavailable: %@", $0) }
        }
        if let message = model.scopeMessage { lines.append(message) }
        return lines
    }
}

/// The parser's message and the expression with the offending fragment highlighted.
struct LightningSyntaxErrorView: View {
    let error: LightningSyntaxError
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LightningStatusText.syntaxMessage(error))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var highlighted: AttributedString {
        var text = AttributedString(source)
        let count = source.count
        let start = error.offset
        guard start >= 0, start < count else { return text }
        let end = min(count, start + max(1, error.fragment.count))
        let lower = text.index(text.startIndex, offsetByCharacters: start)
        let upper = text.index(text.startIndex, offsetByCharacters: end)
        text[lower..<upper].foregroundColor = .red
        text[lower..<upper].backgroundColor = Color.red.opacity(0.18)
        text[lower..<upper].underlineStyle = .single
        return text
    }
}

struct LightningNoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.08))
    }
}

// MARK: - Results chrome

/// Centered over the results (header included): a prompt before the first search, progress, or no results.
struct LightningEmptyState: View {
    @ObservedObject var model: LightningSearchModel
    @ObservedObject var service: LightningSearchService

    var body: some View {
        if model.rows.isEmpty {
            VStack(spacing: 6) {
                content
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(24)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearchBlocked {
            EmptyView()
        } else if !model.hasQuery {
            Text(L("Type a keyword or set a filter to start searching.")).font(.system(size: 13)).foregroundStyle(.secondary)
        } else if model.isSearching {
            ProgressView().controlSize(.small)
            Text(L("Searching…")).font(.system(size: 13)).foregroundStyle(.secondary)
        } else if model.hasSearched, model.syntaxError == nil {
            if model.scope == .computer, !service.status.stage.isSearchable {
                if case .failed = service.status.stage {
                    Text(L("Search index unavailable")).font(.system(size: 13, weight: .semibold))
                    Text(L("Choose folders in Lightning Search settings.")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("Building Search Index…")).font(.system(size: 13, weight: .semibold))
                    Text(L("Matching items appear as soon as the index is ready."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(L("No Results")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Index state, refresh, the double-click hint, and the result count with the search time.
struct LightningStatusBar: View {
    @ObservedObject var model: LightningSearchModel
    @ObservedObject var service: LightningSearchService

    var body: some View {
        let indicator = LightningStatusText.indicator(service.status, isStarted: service.isStarted)
        HStack(spacing: 0) {
            Circle()
                .fill(color(indicator.tone))
                .frame(width: 7, height: 7)
                .padding(.trailing, 6)
            Text(indicator.text)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(LF("Indexed: %lld", Int64(service.status.indexedCount)))
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Results don't update by themselves while you look through them. Click to search again."))
            .accessibilityLabel(L("Refresh Search Results"))
            .accessibilityIdentifier("LightningSearch.RefreshResults")
            .padding(.leading, 5)
            if let notice = model.notice {
                Text(notice).foregroundStyle(.primary).lineLimit(1).padding(.leading, 4)
            } else {
                Text(L("Double-click to go to the file's location"))
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            if model.hasSearched, !model.isSearchBlocked, model.syntaxError == nil || model.mode == .visual {
                if model.isTruncated, model.rows.count < model.totalCount {
                    Text(LF("Showing the first %lld results.", Int64(model.rows.count))).padding(.trailing, 8)
                }
                Text(LF("%lld results · %lld ms", Int64(model.totalCount), Int64(model.elapsedMilliseconds)))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 12.5)
        .frame(height: 30)
    }

    private func color(_ tone: LightningStatusText.Tone) -> Color {
        switch tone {
        case .ready: Color(nsColor: .systemGreen)
        case .busy: Color(nsColor: .systemOrange)
        case .problem: Color(nsColor: .systemRed)
        case .idle: Color(nsColor: .tertiaryLabelColor)
        }
    }
}
