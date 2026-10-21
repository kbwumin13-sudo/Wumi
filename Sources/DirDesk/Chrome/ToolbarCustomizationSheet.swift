import AppKit
import DirDeskCore
import SwiftUI

/// "Customize Tool Order and Visibility" sheet, opened from the toolbar's More menu as in the original: labels and
/// colored-icon checkboxes, the shown tools in order (up, down, move to More) and the tools in More (add to the
/// toolbar), then Restore Toolbar Defaults / Done. Layout, inspector, search and folders-first are not listed;
/// they have fixed places.
struct ToolbarCustomizationSheet: View {
    @ObservedObject var app = AppModel.shared
    let done: () -> Void

    static let fixedCommands: Set<ToolbarCommand> = [.paneLayout, .search, .inspector, .foldersFirst]

    // Metrics follow the original's 660 × 500 pt sheet (runtime capture `toolbar-customization`): 18 pt bold title,
    // two 308 × 313 pt columns 12 pt apart, 32 pt cards 4 pt apart on the left, 34 pt rows on the right.
    var body: some View {
        let shown = app.configuration.toolbarCommands.filter { !Self.fixedCommands.contains($0) }
        let more = ToolbarCommand.allCases.filter { !shown.contains($0) && !Self.fixedCommands.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Customize Tool Order and Visibility")).font(.system(size: 18, weight: .bold))
            Text(L("Use the arrows to reorder toolbar actions, or move actions between the toolbar and the More menu."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 16) {
                Toggle(L("Show names with toolbar icons"), isOn: preference(\.showsToolbarLabels))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("ToolbarCustomization.ShowLabels")
                Toggle(L("Colored Toolbar Icons"), isOn: preference(\.usesColoredToolbarIcons))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("ToolbarCustomization.ColoredIcons")
            }
            .padding(.top, 11.5)
            HStack(alignment: .top, spacing: 12) {
                column(L("Shown in Toolbar"), spacing: 4, top: 9) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, command in
                        ShownToolRow(command: command, colored: app.preferences.usesColoredToolbarIcons,
                                     canMoveUp: index > 0, canMoveDown: index < shown.count - 1,
                                     move: { move(command, by: $0) },
                                     remove: { app.update { $0.toolbarCommands.removeAll { $0 == command } } })
                    }
                }
                column(L("In More"), spacing: 0, top: 7) {
                    ForEach(more, id: \.self) { command in
                        MoreToolRow(command: command, colored: app.preferences.usesColoredToolbarIcons) {
                            app.update { $0.toolbarCommands.append(command) }
                        }
                    }
                }
            }
            .padding(.top, 12)
            HStack {
                Button(L("Restore Toolbar Defaults")) {
                    app.update { $0.toolbarCommands = ToolbarCommand.defaultToolbar }
                }
                Spacer()
                Button(L("Done"), action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 27)
        .padding(.bottom, 27)
        .frame(width: 660, height: 500, alignment: .top)
    }

    private func column<Content: View>(_ title: String, spacing: CGFloat, top: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) { content() }
                    .padding(.horizontal, 5)
                    .padding(.top, top)
                    .padding(.bottom, 6)
            }
            .frame(height: 313)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.032)))
        }
        .frame(maxWidth: .infinity)
    }

    private func move(_ command: ToolbarCommand, by offset: Int) {
        app.update { configuration in
            let customizable = configuration.toolbarCommands.filter { !Self.fixedCommands.contains($0) }
            guard let index = customizable.firstIndex(of: command), customizable.indices.contains(index + offset) else { return }
            let other = customizable[index + offset]
            guard let a = configuration.toolbarCommands.firstIndex(of: command), let b = configuration.toolbarCommands.firstIndex(of: other) else { return }
            configuration.toolbarCommands.swapAt(a, b)
        }
    }

    private func preference(_ keyPath: WritableKeyPath<WorkspacePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { app.preferences[keyPath: keyPath] }, set: { value in app.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}

/// A tool shown in the toolbar: a 32 pt card with a drag handle, the glyph and name, and move up / move down /
/// move to More buttons at the right.
private struct ShownToolRow: View {
    let command: ToolbarCommand
    let colored: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 13)).foregroundStyle(.tertiary)
                .frame(width: 13)
            ToolbarRowView.glyph(command).view(colored: colored).frame(width: 17, height: 17).padding(.leading, 7)
            Text(ToolbarRowView.customizationTitle(command)).font(.system(size: 13)).lineLimit(1).padding(.leading, 5.5)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                // Dimmed explicitly: the row's secondary tint would otherwise hide the disabled state.
                Button { move(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 13)) }
                    .disabled(!canMoveUp).opacity(canMoveUp ? 1 : 0.35).help(L("Move Up"))
                Button { move(1) } label: { Image(systemName: "chevron.down").font(.system(size: 13)) }
                    .disabled(!canMoveDown).opacity(canMoveDown ? 1 : 0.35).help(L("Move Down"))
                Button(action: remove) { Image(systemName: "minus.circle").font(.system(size: 13)) }
                    .help(L("Move to More"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 5.5)
        .padding(.trailing, 4.5)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.025)))
    }
}

/// A tool in the More menu: glyph and name on a 34 pt row; the add button appears while the pointer is over it.
private struct MoreToolRow: View {
    let command: ToolbarCommand
    let colored: Bool
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9.5) {
            ToolbarRowView.glyph(command).view(colored: colored).frame(width: 17, height: 17)
            Text(ToolbarRowView.customizationTitle(command)).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 6)
            Button(action: add) { Image(systemName: "plus.circle").font(.system(size: 13)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help(L("Add to Toolbar"))
                .accessibilityLabel(L("Add to Toolbar"))
        }
        .padding(.leading, 1.5)
        .padding(.trailing, 4.5)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension WorkspaceController {
    func showToolbarCustomization() {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: ToolbarCustomizationSheet { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }
}
