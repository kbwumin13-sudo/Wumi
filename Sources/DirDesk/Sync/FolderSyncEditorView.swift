import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Which task the editor sheet edits.
enum FolderSyncEditorRequest: Identifiable {
    case new
    case edit(FolderSyncPreset)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let preset): preset.id.uuidString
        }
    }
}

struct FolderSyncFilterDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: FolderSyncFilterKind = .exclude
    var target: FolderSyncFilterTarget = .fileName
    var pattern = ""

    init() {}

    init(_ rule: FolderSyncFilterRule) {
        kind = rule.kind
        target = rule.target
        pattern = rule.pattern
    }

    /// nil while the pattern is empty; the engine would ignore such a rule anyway.
    var rule: FolderSyncFilterRule? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : FolderSyncFilterRule(kind: kind, target: target, pattern: trimmed)
    }
}

/// Editable copy of a task. The folders are kept as typed until they are saved.
struct FolderSyncDraft: Equatable {
    enum Side {
        case left, right
    }

    struct FolderKey: Hashable {
        let left: String?
        let right: String?
        let direction: FolderSyncDirection
    }

    static let maximumTolerance: TimeInterval = 3_600

    var id: UUID
    var name: String
    var leftPath: String
    var rightPath: String
    var direction: FolderSyncDirection
    var includeHiddenItems: Bool
    var tolerance: Double
    var caseSensitive: Bool
    var filters: [FolderSyncFilterDraft]
    var schedule: FolderSyncSchedule
    var previewSyncDetails: Bool

    /// A new task starts like the original's: the right folder is updated, hidden items are compared, modification
    /// times must match exactly, letter case follows each disk, no schedule, and runs show a preview first.
    init() {
        id = UUID()
        name = ""
        leftPath = ""
        rightPath = ""
        direction = .updateRight
        includeHiddenItems = true
        tolerance = 0
        caseSensitive = false
        filters = []
        schedule = .off
        previewSyncDetails = true
    }

    init(_ preset: FolderSyncPreset) {
        id = preset.id
        name = preset.name
        leftPath = FolderSyncMessages.displayPath(preset.leftURL)
        rightPath = FolderSyncMessages.displayPath(preset.rightURL)
        direction = preset.direction
        includeHiddenItems = preset.includeHiddenItems
        tolerance = preset.modificationTimeTolerance
        caseSensitive = preset.caseSensitivity == .sensitive
        filters = preset.filters.map { FolderSyncFilterDraft($0) }
        schedule = preset.schedule
        previewSyncDetails = preset.previewSyncDetails
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var left: URL? { Self.folderURL(leftPath) }
    var right: URL? { Self.folderURL(rightPath) }

    func path(_ side: Side) -> String { side == .left ? leftPath : rightPath }
    func url(_ side: Side) -> URL? { side == .left ? left : right }

    /// An absolute path, or one starting with "~"; nil for anything else.
    static func folderURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// What folder validation depends on; the name is checked separately.
    var folderKey: FolderKey {
        FolderKey(left: left?.path, right: right?.path, direction: direction)
    }

    func makePreset(name: String) -> FolderSyncPreset? {
        guard let left, let right else { return nil }
        return FolderSyncPreset(id: id, name: name, leftURL: left, rightURL: right, direction: direction, includeHiddenItems: includeHiddenItems,
                                modificationTimeTolerance: min(max(tolerance, 0), Self.maximumTolerance),
                                caseSensitivity: caseSensitive ? .sensitive : .automatic,
                                filters: filters.compactMap(\.rule), schedule: schedule, previewSyncDetails: previewSyncDetails)
    }
}

/// What is wrong with the folders as entered: a problem with one folder (shown in its card; it may be temporary, such
/// as an unplugged disk) or with the pair (shown at the bottom; it keeps the task from being saved).
struct FolderSyncFolderCheck: Equatable, Sendable {
    var left: String?
    var right: String?
    var pair: String?

    static func run(left: URL?, right: URL?, direction: FolderSyncDirection) -> FolderSyncFolderCheck {
        var check = FolderSyncFolderCheck()
        guard let left, let right else {
            if let left { check.left = missingMessage(left) }
            if let right { check.right = missingMessage(right) }
            return check
        }
        do {
            try FolderSyncService.validate(FolderSyncPreset(name: "check", leftURL: left, rightURL: right, direction: direction))
        } catch let error as FolderSyncError {
            switch error {
            case .folderMissing(let url), .folderUnreadable(let url), .folderNotWritable(let url):
                let message = cardMessage(error)
                if url == left { check.left = message } else { check.right = message }
            default:
                check.pair = FolderSyncMessages.message(error)
            }
        } catch {
            check.pair = error.localizedDescription
        }
        return check
    }

