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

    func testManyYieldBoundariesKeepSeenRowsAndPruneOnlyAtCompletion() throws {
        let root=try savedRoot()
        let scanner=FileScanner(database:db)
        _ = try scanner.scan(root:root)
        let retained=try id("a.txt")
        try FileManager.default.removeItem(at:source.appendingPathComponent("b.txt"))
        for index in 0..<30 { try write("item\(index).txt","body") }
        let session=try scanner.session(root:root,relativePath:"",options:ScanOptions())
        var slices=0
        repeat {
            let result=try session.advance(cancelled:{ false },maximumItems:2,progress:{ _ in })
            slices += 1
            if !session.finished {
                XCTAssertFalse(result.complete)
                XCTAssertTrue(try paths().contains("b.txt"),"yield 不能提前 prune")
                XCTAssertNil(try db.roots().first?.lastError)
            }
            XCTAssertLessThan(slices,100)
        } while !session.finished && slices < 100
        XCTAssertGreaterThan(slices,10)
        XCTAssertEqual(try paths().count,33)
        XCTAssertFalse(try paths().contains("b.txt"))
        XCTAssertEqual(try id("a.txt"),retained)
        XCTAssertEqual(session.pruned,1)
    }

    func testWholePrunePreservesInterleavedScopeInsertAndScopePrunesDeletion() throws {
        let root=try savedRoot()
        let scanner=FileScanner(database:db)
        _ = try scanner.scan(root:root)
        try FileManager.default.removeItem(at:source.appendingPathComponent("b.txt"))
        let whole=try scanner.session(root:root,relativePath:"",options:ScanOptions())
        // Suspend exactly after the traversal, before its final prune. The live
        // session must retain its seen set across this and later local scans.
        let result=try whole.advance(cancelled:{
            whole.checkpoint.started && whole.checkpoint.currentDirectory == nil && whole.checkpoint.directories.isEmpty
        },progress:{ _ in })
        XCTAssertFalse(result.complete)
        XCTAssertFalse(whole.finished)
        try FileManager.default.removeItem(at:source.appendingPathComponent("sub/c.txt"))
        try write("sub/after.txt","new after whole traversal")
        whole.preserveReconciledScope("sub")
        XCTAssertTrue(try scanner.scan(root:root,relativePath:"sub").complete)
        XCTAssertTrue(try whole.advance(cancelled:{ false },progress:{ _ in }).complete)
        XCTAssertEqual(try paths(),["a.txt","sub","sub/after.txt"])
        XCTAssertEqual(whole.pruned,1,"整盘仍然会删除局部范围之外的过期行")
    }

    func testScheduledSlicesFinishContentWithoutCancellingValidExtractionAndThenStayIdle() throws {
        let root=try savedRoot()
        for index in 0..<20 { try write("item\(index).txt","body") }
        let scheduler=ManualIndexScheduler()
        let clock=SliceClock()
        var policy=scheduler.policy(clock:clock)
        policy.metadataItems=2
        let calls=Counter()
        var service:IndexService!
        service=IndexService(database:db,extractor:{ _,cancelled in
            calls.increment()
            // A long OCR is allowed to cross the deadline and finish. Typing
            // affects the next batch, not the current result's validity.
            clock.advance(10)
            if calls.value == 1 { service.setUserActive(true) }
            XCTAssertFalse(cancelled())
            return ExtractedContent(text:"finished")
        },contentClock:{ clock.now },watchEvents:false,resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait();service=nil }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(calls.value,1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE content_state='done'"),1)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(scheduler.pendingCount,0,"输入期间不应轮询")
        service.setUserActive(false)
        var turns=0
        while scheduler.runNext(),turns < 200 { turns += 1 }
        XCTAssertLessThan(turns,200)
        XCTAssertGreaterThan(turns,10)
        XCTAssertEqual(try paths().count,24)
        XCTAssertEqual(calls.value,23)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE content_state='pending'"),0)
        XCTAssertNotNil(service.currentState.roots[root.id]?.lastFullScan)
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(scheduler.delays.contains { $0 == policy.continuationDelay })
        let enqueued=scheduler.enqueueCount
        XCTAssertFalse(scheduler.runNext())
        XCTAssertEqual(scheduler.enqueueCount,enqueued,"静止状态不应安排空转 continuation")
    }

    func testLocalEventsAndManualRefreshProgressWhileWholeScanYields() throws {
        let root=try savedRoot()
        for index in 0..<40 { try write("item\(index).txt","body") }
        let stateURL=directory.appendingPathComponent("state.json")
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:[])
        state.requestFull(rootID:root.id,immediate:false,reason:"automatic test")
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock()
        var policy=scheduler.policy(clock:clock);policy.metadataItems=1
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertNotNil(service.currentState.roots[root.id]?.runningFull)
        try write("urgent.txt","urgent")
        service.receiveEvents([FileChangeEvent(path:source.appendingPathComponent("urgent.txt").path)])
        service.requestIncrementalUpdate()
        XCTAssertTrue(scheduler.runNext())
        XCTAssertTrue(try paths().contains("urgent.txt"),"局部更新在下一个轮次即可处理")
        XCTAssertNotNil(service.currentState.roots[root.id]?.runningFull)
        service.requestScan()
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(service.currentState.roots[root.id]?.runningFull?.immediate,true)
        var turns=0
        while scheduler.runNext(),turns < 200 { turns += 1 }
        XCTAssertLessThan(turns,200)
        XCTAssertNotNil(service.currentState.roots[root.id]?.lastFullScan)
        XCTAssertEqual(try paths().count,45)
        XCTAssertTrue(try paths().contains("urgent.txt"),"整盘 prune 不能误删局部新增")
    }

    func testShortExactScopesDrainWithinOneSliceAndShareOneBudgetAcrossRoots() throws {
        let first=try savedRoot()
        let other=directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let second=try VolumeIdentity.root(for:other)
        try db.saveRoot(second)
        let pending=(0..<100).map { "event\($0).txt" }
        for path in pending {
            try write(path,"first")
            try Data("second".utf8).write(to:other.appendingPathComponent(path))
        }
        let stateURL=directory.appendingPathComponent("many-scopes.json")
        var state=IncrementalIndexState()
        for root in [first,second] { state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:pending) }
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=12
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"),12,"条数预算必须由所有根和scope共享")
        XCTAssertEqual(service.currentState.roots[first.id]?.pending.count,94)
        XCTAssertEqual(service.currentState.roots[second.id]?.pending.count,94)
        XCTAssertEqual(service.currentState.roots[first.id]?.inFlight,[])
        XCTAssertEqual(service.currentState.roots[second.id]?.inFlight,[])
        var turns=0
        while scheduler.runNext(),turns < 30 { turns += 1 }
        XCTAssertLessThan(turns,30)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files"),200)
        XCTAssertFalse(service.isRunning)
    }

    func testMixedWholeAndExactScopesBothProgressWithinOneGlobalSliceBudget() throws {
        let root=try savedRoot()
        let pending=(0..<100).map { "event\($0).txt" }
        for path in pending { try write(path,"event") }
        let stateURL=directory.appendingPathComponent("mixed-scopes.json")
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:pending)
        state.requestFull(rootID:root.id,immediate:false,reason:"mixed test")
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=20
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var wholeCount=0
        service.onProgress={ progress in if progress.phase == "正在建立文件目录" { wholeCount=max(wholeCount,progress.processed) } }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(wholeCount,10)
        XCTAssertEqual(service.currentState.roots[root.id]?.pending.count,90,"同片应完成10个精确局部scope")
        XCTAssertNotNil(service.currentState.roots[root.id]?.runningFull)
        XCTAssertEqual(service.currentState.roots[root.id]?.inFlight,[""])
        XCTAssertTrue(scheduler.runNext())
        XCTAssertGreaterThan(wholeCount,10,"连续局部事件不能饿死全盘扫描")
        XCTAssertLessThanOrEqual(service.currentState.roots[root.id]?.pending.count ?? 100,80)
        var turns=0
        while scheduler.runNext(),turns < 50 { turns += 1 }
        XCTAssertLessThan(turns,50)
        XCTAssertEqual(try paths().count,104)
        XCTAssertNotNil(service.currentState.roots[root.id]?.lastFullScan)
    }

    func testMultipleWholeRootsShareQuotaAndRotateWithoutStarvingLocalScopes() throws {
        let first=try savedRoot()
        let other=directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let second=try VolumeIdentity.root(for:other)
        try db.saveRoot(second)
        let pending=(0..<100).map { "event\($0).txt" }
        for path in pending {
            try write(path,"first")
            try Data("second".utf8).write(to:other.appendingPathComponent(path))
        }
        let stateURL=directory.appendingPathComponent("multiple-whole.json")
        var state=IncrementalIndexState()
        for root in [first,second] {
            state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:pending)
            state.requestFull(rootID:root.id,immediate:false,reason:"multi whole test")
        }
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=20
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var wholeCounts:[String:Int]=[:]
        service.onProgress={ progress in
            if progress.phase == "正在建立文件目录" { wholeCounts[progress.detail]=max(wholeCounts[progress.detail] ?? 0,progress.processed) }
        }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(wholeCounts.values.reduce(0,+),10,"多个全盘根必须共享半片预算")
        XCTAssertEqual(service.currentState.roots.values.reduce(0) { $0+$1.pending.count },190,"剩余10项预算应处理局部scope")
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(wholeCounts.values.filter { $0 > 0 }.count,2,"下片必须轮到另一个全盘根")
        XCTAssertEqual(service.currentState.roots.values.reduce(0) { $0+$1.pending.count },180)
    }

    func testShortScopeDrainStopsAtInjectedClockDeadline() throws {
        let root=try savedRoot()
        let pending=(0..<100).map { "event\($0).txt" }
        for path in pending { try write(path,"event") }
        let stateURL=directory.appendingPathComponent("timed-scopes.json")
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:pending)
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0.001)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=100;policy.metadataSeconds=0.01
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        let completed=try scalar("SELECT count(*) FROM files")
        XCTAssertGreaterThan(completed,1)
        XCTAssertLessThan(completed,10,"不能在循环中重置每个scope的截止时间")
        XCTAssertEqual(Int(completed)+(service.currentState.roots[root.id]?.pending.count ?? 0),100)
        XCTAssertEqual(scheduler.pendingCount,1)
    }

    func testLargeLocalContinuationDoesNotFlushEventInboxEverySliceButStopSavesReplay() throws {
        let root=try savedRoot()
        let large=source.appendingPathComponent("000-large")
        try FileManager.default.createDirectory(at:large,withIntermediateDirectories:true)
        for index in 0..<100 { try Data("body".utf8).write(to:large.appendingPathComponent("file\(index).txt")) }
        let stateURL=directory.appendingPathComponent("batched-events.json")
        var state=IncrementalIndexState()
        let backlog=(0..<8_100).map { "Users/me/events\($0)/document.txt" }
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:["000-large"]+backlog)
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=2
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(service.currentState.roots[root.id]?.inFlight,["000-large"])
        let durable=try Data(contentsOf:stateURL)
        for index in 0..<8 {
            service.receiveEvents([FileChangeEvent(path:source.appendingPathComponent("arrival\(index).txt").path)])
            XCTAssertTrue(scheduler.runNext())
            XCTAssertEqual(try Data(contentsOf:stateURL),durable,"续片不得提前flush原本应批量保存的事件")
        }
        XCTAssertEqual(service.currentState.roots[root.id]?.pending.count,8_108)
        service.stopAndWait()
        XCTAssertNotEqual(try Data(contentsOf:stateURL),durable)
        var replay=IncrementalIndexState.read(stateURL)
        replay.migrateInterruptedScans()
        let replayPaths=Set(replay.roots[root.id]?.pending ?? [])
        XCTAssertTrue(replayPaths.contains("000-large"),"停止后必须重放未完成局部扫描")
        XCTAssertTrue(Set(backlog).isSubset(of:replayPaths))
        for index in 0..<8 { XCTAssertTrue(replayPaths.contains("arrival\(index).txt")) }
    }

    func testActualRootAdditionImmediatelyPersistsWhileLocalScanIsSuspended() throws {
        let root=try savedRoot()
        let large=source.appendingPathComponent("000-large")
        try FileManager.default.createDirectory(at:large,withIntermediateDirectories:true)
        for index in 0..<20 { try Data("body".utf8).write(to:large.appendingPathComponent("file\(index).txt")) }
        let stateURL=directory.appendingPathComponent("new-root.json")
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:["000-large"])
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock(step:0)
        var policy=scheduler.policy(clock:clock);policy.metadataItems=1
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        let other=directory.appendingPathComponent("new-root")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        var newRoot=try VolumeIdentity.root(for:other)
        newRoot.enabled=false // Keep nextScope from writing on behalf of this root.
        try db.saveRoot(newRoot)
        service.receiveEvents([FileChangeEvent(path:source.appendingPathComponent("arrival.txt").path)])
        XCTAssertTrue(scheduler.runNext())
        let durable=IncrementalIndexState.read(stateURL)
        XCTAssertEqual(durable.roots[newRoot.id]?.path,newRoot.path)
        XCTAssertEqual(durable.roots[newRoot.id]?.fullRescan?.immediate,true)
        XCTAssertEqual(durable.roots[root.id]?.pending,["arrival.txt"])
        XCTAssertEqual(durable.roots[root.id]?.inFlight,["000-large"])
    }

    func testStopAndWaitCancelsScheduledContinuationWithoutWaitingForItsDelay() throws {
        _ = try savedRoot()
        let scheduler=ManualIndexScheduler(),clock=SliceClock()
        var policy=scheduler.policy(clock:clock);policy.metadataItems=1;policy.continuationDelay=3600
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,
                                 resources:{ IndexResourceState() },scheduling:policy)
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.images=false;prefs.documents=false
        service.configure(prefs)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertTrue(service.isRunning)
        let started=ProcessInfo.processInfo.systemUptime
        service.stopAndWait()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,1)
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(scheduler.runNext())
    }

    func testStopAndWaitCancelsActiveExtractionAtItsCancellationBoundary() throws {
        _ = try savedRoot()
        let entered=expectation(description:"extractor entered")
        let exited=Counter()
        let service=IndexService(database:db,extractor:{ _,cancelled in
            entered.fulfill()
            while !cancelled() { Thread.sleep(forTimeInterval:0.001) }
            exited.increment()
            throw CancellationError()
        },watchEvents:false,resources:{ IndexResourceState() })
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        wait(for:[entered],timeout:3)
        let start=ProcessInfo.processInfo.systemUptime
        service.stopAndWait()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1)
        XCTAssertEqual(exited.value,1)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE content_state='done'"),0)
    }

    func testContentNotificationsFollowCommittedSuccessOrFailureOnly() throws {
        _ = try savedRoot()
        let scheduler=ManualIndexScheduler(),clock=SliceClock(),notifications=Counter()
        let service=IndexService(database:db,extractor:{url,_ in
            if url.lastPathComponent=="a.txt" {throw SearchDatabaseError(message:"fixture extraction failure")}
            return ExtractedContent(text:"fresh indexed body")
        },watchEvents:false,resources:{IndexResourceState()},scheduling:scheduler.policy(clock:clock))
        defer {service.stopAndWait()}
        service.onContentChange={notifications.increment()}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        var turns=0
        while scheduler.runNext(),turns<100 {turns += 1}
        XCTAssertLessThan(turns,100)
        XCTAssertEqual(notifications.value,3)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE content_state='error'"),1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM files WHERE content_state='done'"),2)
        prefs.documents=false;prefs.images=false;service.configure(prefs)
        service.receiveEvents([FileChangeEvent(path:source.appendingPathComponent("sub").path)])
        turns=0
        while scheduler.runNext(),turns<100 {turns += 1}
        XCTAssertLessThan(turns,100)
        XCTAssertEqual(notifications.value,3,"Unchanged metadata scans do not invalidate content queries")
    }

    func testUnchangedYieldedScanDoesNotAnnounceCatalogChanges() throws {
        let root=try savedRoot()
        _ = try FileScanner(database:db).scan(root:root)
        let stateURL=directory.appendingPathComponent("quiet-state.json")
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FSEventsGetCurrentEventId(),pending:[])
        state.requestFull(rootID:root.id,immediate:false,reason:"unchanged scan")
        try state.write(stateURL)
        let scheduler=ManualIndexScheduler(),clock=SliceClock()
        var policy=scheduler.policy(clock:clock);policy.metadataItems=1
        let service=IndexService(database:db,extractor:{ _,_ in ExtractedContent() },watchEvents:false,stateURL:stateURL,
                                 resources:{ IndexResourceState() },scheduling:policy)
        defer { service.stopAndWait() }
        let catalog=Counter(),changes=Counter()
        service.onIndexChange={ _ in catalog.increment() }
        service.onChange={ changes.increment() }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        service.configure(prefs)
        var turns=0
        while scheduler.runNext(),turns < 50 { turns += 1 }
        XCTAssertLessThan(turns,50)
        XCTAssertGreaterThan(turns,1)
        XCTAssertEqual(catalog.value,0)
        XCTAssertEqual(changes.value,0)
        XCTAssertNotNil(service.currentState.roots[root.id]?.lastFullScan)
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

