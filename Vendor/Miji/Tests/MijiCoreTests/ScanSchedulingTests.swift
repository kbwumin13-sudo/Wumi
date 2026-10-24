import XCTest
import CSQLite
import CoreServices
@testable import MijiCore

/// Rescans confirm unchanged rows without rewriting them, and whole-root rescans
/// are requested per root and wait for their cool-down and for power.
final class ScanSchedulingTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var db: SearchDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-scan-\(UUID().uuidString)")
        source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "sub/c.txt"] { try write(name, name) }
        db = try SearchDatabase(url: directory.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("sub").path)
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: source.appendingPathComponent(path))
    }

    private func savedRoot() throws -> IndexedRoot {
        let root = try VolumeIdentity.root(for: source)
        try db.saveRoot(root)
        return root
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        XCTAssertTrue(try db.next(statement))
        return sqlite3_column_int64(statement, 0)
    }

    private func paths() throws -> [String] {
        let statement = try db.prepare("SELECT relative_path FROM files ORDER BY relative_path")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while try db.next(statement) { result.append(db.text(statement, 0)) }
        return result
    }

    private func id(_ path: String) throws -> Int64 {
        let statement = try db.prepare("SELECT id FROM files WHERE relative_path=?")
        defer { sqlite3_finalize(statement) }
        try db.bind([.string(path)], to: statement)
        XCTAssertTrue(try db.next(statement))
        return sqlite3_column_int64(statement, 0)
    }

    func testRescanOfUnchangedTreeWritesNoFileRows() throws {
        let root = try savedRoot()
        let scanner = FileScanner(database: db)
        XCTAssertTrue(try scanner.scan(root: root).complete)
        XCTAssertEqual(try paths(), ["a.txt", "b.txt", "sub", "sub/c.txt"])
        let generation = try scalar("SELECT max(generation) FROM files")
        let revision = try scalar("SELECT revision FROM catalog_state")
        try db.execute("""
            CREATE TEMP TABLE writes(n INTEGER);
            CREATE TEMP TRIGGER files_insert_probe AFTER INSERT ON files BEGIN INSERT INTO writes VALUES(1); END;
            CREATE TEMP TRIGGER files_update_probe AFTER UPDATE ON files BEGIN INSERT INTO writes VALUES(2); END;
            CREATE TEMP TRIGGER files_delete_probe AFTER DELETE ON files BEGIN INSERT INTO writes VALUES(3); END;
            CREATE TEMP TRIGGER metadata_insert_probe AFTER INSERT ON wumi_file_metadata BEGIN INSERT INTO writes VALUES(4); END;
            CREATE TEMP TRIGGER metadata_update_probe AFTER UPDATE ON wumi_file_metadata BEGIN INSERT INTO writes VALUES(5); END;
            """)
        for _ in 0..<2 { XCTAssertTrue(try scanner.scan(root: root).complete) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM writes"), 0)
        XCTAssertEqual(try scalar("SELECT max(generation) FROM files"), generation)
        XCTAssertEqual(try scalar("SELECT revision FROM catalog_state"), revision)
        XCTAssertNotNil(try db.roots().first?.lastScan)
    }

    func testRescanWritesOnlyChangesAndPrunesDeletedFiles() throws {
        let root = try savedRoot()
        let scanner = FileScanner(database: db)
        _ = try scanner.scan(root: root)
        let a = try id("a.txt"), c = try id("sub/c.txt")
        try write("a.txt", "a longer body")
        try write("d.txt", "new")
        try FileManager.default.removeItem(at: source.appendingPathComponent("b.txt"))
        let session = try scanner.session(root: root, relativePath: "", options: ScanOptions())
        XCTAssertTrue(try session.advance(cancelled: { false }, progress: { _ in }).complete)
        XCTAssertEqual(session.writes.inserted, 1)
        XCTAssertEqual(session.writes.updated, 1)
        XCTAssertEqual(session.writes.unchanged, 2)
        XCTAssertEqual(session.pruned, 1)
        XCTAssertEqual(try paths(), ["a.txt", "d.txt", "sub", "sub/c.txt"])
        XCTAssertEqual(try id("a.txt"), a)
        XCTAssertEqual(try id("sub/c.txt"), c)
        XCTAssertEqual(try scalar("SELECT size FROM files WHERE relative_path='a.txt'"), 13)
    }

    func testScopeScanPrunesOnlyInsideItsScope() throws {
        let root = try savedRoot()
        let scanner = FileScanner(database: db)
        _ = try scanner.scan(root: root)
        try FileManager.default.removeItem(at: source.appendingPathComponent("sub/c.txt"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("b.txt"))
        XCTAssertTrue(try scanner.scan(root: root, relativePath: "sub").complete)
        XCTAssertEqual(try paths(), ["a.txt", "b.txt", "sub"])
        // A deleted file's own path is a valid scope that removes just its row.
        XCTAssertTrue(try scanner.scan(root: root, relativePath: "b.txt").complete)
        XCTAssertEqual(try paths(), ["a.txt", "sub"])
    }

    func testUnreadableDirectoryKeepsItsRows() throws {
        let root = try savedRoot()
        let scanner = FileScanner(database: db)
        _ = try scanner.scan(root: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.appendingPathComponent("sub").path)
        let result = try scanner.scan(root: root)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.preservingPaths, ["sub"])
        XCTAssertEqual(try paths(), ["a.txt", "b.txt", "sub", "sub/c.txt"])
    }

    func testEventsRequestWholeRootRescansOnlyForTheirRoot() throws {
        let first = source.appendingPathComponent("sub").resolvingSymlinksInPath().path
        let second = directory.appendingPathComponent("other").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        var seeded = IncrementalIndexState()
        seeded.roots = ["first": .init(path: first, cursor: 10, pending: []), "second": .init(path: second, cursor: 10, pending: [])]
        try seeded.write(stateURL)
        let service = IndexService(database: db, extractor: { _, _ in ExtractedContent() }, watchEvents: false, stateURL: stateURL)
        defer { service.stopAndWait() }
        func entry(_ id: String) -> IncrementalIndexState.Root? { service.currentState.roots[id] }

        // A changed stream root (an ejected volume, say) concerns that root only.
        service.receiveEvents([FileChangeEvent(path: first, flags: UInt32(kFSEventStreamEventFlagRootChanged))])
        XCTAssertNotNil(entry("first")?.fullRescan)
        XCTAssertEqual(entry("first")?.fullRescan?.immediate, false)
        XCTAssertNil(entry("second")?.fullRescan)

        // Dropped events below a root rescan that subtree, not the whole root.
        let dropped = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs)
        service.receiveEvents([FileChangeEvent(path: second + "/deep/er", flags: dropped, id: 20)])
        XCTAssertEqual(entry("second")?.pending, ["deep/er"])
        XCTAssertNil(entry("second")?.fullRescan)

        // The root directory's own metadata event queues nothing; the cursor still advances.
        service.receiveEvents([FileChangeEvent(path: second, id: 30)])
        XCTAssertEqual(entry("second")?.pending, ["deep/er"])
        XCTAssertNil(entry("second")?.fullRescan)
        XCTAssertEqual(entry("second")?.cursor, 30)

        // Ordinary file events keep the per-path inbox.
        service.receiveEvents([FileChangeEvent(path: second + "/x.txt", id: 31)])
        XCTAssertEqual(entry("second")?.pending, ["deep/er", "x.txt"])

        // A recovery event that names no root still reconciles every root.
        service.receiveEvents([FileChangeEvent(path: directory.appendingPathComponent("elsewhere").path,
                                               flags: UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs), id: 40)])
        XCTAssertNotNil(entry("second")?.fullRescan)
        XCTAssertEqual(entry("second")?.pending, ["deep/er", "x.txt"], "整盘请求不会吞掉单独的路径队列")
    }

    func testLegacyInboxAndSavedTraversalBecomeAFullRequestPlusPaths() throws {
        let stateURL = directory.appendingPathComponent("legacy.json")
        var legacy = IncrementalIndexState()
        let checkpoint = FileScanCheckpoint(rootPath: source.path, scope: "", options: ScanOptions(), generation: 7, directories: ["sub"], currentDirectory: "", started: true, count: 3)
        legacy.roots = [
            "whole": .init(path: source.path, cursor: 5, pending: [""], inFlight: ["kept"], scan: checkpoint),
            "paths": .init(path: directory.path, cursor: 5, pending: ["p"], inFlight: [""]),
            "quiet": .init(path: directory.path, cursor: 5, pending: ["q"]),
        ]
        try legacy.write(stateURL)
        let service = IndexService(database: db, extractor: { _, _ in ExtractedContent() }, watchEvents: false, stateURL: stateURL)
        defer { service.stopAndWait() }
        let state = service.currentState
        XCTAssertEqual(state.roots["whole"]?.pending, ["kept"])
        XCTAssertEqual(state.roots["whole"]?.inFlight, [])
        XCTAssertNil(state.roots["whole"]?.scan)
        XCTAssertEqual(state.roots["whole"]?.fullRescan?.immediate, false)
        XCTAssertEqual(state.roots["paths"]?.pending, ["p"])
        XCTAssertNotNil(state.roots["paths"]?.fullRescan)
        XCTAssertNil(state.roots["quiet"]?.fullRescan)
        XCTAssertEqual(state.roots["quiet"]?.cursor, 5)
    }

    func testAutomaticWholeRootRescanWaitsForCooldownAndPower() throws {
        let root = try savedRoot()
        let stateURL = directory.appendingPathComponent("state.json")
        let power = PowerBox()
        let extracted = Counter()
        var preferences = IndexingPreferences()
        preferences.autoAddExternal = false
        func service(cooldown: TimeInterval) -> IndexService {
            let service = IndexService(database: db, extractor: { _, _ in extracted.increment(); return ExtractedContent(text: "正文") },
                                       watchEvents: false, stateURL: stateURL, fullRescanCooldown: cooldown,
                                       resources: { power.state })
            service.configure(preferences)
            return service
        }
        func settle(_ service: IndexService, _ condition: @escaping () throws -> Bool = { true }) throws {
            let deadline = Date().addingTimeInterval(15)
            Thread.sleep(forTimeInterval: 1.3)
            while Date() < deadline {
                if !service.isRunning, try condition() { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            XCTFail("index service did not settle")
        }

        // A new root is indexed immediately, content included.
        let first = service(cooldown: 3600)
        first.start()
        try settle(first) { try self.scalar("SELECT count(*) FROM files") == 4 && extracted.value >= 3 }
        XCTAssertNotNil(first.currentState.roots[root.id]?.lastFullScan)
        XCTAssertNil(first.currentState.roots[root.id]?.fullRescan)

        // Dropped events request a reconciliation, which waits for the cool-down,
        // while ordinary changes keep flowing.
        first.receiveEvents([FileChangeEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs))])
        try write("e.txt", "e")
        first.receiveEvents([FileChangeEvent(path: root.path + "/e.txt")])
        try settle(first) { try self.paths().contains("e.txt") }
        XCTAssertNotNil(first.currentState.roots[root.id]?.fullRescan)
        XCTAssertEqual(first.currentState.roots[root.id]?.inFlight, [])
        first.stopAndWait()

        // On battery: no automatic reconciliation and no extraction, but changes are still indexed.
        power.state = IndexResourceState(battery: true)
        let calls = extracted.value
        let second = service(cooldown: 0)
        second.start()
        try write("f.txt", "f")
        second.receiveEvents([FileChangeEvent(path: root.path + "/f.txt")])
        try settle(second) { try self.paths().contains("f.txt") }
        XCTAssertNotNil(second.currentState.roots[root.id]?.fullRescan)
        XCTAssertEqual(extracted.value, calls)

        // Back on power, the waiting reconciliation and the extraction run.
        power.state = IndexResourceState()
        let before = second.currentState.roots[root.id]?.lastFullScan ?? 0
        second.requestIncrementalUpdate()
        try settle(second) { (second.currentState.roots[root.id]?.lastFullScan ?? 0) > before && extracted.value > calls }
        XCTAssertNil(second.currentState.roots[root.id]?.fullRescan)
        second.stopAndWait()
    }

    func testAbandonedReconciliationKeepsQueuedPaths() throws {
        let root = try savedRoot()
        try write("queued.txt", "q")
        let stateURL = directory.appendingPathComponent("state.json")
        var seeded = IncrementalIndexState()
        seeded.roots = [root.id: .init(path: root.path, cursor: FSEventsGetCurrentEventId(), pending: ["queued.txt"])]
        seeded.requestFull(rootID: root.id, immediate: false, reason: "测试丢事件")
        try seeded.write(stateURL)
        // On power when the reconciliation starts, on battery right after.
        let checks = Counter()
        var preferences = IndexingPreferences()
        preferences.autoAddExternal = false
        let service = IndexService(database: db, extractor: { _, _ in ExtractedContent() }, watchEvents: false, stateURL: stateURL,
                                   fullRescanCooldown: 0, resources: { checks.increment(); return IndexResourceState(battery: checks.value > 1) },
                                   resourceCheckInterval: 0)
        service.configure(preferences)
        service.start()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, service.isRunning || (try? paths().contains("queued.txt")) != true {
            Thread.sleep(forTimeInterval: 0.05)
        }
        service.stopAndWait()
        XCTAssertEqual(try paths(), ["queued.txt"], "放弃的整盘扫描不能吞掉排队的路径")
        XCTAssertNotNil(service.currentState.roots[root.id]?.fullRescan)
        XCTAssertNil(service.currentState.roots[root.id]?.runningFull)
        XCTAssertNil(service.currentState.roots[root.id]?.lastFullScan)
    }

    func testInterruptedScanKeepsItsUrgencyAcrossRelaunch() throws {
        let stateURL = directory.appendingPathComponent("state.json")
        var saved = IncrementalIndexState()
        saved.roots = ["new": .init(path: source.path, cursor: 5, pending: [], inFlight: [""],
                                    runningFull: .init(requested: 1, immediate: true, reason: "首次建立索引")),
                       "auto": .init(path: directory.path, cursor: 5, pending: [], inFlight: [""],
                                     runningFull: .init(requested: 1, immediate: false, reason: "用户态丢事件"))]
        try saved.write(stateURL)
        let service = IndexService(database: db, extractor: { _, _ in ExtractedContent() }, watchEvents: false, stateURL: stateURL)
        defer { service.stopAndWait() }
        XCTAssertEqual(service.currentState.roots["new"]?.fullRescan?.immediate, true)
        XCTAssertEqual(service.currentState.roots["new"]?.fullRescan?.reason, "首次建立索引")
        XCTAssertEqual(service.currentState.roots["auto"]?.fullRescan?.immediate, false)
        XCTAssertNil(service.currentState.roots["new"]?.runningFull)
        XCTAssertEqual(service.currentState.roots["new"]?.inFlight, [])
    }

    func testInboxFoldsIntoDirectoriesButNeverIntoShallowAncestors() {
        // Three changed files in each of 3,000 directories: just enough of them fold
        // into their directory to fit the limit, and every change stays covered.
        let clustered = (0..<3_000).flatMap { i in (0..<3).map { "Users/me/Library/c\(i)/f\($0)" } }
        let folded = IndexRelativePath.compacting(clustered)
        XCTAssertLessThanOrEqual(folded.count, 8_192)
        XCTAssertTrue(folded.allSatisfy { $0.hasPrefix("Users/me/Library/c") && $0.split(separator: "/").count >= 4 })
        let cover = Set(folded)
        XCTAssertTrue(clustered.allSatisfy { cover.contains($0) || cover.contains(($0 as NSString).deletingLastPathComponent) })
        // One file in each of 9,000 directories cannot fold below four components:
        // the paths stay exact rather than becoming a scan of "Users/me" or "Users/me/Library".
        let scattered = (0..<9_000).map { "Users/me/Library/c\($0)/f" }
        let kept = IndexRelativePath.compacting(scattered)
        XCTAssertEqual(kept.count, 9_000)
        XCTAssertFalse(kept.contains { $0.split(separator: "/").count < 4 })
    }

    func testOverflowingInboxBecomesOneDeferredWholeRootRequest() {
        var state = IncrementalIndexState()
        state.roots = ["r": .init(path: "/", cursor: 1, pending: [])]
        state.enqueue((0..<(IncrementalIndexState.pendingCap + 10)).map { "Users/me/x\($0)/f" }, rootID: "r")
        XCTAssertEqual(state.roots["r"]?.pending, [])
        XCTAssertEqual(state.roots["r"]?.fullRescan?.immediate, false)
        XCTAssertEqual(state.roots["r"]?.fullRescan?.reason, "变更路径过多，改为整盘核对")
        XCTAssertEqual(state.announcements.count, 1)
        // A modest inbox only folds.
        state.enqueue(["Users/me/a/b/one", "Users/me/a/b/two"], rootID: "r")
        state.compactPending(above: 0)
        XCTAssertEqual(state.roots["r"]?.pending, ["Users/me/a/b/one", "Users/me/a/b/two"])
    }
}

private final class PowerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = IndexResourceState()
    var state: IndexResourceState {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
