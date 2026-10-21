import AppKit
import SwiftUI

/// The Search Expression help sheet: basic rules, filter rules and examples that can be copied.
struct LightningSearchHelpSheet: View {
    @ObservedObject var model: LightningSearchModel
    @State private var filter = ""

    struct Entry: Identifiable {
        var id: String { expression }
        let expression: String
        let detail: String
    }

    static var basics: [Entry] {
        [
            Entry(expression: "invoice 2025", detail: L("A space (or AND) means every word has to appear in the same item's name.")),
            Entry(expression: "jpg | png", detail: L("| (or OR) is satisfied by either side.")),
            Entry(expression: "!backup", detail: L("! (or NOT) leaves out what matches. Group conditions with parentheses.")),
            Entry(expression: "photo (2024 | 2025)", detail: L("NOT is evaluated first, then OR, then AND. Add parentheses whenever you mix them.")),
            Entry(expression: "\"Project Plan\" ext:docx", detail: L("Wrap phrases in straight double quotes, and write a filter's value right after its colon.")),
            Entry(expression: "*.png · IMG_????.jpg · Projects/**/notes.txt",
                  detail: L("Wildcards: * is any run of characters, ? exactly one, and ** any number of folders in a path.")),
            Entry(expression: "/src/ · build/ · /draft",
                  detail: L("A word with a slash matches names along the path: /name/ is a whole name, name/ the end of one, /name the start of one. Add /** to list everything inside a folder.")),
        ]
    }

    static var filters: [Entry] {
        [
            Entry(expression: "file: · folder:", detail: L("Keep only files, or only folders.")),
            Entry(expression: "ext:jpg;png", detail: L("Extensions are written without the dot; any of the listed ones matches.")),
            Entry(expression: "type:image · video · audio · doc · pdf", detail: L("Kinds of files; write type: in front of each one.")),
            Entry(expression: "type:presentation · spreadsheet · archive · code · app",
                  detail: L("More kinds. type:text and type:office mean the same as type:doc.")),
            Entry(expression: "audio: · video: · doc: · exe:", detail: L("Short forms of type:audio, type:video, type:doc and type:app.")),
            Entry(expression: "in:~/Documents",
                  detail: L("Searches a folder and everything inside it. infolder: and parent: work the same; ~ is your home folder.")),
            Entry(expression: "nosubfolders:~/Desktop", detail: L("Only what sits directly inside the folder.")),
            Entry(expression: "size:>100MB · size:10KB..2MB · size:empty",
                  detail: L("Compare with >, >=, <, <=, = or != and write ranges as 10KB..2MB. Units are B, KB, MB, GB, TB and PB (1 KB = 1000 bytes). empty, tiny, small, medium, large, huge and gigantic name preset ranges.")),
            Entry(expression: "dm:pastweek · dc:2026-01-01..2026-03-31",
                  detail: L("dm: is the modification date and dc: the creation date. Use today, yesterday, pastweek, thismonth or lastyear, dates written as YYYY-MM-DD, comparisons and ranges.")),
            Entry(expression: "content:TODO",
                  detail: L("content: finds text stored literally in files. It does not read text inside PDF or Word documents, and a smaller scope makes it faster.")),
            Entry(expression: "tag:Work · tagexact:\"Work\"",
                  detail: L("tag: finds tags whose name contains the value, tagexact: needs the whole name. Repeat either one to require several tags.")),
            Entry(expression: "regex:^IMG_\\d+", detail: L("regex: tests the item name with a regular expression and follows Match Case.")),
            Entry(expression: "case:README · nocase:",
                  detail: L("case: makes the next word or group, or on its own the whole search, case-sensitive; nocase: does the opposite.")),
        ]
    }

    static var examples: [Entry] {
        [
            Entry(expression: "type:image vacation dm:pastweek", detail: L("Vacation pictures changed during the last seven days.")),
            Entry(expression: "(type:video | type:audio) size:>500MB", detail: L("Video or audio files bigger than 500 MB.")),
            Entry(expression: "ext:txt;md content:FIXME", detail: L("Text and Markdown files that contain FIXME.")),
            Entry(expression: "in:~/Downloads !ext:dmg", detail: L("Everything in Downloads and its subfolders except disk images.")),
            Entry(expression: "tagexact:\"Finance\" tagexact:\"2025\"", detail: L("Items that carry both of these exact tags.")),
            Entry(expression: "regex:^Invoice.*\\d{4}$ dc:thisyear",
                  detail: L("Names that start with Invoice and end in four digits, created this year.")),
            Entry(expression: "folder: dm:today", detail: L("Folders changed today.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(L("Search Expression")).font(.system(size: 17, weight: .bold))
                Spacer()
                Button(L("Done")) { model.showsHelp = false }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(height: 24)
            .padding(.top, 20)
            TextField(L("Find Expressions or Examples"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .padding(.top, 14)
            Picker(L("Search Expression"), selection: $model.helpTab) {
                Text(L("Basic Rules")).tag(LightningSearchModel.HelpTab.basics)
                Text(L("Filter Rules")).tag(LightningSearchModel.HelpTab.filters)
                Text(L("Examples")).tag(LightningSearchModel.HelpTab.examples)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.top, 13)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry, copyable: isFiltering || model.helpTab == .examples)
                    }
                    if entries.isEmpty {
                        Text(L("No Results"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
            Text(L("Only the filters listed here are supported; any other filter shows an error."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
        .frame(width: 620, height: 530)
    }

    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The selected page, or matches from every page while the search field has text.
    private var entries: [Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            switch model.helpTab {
            case .basics: return Self.basics
            case .filters: return Self.filters
            case .examples: return Self.examples
            }
        }
        return (Self.basics + Self.filters + Self.examples).filter {
            $0.expression.localizedCaseInsensitiveContains(needle) || $0.detail.localizedCaseInsensitiveContains(needle)
        }
    }

    /// An expression in monospaced type above its explanation, then a separator. Examples also get a Copy button.
    private func row(_ entry: Entry, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(entry.expression)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if copyable {
                    Button(L("Copy")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(entry.expression, forType: .string)
                    }
                    .help(L("Copy this expression"))
                }
            }
            Text(entry.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, copyable ? 2.5 : 1.5)
            Divider()
                .padding(.top, 12)
        }
        .padding(.top, 12.5)
    }
}