    private static func missingMessage(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? nil : L("Folder not found.")
    }

    private static func cardMessage(_ error: FolderSyncError) -> String {
        switch error {
        case .folderUnreadable: L("Folder can't be read.")
        case .folderNotWritable: L("Folder isn't writable.")
        default: L("Folder not found.")
        }
    }
}

/// The original's "New Folder Sync Task" sheet: the name, the two folders side by side with the direction arrow,
/// which folder to update, the comparison options, the filters, automatic sync and the preview option, then
/// Cancel / Save / Sync Now.
struct FolderSyncEditorView: View {
    private struct Weekday: Identifiable {
        let number: Int
        let name: String
        var id: Int { number }
    }

    static let size = CGSize(width: 780, height: 760)

    let isNew: Bool
    /// Saves the task; `runNow` is true for Sync Now. The presenter closes the sheet once the save succeeds.
    let save: (_ preset: FolderSyncPreset, _ runNow: Bool) -> Void
    let cancel: () -> Void
    @ObservedObject private var store = FolderSyncStore.shared
    @State private var draft: FolderSyncDraft
    @State private var check = FolderSyncFolderCheck()
    @State private var message: String?
    /// After a save attempt, folders still missing are pointed out in red.
    @State private var attempted = false
    @State private var committing = false
    @State private var choosing: FolderSyncDraft.Side?

