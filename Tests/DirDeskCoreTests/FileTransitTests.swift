import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DirDeskCore

final class FileTransitTests: XCTestCase {
    private var root: URL!
    private var storage: URL!
    private var originals: URL!
    private var exports: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dirdesk-transit-tests-\(UUID().uuidString)", isDirectory: true)
        storage = root.appendingPathComponent("Storage", isDirectory: true)
        originals = root.appendingPathComponent("Originals", isDirectory: true)
        exports = root.appendingPathComponent("Exports", isDirectory: true)
        for folder in [storage, originals, exports] { try fm.createDirectory(at: folder!, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func service(_ limits: FileTransitLimits = .standard) -> FileTransitService {
        FileTransitService(repository: FileTransitRepository(rootURL: storage), limits: limits)
    }

    @discardableResult
    private func original(_ name: String, _ text: String = "content") throws -> URL {
        let url = originals.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func pngData(width: Int = 4, height: Int = 3, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func managedFile(_ item: FileTransitItem, in service: FileTransitService) throws -> URL {
        try XCTUnwrap(item.fileURL(managedRoot: service.managedRootURL))
    }

    private func limits(items: Int = 500, managed: Int64 = 1 << 30, perImport: Int64 = 1 << 30,
                        batches: Int = 20, removed: Int = 500) -> FileTransitLimits {
        FileTransitLimits(maximumItemCount: items, maximumManagedBytes: managed, maximumImportBytes: perImport,
                          maximumRemovedBatches: batches, maximumRemovedItems: removed)
    }

    // MARK: Adding

    func testFilesAndFoldersAreReferencedInPlaceAsOneStack() throws {
        let file = try original("report.pdf")
        let folder = originals.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let transit = service()

        let change = transit.add([.file(file), .file(folder), .file(file)])
        XCTAssertEqual(change.added.count, 2)
        XCTAssertEqual(change.skippedDuplicates, 1)
        XCTAssertTrue(change.failures.isEmpty)
        let items = transit.shelf.items
        XCTAssertEqual(items.map(\.kind), [.file, .directory])
        XCTAssertEqual(items.map(\.name), ["report.pdf", "Photos"])
        XCTAssertEqual(items.map(\.originalPath), [file.path, folder.path])
        XCTAssertEqual(Set(items.map(\.stackID)).count, 1, "items dropped together form one stack")
        XCTAssertTrue(items.allSatisfy { !$0.isManaged && $0.managedByteCount == 0 })
        XCTAssertEqual(transit.shelf.stacks.count, 1)
        XCTAssertTrue(transit.shelf.stacks[0].isGroup)

        // Adding the same file again later is ignored; a separate drop starts a new stack.
        let other = try original("notes.md")
        XCTAssertEqual(transit.add([.file(file)]).skippedDuplicates, 1)
        transit.add([.file(other)])
        XCTAssertEqual(transit.shelf.stacks.map(\.items.count), [2, 1])
        XCTAssertFalse(fm.fileExists(atPath: transit.managedRootURL.path), "references never copy into managed storage")
    }

    func testMissingFilesAndNonFileURLsCannotBeReferenced() throws {
        let transit = service()
        let change = transit.add([.file(originals.appendingPathComponent("gone.txt")), .file(URL(string: "https://example.com")!)])
        XCTAssertEqual(change.failures, [.unsupportedItem, .unsupportedItem])
        XCTAssertTrue(transit.shelf.items.isEmpty)
    }

    func testDroppedTextImagesAndLinksGoIntoManagedStorage() throws {
        let transit = service()
        let png = try pngData()
        let tiff = try pngData(type: .tiff)
        let change = transit.add([
            .text("  \nMeeting notes: Monday / budget\nsecond line"),
            .image(png, typeIdentifier: UTType.png.identifier, name: "chart.png"),
            .image(tiff, typeIdentifier: UTType.tiff.identifier, name: nil),
            .link(URL(string: "https://www.example.com/page")!, title: nil),
            .link(URL(string: "https://example.org")!, title: "Example: Docs"),
        ])
        XCTAssertTrue(change.failures.isEmpty, "\(change.failures)")
        let items = transit.shelf.items
        XCTAssertEqual(items.map(\.kind), [.text, .image, .image, .link, .link])
        XCTAssertEqual(items.map(\.name), ["Meeting notes- Monday - budget.txt", "chart.png", "Dropped Image.png", "example.com.webloc", "Example- Docs.webloc"])

        let text = try managedFile(items[0], in: transit)
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "  \nMeeting notes: Monday / budget\nsecond line")
        XCTAssertEqual(items[0].managedByteCount, Int64(try Data(contentsOf: text).count))
        XCTAssertEqual(try Data(contentsOf: try managedFile(items[1], in: transit)), png, "PNG data is kept as dropped")

        let converted = try Data(contentsOf: try managedFile(items[2], in: transit))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(converted as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, "TIFF is stored as PNG")

        let webloc = try Data(contentsOf: try managedFile(items[3], in: transit))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: webloc, format: nil) as? [String: String])
        XCTAssertEqual(plist["URL"], "https://www.example.com/page")
        XCTAssertEqual(items[3].linkURL, URL(string: "https://www.example.com/page"))
        XCTAssertEqual(transit.shelf.liveManagedBytes, items.reduce(0) { $0 + $1.managedByteCount })
    }

    func testEmptyTextUndecodableImagesAndFileLinksAreRejected() throws {
        let transit = service()
        let change = transit.add([.text(" \n\t"), .image(Data("not an image".utf8), typeIdentifier: nil, name: nil),
                                  .link(URL(fileURLWithPath: "/tmp"), title: nil)])
        XCTAssertEqual(change.failures, [.unsupportedItem, .unsupportedItem, .unsupportedItem])
        XCTAssertTrue(transit.shelf.items.isEmpty)
        let leftovers = (try? fm.contentsOfDirectory(atPath: transit.managedRootURL.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testReceivedFilesMoveFromIncomingIntoManagedStorage() throws {
        let transit = service()
        let incoming = try transit.repository.makeIncomingFolder()
        let received = incoming.appendingPathComponent("Invoice.pdf")
        try Data(repeating: 7, count: 300).write(to: received)

        let change = transit.add([.receivedFile(received)])
        XCTAssertTrue(change.failures.isEmpty)
        let item = try XCTUnwrap(transit.shelf.items.first)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.name, "Invoice.pdf")
        XCTAssertEqual(item.managedByteCount, 300)
        XCTAssertTrue(fm.fileExists(atPath: try managedFile(item, in: transit).path))
        XCTAssertFalse(fm.fileExists(atPath: incoming.path), "the emptied incoming folder is removed")
    }

    // MARK: Limits

    func testItemLimitAddsWhatFitsAndReportsTheRest() throws {
        let transit = service(limits(items: 3))
        let urls = try (1...5).map { try original("file\($0).txt") }
        let change = transit.add(urls.map { .file($0) })
        XCTAssertEqual(change.added.count, 3)
        XCTAssertEqual(change.failures, [.shelfFull, .shelfFull])
        XCTAssertEqual(transit.add([.text("more")]).failures, [.shelfFull])
        XCTAssertFalse(fm.fileExists(atPath: transit.managedRootURL.path), "nothing is written for content that does not fit")
    }

    func testImportAndStorageLimits() throws {
        let transit = service(limits(managed: 100, perImport: 60))
        XCTAssertEqual(transit.add([.text(String(repeating: "a", count: 61))]).failures, [.importLimitExceeded])
        XCTAssertTrue(transit.add([.text(String(repeating: "b", count: 60))]).failures.isEmpty)
        XCTAssertEqual(transit.add([.text(String(repeating: "c", count: 50))]).failures, [.managedStorageFull])
        XCTAssertTrue(transit.add([.text(String(repeating: "d", count: 40))]).failures.isEmpty)
        XCTAssertEqual(transit.shelf.liveManagedBytes, 100)

        // Received files over the import limit are deleted from the incoming folder.
        let incoming = try transit.repository.makeIncomingFolder()
        let big = incoming.appendingPathComponent("big.bin")
        try Data(count: 80).write(to: big)
        XCTAssertEqual(transit.add([.receivedFile(big)]).failures, [.importLimitExceeded])
        XCTAssertFalse(fm.fileExists(atPath: big.path))
    }

    func testStoragePressureDropsRestorableContentOldestFirst() throws {
        let transit = service(limits(managed: 100, perImport: 100))
        transit.add([.text(String(repeating: "a", count: 40))])
        transit.add([.text(String(repeating: "b", count: 40))])
        let first = transit.shelf.items[0], second = transit.shelf.items[1]
        transit.remove([first.id])
        transit.remove([second.id])
        XCTAssertEqual(transit.shelf.retainedManagedBytes, 80)

        // 50 new bytes only fit after the oldest removal's content is dropped; the newer one stays restorable.
        XCTAssertTrue(transit.add([.text(String(repeating: "c", count: 50))]).failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: try managedFile(first, in: transit).path))
        XCTAssertTrue(fm.fileExists(atPath: try managedFile(second, in: transit).path))
        XCTAssertEqual(transit.restoreRecentlyRemoved().restored, [second.id])
        XCTAssertEqual(transit.restoreRecentlyRemoved().failures, [.nothingToRestore])
    }

    // MARK: Stacks, locks and removal

    func testSeparateLockClearAndTransfer() throws {
        let transit = service()
        let a = try original("a.txt"), b = try original("b.txt"), c = try original("c.txt")
        transit.add([.file(a), .file(b)])
        transit.add([.file(c)])
        let stack = transit.shelf.items[0].stackID
        let ids = transit.shelf.items.map(\.id)

        XCTAssertTrue(transit.separate(stack).failures.isEmpty)
        XCTAssertEqual(transit.shelf.stacks.count, 3)
        XCTAssertEqual(transit.separate(stack).failures, [.stackMissing])

        XCTAssertTrue(transit.toggleLock(ids[0]).failures.isEmpty)
        XCTAssertTrue(transit.shelf.items[0].isLocked)
        XCTAssertEqual(transit.toggleLock(UUID()).failures, [.itemMissing])

        // A move drag or "Export & Clear" removes only the unlocked records it transferred.
        XCTAssertEqual(Set(transit.completeTransfer(of: [ids[0], ids[1]]).removed), [ids[1]])
        XCTAssertEqual(transit.shelf.items.map(\.id), [ids[0], ids[2]])

        XCTAssertEqual(transit.clearUnlocked().removed, [ids[2]])
        XCTAssertEqual(transit.shelf.items.map(\.id), [ids[0]])
        XCTAssertTrue(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path) && fm.fileExists(atPath: c.path),
                      "originals are never touched")
    }

    func testRemoveStackAndMissingTargets() throws {
        let transit = service()
        transit.add([.file(try original("x.txt")), .file(try original("y.txt"))])
        let stack = transit.shelf.items[0].stackID
        XCTAssertEqual(transit.removeStack(stack).removed.count, 2)
        XCTAssertEqual(transit.removeStack(stack).failures, [.stackMissing])
        XCTAssertEqual(transit.remove([UUID()]).failures, [.itemMissing])
    }

    func testRestorePutsRecordsBackWhereTheyWereNewestRemovalFirst() throws {
        let transit = service()
        let urls = try ["1", "2", "3", "4"].map { try original("\($0).txt") }
        transit.add(urls.map { .file($0) })
        let ids = transit.shelf.items.map(\.id)
        transit.remove([ids[1]])
        transit.remove([ids[0], ids[3]])
        XCTAssertEqual(transit.shelf.items.map(\.id), [ids[2]])

        XCTAssertEqual(Set(transit.restoreRecentlyRemoved().restored), [ids[0], ids[3]])
        XCTAssertEqual(transit.shelf.items.map(\.id), [ids[0], ids[2], ids[3]])
        XCTAssertEqual(transit.restoreRecentlyRemoved().restored, [ids[1]])
        XCTAssertEqual(transit.shelf.items.map(\.id), ids)
        XCTAssertFalse(transit.shelf.canRestore)
    }

    func testManagedContentIsDeletedOnlyWhenRecordsAreFinallyRemoved() throws {
        let transit = service(limits(batches: 2))
        transit.add([.text("first")])
        transit.add([.text("second")])
        transit.add([.text("third")])
        let items = transit.shelf.items
        let files = try items.map { try managedFile($0, in: transit) }

        transit.remove([items[0].id])
        XCTAssertTrue(fm.fileExists(atPath: files[0].path), "removed content stays while it can be restored")
        transit.remove([items[1].id])
        transit.remove([items[2].id])
        XCTAssertFalse(fm.fileExists(atPath: files[0].path), "content leaves disk once its record drops out of the history")
        XCTAssertFalse(fm.fileExists(atPath: files[0].deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: files[1].path))
        XCTAssertTrue(fm.fileExists(atPath: files[2].path))

        transit.restoreRecentlyRemoved()
        XCTAssertEqual(transit.shelf.items.map(\.id), [items[2].id])
        XCTAssertEqual(try String(contentsOf: files[2], encoding: .utf8), "third")
    }

    // MARK: Persistence

    func testShelfIsSavedAndReloadedWithItsRestoreHistory() throws {
        let file = try original("keep.txt")
        let first = service()
        first.add([.file(file), .text("hello"), .link(URL(string: "https://example.com")!, title: "Example")])
        first.toggleLock(first.shelf.items[0].id)
        first.remove([first.shelf.items[1].id])

        let second = service()
        XCTAssertNil(second.loadNotice)
        XCTAssertFalse(second.isReadOnly)
        XCTAssertEqual(second.shelf, first.shelf)
        XCTAssertTrue(second.shelf.items[0].isLocked)
        XCTAssertEqual(second.restoreRecentlyRemoved().restored.count, 1)
        XCTAssertEqual(try String(contentsOf: try managedFile(second.shelf.items[1], in: second), encoding: .utf8), "hello")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: second.repository.documentURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, FileTransitRepository.schemaVersion)
    }

