import XCTest
@testable import DirDeskCore

final class ConfigurationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The original's stored configuration decodes field for field, including the flat shortcut array.
    func testDecodesOriginalEfficiencyConfiguration() throws {
        let configuration = try JSONDecoder().decode(EfficiencyConfiguration.self, from: fixture("original-efficiency-configuration"))
        XCTAssertEqual(configuration.schemaVersion, 32)
        XCTAssertEqual(configuration.contextMenuCommands, ContextMenuCommand.finderStylePreset)
        XCTAssertEqual(configuration.shortcuts.count, 35)
        XCTAssertEqual(configuration.shortcuts, ShortcutDefaults.primary)
        XCTAssertEqual(configuration.toolbarCommands, ToolbarCommand.defaultToolbar)
        XCTAssertEqual(Set(configuration.enabledBuiltInTools), Set(BuiltInToolID.allCases))
        // Imported appearance choices survive Wumi's new defaults.
        var originalPreferences = WorkspacePreferences.defaults
        originalPreferences.usesColoredToolbarIcons = true
        originalPreferences.bookmarkBarBackground = .paleBlue
        XCTAssertEqual(configuration.workspacePreferences, originalPreferences)
        XCTAssertEqual(configuration.fileTemplates.map(\.fileNamePattern),
                       ["Untitled.md", "Untitled.txt", "Untitled.json", "Untitled.docx", "Untitled.xlsx", "Untitled.pptx", "Untitled.csv"])
        XCTAssertEqual(configuration.fileTemplates.first { $0.builtInKind == .jsonFile }?.contents, "{\n}\n")
    }

    func testEncodesShortcutsAsFlatArrayLikeOriginal() throws {
        var configuration = EfficiencyConfiguration()
        configuration.shortcuts = [.copy: ShortcutBinding([.cmd], "c")]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        let shortcuts = try XCTUnwrap(json?["shortcuts"] as? [Any])
        XCTAssertEqual(shortcuts.first as? String, "copy")
        XCTAssertEqual((shortcuts.last as? [String: Any])?["key"] as? String, "c")
    }

    func testDecodesOriginalWindowSession() throws {
        let session = try JSONDecoder().decode(WindowSession.self, from: fixture("original-window-session"))
        XCTAssertEqual(session.tabs.count, 1)
        let pane = try XCTUnwrap(session.tabs.first?.panes.first)
        XCTAssertEqual(pane.viewConfiguration.mode, .list)
        XCTAssertEqual(pane.viewConfiguration.visibleListColumns, [.name, .modificationDate, .size, .kind, .lastOpenedDate])
        XCTAssertFalse(pane.history.entries.isEmpty)
        let recent = pane.history.entries.compactMap { entry -> RecentDateFilter? in
            if case .recent(let filter) = entry { return filter }
            return nil
        }
        XCTAssertEqual(recent.first?.period, .week, "recent destinations decode with their period")
        XCTAssertEqual(session.tabs.first?.layout, .single)
    }

    func testMissingPreferenceKeysFallBackToDefaults() throws {
        let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"listDensity":"compact"}"#.utf8))
        XCTAssertEqual(preferences.listDensity, .compact)
        XCTAssertEqual(preferences.archiveDirectBrowseSizeLimitMB, 512)
        XCTAssertEqual(preferences.dragHoverExpansionDelay, 0.45)
    }

    func testShortcutParsingAndDisplay() throws {
        XCTAssertEqual(try ShortcutBinding.parse("cmd+option+k"), ShortcutBinding([.option, .cmd], "k"))
        XCTAssertEqual(try ShortcutBinding.parse("dd").isDoubleTap, true)
        XCTAssertEqual(try ShortcutBinding.parse("space"), ShortcutBinding([], "space"))
        XCTAssertThrowsError(try ShortcutBinding.parse("k"))
        XCTAssertThrowsError(try ShortcutBinding.parse("cmd+a+b"))
        XCTAssertThrowsError(try ShortcutBinding.parse(""))
        XCTAssertEqual(ShortcutBinding([.shift, .cmd], "n").displayString, "⇧⌘N")
        XCTAssertEqual(ShortcutBinding([.cmd], "up").displayString, "⌘↑")
    }

    func testShortcutConflictsAndDisabledCommands() {
        var table = ShortcutTable(primary: ShortcutDefaults.primary, secondary: [.newFile: ShortcutBinding([.cmd], "c")], disabled: [])
        XCTAssertEqual(table.conflicts.count, 1)
        XCTAssertEqual(table.conflicts.first.map { Set($0.commands) }, [.copy, .newFile])
        table.disabled = [.newFile]
        XCTAssertTrue(table.conflicts.isEmpty)
        XCTAssertEqual(table.command(for: ShortcutBinding([.cmd], "c")), .copy)
    }

    func testNavigationHistory() {
        let a = PaneDestination.directory(URL(fileURLWithPath: "/a"))
        let b = PaneDestination.directory(URL(fileURLWithPath: "/b"))
        let c = PaneDestination.directory(URL(fileURLWithPath: "/c"))
        var history = NavigationHistory(start: a)
        history.visit(b)
        history.visit(b)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.goBack(), a)
        history.visit(c)
        XCTAssertEqual(history.entries, [a, c])
        XCTAssertFalse(history.canGoForward)
    }

    func testBookmarkLibraryRules() throws {
        var library = BookmarkLibrary.initial
        let root = try XCTUnwrap(library.defaultFolder)
        let folder = try library.add(title: "Projects", payload: .folder, parent: root.id)
        let target = try library.add(title: "Docs", payload: .target(.init(url: URL(fileURLWithPath: "/tmp"), kind: .folder)), parent: folder.id)
        XCTAssertThrowsError(try library.add(title: "  ", payload: .folder, parent: nil))
        XCTAssertThrowsError(try library.add(title: "x", payload: .folder, parent: target.id))
        XCTAssertThrowsError(try library.move(folder.id, to: folder.id, index: 0))
        library.remove(folder.id)
        XCTAssertNil(library.node(target.id))
        library.remove(root.id)
        XCTAssertNotNil(library.defaultFolder, "the default folder cannot be removed")
    }

    func testFolderOutlineListsFoldersInOrderAndSkipsTheMovingSubtree() throws {
        var library = BookmarkLibrary.initial
        let root = try XCTUnwrap(library.defaultFolder)
        let work = try library.add(title: "Work", payload: .folder, parent: root.id)
        let nested = try library.add(title: "Nested", payload: .folder, parent: work.id)
        _ = try library.add(title: "Docs", payload: .target(.init(url: URL(fileURLWithPath: "/tmp"), kind: .folder)), parent: work.id)
        let top = try library.add(title: "Top", payload: .folder, parent: nil)
        XCTAssertEqual(library.folderOutline().map { "\($0.depth):\($0.node.title)" }, ["0:Default", "1:Work", "2:Nested", "0:Top"])
        XCTAssertEqual(library.folderOutline(excluding: work.id).map(\.node.id), [root.id, top.id])
        XCTAssertEqual(library.folderOutline(excluding: nested.id).map(\.node.id), [root.id, work.id, top.id])
    }

    /// Both context-menu presets list every command once; the DirDeck order puts Built-in Tools ahead of Get Info.
    func testContextMenuPresetsArePermutations() {
        for preset in [ContextMenuCommand.defaultPreset, ContextMenuCommand.finderStylePreset] {
            XCTAssertEqual(preset.count, ContextMenuCommand.allCases.count)
            XCTAssertEqual(Set(preset), Set(ContextMenuCommand.allCases))
        }
        XCTAssertEqual(Array(ContextMenuCommand.defaultPreset[6...8]), [.separatorOpen, .builtInTools, .getInfo])
        XCTAssertEqual(EfficiencyConfiguration().contextMenuCommands, ContextMenuCommand.finderStylePreset)
    }
}
