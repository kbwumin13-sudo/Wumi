import XCTest
import MijiCore
@testable import DirDeskCore

final class MijiHostConfigurationTests: XCTestCase {
    func testLatestConfigurationBeforeStartWinsOverLaunchSnapshot() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite")
        _ = try SearchDatabase(url:url)
        let host=try MijiIndexHost(databaseURL:url,readOnly:true)
        defer {host.shutdown()}
        let snapshot=IndexingPreferences()
        var latest=snapshot;latest.retainOffline=false
        host.configure(latest)
        try host.start(watchedFolders:[],ignoredFolders:[],preferences:snapshot)
        XCTAssertFalse(host.engine.retainsOffline)
        latest.retainOffline=true;host.configure(latest)
        XCTAssertTrue(host.engine.retainsOffline)
    }

    func testExplicitFolderUpdateDoesNotEnableAnIndependentlyDisabledRoot() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite")
        let db=try SearchDatabase(url:url)
        let old=directory.appendingPathComponent("old"),disabled=directory.appendingPathComponent("disabled"),added=directory.appendingPathComponent("added")
        for path in [old,disabled,added] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
        try db.saveRoot(IndexedRoot(id:"old",path:old.path))
        try db.saveRoot(IndexedRoot(id:"disabled",path:disabled.path,enabled:false))
        let host=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"))
        defer {host.shutdown()}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
        host.configure(prefs)
        try host.start(watchedFolders:[disabled.path,added.path],ignoredFolders:[],updateRoots:true)
        let roots=try host.roots()
        XCTAssertEqual(roots.first(where:{$0.id=="old"})?.enabled,false)
        XCTAssertEqual(roots.first(where:{$0.id=="disabled"})?.enabled,false)
        XCTAssertEqual(roots.first(where:{$0.path==added.path})?.enabled,true)
    }
    func testFolderListRoundTripAcrossHostsRestoresOnlyListDisabledRoots() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),a=directory.appendingPathComponent("A"),b=directory.appendingPathComponent("B")
        for path in [a,b] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
        let db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"A",path:a.path))
        try db.saveRoot(IndexedRoot(id:"manual",path:directory.appendingPathComponent("manual").path,enabled:false))
        var persisted=Set<String>()
        func launch(_ paths:[String]) throws -> MijiIndexHost {
            let host=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"))
            var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false
            host.configure(prefs)
            try host.start(watchedFolders:paths,ignoredFolders:[],updateRoots:true,listDisabledRootIDs:persisted,persistListDisabledRootIDs:{persisted=$0})
            return host
        }
        let first=try launch([b.path]);first.shutdown()
        XCTAssertTrue(persisted.contains("A"));XCTAssertFalse(persisted.contains("manual"))
        let second=try launch([a.path,directory.appendingPathComponent("manual").path]);second.shutdown()
        XCTAssertEqual(try db.roots().first(where:{$0.id=="A"})?.enabled,true)
        XCTAssertEqual(try db.roots().first(where:{$0.id=="manual"})?.enabled,false)
        XCTAssertFalse(persisted.contains("A"))
        let third=try launch([b.path])
        let switched=expectation(description:"explicit root switch")
        third.setRootEnabled(id:"A",enabled:false) {error in XCTAssertNil(error);switched.fulfill()}
        wait(for:[switched],timeout:3);third.shutdown()
        XCTAssertFalse(persisted.contains("A"),"An independent false switch clears the list-removal source")
        let fourth=try launch([a.path]);fourth.shutdown()
        XCTAssertEqual(try db.roots().first(where:{$0.id=="A"})?.enabled,false)
    }

    func testFolderSourcePersistenceFailureDoesNotOverrideIndependentDisableAfterRestart() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),a=directory.appendingPathComponent("A"),b=directory.appendingPathComponent("B")
        for path in [a,b] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
        let db=try SearchDatabase(url:url);try db.saveRoot(IndexedRoot(id:"A",path:a.path))
        let host=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"))
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false;prefs.images=false;host.configure(prefs)
        XCTAssertThrowsError(try host.start(watchedFolders:[b.path],ignoredFolders:[],updateRoots:true,listDisabledRootIDs:[],persistListDisabledRootIDs:{_ in throw SearchDatabaseError(message:"fixture preference failure")}))
        XCTAssertEqual(try db.roots().first?.enabled,true,"No DB disable occurs before its source is saved")
        host.shutdown()
        var persisted:Set<String>=["A"]
        var root=try db.roots().first!;root.enabled=false;try db.saveRoot(root)
        let retry=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"));retry.configure(prefs)
        XCTAssertThrowsError(try retry.start(watchedFolders:[a.path],ignoredFolders:[],updateRoots:true,listDisabledRootIDs:persisted,persistListDisabledRootIDs:{_ in throw SearchDatabaseError(message:"fixture post-restore failure")}))
        XCTAssertEqual(try db.roots().first?.enabled,true,"Restore commits before source removal")
        retry.shutdown()
        // A subsequent explicit choice removes the stale source before another launch.
        let next=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"));next.configure(prefs)
        try next.start(watchedFolders:[b.path],ignoredFolders:[],updateRoots:true,listDisabledRootIDs:persisted,persistListDisabledRootIDs:{persisted=$0})
        let switched=expectation(description:"explicit disable after retry")
        next.setRootEnabled(id:"A",enabled:false) {error in XCTAssertNil(error);switched.fulfill()}
        wait(for:[switched],timeout:3);next.shutdown()
        XCTAssertFalse(persisted.contains("A"))
        let final=try MijiIndexHost(databaseURL:url,extractionWorker:URL(fileURLWithPath:"/usr/bin/true"));final.configure(prefs)
        try final.start(watchedFolders:[a.path],ignoredFolders:[],updateRoots:true,listDisabledRootIDs:persisted,persistListDisabledRootIDs:{persisted=$0})
        final.shutdown();XCTAssertEqual(try db.roots().first(where:{$0.id=="A"})?.enabled,false)
    }

}