    func testUnreadableDataRestoresAnEmptyShelfAndKeepsTheOldFileAside() throws {
        let repository = FileTransitRepository(rootURL: storage)
        try Data("{ not json".utf8).write(to: repository.documentURL)
        let transit = service()
        XCTAssertEqual(transit.loadNotice, .unreadableDataReplaced)
        XCTAssertTrue(transit.shelf.items.isEmpty)
        XCTAssertFalse(transit.isReadOnly)
        XCTAssertEqual(try String(contentsOf: repository.unreadableDocumentURL, encoding: .utf8), "{ not json")
        XCTAssertNil(service().loadNotice, "the replacement document reads cleanly next time")

        // A current header with a broken body is unreadable too.
        try Data(#"{"schemaVersion":1,"items":"oops"}"#.utf8).write(to: repository.documentURL)
        XCTAssertEqual(service().loadNotice, .unreadableDataReplaced)
    }

    func testNewerVersionDataIsLeftUntouchedAndTheShelfIsReadOnly() throws {
        let repository = FileTransitRepository(rootURL: storage)
        let original = Data(#"{"schemaVersion":2,"items":[{"future":true}]}"#.utf8)
        try original.write(to: repository.documentURL)
        let transit = service()
        XCTAssertEqual(transit.loadNotice, .newerVersion(2))
        XCTAssertTrue(transit.isReadOnly)
        XCTAssertTrue(transit.shelf.items.isEmpty)

        let incoming = try transit.repository.makeIncomingFolder()
        let received = incoming.appendingPathComponent("r.bin")
        try Data(count: 3).write(to: received)
        XCTAssertEqual(transit.add([.file(try self.original("a.txt")), .receivedFile(received)]).failures, [.readOnly])
        XCTAssertFalse(fm.fileExists(atPath: received.path))
        XCTAssertEqual(transit.clearUnlocked().failures, [.readOnly])
        XCTAssertEqual(transit.restoreRecentlyRemoved().failures, [.readOnly])
        XCTAssertEqual(try Data(contentsOf: repository.documentURL), original)
        XCTAssertFalse(fm.fileExists(atPath: repository.unreadableDocumentURL.path))
    }

    func testDamagedRecordsAreLeftOutWithANotice() throws {
        let repository = FileTransitRepository(rootURL: storage)
        let stack = UUID()
        let good = FileTransitItem(kind: .file, stackID: stack, addedAt: Date(), name: "ok.txt", originalPath: "/tmp/ok.txt")
        let escaping = FileTransitItem(kind: .text, stackID: stack, addedAt: Date(), name: "x.txt", managedPath: "../../x.txt")
        let relative = FileTransitItem(kind: .file, stackID: stack, addedAt: Date(), name: "rel", originalPath: "relative/path")
        let both = FileTransitItem(kind: .file, stackID: stack, addedAt: Date(), name: "both", originalPath: "/tmp/b",
                                   managedPath: "\(UUID().uuidString)/b")
        try repository.save(FileTransitShelf(items: [good, escaping, relative, both, good]))

        let transit = service()
        XCTAssertEqual(transit.loadNotice, .invalidRecordsDropped(4))
        XCTAssertEqual(transit.shelf.items, [good])
        XCTAssertNil(service().loadNotice)
    }

    func testLegacyRecordsAreAdoptedOnlyIntoAnEmptyShelf() throws {
        let transit = service()
        XCTAssertTrue(transit.startedWithoutDocument)
        let legacy = FileTransitItem(kind: .directory, stackID: UUID(), isLocked: true, addedAt: Date(), name: "Old", originalPath: "/tmp/Old")
        XCTAssertEqual(transit.adoptLegacyRecords([legacy]).added, [legacy.id])
        XCTAssertTrue(transit.adoptLegacyRecords([legacy]).added.isEmpty)
        XCTAssertFalse(service().startedWithoutDocument)
    }

    // MARK: Export

    func testExportCopiesWithConflictSafeNamesAndLeavesSourcesInPlace() throws {
        let file = try original("photo.jpg", "original")
        try Data("existing".utf8).write(to: exports.appendingPathComponent("photo.jpg"))
        try Data("existing 2".utf8).write(to: exports.appendingPathComponent("photo 2.jpg"))
        let folder = originals.appendingPathComponent("Album", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let transit = service()
        transit.add([.file(file), .file(folder), .text("Shopping list")])
        let missing = FileTransitItem(kind: .file, stackID: UUID(), addedAt: Date(), name: "gone.txt", originalPath: originals.appendingPathComponent("gone.txt").path)

        let items = transit.shelf.items + [missing]
        var progress: [Int] = []
        let report = FileTransitExporter.export(items, managedRoot: transit.managedRootURL, to: exports, progress: { done, _ in progress.append(done) })
        XCTAssertEqual(progress, [1, 2, 3, 4])
        XCTAssertEqual(report.destinations[items[0].id]?.lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(report.destinations[items[1].id]?.lastPathComponent, "Album")
        XCTAssertEqual(report.destinations[items[2].id]?.lastPathComponent, "Shopping list.txt")
        XCTAssertNotNil(report.failures[missing.id])
        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(try String(contentsOf: exports.appendingPathComponent("photo 3.jpg"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: exports.appendingPathComponent("photo.jpg"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: exports.appendingPathComponent("Album/inside.txt"), encoding: .utf8), "inside")
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertTrue(fm.fileExists(atPath: try managedFile(items[2], in: transit).path))

        // Exporting twice into the same folder keeps both copies.
        let again = FileTransitExporter.export([items[2]], managedRoot: transit.managedRootURL, to: exports)
        XCTAssertEqual(again.destinations[items[2].id]?.lastPathComponent, "Shopping list 2.txt")

        // "Export & Clear": exported, unlocked records leave the shelf.
        transit.toggleLock(items[1].id)
        XCTAssertEqual(Set(transit.completeTransfer(of: report.exportedIDs).removed), [items[0].id, items[2].id])
        XCTAssertEqual(transit.shelf.items.map(\.id), [items[1].id])
    }

    func testExportRefusesMissingDestinationsFoldersIntoThemselvesAndStopsWhenCancelled() throws {
        let folder = originals.appendingPathComponent("Parent", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let transit = service()
        transit.add([.file(folder), .file(try original("one.txt"))])
        let items = transit.shelf.items

        let notAFolder = FileTransitExporter.export(items, managedRoot: transit.managedRootURL, to: root.appendingPathComponent("nowhere"))
        XCTAssertEqual(notAFolder.failures.count, 2)

        let inside = folder.appendingPathComponent("Child", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        let selfExport = FileTransitExporter.export([items[0]], managedRoot: transit.managedRootURL, to: inside)
        XCTAssertNotNil(selfExport.failures[items[0].id])

        let cancelled = FileTransitExporter.export(items, managedRoot: transit.managedRootURL, to: exports, isCancelled: { true })
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertTrue(cancelled.destinations.isEmpty)
    }

    // MARK: Drag out

    func testDragPreparationOffersClonesSoOriginalsStayInPlace() throws {
        let file = try original("drag me.txt", "payload")
        let transit = service()
        transit.add([.file(file), .text("dragged text")])
        let missing = FileTransitItem(kind: .file, stackID: UUID(), addedAt: Date(), name: "x", originalPath: originals.appendingPathComponent("x").path)
        let items = transit.shelf.items + [missing]

        let preparation = FileTransitDragPreparer.prepare(items, managedRoot: transit.managedRootURL)
        XCTAssertEqual(preparation.unavailableIDs, [missing.id])
        XCTAssertEqual(preparation.files.map(\.itemID), [items[0].id, items[1].id])
        XCTAssertTrue(preparation.allowsMove, "the temporary folder is on an APFS volume")
        XCTAssertEqual(preparation.files[0].url.lastPathComponent, "drag me.txt")
        XCTAssertNotEqual(preparation.files[0].url.path, file.path)
        XCTAssertEqual(try String(contentsOf: preparation.files[0].url, encoding: .utf8), "payload")

        // A destination that moves the dragged file takes the clone, not the original.
        let moved = exports.appendingPathComponent("drag me.txt")
        try fm.moveItem(at: preparation.files[0].url, to: moved)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "payload")

        FileTransitDragPreparer.discard(preparation)
        XCTAssertTrue(preparation.temporaryFolders.allSatisfy { !fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertTrue(fm.fileExists(atPath: try managedFile(items[1], in: transit).path))
    }

    /// An app that opened a dropped clone in place and saved into it keeps its work: that clone is not discarded.
    func testDiscardKeepsClonesEditedAfterTheDrag() throws {
        let file = try original("edit me.txt", "before")
        let transit = service()
        transit.add([.file(file)])
        let preparation = FileTransitDragPreparer.prepare(transit.shelf.items, managedRoot: transit.managedRootURL)
        let clone = try XCTUnwrap(preparation.files.first?.url)
        try Data("after".utf8).write(to: clone)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: clone.path)
        FileTransitDragPreparer.discard(preparation)
        XCTAssertEqual(try String(contentsOf: clone, encoding: .utf8), "after")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        preparation.temporaryFolders.forEach { try? fm.removeItem(at: $0) }
    }
}
