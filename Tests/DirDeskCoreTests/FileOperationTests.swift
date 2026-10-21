import XCTest
@testable import DirDeskCore

final class FileOperationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testKeepBothNamingStartsAtTwo() throws {
        let original = try write("Report.txt", "a")
        XCTAssertEqual(FileOperationCoordinator.keepBothURL(for: original).lastPathComponent, "Report 2.txt")
        _ = try write("Report 2.txt", "b")
        XCTAssertEqual(FileOperationCoordinator.keepBothURL(for: original).lastPathComponent, "Report 3.txt")
        let noExtension = try write("Makefile", "c")
        XCTAssertEqual(FileOperationCoordinator.keepBothURL(for: noExtension).lastPathComponent, "Makefile 2")
    }

    /// Pasting into the same folder asks like any other name conflict (runtime reference 09-文件操作/paste-conflict-*).
    func testCopyIntoSameFolderAsks() async throws {
        let source = try write("a.txt", "hello")
        var asked = 0
        let keep = await FileOperationCoordinator().run(.init(kind: .copy, sources: [source], destination: root),
                                                       conflictHandler: { _, _ in asked += 1; return (.keepBoth, false) },
                                                       progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(keep.mutations.map(\.destination.lastPathComponent), ["a 2.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a 2.txt"), encoding: .utf8), "hello")
        let cancelled = await FileOperationCoordinator().run(.init(kind: .copy, sources: [source], destination: root),
                                                            conflictHandler: { _, _ in (.stop, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertTrue(cancelled.mutations.isEmpty)
        let replaced = await FileOperationCoordinator().run(.init(kind: .copy, sources: [source], destination: root),
                                                           conflictHandler: { _, _ in (.replace, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(replaced.skipped, [source], "replacing an item with itself does nothing")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
    }

    func testConflictResolutions() async throws {
        let destination = try folder("dest")
        let source = try write("same.txt", "new", in: try folder("src"))
        _ = try write("same.txt", "old", in: destination)
        let coordinator = FileOperationCoordinator()
        let skip = await coordinator.run(.init(kind: .copy, sources: [source], destination: destination),
                                         conflictHandler: { _, _ in (.skip, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(skip.skipped, [source])
        let keep = await coordinator.run(.init(kind: .copy, sources: [source], destination: destination),
                                         conflictHandler: { _, _ in (.keepBoth, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(keep.mutations.first?.destination.lastPathComponent, "same 2.txt")
        let replace = await coordinator.run(.init(kind: .copy, sources: [source], destination: destination),
                                            conflictHandler: { _, _ in (.replace, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("same.txt"), encoding: .utf8), "new")
        let backup = try XCTUnwrap(replace.mutations.first?.replacedBackupURL)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old", "the replaced item is retained for undo")
    }

    func testFolderReplaceIsRefused() async throws {
        let destination = try folder("dest")
        let sourceFolder = try folder("src/Same")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Same"), withIntermediateDirectories: true)
        let report = await FileOperationCoordinator().run(.init(kind: .copy, sources: [sourceFolder], destination: destination),
                                                         conflictHandler: { _, _ in (.replace, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.message, FileOperationError.directoryReplaceNotSupported.message)
    }

    func testMoveIntoItselfIsRefused() async throws {
        let parent = try folder("p")
        let child = try folder("p/child")
        let report = await FileOperationCoordinator().run(.init(kind: .move, sources: [parent], destination: child),
                                                         conflictHandler: { _, _ in (.stop, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(report.failures.first?.message, FileOperationError.sourceInsideItself.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
    }

    func testMoveSameVolumeRenames() async throws {
        let source = try write("m.txt", "move me")
        let destination = try folder("target")
        let report = await FileOperationCoordinator().run(.init(kind: .move, sources: [source], destination: destination),
                                                         conflictHandler: { _, _ in (.stop, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(report.mutations.first?.kind, .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("m.txt").path))
    }

    func testRecursiveCopyPublishesWithoutPartialNames() async throws {
        let tree = try folder("tree")
        _ = try write("a/b/c.txt", "deep", in: tree)
        let destination = try folder("out")
        let report = await FileOperationCoordinator().run(.init(kind: .copy, sources: [tree], destination: destination),
                                                         conflictHandler: { _, _ in (.stop, false) }, progress: { _ in }, isCancelled: { false })
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tree/a/b/c.txt"), encoding: .utf8), "deep")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".dirdesk-partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testFolderCollectAndDissolveWithUndo() throws {
        let a = try write("a.txt", "a")
        let b = try write("b.txt", "b")
        let collect = try FolderOrganizationService.collect([a, b], into: root, folderName: "New Folder")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: collect.folder.path)), ["a.txt", "b.txt"])
        FolderOrganizationService.undo(collect)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: collect.folder.path))

        let box = try folder("Box")
        _ = try write("a.txt", "inner", in: box)
        let dissolve = try FolderOrganizationService.dissolve(box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a (2).txt").path), "clashes use name (n)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.path))
        FolderOrganizationService.undo(dissolve)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.appendingPathComponent("a.txt").path))
    }

    func testChecksumMatchesKnownDigest() throws {
        let url = try write("abc.txt", "abc")
        XCTAssertEqual(try ChecksumService().checksum(of: url, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try ChecksumService().checksum(of: url, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testArchiveRoundTripAndSafety() throws {
        let source = try folder("pack")
        _ = try write("one.txt", "1", in: source)
        _ = try write("sub/two.txt", "2", in: source)
        let zip = try XCTUnwrap(try ArchiveService.create(from: [source], to: root.appendingPathComponent("pack.zip"), options: ArchiveCreationOptions()).first)
        let index = try ArchiveService.index(of: zip)
        XCTAssertTrue(index.entries.contains { $0.path.hasSuffix("sub/two.txt") })
        let out = try folder("out")
        let extracted = try ArchiveService.extract(zip, to: out)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("sub/two.txt"), encoding: .utf8), "2")
        XCTAssertNil(ArchiveService.safeRelativePath("../evil"))
        XCTAssertNil(ArchiveService.safeRelativePath("/etc/passwd"))
        XCTAssertEqual(ArchiveService.safeRelativePath("./a/./b"), "a/b")
    }

    /// tar and 7z list "./a.txt" and a "./" root; the index drops the root and treats "./a.txt" as "a.txt".
    func testDotPrefixedEntriesNameTheSameItems() throws {
        let source = try folder("dotted")
        _ = try write("a.txt", "alpha", in: source)
        _ = try write("Sub/b.txt", "beta", in: source)
        let tar = root.appendingPathComponent("dotted.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tar.path, "-C", source.path, "."]
        try process.run()
        process.waitUntilExit()
        let index = try ArchiveService.index(of: tar)
        XCTAssertEqual(Set(index.entries.map { $0.pathComponents.joined(separator: "/") }), ["Sub", "Sub/b.txt", "a.txt"])
        let preview = try ArchiveService.extractEntry("/Sub/b.txt", from: tar, to: try folder("entry"))
        XCTAssertEqual(try String(contentsOf: preview, encoding: .utf8), "beta")
    }

    func testPasswordOnlyForZip() {
        XCTAssertThrowsError(try ArchiveService.create(from: [], to: root.appendingPathComponent("x.7z"),
                                                       options: ArchiveCreationOptions(format: .sevenZip, password: "1")))
    }

    func testOfficeSeedsAreValidZipPackages() throws {
        for (name, data) in [("w.docx", OfficeSeeds.word), ("x.xlsx", OfficeSeeds.excel), ("p.pptx", OfficeSeeds.powerPoint)] {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            let index = try ArchiveService.index(of: url)
            XCTAssertTrue(index.entries.contains { $0.path == "[Content_Types].xml" }, name)
        }
    }
}

final class ArchiveMergeTests: XCTestCase {
    /// Double-click extraction puts the archive's items straight into the folder, keeping both on name clashes.
    func testExtractMergingPublishesRootsInArchiveOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-merge-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: source.appendingPathComponent("Sub/b.txt"))
        let zip = root.appendingPathComponent("sample.zip")
        _ = try ArchiveService.create(from: [source.appendingPathComponent("Sub"), source.appendingPathComponent("a.txt")], to: zip,
                                      options: ArchiveCreationOptions())
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let first = try ArchiveService.extractMerging(zip, into: out)
        XCTAssertEqual(first.map(\.lastPathComponent), ["Sub", "a.txt"])
        let second = try ArchiveService.extractMerging(zip, into: out)
        XCTAssertEqual(Set(second.map(\.lastPathComponent)), ["Sub 2", "a 2.txt"])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Sub/b.txt"), encoding: .utf8), "b")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix(".dirdesk-extract") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