private final class SliceClock: @unchecked Sendable {
    private let lock=NSLock()
    private var value:TimeInterval=0
    private let step:TimeInterval
    init(step:TimeInterval = 0.01) { self.step=step }
    var now:TimeInterval { lock.lock();defer { lock.unlock() };value += step;return value }
    func advance(_ seconds:TimeInterval) { lock.lock();value += seconds;lock.unlock() }
}

private final class ManualIndexScheduler: @unchecked Sendable {
    private let lock=NSLock()
    private var items:[(DispatchQueue,DispatchWorkItem)]=[]
    private(set) var delays:[TimeInterval]=[]
    var enqueueCount:Int { lock.lock();defer { lock.unlock() };return delays.count }
    var pendingCount:Int { lock.lock();defer { lock.unlock() };return items.filter { !$0.1.isCancelled }.count }
    func policy(clock:SliceClock) -> IndexWorkScheduling {
        var policy=IndexWorkScheduling()
        policy.now={ clock.now }
        policy.enqueue={ [self] queue,delay,item in
            lock.lock();items.append((queue,item));delays.append(delay);lock.unlock()
        }
        return policy
    }
    @discardableResult func runNext() -> Bool {
        let next:(DispatchQueue,DispatchWorkItem)?={
            lock.lock();defer { lock.unlock() }
            while !items.isEmpty {
                let item=items.removeFirst()
                if !item.1.isCancelled { return item }
            }
            return nil
        }()
        guard let (queue,item)=next else { return false }
        queue.sync { item.perform() }
        return true
    }
}
