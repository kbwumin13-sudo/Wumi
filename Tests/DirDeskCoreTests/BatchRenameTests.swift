import XCTest
@testable import DirDeskCore

final class BatchRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-rename-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every name in the folder, hidden temporaries included.
    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private func name(_ original: String, _ rules: [BatchRenameRule], index: Int = 0) throws -> String {
        try BatchRenameService.proposedName(for: original, at: index, rules: rules)
    }

    func testEachRule() throws {
        XCTAssertEqual(try name("photo.jpg", [.addPrefix("x-")]), "x-photo.jpg")
        XCTAssertEqual(try name("photo.jpg", [.addSuffix("-v2")]), "photo-v2.jpg")
        XCTAssertEqual(try name("Photo.jpg", [.replace(target: "o", replacement: "0")]), "Ph0t0.jpg")
        XCTAssertEqual(try name("photo.jpg", [.replace(target: "P", replacement: "p")]), "photo.jpg", "replace is case-sensitive")
        XCTAssertEqual(try name("a.b.jpg", [.replace(target: ".", replacement: "_")]), "a_b.jpg", "replace is literal and skips the extension")
        XCTAssertEqual(try name("12-abc.txt", [.regularExpression(pattern: "(\\d+)-(\\w+)", replacement: "$2-$1")]), "abc-12.txt")
        XCTAssertEqual(try name("notes.md", [.replaceExtension("txt")]), "notes.txt")
        XCTAssertEqual(try name("notes.md", [.replaceExtension(".TXT")]), "notes.TXT", "the leading dot is optional")
        XCTAssertEqual(try name("notes.md", [.replaceExtension("")]), "notes")
        XCTAssertEqual(try name("Makefile", [.replaceExtension("txt")]), "Makefile.txt")
        XCTAssertEqual(try name("photo.jpg", [.prependSequence(start: 1, width: 3, separator: "_")], index: 4), "005_photo.jpg")
        XCTAssertEqual(try name("photo.jpg", [.sequence(start: 9, width: 2, separator: " ")], index: 1), "photo 10.jpg")
        XCTAssertEqual(try name("photo.jpg", [.sequence(start: 1, width: 0, separator: "-")]), "photo-1.jpg")
        XCTAssertEqual(try name("PHOTO.JPG", [.lowercase]), "photo.JPG", "case rules leave the extension alone")
        XCTAssertEqual(try name("photo.jpg", [.uppercase]), "PHOTO.jpg")
    }

    func testRulesRunTopToBottom() throws {
        XCTAssertEqual(try name("x.txt", [.addPrefix("a"), .uppercase]), "AX.txt")
        XCTAssertEqual(try name("x.txt", [.uppercase, .addPrefix("a")]), "aX.txt")
        let chain: [BatchRenameRule] = [.replace(target: "draft", replacement: "final"), .sequence(start: 1, width: 2, separator: "_"),
                                        .replaceExtension("md")]
        XCTAssertEqual(try name("draft.txt", chain), "final_01.md")
    }

    /// The filled-in rules of the original's all-rule-types capture (the empty prefix, suffix, find and pattern rules
    /// are left out of its preview): an empty extension removes the extension and the number follows the name with "-".
    func testCapturedChainMatchesTheOriginalPreview() throws {
        let chain: [BatchRenameRule] = [.replaceExtension(""), .lowercase, .uppercase, .sequence(start: 1, width: 2, separator: "-")]
        XCTAssertEqual(try name("IMG_001.JPG", chain), "IMG_001-01")
        XCTAssertEqual(try name("IMG_008.JPG", chain, index: 7), "IMG_008-08")
        XCTAssertEqual(try name("IMG_001.JPG", [.addPrefix("Trip_")]), "Trip_IMG_001.JPG")
    }

    func testPlanNumbersItemsInTheGivenOrder() throws {
        let b = try write("b.jpg"), a = try write("a.png")
        let previews = try BatchRenameService.plan(sources: [b, a], rules: [.prependSequence(start: 1, width: 2, separator: " ")])
        XCTAssertEqual(previews.map(\.destinationName), ["01 b.jpg", "02 a.png"])
        XCTAssertEqual(previews.map(\.destination.lastPathComponent), ["01 b.jpg", "02 a.png"])
        XCTAssertTrue(previews.allSatisfy { $0.error == nil })
    }

    func testInvalidRegularExpressionThrows() throws {
        let a = try write("a.txt")
        XCTAssertThrowsError(try BatchRenameService.plan(sources: [a], rules: [.regularExpression(pattern: "(", replacement: "")])) {
            XCTAssertEqual($0 as? BatchRenameError, .invalidRegularExpression)
        }
    }

    func testInvalidNamesAreFlaggedAndBlockExecution() throws {
        let a = try write("abc")
        let invalid: [[BatchRenameRule]] = [[.replace(target: "b", replacement: "/")], [.addSuffix(":")],
                                            [.regularExpression(pattern: "^.*$", replacement: "")],
                                            [.regularExpression(pattern: "^.*$", replacement: "..")]]
        for rules in invalid {
            XCTAssertEqual(try BatchRenameService.plan(sources: [a], rules: rules).first?.error, .invalidName, "\(rules)")
        }
        XCTAssertThrowsError(try BatchRenameService.execute(BatchRenameService.plan(sources: [a], rules: [.addSuffix(":")]))) {
            XCTAssertEqual($0 as? BatchRenameError, .invalidPlan)
        }
        XCTAssertEqual(try names(), ["abc"])
    }

    func testUnchangedNamesAreNoOps() throws {
        let a = try write("a.txt", "A")
        let previews = try BatchRenameService.plan(sources: [a], rules: [.replace(target: "zzz", replacement: "y")])
        XCTAssertTrue(previews[0].isUnchanged)
        XCTAssertNil(previews[0].error)
        XCTAssertTrue(try BatchRenameService.execute(previews).operations.isEmpty)
        XCTAssertEqual(try names(), ["a.txt"])
    }

    func testDuplicateDestinationsCompareNFCAndIgnoreCase() throws {
        let one = try write("x1.txt"), two = try write("x2.txt"), three = try write("x3.txt")
        // x1 becomes a precomposed "CAFÉ", x2 a decomposed lowercase "café": one name on disk.
        let rules: [BatchRenameRule] = [.replace(target: "x1", replacement: "CAF\u{00C9}"), .replace(target: "x2", replacement: "cafe\u{0301}"),
                                        .replace(target: "x3", replacement: "other")]
        let previews = try BatchRenameService.plan(sources: [one, two, three], rules: rules)
        XCTAssertEqual(previews.map(\.error), [.duplicateDestination, .duplicateDestination, nil])
    }

    func testUnchangedItemsStillClaimTheirNames() throws {
        let a = try write("a.txt"), b = try write("b.txt")
        let previews = try BatchRenameService.plan(sources: [a, b], rules: [.replace(target: "b", replacement: "a")])
        XCTAssertTrue(previews[0].isUnchanged)
        XCTAssertEqual(previews.map(\.error), [.duplicateDestination, .duplicateDestination])
    }

    func testExistingDestinationIsFlagged() throws {
        let a = try write("a.txt")
        try write("x-a.txt", "existing")
        XCTAssertEqual(try BatchRenameService.plan(sources: [a], rules: [.addPrefix("x-")]).first?.error, .destinationExists)
    }

    func testCaseOnlyRename() throws {
        let foo = try write("Foo.txt", "content")
        let previews = try BatchRenameService.plan(sources: [foo], rules: [.lowercase])
        XCTAssertNil(previews[0].error, "on a case-insensitive volume foo.txt resolves to the item being renamed")
        XCTAssertEqual(previews[0].destinationName, "foo.txt")
        try BatchRenameService.execute(previews)
        XCTAssertEqual(try names(), ["foo.txt"])
        XCTAssertEqual(try read("foo.txt"), "content")
    }

    func testSwapAndCycleThenUndo() throws {
        try write("a.txt", "A")
        try write("b.txt", "B")
        let swap: [BatchRenameRule] = [.replace(target: "a", replacement: "tmp"), .replace(target: "b", replacement: "a"),
                                       .replace(target: "tmp", replacement: "b")]
        let previews = try BatchRenameService.plan(sources: [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")], rules: swap)
        XCTAssertEqual(previews.map(\.destinationName), ["b.txt", "a.txt"])
        XCTAssertTrue(previews.allSatisfy { $0.error == nil })
        let transaction = try BatchRenameService.execute(previews)
        XCTAssertEqual(try read("a.txt"), "B")
        XCTAssertEqual(try read("b.txt"), "A")
        try BatchRenameService.undo(transaction)
        XCTAssertEqual(try read("a.txt"), "A")
        XCTAssertEqual(try read("b.txt"), "B")

        try write("c.txt", "C")
        let cycle: [BatchRenameRule] = [.replace(target: "a", replacement: "x"), .replace(target: "b", replacement: "y"),
                                        .replace(target: "c", replacement: "z"), .replace(target: "x", replacement: "b"),
                                        .replace(target: "y", replacement: "c"), .replace(target: "z", replacement: "a")]
        let sources = ["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }
        try BatchRenameService.execute(BatchRenameService.plan(sources: sources, rules: cycle))
        XCTAssertEqual(try ["a.txt", "b.txt", "c.txt"].map { try self.read($0) }, ["C", "A", "B"])
        XCTAssertEqual(try names(), ["a.txt", "b.txt", "c.txt"])
    }

    func testDestinationAppearingAfterPlanningRollsEverythingBack() throws {
        let a = try write("a.txt", "A"), b = try write("b.txt", "B")
        let previews = try BatchRenameService.plan(sources: [a, b], rules: [.addPrefix("new-")])
        XCTAssertTrue(previews.allSatisfy { $0.error == nil })
        try write("new-b.txt", "intruder")
        XCTAssertThrowsError(try BatchRenameService.execute(previews)) {
            XCTAssertEqual($0 as? BatchRenameError, .destinationExists(previews[1].destination))
        }
        // new-a.txt was committed before the conflict and has been moved back; no temporary is left behind.
        XCTAssertEqual(try names(), ["a.txt", "b.txt", "new-b.txt"])
        XCTAssertEqual(try read("a.txt"), "A")
        XCTAssertEqual(try read("b.txt"), "B")
        XCTAssertEqual(try read("new-b.txt"), "intruder")
    }

    func testExecuteRechecksSources() throws {
        let a = try write("a.txt")
        let previews = try BatchRenameService.plan(sources: [a], rules: [.addSuffix("-1")])
        try FileManager.default.removeItem(at: a)
        XCTAssertThrowsError(try BatchRenameService.execute(previews)) {
            XCTAssertEqual($0 as? BatchRenameError, .sourceUnavailable(a))
        }
    }

    func testLimits() throws {
        XCTAssertEqual(BatchRenameLimits.default.maximumSelectionCount, 10_000)
        XCTAssertEqual(BatchRenameLimits.default.maximumPlanningDuration, 2.0)
        XCTAssertEqual(BatchRenameLimits.default.maximumExecutionDuration, 60.0)
        let a = try write("a.txt", "A"), b = try write("b.txt")
        XCTAssertThrowsError(try BatchRenameService.plan(sources: [a, b], rules: [.uppercase], limits: BatchRenameLimits(maximumSelectionCount: 1))) {
            XCTAssertEqual($0 as? BatchRenameError, .selectionLimitExceeded(count: 2, limit: 1))
        }
        XCTAssertThrowsError(try BatchRenameService.plan(sources: [a], rules: [.uppercase], limits: BatchRenameLimits(maximumPlanningDuration: -1))) {
            XCTAssertEqual($0 as? BatchRenameError, .elapsedTimeLimitExceeded)
        }
        let previews = try BatchRenameService.plan(sources: [a, b], rules: [.uppercase])
        XCTAssertThrowsError(try BatchRenameService.execute(previews, limits: BatchRenameLimits(maximumExecutedItems: 1))) {
            XCTAssertEqual($0 as? BatchRenameError, .itemLimitExceeded)
        }
        XCTAssertThrowsError(try BatchRenameService.execute(previews, limits: BatchRenameLimits(maximumExecutionDuration: -1))) {
            XCTAssertEqual($0 as? BatchRenameError, .elapsedTimeLimitExceeded)
        }
        XCTAssertEqual(try names(), ["a.txt", "b.txt"])
    }

    func testModelsRoundTripThroughJSON() throws {
        let rules: [BatchRenameRule] = [.addPrefix("a"), .addSuffix("b"), .replace(target: "c", replacement: "d"),
                                        .regularExpression(pattern: "(e)", replacement: "$1"), .replaceExtension("f"),
                                        .prependSequence(start: 1, width: 2, separator: "-"), .sequence(start: 3, width: 4, separator: "_"),
                                        .lowercase, .uppercase]
        let preset = BatchRenamePreset(name: "Everything", rules: rules)
        XCTAssertEqual(try JSONDecoder().decode(BatchRenamePreset.self, from: JSONEncoder().encode(preset)), preset)

        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let transaction = BatchRenameTransaction(createdAt: Date(timeIntervalSinceReferenceDate: 1000), operations: [.init(source: a, destination: b)])
        XCTAssertEqual(transaction.inverse.operations, [BatchRenameOperation(source: b, destination: a)])
        XCTAssertEqual(transaction.inverse.id, transaction.id)
        XCTAssertEqual(try JSONDecoder().decode(BatchRenameTransaction.self, from: JSONEncoder().encode(transaction)), transaction)
        let entry = BatchRenameLogEntry(transaction: transaction, outcome: .undone, elapsedTime: 0.25, date: Date(timeIntervalSinceReferenceDate: 2000))
        XCTAssertEqual(try JSONDecoder().decode(BatchRenameLogEntry.self, from: JSONEncoder().encode(entry)), entry)
    }
}
