import XCTest
@testable import DirDeskCore

final class DesktopLayoutTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wumi-desktop-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func file(_ name: String, contents: String = "fixture") throws -> FileItem {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try XCTUnwrap(DirectoryLoader.item(at: url))
    }
    private func layout() -> DesktopLayout {
        var layout = DesktopLayout()
        layout.prepare(screenSizes: ["left": (900, 700), "right": (1200, 800)], primaryID: "left")
        layout.zones.append(.init(id: "collection", title: "Fixture", screenID: "right", frame: .init(x: 20, y: 30, width: 300, height: 240)))
        return layout
    }
    func testVisualAssignmentDoesNotMoveOrModifyFiles() throws {
        let note = try file("Note.txt", contents: "unchanged")
        let image = try file("Image.png")
        var model = layout()
        XCTAssertTrue(model.assign([note, image], to: "collection"))
        XCTAssertEqual(model.zoneID(for: note), "collection")
        XCTAssertEqual(try Data(contentsOf: note.url), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Image.png", "Note.txt"])
        XCTAssertEqual(model.visibleZones(on: "right", items: [note, image]).map(\.id), ["collection"])
        XCTAssertFalse(model.assign([note], to: "missing"))
    }
    func testStableIdentityFollowsExternalRenameAndPersistence() throws {
        let old = try file("Old.txt")
        var model = layout()
        model.assign([old], to: "collection")
        let url = try DesktopFileActions.rename(old.url, name: "Renamed.md")
        let renamed = try XCTUnwrap(DirectoryLoader.item(at: url))
        XCTAssertEqual(DesktopLayout.identityKey(old), DesktopLayout.identityKey(renamed))
        model.reconcile([renamed])
        let restored = try JSONDecoder().decode(DesktopLayout.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.zoneID(for: renamed), "collection")
        XCTAssertEqual(restored.assignments[DesktopLayout.identityKey(renamed)]?.lastKnownPath, url.path)
    }
    func testListingAndDirectMetadataKeepSameAssignmentAfterRename() throws {
        _ = try file("Listed.txt")
        let listed = try XCTUnwrap(DirectoryLoader.load(directory: root).items.first)
        var model = layout()
        model.assign([listed], to: "collection")
        let renamedURL = try DesktopFileActions.rename(listed.url, name: "Renamed.txt")
        let direct = try XCTUnwrap(DirectoryLoader.item(at: renamedURL))
        model.didRename(listed, to: direct)
        let relisted = try XCTUnwrap(DirectoryLoader.load(directory: root).items.first)
        XCTAssertEqual(DesktopLayout.identityKey(direct), DesktopLayout.identityKey(relisted))
        model.reconcile([relisted])
        XCTAssertEqual(model.zoneID(for: relisted), "collection")
    }
    func testReplacementAtSamePathDoesNotInheritStableAssignment() throws {
        let original = try file("Target.txt")
        let replacement = try file("Replacement.txt")
        var model = layout()
        model.assign([original], to: "collection")
        try FileManager.default.removeItem(at: original.url)
        try FileManager.default.moveItem(at: replacement.url, to: original.url)
        let new = try XCTUnwrap(DirectoryLoader.item(at: original.url))
        XCTAssertNotEqual(DesktopLayout.identityKey(original), DesktopLayout.identityKey(new))
        XCTAssertNotEqual(model.zoneID(for: new), "collection")
    }
    func testPathOnlyIdentityMigratesOnExplicitRename() {
        let old = FileItem(id: .init(fallbackPath: "/fixture/Old.txt"), url: URL(fileURLWithPath: "/fixture/Old.txt"), name: "Old.txt", isDirectory: false)
        let new = FileItem(id: .init(fallbackPath: "/fixture/New.txt"), url: URL(fileURLWithPath: "/fixture/New.txt"), name: "New.txt", isDirectory: false)
        var model = layout()
        model.assign([old], to: "collection")
        model.didRename(old, to: new)
        XCTAssertNil(model.assignments[DesktopLayout.identityKey(old)])
        XCTAssertEqual(model.zoneID(for: new), "collection")
    }
    func testNewItemStaysInOriginZoneAcrossTypeAndGroupingChanges() throws {
        var model = layout()
        let folder = try DesktopFileActions.create(in: root, name: "Folder", folder: true)
        let item = try XCTUnwrap(DirectoryLoader.item(at: folder))
        let source = "desktop.kind.documents"
        model.assign([item], to: source)
        XCTAssertEqual(model.zoneID(for: item), source)
        model.automaticGrouping = false
        XCTAssertEqual(model.zoneID(for: item), DesktopLayout.unassignedZoneID)
        model.automaticGrouping = true
        XCTAssertEqual(model.zoneID(for: item), source)
    }
    func testRemovingCollectionReturnsFilesToAutomaticGrouping() throws {
        let item = try file("Note.md")
        var model = layout()
        model.assign([item], to: "collection")
        model.removeZone("collection")
        XCTAssertEqual(model.zoneID(for: item), "desktop.kind.documents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }
    func testScreenRemovalRelocatesAndClampsWithoutDuplicatingZones() {
        var model = layout()
        model.zones[model.zones.firstIndex { $0.id == "collection" }!].frame = .init(x: 1500, y: -400, width: 1600, height: 1200)
        model.prepare(screenSizes: ["left": (640, 480)], primaryID: "left")
        let zone = model.zones.first { $0.id == "collection" }!
        XCTAssertEqual(zone.screenID, "left")
        XCTAssertEqual(zone.frame, .init(x: 0, y: 0, width: 640, height: 480))
        let count = model.zones.count
        model.prepare(screenSizes: ["left": (640, 480)], primaryID: "left")
        XCTAssertEqual(model.zones.count, count)
        XCTAssertEqual(Set(model.zones.map(\.id)).count, count)
    }
    func testNegativeAndInvalidGeometryClampsAndSmallScreensRemainReachable() {
        XCTAssertEqual(DesktopRect(x: -1920, y: -300, width: 400, height: 300).clamped(width: 800, height: 600), .init(x: 0, y: 0, width: 400, height: 300))
        let invalid = DesktopRect(x: .nan, y: .infinity, width: .nan, height: -.infinity).clamped(width: 120, height: 80)
        XCTAssertEqual(invalid, .init(x: 0, y: 0, width: 120, height: 80))
    }
    func testSearchAndCollectionGeometryRoundTrip() throws {
        var model = layout()
        model.searchWidgets["left"] = .init(frame: .init(x: 50, y: 60, width: 420, height: 310), isVisible: false)
        model.zones[0].isCollapsed = true
        model.zones[0].title = "Saved Name"
        let restored = try JSONDecoder().decode(DesktopLayout.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored, model)
    }
    func testCreateUsesOriginalNameThenUniqueNameAndUndoRedo() throws {
        let first = try DesktopFileActions.create(in: root, name: "Note.txt", contents: Data("first".utf8), folder: false)
        let second = try DesktopFileActions.create(in: root, name: "Note.txt", contents: Data("second".utf8), folder: false)
        XCTAssertEqual(first.lastPathComponent, "Note.txt")
        XCTAssertEqual(second.lastPathComponent, "Note 2.txt")
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        // Use an in-fixture move for undo verification; this test never touches the user's Trash.
        let renamed = try DesktopFileActions.rename(second, name: "Renamed.txt")
        let steps = [FileUndoStep.move(renamed, to: second)]
        XCTAssertNil(FileUndoSafety.verify(steps))
        let redo = try FileUndoSafety.perform(steps)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        _ = try FileUndoSafety.perform(redo)
        XCTAssertEqual(try Data(contentsOf: renamed), Data("second".utf8))
    }
    func testTraversalAndOccupiedRenameDoNotAlterOtherFile() throws {
        XCTAssertThrowsError(try DesktopFileActions.create(in: root, name: "../escape", folder: false))
        let first = try file("First.txt", contents: "first")
        let second = try file("Second.txt", contents: "second")
        XCTAssertThrowsError(try DesktopFileActions.rename(first.url, name: "Second.txt"))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second".utf8))
        XCTAssertThrowsError(try DesktopFileActions.rename(first.url, name: "../escape"))
    }
    func testRealFolderDropUsesTransferRatherThanVisualAssignment() async throws {
        let item = try file("Note.txt")
        let folder = try DesktopFileActions.create(in: root, name: "Folder", folder: true)
        let report = await FileOperationCoordinator().run(.init(kind: .move, sources: [item.url], destination: folder, conflictResolution: .stop),
                                                         conflictHandler: { _, _ in (.stop, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.mutations.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Note.txt")), Data("fixture".utf8))
    }
}
