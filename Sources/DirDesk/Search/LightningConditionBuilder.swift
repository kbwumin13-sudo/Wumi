import AppKit
import DirDeskCore
import SwiftUI

/// Advanced Search: a small panel attached to the top right of its search window. Closing the panel keeps the
/// conditions; closing the search window discards them.
@MainActor
final class LightningAdvancedPanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 490, height: 384)

    private let model: LightningSearchModel
    private weak var parent: NSWindow?
    private(set) var panel: NSPanel?
    /// Called when the panel stops being the key window.
    var onResignKey: (() -> Void)?

    init(model: LightningSearchModel, parent: NSWindow) {
        self.model = model
        self.parent = parent
    }

    func show() {
        guard let parent else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            // Top right of the search window, below its title bar.
            let frame = parent.frame
            panel.setFrame(NSRect(x: frame.maxX - 12 - Self.size.width, y: frame.maxY - 60 - Self.size.height,
                                  width: Self.size.width, height: Self.size.height), display: false)
        }
        panel.level = parent.level
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel?.delegate = nil
        panel = nil
    }

    func updateLevel() {
        if let panel, let parent { panel.level = parent.level }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L("Advanced Search")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = false
        panel.minSize = NSSize(width: 460, height: 300)
        panel.identifier = NSUserInterfaceItemIdentifier("DirDesk.LightningSearch.Advanced")
        panel.contentView = NSHostingView(rootView: LightningAdvancedView(model: model))
        panel.delegate = self
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        if let panel { parent?.removeChildWindow(panel) }
        if model.showsAdvanced { model.showsAdvanced = false }
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}

