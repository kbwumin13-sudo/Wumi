import AppKit
import DirDeskCore
import SwiftUI

/// State of one Batch Rename sheet: the rule chain and the latest plan for its items.
@MainActor
final class BatchRenameSession: ObservableObject {
    struct Row: Identifiable, Equatable {
        /// Position in the selection, which is also the index into `items`.
        let id: Int
        let original: String
        let folder: String
        var newName: String
        var error: BatchRenamePreviewError?
        var isUnchanged: Bool
    }

    struct Counts: Equatable {
        var renamed = 0
        var unchanged = 0
        var problems = 0
    }

    struct Status: Equatable {
        let text: String
        let isProblem: Bool
    }

    let items: [FileItem]
    let sources: [URL]
    let limits = BatchRenameLimits.default
    weak var controller: WorkspaceController?

    @Published var rules: [BatchRenameRuleDraft] {
        didSet {
            guard rules != oldValue else { return }
            renameError = nil
            renameWhenPlanned = nil
            if rules.isEmpty {
                status = nil
            } else if let ruleStatus {
                status = ruleStatus
            }
            schedulePlan()
        }
    }
    @Published private(set) var rows: [Row]
    @Published private(set) var counts = Counts()
    @Published private(set) var isPlanning = false
    @Published private(set) var planError: String?
    @Published private(set) var isRenaming = false
    @Published private(set) var renameError: String?
    /// The note under the rule chain. It changes when the rules change in a way that needs no plan (an empty rule),
    /// otherwise when the next plan arrives, so it does not flicker while a name is being typed.
    @Published private(set) var status: Status?

    private var previews: [BatchRenamePreview] = []
    /// The rules `previews` was planned with; renaming waits until it matches the current rules.
    private var plannedRules: [BatchRenameRule]?
    private var planTask: Task<Void, Never>?
    private var generation = 0
    /// Rename was chosen while the plan for the current rules was still being made.
    private var renameWhenPlanned: (() -> Void)?

    init(items: [FileItem], controller: WorkspaceController?) {
        self.items = items
        sources = items.map(\.url)
        self.controller = controller
        rules = []
        rows = Self.unchangedRows(for: items.map(\.url))
        schedulePlan(immediately: true)
    }

    var activeRules: [BatchRenameRule] { rules.compactMap(\.rule) }

    /// Every rule is filled in and valid.
    var rulesAreComplete: Bool { !rules.isEmpty && rules.allSatisfy { $0.rule != nil } }

    private var planIsCurrent: Bool { !isPlanning && plannedRules == activeRules }

    /// Uses the latest plan; a click that comes before the plan for the current rules is held until it arrives.
    var canRename: Bool {
        !isRenaming && renameWhenPlanned == nil && !sources.isEmpty && rulesAreComplete && planError == nil
            && counts.problems == 0 && counts.renamed > 0
    }

    /// Problems that can be told from the rules alone.
    private var ruleStatus: Status? {
        if sources.isEmpty { return Status(text: L("Select at least one item."), isProblem: true) }
        if rules.contains(where: \.hasInvalidPattern) { return Status(text: L("Invalid regular expression."), isProblem: true) }
        if rules.contains(where: { $0.rule == nil }) { return Status(text: L("Some rules are still empty."), isProblem: true) }
        return nil
    }

    private var planStatus: Status? {
        if let planError { return Status(text: planError, isProblem: true) }
        if counts.problems == 1 { return Status(text: L("Fix the name marked in red before renaming."), isProblem: true) }
        if counts.problems > 1 {
            return Status(text: LF("Fix the %lld names marked in red before renaming.", Int64(counts.problems)), isProblem: true)
        }
        if counts.renamed == 0 { return Status(text: L("These rules do not change any names."), isProblem: false) }
        return nil
    }

    // MARK: Editing

    func addRule(_ kind: BatchRenameRuleDraft.Kind) {
        rules.append(BatchRenameRuleDraft(kind: kind))
    }