    init(request: FolderSyncEditorRequest, save: @escaping (_ preset: FolderSyncPreset, _ runNow: Bool) -> Void, cancel: @escaping () -> Void) {
        switch request {
        case .new:
            isNew = true
            _draft = State(initialValue: FolderSyncDraft())
        case .edit(let preset):
            isNew = false
            _draft = State(initialValue: FolderSyncDraft(preset))
        }
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? L("New Folder Sync Task") : L("Edit Folder Sync Task"))
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
                .padding(.top, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nameField
                    folders
                        .padding(.top, 19)
                    Divider()
                        .padding(.top, 21)
                    directionRow
                        .padding(.top, 19)
                    comparison
                        .padding(.top, 20)
                    filterList
                        .padding(.top, 19)
                    bottomRow
                        .padding(.top, 20)
                }
                .padding(.horizontal, 26)
                .padding(.top, 19)
                .padding(.bottom, 20)
            }
            Divider()
                .padding(.horizontal, 24)
            footer
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task(id: draft.folderKey) { await checkFolders() }
        .onChange(of: draft) { _, _ in message = nil }
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, let side = choosing { setFolder(url, side: side) }
            choosing = nil
        }
        .fileDialogMessage(Text(choosing == .right ? L("Right Folder") : L("Left Folder")))
        .fileDialogConfirmationLabel(Text(L("Choose")))
        .fileDialogDefaultDirectory(choosing.flatMap { draft.url($0)?.deletingLastPathComponent() })
    }

    // MARK: Name and folders

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Sync Task Name"))
                .font(.system(size: 12, weight: .bold))
            TextField(L("Sync Task Name"), text: $draft.name, prompt: Text(L("e.g. Documents Backup")))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityIdentifier("FolderSync.Editor.Name")
        }
    }

    private var folders: some View {
        HStack(alignment: .center, spacing: 14) {
            folderCard(.left)
            Image(systemName: FolderSyncMessages.directionSymbol(draft.direction))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
                .accessibilityLabel(FolderSyncMessages.direction(draft.direction))
            folderCard(.right)
        }
    }

    private func folderCard(_ side: FolderSyncDraft.Side) -> some View {
        let title = side == .left ? L("Left Folder") : L("Right Folder")
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
            HStack(spacing: 6) {
                TextField(title, text: side == .left ? $draft.leftPath : $draft.rightPath, prompt: Text(L("Folder Path")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(height: 26)
                    .truncationMode(.middle)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(side == .left ? "FolderSync.Editor.Left" : "FolderSync.Editor.Right")
                Menu {
                    Button(L("Choose Folder…")) { choosing = side }
                    Button(L("Reveal in Finder")) { reveal(side) }
                        .disabled(draft.url(side) == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityLabel(L("More"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Choose Folder"))
            }
            .padding(.top, 7)
            folderHint(side)
                .padding(.top, 8)
        }
        .padding(.horizontal, 13)
        .padding(.top, 15)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }

    /// "Choose a folder." until one is entered, then any problem with it. The line keeps its height either way.
    private func folderHint(_ side: FolderSyncDraft.Side) -> some View {
        let problem = side == .left ? check.left : check.right
        let missing = draft.url(side) == nil
        let text = missing ? L("Choose a folder.") : (problem ?? " ")
        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(missing ? (attempted ? Color.red : Color.secondary) : Color.orange)
            .lineLimit(1)
            .accessibilityHidden(!missing && problem == nil)
    }

    private func setFolder(_ url: URL, side: FolderSyncDraft.Side) {
        let path = FolderSyncMessages.displayPath(url.standardizedFileURL)
        switch side {
        case .left: draft.leftPath = path
        case .right: draft.rightPath = path
        }
        if draft.trimmedName.isEmpty { draft.name = url.lastPathComponent }
    }

    private func reveal(_ side: FolderSyncDraft.Side) {
        guard let url = draft.url(side) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Options

    private var directionRow: some View {
        HStack(spacing: 12) {
            Text(L("Which folder to update"))
                .font(.system(size: 13, weight: .bold))
            Spacer(minLength: 0)
            Picker(L("Which folder to update"), selection: $draft.direction) {
                ForEach(FolderSyncDirection.allCases, id: \.self) { direction in
                    Text(FolderSyncMessages.direction(direction)).tag(direction)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 160, alignment: .leading)
            .help(FolderSyncMessages.directionHelp(draft.direction))
        }
    }

    private var comparison: some View {
        FolderSyncEditorSection(L("Comparison")) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(L("Include Hidden Items"), isOn: $draft.includeHiddenItems)
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 14.5)
                Divider()
                HStack(spacing: 8) {
                    Text(L("Treat modification times up to"))
                    TextField(L("Allowed Modification Time Difference"), value: $draft.tolerance, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 66, height: 26)
                        .accessibilityLabel(L("Allowed Modification Time Difference"))
                    Text(L("seconds apart as the same."))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 13)
                Divider()
                VStack(alignment: .leading, spacing: 3.5) {
                    Toggle(L("Always match filename case"), isOn: $draft.caseSensitive)
                        .toggleStyle(.checkbox)
                    Text(L("When off, each disk decides whether names that differ only in letter case are the same item."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                .padding(.vertical, 15.5)
            }
            .padding(.horizontal, 15)
        }
    }

    private var filterList: some View {
        FolderSyncEditorSection(L("Filters")) {
            VStack(alignment: .leading, spacing: 0) {
                if draft.filters.isEmpty {
                    Text(L("All items are included."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 47)
                        .padding(.bottom, 2)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach($draft.filters) { $filter in
                            FolderSyncFilterRow(filter: $filter) { draft.filters.removeAll { $0.id == filter.id } }
                                .padding(.vertical, 9)
                            Divider()
                        }
                        Text(L("* matches any run of characters and ? matches one. Exclude rules win over include rules, and an excluded folder is skipped with everything in it."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 4)
                }
                HStack {
                    Spacer()
                    Button { draft.filters.append(FolderSyncFilterDraft()) } label: {
                        Image(systemName: "plus")
                            .frame(width: 20)
                    }
                    .help(L("Add Filter"))
                    .accessibilityLabel(L("Add"))
                    .accessibilityIdentifier("FolderSync.Editor.AddFilter")
                }
                .padding(.trailing, 5)
                .padding(.bottom, 5)
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Text(L("Automatic Sync"))
                .frame(minWidth: 75, alignment: .leading)
            Picker(L("Automatic Sync"), selection: $draft.schedule.frequency) {
                ForEach(FolderSyncScheduleFrequency.allCases, id: \.self) { frequency in
                    Text(FolderSyncMessages.frequency(frequency)).tag(frequency)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(scheduleHelp)
            if draft.schedule.frequency == .weekly {
                Picker(L("Weekday"), selection: $draft.schedule.weekday) {
                    ForEach(weekdays) { day in Text(day.name).tag(day.number) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if draft.schedule.frequency == .monthly {
                Picker(L("Day of Month"), selection: $draft.schedule.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in Text(LF("Day %lld", Int64(day))).tag(day) }
                }
                .labelsHidden()
                .fixedSize()
                .help(L("In months without this day, the task runs on the last day of the month."))
            }
            if draft.schedule.frequency != .off {
                DatePicker(L("Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    .help(scheduleHelp)
            }
            Spacer(minLength: 12)
            Toggle(L("Preview Sync Details"), isOn: $draft.previewSyncDetails)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("FolderSync.Editor.Preview")
        }
    }

    private var scheduleHelp: String {
        guard let next = draft.schedule.nextRunDate(after: Date()) else { return L("Automatic sync runs while Wumi is open.") }
        return LF("Next run: %@", FolderSyncMessages.dateText(next)) + "\n" + L("Automatic sync runs while Wumi is open.")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let text = footerMessage {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(text)
            }
            Spacer(minLength: 8)
            Button(L("Cancel"), action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(L("Save")) { commit(runNow: false) }
                .accessibilityIdentifier("FolderSync.Editor.Save")
            Button(L("Sync Now")) { commit(runNow: true) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("FolderSync.Editor.SyncNow")
        }
        .disabled(committing)
    }

    /// A save problem, the reason the last save attempt stopped, or a problem with the pair of folders.
    private var footerMessage: String? {
        store.saveError ?? message ?? check.pair
    }

    /// Checks everything a task needs before saving, folders off the main thread.
    private func commit(runNow: Bool) {
        attempted = true
        let name = draft.trimmedName
        guard !name.isEmpty else {
            message = L("Enter a name for this sync preset.")
            return
        }
        guard draft.left != nil, draft.right != nil else {
            message = L("Choose both folders.")
            return
        }
        guard !store.isNameTaken(name, excluding: draft.id) else {
            message = L("A sync preset with this name already exists.")
            return
        }
        message = nil
        committing = true
        let draft = self.draft
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderSyncFolderCheck.run(left: draft.left, right: draft.right, direction: draft.direction)
            }.value
            committing = false
            check = result
            guard result.pair == nil, let preset = draft.makePreset(name: name) else { return }
            save(preset, runNow)
        }
    }

    /// Validates the folders off the main thread, a moment after they change.
    private func checkFolders() async {
        let key = draft.folderKey
        guard key.left != nil || key.right != nil else {
            check = FolderSyncFolderCheck()
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let left = draft.left, right = draft.right, direction = draft.direction
        let result = await Task.detached(priority: .userInitiated) {
            FolderSyncFolderCheck.run(left: left, right: right, direction: direction)
        }.value
        if Task.isCancelled { return }
        check = result
    }

    // MARK: Schedule

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: min(max(draft.schedule.hour, 0), 23), minute: min(max(draft.schedule.minute, 0), 59),
                                  second: 0, of: Date()) ?? Date()
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.schedule.hour = components.hour ?? 9
            draft.schedule.minute = components.minute ?? 0
        })
    }

    /// Weekdays in the order of the user's calendar, named in the app's language.
    private var weekdays: [Weekday] {
        var calendar = Calendar.current
        calendar.locale = Localizer.shared.locale
        let symbols = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let number = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return Weekday(number: number, name: symbols[number - 1])
        }
    }
}

/// A small header above a rounded group of rows, like the editor's "Comparison" and "Filters".
private struct FolderSyncEditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 10)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
        }
    }
}

private struct FolderSyncFilterRow: View {
    @Binding var filter: FolderSyncFilterDraft
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker(L("Filters"), selection: $filter.kind) {
                Text(L("Include")).tag(FolderSyncFilterKind.include)
                Text(L("Exclude")).tag(FolderSyncFilterKind.exclude)
            }
            .labelsHidden()
            .fixedSize()
            Picker(L("Filters"), selection: $filter.target) {
                Text(L("File Name")).tag(FolderSyncFilterTarget.fileName)
                Text(L("File Extension")).tag(FolderSyncFilterTarget.fileExtension)
                Text(L("Relative Path")).tag(FolderSyncFilterTarget.relativePath)
            }
            .labelsHidden()
            .fixedSize()
            TextField("", text: $filter.pattern, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(L("Remove Filter"))
                .accessibilityLabel(L("Remove Filter"))
        }
    }

    private var placeholder: String {
        switch filter.target {
        case .fileName: "*.tmp"
        case .fileExtension: "log"
        case .relativePath: "build/*"
        }
    }
}