/// Content of the Advanced Search panel.
struct LightningAdvancedView: View {
    @ObservedObject var model: LightningSearchModel
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Advanced Search"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 16)
            Text(L("Combined with the filters above."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            ScrollView(.vertical) {
                LightningGroupView(group: model.visual.conditions, level: 1, model: model)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            Divider()
            Toggle(L("Match Case"), isOn: $model.visual.matchCase)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("LightningSearch.MatchCase")
                .padding(.top, 12)
            Text(L("The search updates as you edit. Hiding this panel keeps the conditions until you close the window."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity, alignment: .topLeading)
        .id(app.language)
    }
}

/// One condition group: how its conditions combine, Exclude Group, its conditions and nested groups, and
/// the buttons that add to it.
struct LightningGroupView: View {
    let group: LightningConditionGroup
    let level: Int
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker(L("Condition Matching"), selection: matchBinding) {
                    Text(L("Match All Conditions")).tag(true)
                    Text(L("Match Any Condition")).tag(false)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L("Condition Matching"))
                Toggle(L("Exclude Group"), isOn: excludeBinding)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                if level > 1 {
                    Button {
                        model.removeItem(group.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help(L("Remove Group"))
                    .accessibilityLabel(L("Remove Group"))
                }
            }
            .frame(height: 24)
            ForEach(group.items) { item in
                switch item {
                case let .condition(condition):
                    LightningConditionRow(condition: condition, model: model)
                        .padding(.top, 10)
                    Divider()
                        .padding(.top, 10)
                case let .group(nested):
                    AnyView(LightningGroupView(group: nested, level: level + 1, model: model))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(nested.isExcluded ? Color.red.opacity(0.45) : Color.primary.opacity(0.1)))
                        .padding(.top, 9)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.addCondition(to: group.id)
                } label: {
                    Label(L("Add Condition"), systemImage: "plus")
                }
                .disabled(!model.visual.conditions.canAddCondition())
                Button {
                    model.addGroup(to: group.id)
                } label: {
                    Label(L("Add Group"), systemImage: "plus.square.on.square")
                }
                .disabled(!model.visual.conditions.canAddGroup(to: group.id))
            }
            .padding(.top, group.items.isEmpty ? 10.5 : 11)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Condition Group"))
    }

    private var matchBinding: Binding<Bool> {
        Binding(get: { group.matchesAll }, set: { value in model.updateGroup(group.id) { $0.matchesAll = value } })
    }

    private var excludeBinding: Binding<Bool> {
        Binding(get: { group.isExcluded }, set: { value in model.updateGroup(group.id) { $0.isExcluded = value } })
    }
}

/// One condition: Enabled, field, comparison, Exclude and Remove on the first line, the value below, then any problem.
struct LightningConditionRow: View {
    let condition: LightningCondition
    @ObservedObject var model: LightningSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Toggle(L("Enable"), isOn: binding(\.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(L("Enable"))
                Picker(L("Condition"), selection: fieldBinding) {
                    ForEach(LightningConditionField.allCases, id: \.self) { field in
                        Text(Self.title(field)).tag(field)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L("Condition"))
                Picker(L("Comparison"), selection: binding(\.comparison)) {
                    ForEach(condition.field.comparisons, id: \.self) { comparison in
                        Text(Self.title(comparison, field: condition.field)).tag(comparison)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L("Comparison"))
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Toggle(L("Exclude"), isOn: binding(\.isExcluded))
                        .toggleStyle(.checkbox)
                    Button {
                        model.removeItem(condition.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: 15)
                    }
                    .help(L("Remove Condition"))
                    .accessibilityLabel(L("Remove Condition"))
                }
            }
            .frame(height: 24)
            valueEditor
                .padding(.top, 6)
                .disabled(!condition.isEnabled)
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .padding(.top, 6)
            }
        }
    }

    private var message: String? {
        guard condition.isEnabled,
              let issue = model.compiled.issues.first(where: { $0.conditionID == condition.id }) else { return nil }
        return LightningStatusText.issueMessage(issue.kind)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch condition.field.valueKind {
        case .text:
            TextField(Self.placeholder(condition.field), text: binding(\.value))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: condition.field == .regex ? .monospaced : .default))
                .accessibilityLabel(L("Condition Value"))
        case .extensions:
            TextField("jpg;png", text: binding(\.value))
                .textFieldStyle(.roundedBorder)
                .help(L("Separate extensions with semicolons; an item matches any of them."))
                .accessibilityLabel(L("Condition Value"))
        case .size:
            HStack(spacing: 6) {
                TextField("0", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .accessibilityLabel(L("Condition Value"))
                if condition.comparison == .between {
                    Text(L("and")).font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("0", text: binding(\.secondValue))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel(L("Range End"))
                }
                Picker(L("Size Unit"), selection: binding(\.unit)) {
                    ForEach(LightningVisualSizeUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L("Size Unit"))
                Spacer(minLength: 0)
            }
        case .date:
            HStack(spacing: 6) {
                DatePicker(L("Condition Value"), selection: dayBinding(\.day), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                if condition.comparison == .between {
                    Text(L("and")).font(.system(size: 12)).foregroundStyle(.secondary)
                    DatePicker(L("Range End"), selection: dayBinding(\.secondDay), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
        case .folder:
            HStack(spacing: 6) {
                TextField("~/Documents", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("Folder Location"))
                Button(L("Choose…")) { chooseFolder() }
            }
        }
    }

    static func title(_ field: LightningConditionField) -> String {
        switch field {
        case .name: L("Name")
        case .contents: L("File Contents")
        case .size: L("Size")
        case .created: L("Created")
        case .modified: L("Modified")
        case .extension: L("Extension")
        case .folder: L("Folder Location")
        case .tag: L("Finder Tags")
        case .regex: L("Regular Expression")
        }
    }

    static func title(_ comparison: LightningConditionComparison, field: LightningConditionField) -> String {
        let isDate = field.valueKind == .date
        switch comparison {
        case .contains: return L("Contains")
        case .equals: return L("Equals")
        case .starts: return L("Starts With")
        case .ends: return L("Ends With")
        case .greater: return isDate ? L("After") : L("Greater Than")
        case .less: return isDate ? L("Before") : L("Less Than")
        case .atLeast: return isDate ? L("On or After") : L("At Least")
        case .atMost: return isDate ? L("On or Before") : L("At Most")
        case .between: return L("Between")
        case .descendants: return L("Include Subfolders")
        case .children: return L("Direct Children Only")
        case .directFiles: return L("Folder and Direct Files")
        }
    }

    static func placeholder(_ field: LightningConditionField) -> String {
        switch field {
        case .contents: L("Text in the file")
        case .tag: L("Tag Name")
        case .regex: "^IMG_\\d+"
        default: L("Search Text")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LightningCondition, Value>) -> Binding<Value> {
        let id = condition.id
        let fallback = condition[keyPath: keyPath]
        return Binding(get: { model.visual.conditions.condition(id: id)?[keyPath: keyPath] ?? fallback },
                       set: { value in model.updateCondition(id) { $0[keyPath: keyPath] = value } })
    }

    private var fieldBinding: Binding<LightningConditionField> {
        let id = condition.id
        return Binding(get: { model.visual.conditions.condition(id: id)?.field ?? condition.field }, set: { field in
            let today = model.today
            model.updateCondition(id) { $0.setField(field, today: today) }
        })
    }

    private func dayBinding(_ keyPath: WritableKeyPath<LightningCondition, LightningVisualDay?>) -> Binding<Date> {
        let id = condition.id
        return Binding(get: { (model.visual.conditions.condition(id: id)?[keyPath: keyPath] ?? model.today).date() ?? Date() },
                       set: { date in model.updateCondition(id) { $0[keyPath: keyPath] = LightningVisualDay(date) } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        let id = condition.id
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                model.updateCondition(id) { $0.value = LightningSearchModel.displayPath(url.path) }
            }
        }
        if let window = model.window {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }
}