    /// The rule bar's Prefix and Suffix button: one prefix rule followed by one suffix rule.
    func addPrefixAndSuffix() {
        rules.append(contentsOf: [BatchRenameRuleDraft(kind: .prefix), BatchRenameRuleDraft(kind: .suffix)])
    }

    func moveRule(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }

    func removeRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func apply(_ preset: BatchRenamePreset) {
        rules = preset.rules.map(BatchRenameRuleDraft.init(rule:))
    }

    // MARK: Planning

    /// Plans off the main thread (planning checks every name on disk), a moment after the last edit.
    /// Incomplete rules are left out, so the preview follows the rules that are filled in.
    func schedulePlan(immediately: Bool = false) {
        planTask?.cancel()
        generation += 1
        let generation = generation
        let rules = activeRules
        let sources = sources
        let limits = limits
        isPlanning = true
        let delay: Duration = immediately ? .zero : .milliseconds(sources.count > 1_000 ? 300 : 120)
        planTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BatchRenameService.plan(sources: sources, rules: rules, limits: limits) }
            }.value
            guard !Task.isCancelled, generation == self.generation else { return }
            self.apply(result, rules: rules)
        }
    }

    private func apply(_ result: Result<[BatchRenamePreview], Error>, rules: [BatchRenameRule]) {
        isPlanning = false
        plannedRules = rules
        switch result {
        case .success(let previews):
            self.previews = previews
            planError = nil
            var counts = Counts()
            rows = previews.enumerated().map { index, preview in
                if preview.error != nil {
                    counts.problems += 1
                } else if preview.isUnchanged {
                    counts.unchanged += 1
                } else {
                    counts.renamed += 1
                }
                return Row(id: index, original: preview.source.lastPathComponent, folder: preview.source.deletingLastPathComponent().path,
                           newName: preview.destinationName, error: preview.error, isUnchanged: preview.isUnchanged)
            }
            self.counts = counts
        case .failure(let error):
            previews = []
            planError = BatchRenameMessages.message(error)
            counts = Counts()
            rows = Self.unchangedRows(for: sources)
        }
        status = self.rules.isEmpty ? nil : (ruleStatus ?? planStatus)
        if let pending = renameWhenPlanned, planIsCurrent {
            renameWhenPlanned = nil
            if canRename { commit(onSuccess: pending) }
        }
    }

    private static func unchangedRows(for urls: [URL]) -> [Row] {
        urls.enumerated().map { index, url in
            Row(id: index, original: url.lastPathComponent, folder: url.deletingLastPathComponent().path, newName: url.lastPathComponent,
                error: nil, isUnchanged: true)
        }
    }

    // MARK: Renaming

    func rename(onSuccess: @escaping () -> Void) {
        guard canRename else { return }
        guard planIsCurrent else {
            renameWhenPlanned = onSuccess
            schedulePlan(immediately: true)
            return
        }
        commit(onSuccess: onSuccess)
    }

    private func commit(onSuccess: @escaping () -> Void) {
        isRenaming = true
        renameError = nil
        let previews = previews
        Task {
            let result = await BatchRenameStore.shared.commit(previews, limits: limits, controller: controller)
            isRenaming = false
            switch result {
            case .success:
                onSuccess()
            case .failure(let error):
                renameError = BatchRenameMessages.message(error)
                // Names on disk may differ from what the plan saw.
                schedulePlan(immediately: true)
            }
        }
    }
}

/// Batch Rename sheet: header, presets and history, the rule bar, the rule chain applied top to bottom, and a live
/// preview of every new name.
struct BatchRenameView: View {
    @StateObject private var session: BatchRenameSession
    @ObservedObject private var store = BatchRenameStore.shared
    @ObservedObject private var app = AppModel.shared
    @State private var presetName = ""
    @State private var showsHistory = false
    @State private var showsPlanningIndicator = false
    private let close: () -> Void

