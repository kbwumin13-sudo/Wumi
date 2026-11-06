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
}
