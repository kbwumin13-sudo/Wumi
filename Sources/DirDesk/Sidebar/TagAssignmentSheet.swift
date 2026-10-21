import AppKit
import DirDeskCore
import SwiftUI

/// "Add Tags…" sheet: every known tag with its state for the selected items (all, some, none); clicking a tag adds it
/// to every item or, when all already carry it, removes it. A name field adds a new tag. Remove All Tags and Done
/// below. Structure follows the original's `TagAssignmentSheet` (title with tag.fill, name field + Add, tag list,
/// Remove All Tags, progress, Done); sizes and state symbols are our own.
struct TagAssignmentSheet: View {
    let finish: () -> Void
    @ObservedObject private var catalog = FinderTagCatalog.shared
    @State private var tagsByURL: [URL: [String]]
    @State private var newName = ""
    @State private var message: String?

    private enum Applied {
        case all, some, none
    }

    init(items: [FileItem], finish: @escaping () -> Void) {
        self.finish = finish
        _tagsByURL = State(initialValue: Dictionary(items.map { ($0.url, $0.tags) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill").foregroundStyle(Color.accentColor)
                Text(L("Tags")).font(.system(size: 15, weight: .semibold))
                if tagsByURL.count > 1 {
                    Text(LF("%lld items selected", Int64(tagsByURL.count))).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField(L("Name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewTag)
                Button(L("Add"), action: addNewTag)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(allTags, id: \.name) { tag in
                        tagRow(tag)
                    }
                }
                .padding(4)
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button(L("Remove All Tags")) { write { _ in [] } }
                    .disabled(tagsByURL.values.allSatisfy(\.isEmpty))
                Spacer()
                Button(L("Done"), action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// Tags in the catalog's order, plus tags the items carry that the catalog does not list.
    private var allTags: [FinderTagCatalog.Tag] {
        var result = catalog.tags
        let known = Set(result.map(\.name))
        let extra = Set(tagsByURL.values.flatMap { $0 }).subtracting(known)
        result += extra.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FinderTagCatalog.Tag(name: $0, label: FinderTagCatalog.label(for: $0)) }
        return result
    }

    private func state(of name: String) -> Applied {
        let carrying = tagsByURL.values.filter { $0.contains(name) }.count
        if carrying == 0 { return .none }
        return carrying == tagsByURL.count ? .all : .some
    }

    private func tagRow(_ tag: FinderTagCatalog.Tag) -> some View {
        let applied = state(of: tag.name)
        return Button {
            toggle(tag.name, applied: applied)
        } label: {
            HStack(spacing: 8) {
                if let color = Theme.finderTagColor(tag.label) {
                    Circle().fill(Color(nsColor: color)).frame(width: 9, height: 9)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 9, height: 9)
                }
                Text(tag.name).lineLimit(1)
                Spacer()
                switch applied {
                case .all: Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                case .some: Image(systemName: "minus").foregroundStyle(.secondary)
                case .none: EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(applied == .all ? L("Applied to all selected items")
                            : applied == .some ? L("Applied to some selected items") : L("Not applied"))
    }

    private func toggle(_ name: String, applied: Applied) {
        if applied == .all {
            write { $0.filter { $0 != name } }
        } else {
            write { $0.contains(name) ? $0 : $0 + [name] }
        }
    }

    private func addNewTag() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !catalog.tags.contains(where: { $0.name == name }) { catalog.create(name) }
        write { $0.contains(name) ? $0 : $0 + [name] }
        newName = ""
    }

    /// Applies `change` to every item's tag list and writes the results; items that fail keep their tags.
    private func write(_ change: ([String]) -> [String]) {
        var failed: [String] = []
        for (url, tags) in tagsByURL {
            let updated = change(tags)
            guard updated != tags else { continue }
            do {
                try (url as NSURL).setResourceValue(updated, forKey: .tagNamesKey)
                tagsByURL[url] = updated
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        message = failed.isEmpty ? nil : LF("Tags could not be changed for: %@", failed.joined(separator: ", "))
        NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
        catalog.tagsChanged()
    }
}

extension WorkspaceController {
    /// "Add Tags…" from the Tags submenu and the inspector.
    func editTags(for items: [FileItem]) {
        guard !items.isEmpty, let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: TagAssignmentSheet(items: items) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }
}
