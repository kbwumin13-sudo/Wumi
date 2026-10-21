import XCTest
@testable import DirDeskCore

final class FileUndoSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("undo-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testMoveBackAndRedo() throws {
        let original = root.appendingPathComponent("a.txt")
        let moved = try file("b.txt")
        let undo = [FileUndoStep.move(moved, to: original)]
        XCTAssertNil(FileUndoSafety.verify(undo))
        let redo = try FileUndoSafety.perform(undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNil(FileUndoSafety.verify(redo))
        _ = try FileUndoSafety.perform(redo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testStopsWhenTheItemIsMissing() throws {
        let gone = root.appendingPathComponent("gone.txt")
        let step = FileUndoStep(from: gone, action: .move(to: root.appendingPathComponent("back.txt")), expected: nil)
        XCTAssertEqual(FileUndoSafety.verify([step]), .missing("gone.txt"))
    }

    func testStopsWhenTheOriginalNameIsTaken() throws {
        let moved = try file("b.txt")
        let original = try file("a.txt", "someone else")
        XCTAssertEqual(FileUndoSafety.verify([.move(moved, to: original)]), .occupied("a.txt"))
    }

    func testStopsWhenTheFileChangedElsewhere() throws {
        let moved = try file("b.txt")
        let step = FileUndoStep.move(moved, to: root.appendingPathComponent("a.txt"))
        try Data("edited elsewhere".utf8).write(to: moved)
        XCTAssertEqual(FileUndoSafety.verify([step]), .changed("b.txt"))
    }

    func testCaseOnlyRenameIsNotOccupied() throws {
        let renamed = try file("Note.txt")
        XCTAssertNil(FileUndoSafety.verify([.move(renamed, to: root.appendingPathComponent("note.txt"))]))
    }

    /// Undoing "replace": the copy leaves, then the replaced original returns to the same name.
    func testLaterStepsMayUseANameAnEarlierStepFrees() throws {
        let destination = try file("report.txt", "new")
        let backup = try file(".backup-report.txt", "old")
        let steps = [FileUndoStep.trash(destination), .move(backup, to: destination)]
        XCTAssertNil(FileUndoSafety.verify(steps))
        let redo = try FileUndoSafety.perform(steps)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertNil(FileUndoSafety.verify(redo))
        _ = try FileUndoSafety.perform(redo)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
    }

    func testNewFolderContentsDoNotBlockUndo() throws {
        let folder = root.appendingPathComponent("untitled folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let step = FileUndoStep.trash(folder)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        XCTAssertNil(FileUndoSafety.verify([step]))
    }

    func testCollectUndoAndRedo() throws {
        let a = try file("a.txt")
        let b = try file("b.txt")
        let transaction = try FolderOrganizationService.collect([a, b], into: root, folderName: "New Folder")
        let undo = FileUndoStep.undoing(transaction)
        XCTAssertNil(FileUndoSafety.verify(undo))
        let redo = try FileUndoSafety.perform(undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.folder.path))
        XCTAssertNil(FileUndoSafety.verify(redo))
        _ = try FileUndoSafety.perform(redo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.folder.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testDissolveUndoRecreatesTheFolder() throws {
        let folder = root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: folder.appendingPathComponent("one.txt"))
        let transaction = try FolderOrganizationService.dissolve(folder)
        let undo = FileUndoStep.undoing(transaction)
        XCTAssertNil(FileUndoSafety.verify(undo))
        _ = try FileUndoSafety.perform(undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    }

    func testDissolveUndoStopsWhenTheFolderNameIsTaken() throws {
        let folder = root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: folder.appendingPathComponent("one.txt"))
        let transaction = try FolderOrganizationService.dissolve(folder)
        _ = try file("box")
        XCTAssertEqual(FileUndoSafety.verify(FileUndoStep.undoing(transaction)), .occupied("box"))
    }
}
