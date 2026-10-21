import XCTest
@testable import DirDeskCore

final class FolderSyncTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-sync-tests-\(UUID().uuidString)", isDirectory: true)
        left = root.appendingPathComponent("Left", isDirectory: true)
        right = root.appendingPathComponent("Right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a file whose modification time is `base + modified` seconds.
    @discardableResult
    private func write(_ path: String, _ text: String, in folder: URL, modified: TimeInterval = 0) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(modified)], ofItemAtPath: url.path)
        return url
    }

    private func read(_ path: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    private func preset(_ direction: FolderSyncDirection, filters: [FolderSyncFilterRule] = [], hidden: Bool = false) -> FolderSyncPreset {
        FolderSyncPreset(name: "Test", leftURL: left, rightURL: right, direction: direction, includeHiddenItems: hidden, filters: filters)
    }

    private func actions(_ analysis: FolderSyncAnalysis) -> [String: FolderSyncAction] {
        Dictionary(uniqueKeysWithValues: analysis.items.map { ($0.relativePath, $0.action) })
    }

    func testOneWayCopyNeverDeletesAndKeepsModificationDates() throws {
        try write("a.txt", "a", in: left)
        try write("sub/b.txt", "b", in: left, modified: 10)
        try write("extra.txt", "only right", in: right)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateRight))
        XCTAssertEqual(actions(analysis), ["a.txt": .copyToRight, "sub": .copyToRight, "sub/b.txt": .copyToRight, "extra.txt": .skip])
        XCTAssertEqual([analysis.copyRightCount, analysis.copyLeftCount, analysis.updateCount, analysis.conflictCount], [3, 0, 0, 0])

        let summary = try FolderSyncService.apply(analysis)
        XCTAssertEqual(summary.outcome, .completed)
        XCTAssertEqual(summary.copiedToRightCount, 3)
        XCTAssertEqual(try read("sub/b.txt", in: right), "b")
        XCTAssertEqual(try read("extra.txt", in: right), "only right")
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("extra.txt").path))
        let copied = try right.appendingPathComponent("sub/b.txt").resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(copied.contentModificationDate, base.addingTimeInterval(10))
        XCTAssertEqual(Set(summary.baseline.entries.keys), ["a.txt", "sub/b.txt"])
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: right.path).filter { $0.contains(FolderSyncService.partialPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertFalse(try FolderSyncService.analyze(preset: preset(.updateRight)).hasChanges)
    }

    func testOneWayUpdatesUnlessTheUpdatedSideIsNewer() throws {
        try write("newer-left.txt", "new", in: left, modified: 100)
        try write("newer-left.txt", "old", in: right)
        try write("newer-right.txt", "old", in: left)
        try write("newer-right.txt", "new!", in: right, modified: 100)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateRight))
        XCTAssertEqual(actions(analysis), ["newer-left.txt": .updateRight, "newer-right.txt": .skip])
        XCTAssertEqual(analysis.updateCount, 1)
        _ = try FolderSyncService.apply(analysis)
        XCTAssertEqual(try read("newer-left.txt", in: right), "new")
        XCTAssertEqual(try read("newer-right.txt", in: right), "new!")
        XCTAssertEqual(actions(try FolderSyncService.analyze(preset: preset(.updateLeft))),
                       ["newer-left.txt": .skip, "newer-right.txt": .updateLeft])
    }

    func testModificationTimeTolerance() throws {
        try write("near.txt", "same", in: left)
        try write("near.txt", "same", in: right, modified: 1.5)
        try write("far.txt", "same", in: left, modified: 3)
        try write("far.txt", "same", in: right)
        var settings = preset(.updateRight)
        XCTAssertEqual(actions(try FolderSyncService.analyze(preset: settings)), ["near.txt": .skip, "far.txt": .updateRight])
        settings.modificationTimeTolerance = 5
        XCTAssertEqual(actions(try FolderSyncService.analyze(preset: settings)), ["near.txt": .skip, "far.txt": .skip])
    }

    func testTwoWayConflictWithoutBaseline() throws {
        try write("doc.txt", "left", in: left)
        try write("doc.txt", "right side", in: right, modified: 50)
        try write("only-left.txt", "l", in: left)
        try write("only-right.txt", "r", in: right)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateBoth))
        XCTAssertEqual(actions(analysis), ["doc.txt": .conflict, "only-left.txt": .copyToRight, "only-right.txt": .copyToLeft])
        XCTAssertEqual(analysis.conflicts.map(\.conflictReason), [.differentWithoutBaseline])
        XCTAssertThrowsError(try FolderSyncService.apply(analysis)) {
            XCTAssertEqual($0 as? FolderSyncError, .unresolvedConflicts)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("only-right.txt").path), "nothing runs before every conflict is decided")

        let summary = try FolderSyncService.apply(analysis, decisions: ["doc.txt": .keepLeft])
        XCTAssertEqual(summary.outcome, .completed)
        XCTAssertEqual([summary.copiedToLeftCount, summary.copiedToRightCount], [1, 2])
        XCTAssertEqual(try read("doc.txt", in: right), "left")
        XCTAssertEqual(try read("only-right.txt", in: left), "r")
        XCTAssertEqual(Set(summary.baseline.entries.keys), ["doc.txt", "only-left.txt", "only-right.txt"])
    }

    func testBaselineDecidesWhichSideChanged() throws {
        for folder in [left!, right!] {
            try write("doc.txt", "v1", in: folder)
            try write("notes.txt", "n1", in: folder)
            try write("plan.txt", "p1", in: folder)
        }
        let first = try FolderSyncService.apply(try FolderSyncService.analyze(preset: preset(.updateBoth)))
        XCTAssertEqual(first.baseline.entries.keys.sorted(), ["doc.txt", "notes.txt", "plan.txt"])

        try write("doc.txt", "v2 left", in: left, modified: 100)
        try write("doc.txt", "v2 right!", in: right, modified: 200)
        try write("notes.txt", "n2", in: right, modified: 100)
        try write("plan.txt", "p2", in: left, modified: 100)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateBoth), baseline: first.baseline)
        XCTAssertEqual(actions(analysis), ["doc.txt": .conflict, "notes.txt": .updateLeft, "plan.txt": .updateRight])
        XCTAssertEqual(analysis.conflicts.map(\.conflictReason), [.bothChanged])

        let summary = try FolderSyncService.apply(analysis, decisions: ["doc.txt": .skip])
        XCTAssertEqual(try read("notes.txt", in: left), "n2")
        XCTAssertEqual(try read("plan.txt", in: right), "p2")
        XCTAssertEqual(summary.baseline.entries["doc.txt"], first.baseline.entries["doc.txt"], "a skipped conflict keeps its old entry")
        XCTAssertEqual(summary.baseline.entries["notes.txt"]?.modificationDate, base.addingTimeInterval(100))
    }

    func testKeepBothKeepsEveryVersionOnBothSides() throws {
        try write("Report.txt", "older left", in: left)
        try write("Report.txt", "newer right", in: right, modified: 60)
        // "Memo 2" already exists on the right, so the keep-both name for "Memo" has to be free on both sides.
        try write("Memo", "memo left", in: left)
        try write("Memo", "memo right", in: right, modified: 10)
        try write("Memo 2", "unrelated", in: right)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateBoth))
        XCTAssertEqual(analysis.conflictCount, 2)

        let summary = try FolderSyncService.apply(analysis, decisions: ["Report.txt": .keepBoth, "Memo": .keepBoth])
        XCTAssertEqual(summary.outcome, .completed)
        for folder in [left!, right!] {
            XCTAssertEqual(try read("Report.txt", in: folder), "newer right")
            XCTAssertEqual(try read("Report 2.txt", in: folder), "older left")
            XCTAssertEqual(try read("Memo", in: folder), "memo right")
            XCTAssertEqual(try read("Memo 2", in: folder), "unrelated")
            XCTAssertEqual(try read("Memo 3", in: folder), "memo left")
        }
        XCTAssertFalse(try FolderSyncService.analyze(preset: preset(.updateBoth), baseline: summary.baseline).hasChanges)
    }

    func testTypeMismatchSettlesTheWholeFolder() throws {
        try write("x", "a file", in: left)
        try write("x/inner.txt", "inside", in: right)
        let oneWay = try FolderSyncService.analyze(preset: preset(.updateRight))
        XCTAssertEqual(oneWay.items.map(\.relativePath), ["x"], "the folder's contents are not listed separately")
        XCTAssertEqual(oneWay.items.first?.action, .skip)
        XCTAssertEqual(oneWay.items.first?.conflictReason, .typeMismatch)

        let twoWay = try FolderSyncService.analyze(preset: preset(.updateBoth))
        XCTAssertEqual(twoWay.conflicts.map(\.conflictReason), [.typeMismatch])
        // The folder was created just now, so it is newer and keeps the name; the file becomes "x 2" on both sides.
        let summary = try FolderSyncService.apply(twoWay, decisions: ["x": .keepBoth])
        XCTAssertEqual(summary.outcome, .completed)
        for folder in [left!, right!] {
            XCTAssertEqual(try read("x/inner.txt", in: folder), "inside")
            XCTAssertEqual(try read("x 2", in: folder), "a file")
        }
    }

    func testCaseCollisionsFromACaseSensitiveSide() {
        func file(_ path: String) -> FolderSyncEntry {
            FolderSyncEntry(relativePath: path, kind: .file, fingerprint: FolderSyncFingerprint(size: 1, modificationDate: base))
        }
        let leftEntries = [file("README"), file("readme"), file("other")]
        let twoWay = FolderSyncService.classify(left: leftEntries, right: [file("Readme")], direction: .updateBoth, baseline: nil, tolerance: 2,
                                                caseSensitiveMatching: false, leftCaseSensitive: true, rightCaseSensitive: false)
        XCTAssertEqual(twoWay.map(\.relativePath), ["README", "Readme", "other", "readme"])
        XCTAssertEqual(twoWay.filter { $0.conflictReason == .caseCollision }.map(\.action), [.conflict, .conflict, .conflict])
        XCTAssertEqual(twoWay.first { $0.relativePath == "other" }?.action, .copyToRight)

        let oneWay = FolderSyncService.classify(left: leftEntries, right: [], direction: .updateRight, baseline: nil, tolerance: 2,
                                                caseSensitiveMatching: false, leftCaseSensitive: true, rightCaseSensitive: false)
        XCTAssertEqual(oneWay.filter { $0.conflictReason == .caseCollision }.map(\.action), [.skip, .skip], "one-way runs never conflict")

        let bothSensitive = FolderSyncService.classify(left: leftEntries, right: [file("Readme")], direction: .updateBoth, baseline: nil,
                                                       tolerance: 2, caseSensitiveMatching: true, leftCaseSensitive: true, rightCaseSensitive: true)
        XCTAssertTrue(bothSensitive.allSatisfy { $0.conflictReason == nil }, "case-sensitive disks hold every spelling apart")
    }

    func testIncludeAndExcludeFilters() throws {
        for path in ["a.jpg", "b.txt", "docs/c.JPG", "docs/d.md", "node_modules/x.jpg", "text/only.txt"] {
            try write(path, path, in: left)
        }
        let photos = [FolderSyncFilterRule(kind: .include, target: .fileExtension, pattern: "jpg"),
                      FolderSyncFilterRule(kind: .exclude, target: .fileName, pattern: "node_modules")]
        XCTAssertEqual(try FolderSyncService.analyze(preset: preset(.updateRight, filters: photos)).items.map(\.relativePath),
                       ["a.jpg", "docs", "docs/c.JPG"], "folders without included files are dropped")

        let excludeWins = [FolderSyncFilterRule(kind: .include, target: .relativePath, pattern: "*"),
                           FolderSyncFilterRule(kind: .exclude, target: .relativePath, pattern: "/docs/*.md"),
                           FolderSyncFilterRule(kind: .exclude, target: .fileName, pattern: "?.txt")]
        XCTAssertEqual(try FolderSyncService.analyze(preset: preset(.updateRight, filters: excludeWins)).items.map(\.relativePath),
                       ["a.jpg", "docs", "docs/c.JPG", "node_modules", "node_modules/x.jpg", "text", "text/only.txt"])

        XCTAssertTrue(FolderSyncFilterRule(kind: .exclude, target: .fileExtension, pattern: ".JPG").matches(relativePath: "x/y.jpg"))
        XCTAssertFalse(FolderSyncFilterRule(kind: .exclude, target: .fileName, pattern: "").matches(relativePath: "anything"))
    }

    func testHiddenItemsAreSyncedOnlyWhenIncluded() throws {
        try write(".secret", "s", in: left)
        try write("visible.txt", "v", in: left)
        try write(".DS_Store", "finder", in: left)
        XCTAssertEqual(try FolderSyncService.analyze(preset: preset(.updateRight)).items.map(\.relativePath), ["visible.txt"])
        XCTAssertEqual(try FolderSyncService.analyze(preset: preset(.updateRight, hidden: true)).items.map(\.relativePath),
                       [".secret", "visible.txt"], ".DS_Store is never synced")
    }

    func testFolderValidation() throws {
        var settings = preset(.updateBoth)
        settings.rightURL = left
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: settings)) { XCTAssertEqual($0 as? FolderSyncError, .sameFolder) }

        let link = root.appendingPathComponent("LeftLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: left)
        settings.rightURL = link
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: settings)) { XCTAssertEqual($0 as? FolderSyncError, .sameFolder) }

        let inner = left.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        settings.rightURL = inner
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: settings)) { XCTAssertEqual($0 as? FolderSyncError, .nestedFolders) }
        settings.leftURL = inner
        settings.rightURL = left
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: settings)) { XCTAssertEqual($0 as? FolderSyncError, .nestedFolders) }

        let missing = root.appendingPathComponent("missing")
        settings.leftURL = left
        settings.rightURL = missing
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: settings)) { XCTAssertEqual($0 as? FolderSyncError, .folderMissing(missing)) }

        XCTAssertThrowsError(try FolderSyncService.validate(FolderSyncPreset(name: "  ", leftURL: left, rightURL: right))) {
            XCTAssertEqual($0 as? FolderSyncError, .invalidName)
        }
        XCTAssertNoThrow(try FolderSyncService.validate(preset(.updateBoth)))
    }

    func testChangesAfterAnalysisAreDetected() throws {
        try write("a.txt", "a", in: left)
        let analysis = try FolderSyncService.analyze(preset: preset(.updateRight))
        try write("a.txt", "changed", in: left, modified: 30)
        XCTAssertThrowsError(try FolderSyncService.apply(analysis)) { XCTAssertEqual($0 as? FolderSyncError, .staleAnalysis) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("a.txt").path))

        let fresh = try FolderSyncService.analyze(preset: preset(.updateRight))
        try write("a.txt", "appeared", in: right)
        XCTAssertThrowsError(try FolderSyncService.apply(fresh)) { XCTAssertEqual($0 as? FolderSyncError, .staleAnalysis) }
        XCTAssertEqual(try read("a.txt", in: right), "appeared")
    }

    func testLimitsAndCancellation() throws {
        try write("a.txt", "a", in: left)
        try write("b.txt", "b", in: left)
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: preset(.updateRight), limits: FolderSyncLimits(maximumItemCount: 1))) {
            XCTAssertEqual($0 as? FolderSyncError, .scanLimitExceeded)
        }
        XCTAssertThrowsError(try FolderSyncService.analyze(preset: preset(.updateRight), isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let analysis = try FolderSyncService.analyze(preset: preset(.updateRight))
        let summary = try FolderSyncService.apply(analysis, isCancelled: { true })
        XCTAssertEqual(summary.outcome, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: right.path), [])
    }

    func testScheduleNextRunDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let tuesday = date(2026, 10, 20, 8)
        XCTAssertNil(FolderSyncSchedule.off.nextRunDate(after: tuesday, calendar: calendar))

        let daily = FolderSyncSchedule(frequency: .daily, hour: 9, minute: 30)
        XCTAssertEqual(daily.nextRunDate(after: tuesday, calendar: calendar), date(2026, 10, 20, 9, 30))
        XCTAssertEqual(daily.nextRunDate(after: date(2026, 10, 20, 9, 30), calendar: calendar), date(2026, 10, 21, 9, 30), "strictly after")

        let weekly = FolderSyncSchedule(frequency: .weekly, hour: 8, minute: 0, weekday: 2)
        XCTAssertEqual(weekly.nextRunDate(after: tuesday, calendar: calendar), date(2026, 10, 26, 8))

        let monthly = FolderSyncSchedule(frequency: .monthly, hour: 6, minute: 15, dayOfMonth: 31)
        XCTAssertEqual(monthly.nextRunDate(after: tuesday, calendar: calendar), date(2026, 10, 31, 6, 15))
        XCTAssertEqual(monthly.nextRunDate(after: date(2026, 10, 31, 7), calendar: calendar), date(2026, 11, 30, 6, 15),
                       "a month without the day runs on its last day")
        XCTAssertEqual(monthly.nextRunDate(after: date(2027, 2, 1), calendar: calendar), date(2027, 2, 28, 6, 15))
    }

    func testPresetRoundTripsThroughJSON() throws {
        let saved = FolderSyncPreset(name: "Photos", leftURL: left, rightURL: right, direction: .updateBoth, includeHiddenItems: true,
                                     modificationTimeTolerance: 3, caseSensitivity: .sensitive,
                                     filters: [FolderSyncFilterRule(kind: .exclude, target: .fileExtension, pattern: "tmp")],
                                     schedule: FolderSyncSchedule(frequency: .weekly, hour: 22, minute: 5, weekday: 6),
                                     previewSyncDetails: false)
        XCTAssertEqual(try JSONDecoder().decode(FolderSyncPreset.self, from: JSONEncoder().encode(saved)), saved)
        XCTAssertEqual(FolderSyncPreset(name: "x", leftURL: left, rightURL: right).modificationTimeTolerance, 2)
    }

    func testPresetSavedBeforePreviewOptionDecodesWithPreviewOn() throws {
        let saved = FolderSyncPreset(name: "Old", leftURL: left, rightURL: right, previewSyncDetails: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "previewSyncDetails"))
        let decoded = try JSONDecoder().decode(FolderSyncPreset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.previewSyncDetails)
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertEqual(decoded.rightURL, right)
    }
}