    /// Height of the rule chain's scrolling list; the chain keeps this height whatever the number of rules.
    private static let ruleListHeight: CGFloat = 146.5
    private static let previewRowHeight: CGFloat = 46
    /// The preview shows four rows at a time.
    private static let previewHeight: CGFloat = 184
    private static let horizontalPadding: CGFloat = 28

    init(items: [FileItem], controller: WorkspaceController?, close: @escaping () -> Void) {
        _session = StateObject(wrappedValue: BatchRenameSession(items: items, controller: controller))
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toolRow
                    ruleBar
                    VStack(alignment: .leading, spacing: 11) {
                        ruleChain
                        if let status = displayedStatus {
                            statusLine(status)
                                .padding(.bottom, 1)
                        }
                        preview
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 20)
            }
            Divider()
            footer
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque, like the original sheet; without it AppKit shows the translucent sheet material.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.headerSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Batch Rename"))
                    .font(.system(size: 20, weight: .bold))
                Text(L("Check every new name here before any file is renamed."))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Text(itemCount)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(BatchRenameStyle.subtleFill))
        }
    }

    private var itemCount: String {
        let count = Int64(session.sources.count)
        return count == 1 ? LF("%lld item", count) : LF("%lld items", count)
    }

    /// The text-format symbol has script-specific variants; pick the one for the app language rather than the system's.
    private static var headerSymbol: String {
        let code = Localizer.shared.code
        let script = String(code.prefix { $0 != "-" })
        let localized = "textformat." + script
        guard code != "en", NSImage(systemSymbolName: localized, accessibilityDescription: nil) != nil else { return "textformat" }
        return localized
    }

    // MARK: Presets and history

    private var trimmedPresetName: String { presetName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSavePreset: Bool { !trimmedPresetName.isEmpty && session.rulesAreComplete && !session.isRenaming }

    private var toolRow: some View {
        HStack(spacing: 10) {
            presetsMenu
            TextField(L("Preset Name"), text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(savePreset)
                .accessibilityIdentifier("BatchRename.PresetName")
            Button(L("Save Preset"), action: savePreset)
                .disabled(!canSavePreset)
                .help(store.preset(named: presetName) != nil ? L("The preset with this name will be updated.") : L("Save Preset"))
            Spacer(minLength: 8)
            Button { showsHistory.toggle() } label: { Label(L("History"), systemImage: "clock.arrow.circlepath") }
                .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                    BatchRenameHistoryPopover(store: store, controller: session.controller)
                }
                .help(L("Recent Batch Renames"))
                .accessibilityIdentifier("BatchRename.History")
        }
        .disabled(session.isRenaming)
    }

    private var presetsMenu: some View {
        Menu {
            if store.presets.isEmpty {
                Text(L("No saved presets"))
            } else {
                Section(L("Apply Preset")) {
                    ForEach(store.presets) { preset in
                        Button(preset.name) { session.apply(preset) }
                            .help(BatchRenameRuleDraft.summary(of: preset.rules, separator: "\n"))
                    }
                }
                Menu(L("Delete Preset")) {
                    ForEach(store.presets) { preset in
                        Button(preset.name, role: .destructive) { store.deletePreset(preset.id) }
                    }
                }
            }
        } label: {
            Label(L("Presets"), systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .accessibilityIdentifier("BatchRename.Presets")
    }

    private func savePreset() {
        guard canSavePreset else { return }
        store.savePreset(named: trimmedPresetName, rules: session.activeRules)
        presetName = ""
    }

    // MARK: Rule bar

    private enum RuleButton: Identifiable {
        case kind(BatchRenameRuleDraft.Kind)
        case prefixAndSuffix

        static let all: [RuleButton] = BatchRenameRuleDraft.Kind.allCases.map(RuleButton.kind) + [.prefixAndSuffix]

        var id: String { identifier }

        var title: String {
            switch self {
            case .kind(let kind): kind.title
            case .prefixAndSuffix: L("Prefix and Suffix")
            }
        }

        var identifier: String {
            switch self {
            case .kind(let kind): kind.modeIdentifier
            case .prefixAndSuffix: "prefixSuffix"
            }
        }
    }

    private var ruleBar: some View {
        // 39 pt buttons, 7.5 pt apart across and 7 pt down, as measured on the original's sheet.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7.5), count: 4), spacing: 7) {
            ForEach(RuleButton.all) { button in
                Button {
                    switch button {
                    case .kind(let kind): session.addRule(kind)
                    case .prefixAndSuffix: session.addPrefixAndSuffix()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text(button.title).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 39)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BatchRenameOutlinedButtonStyle())
                .accessibilityIdentifier("BatchRename.Mode." + button.identifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BatchRename.AddRule")
        .disabled(session.isRenaming)
    }

    // MARK: Rule chain

    private var ruleChain: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(L("Rules"), symbol: "list.number")
            if session.rules.isEmpty {
                Text(L("Pick rules above; each one works on the result of the previous one."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 91)
                    .padding(.top, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach($session.rules) { $rule in
                                let index = session.rules.firstIndex { $0.id == rule.id } ?? 0
                                BatchRenameRuleCard(rule: $rule, index: index, count: session.rules.count,
                                                    move: { offset in session.moveRule(rule.id, by: offset) },
                                                    remove: { session.removeRule(rule.id) })
                                    .id(rule.id)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: Self.ruleListHeight)
                    .onChange(of: session.rules.count) { oldCount, newCount in
                        // Show a rule that was just added; the rule bar appends at the end.
                        guard newCount > oldCount, let last = session.rules.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .background(Self.sectionBackground)
        .disabled(session.isRenaming)
    }

    private var displayedStatus: BatchRenameSession.Status? {
        if let error = session.renameError { return .init(text: error, isProblem: true) }
        if let status = session.status { return status }
        if let error = store.lastError { return .init(text: error, isProblem: true) }
        return nil
    }

    private func statusLine(_ status: BatchRenameSession.Status) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: status.isProblem ? "exclamationmark.circle.fill" : "info.circle.fill")
            Text(status.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .foregroundStyle(status.isProblem ? Color.red : Color.secondary)
        .help(status.text)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle(L("Live Preview"), symbol: "eye")
                Spacer(minLength: 8)
                if showsPlanningIndicator {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 17.5)
            // Only slow plans (large selections, network volumes) show progress; typing would make it flicker.
            .task(id: session.isPlanning) {
                guard session.isPlanning else {
                    showsPlanningIndicator = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { showsPlanningIndicator = session.isPlanning }
            }
            VStack(spacing: 0) {
                BatchRenamePreviewColumns {
                    Text(L("Name"))
                } newName: {
                    Text(L("Rename To"))
                } marker: {
                    EmptyView()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 31)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.rows) { row in
                            BatchRenamePreviewRow(row: row, icon: icon(for: row))
                                .frame(height: Self.previewRowHeight)
                                .background(row.id.isMultiple(of: 2) ? BatchRenameStyle.subtleFill : Color.clear)
                        }
                    }
                }
                .frame(height: Self.previewHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(Self.sectionBackground)
    }

    private func icon(for row: BatchRenameSession.Row) -> NSImage {
        session.items.indices.contains(row.id) ? FileIcons.shared.icon(for: session.items[row.id]) : NSWorkspace.shared.icon(for: .data)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if session.isRenaming {
                ProgressView().controlSize(.small)
                Text(L("Renaming…")).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("Cancel"), action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(session.isRenaming)
            Button(L("Rename")) { session.rename(onSuccess: close) }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canRename)
                .accessibilityIdentifier("BatchRename.Commit")
        }
    }

    // MARK: Shared pieces

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.headline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private static var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BatchRenameStyle.outline)
    }
}

/// Colors shared by the sheet's sections, rule cards and buttons.
private enum BatchRenameStyle {
    /// Hairline around sections, rule cards and rule bar buttons.
    static let outline = Color.primary.opacity(0.08)
    /// Badges, small buttons, the item count and every other preview row.
    static let subtleFill = Color.primary.opacity(0.058)
}

/// Lays out the preview's two name columns at equal widths, with a narrow marker column at the end.
private struct BatchRenamePreviewColumns<Original: View, NewName: View, Marker: View>: View {
    @ViewBuilder let original: Original
    @ViewBuilder let newName: NewName
    @ViewBuilder let marker: Marker

    var body: some View {
        HStack(spacing: 0) {
            // A zero minimum makes both columns equally flexible, so they always split the width evenly.
            original
                .padding(.trailing, 12)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            newName
                .padding(.trailing, 8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            // Always present, even with nothing to show, so every row keeps the same columns.
            Color.clear
                .frame(width: 18)
                .overlay { marker }
        }
        .padding(.horizontal, 12)
    }
}

/// One preview row: icon and current name, then the new name. A changed name is set in a heavier weight with a check
/// mark; a name that cannot be used is red, with the reason under it.
private struct BatchRenamePreviewRow: View {
    let row: BatchRenameSession.Row
    let icon: NSImage

    var body: some View {
        BatchRenamePreviewColumns {
            HStack(spacing: 9) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(row.original)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.folder)
            }
        } newName: {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.newName)
                    .fontWeight(row.isUnchanged ? .regular : .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.newName)
                if let error = row.error {
                    Text(BatchRenameMessages.preview(error))
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(row.error == nil ? Color.primary : Color.red)
        } marker: {
            if let error = row.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(BatchRenameMessages.preview(error))
            } else if !row.isUnchanged {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.original)
        .accessibilityIdentifier("BatchRename.PreviewRow.\(row.id)")
    }
}

/// The rule bar's buttons: an outlined, unfilled rounded rectangle.
private struct BatchRenameOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BatchRenameStyle.outline))
    }
}

/// The square move and remove buttons of a rule.
private struct BatchRenameSquareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed ? Color.primary.opacity(0.14) : BatchRenameStyle.subtleFill))
            .contentShape(Rectangle())
    }
}

/// One rule of the chain: its number, kind and parameters, and buttons to move or remove it.
private struct BatchRenameRuleCard: View {
    @Binding var rule: BatchRenameRuleDraft
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(index + 1)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(BatchRenameStyle.subtleFill))
            VStack(alignment: .leading, spacing: 6) {
                Text(rule.kind.title)
                    .font(.system(size: 12, weight: .semibold))
                parameters
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .help(L("Move Up"))
                    .accessibilityLabel(L("Move Up"))
                    .accessibilityIdentifier("BatchRename.Rule.\(index).MoveUp")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == count - 1)
                    .help(L("Move Down"))
                    .accessibilityLabel(L("Move Down"))
                    .accessibilityIdentifier("BatchRename.Rule.\(index).MoveDown")
                Button(action: remove) { Image(systemName: "trash") }
                    .help(L("Remove Rule"))
                    .accessibilityLabel(L("Remove Rule"))
                    .accessibilityIdentifier("BatchRename.Rule.\(index).Remove")
            }
            .buttonStyle(BatchRenameSquareButtonStyle())
            .padding(.leading, 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12.5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(rule.hasInvalidPattern ? Color.red.opacity(0.6) : BatchRenameStyle.outline))
    }

    @ViewBuilder private var parameters: some View {
        switch rule.kind {
        case .prefix:
            field($rule.text, title: L("Prefix"), identifier: "BatchRename.Prefix")
        case .suffix:
            field($rule.text, title: L("Suffix"), identifier: "BatchRename.Suffix")
        case .replace:
            HStack(spacing: 8) {
                field($rule.text, title: L("Find"), identifier: "BatchRename.Find")
                arrow
                field($rule.replacement, title: L("Replace With"), identifier: "BatchRename.ReplaceWith")
            }
        case .regularExpression:
            HStack(spacing: 8) {
                field($rule.text, title: L("Pattern"), identifier: "BatchRename.Pattern")
                arrow
                field($rule.replacement, title: L("Replacement (use $1 for group 1)"), identifier: "BatchRename.Template")
                if rule.hasInvalidPattern {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(L("Invalid regular expression."))
                }
            }
        case .fileExtension:
            HStack(spacing: 10) {
                field($rule.text, title: L("New extension"), identifier: "BatchRename.Extension")
                    .frame(maxWidth: 200)
                Text(L("Leave empty to remove the extension."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .lowercase, .uppercase:
            Text(L("The extension is left as it is."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .sequence:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sequenceControls }
                VStack(alignment: .leading, spacing: 8) { sequenceControls }
            }
        }
    }

    @ViewBuilder private var sequenceControls: some View {
        HStack(spacing: 8) {
            Text(L("Position"))
            Picker(L("Position"), selection: $rule.placement) {
                Text(L("Beginning")).tag(BatchRenameRuleDraft.Placement.beginning)
                Text(L("End")).tag(BatchRenameRuleDraft.Placement.end)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("BatchRename.SequencePosition")
        }
        Stepper(LF("Start: %lld", Int64(rule.start)), value: $rule.start, in: 0...BatchRenameRuleDraft.maximumStart)
            .fixedSize()
        Stepper(LF("Digits: %lld", Int64(rule.digits)), value: $rule.digits, in: 1...BatchRenameRuleDraft.maximumDigits)
            .fixedSize()
        TextField(L("Separator"), text: $rule.separator)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .frame(width: 80)
            .help(L("Separator"))
            .accessibilityIdentifier("BatchRename.Separator")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private func field(_ text: Binding<String>, title: String, identifier: String) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
    }
}

/// "Recent Batch Renames": the last batches, with Undo for the ones that can still be put back.
private struct BatchRenameHistoryPopover: View {
    @ObservedObject var store: BatchRenameStore
    let controller: WorkspaceController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Recent Batch Renames")).font(.system(size: 13, weight: .semibold))
            if store.log.isEmpty {
                Text(L("No batch rename history"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.log.reversed()) { entry in row(entry) }
                    }
                }
                .frame(height: min(CGFloat(store.log.count) * 62, 310))
            }
            if let error = store.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 380)
        .onAppear { store.refreshRevertibility() }
    }

    private func row(_ entry: BatchRenameLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.outcome == .committed ? "pencil.line" : "arrow.uturn.backward")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(entry)).font(.system(size: 12, weight: .medium))
                Text(sample(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Self.relativeDate(entry.date)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if store.isUndoAvailable(entry) {
                Button(L("Undo")) { store.undo(entry, controller: controller) }
                    .controlSize(.small)
                    .disabled(store.isBusy)
            }
        }
    }

    private func title(_ entry: BatchRenameLogEntry) -> String {
        let count = Int64(entry.operations.count)
        switch entry.outcome {
        case .committed: return count == 1 ? L("Renamed 1 item") : LF("Renamed %lld items", count)
        case .undone: return count == 1 ? L("Undid the rename of 1 item") : LF("Undid the rename of %lld items", count)
        }
    }

    private func sample(_ entry: BatchRenameLogEntry) -> String {
        let shown = entry.operations.prefix(2).map { "\($0.source.lastPathComponent) → \($0.destination.lastPathComponent)" }
        let rest = entry.operations.count - shown.count
        let text = shown.joined(separator: ", ")
        return rest > 0 ? text + " " + LF("and %lld more", Int64(rest)) : text
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
