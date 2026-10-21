import DirDeskCore
import XCTest

final class FolderDisplayTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "DirDeskTests.FolderDisplay"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testRememberForgetAndReload() {
        let store = FolderDisplayStore(defaults: defaults)
        let folder = URL(fileURLWithPath: "/tmp/a/")
        let rules = FolderDisplayRules(sortKey: .size, ascending: false, foldersFirst: true, grouping: .kind)
        XCTAssertNil(store.rules(for: folder))
        store.remember(rules, for: folder)
        XCTAssertEqual(store.rules(for: URL(fileURLWithPath: "/tmp/a")), rules, "trailing slash is ignored")
        XCTAssertEqual(FolderDisplayStore(defaults: defaults).rules(for: folder), rules, "stored in UserDefaults")
        store.forget(folder)
        XCTAssertNil(FolderDisplayStore(defaults: defaults).rules(for: folder))
    }

    func testCapacityDropsOldestRecords() {
        let store = FolderDisplayStore(defaults: defaults)
        let rules = FolderDisplayRules(sortKey: .name, ascending: false, foldersFirst: false, grouping: .none)
        for index in 0..<(FolderDisplayStore.capacity + 5) {
            store.remember(rules, for: URL(fileURLWithPath: "/tmp/f\(index)"))
        }
        XCTAssertEqual(store.count, FolderDisplayStore.capacity)
        XCTAssertNil(store.rules(for: URL(fileURLWithPath: "/tmp/f0")))
        XCTAssertNotNil(store.rules(for: URL(fileURLWithPath: "/tmp/f\(FolderDisplayStore.capacity + 4)")))
    }

    func testStandardRulesUseBaselineGrouping() {
        let baseline = FolderDisplayBaseline(groupingMode: .kind, foldersFirst: true)
        let rules = FolderDisplayRules.standard(sortKey: .modificationDate, ascending: false, baseline: baseline)
        var configuration = ViewConfiguration()
        rules.apply(to: &configuration)
        XCTAssertEqual(configuration.sortKey, .modificationDate)
        XCTAssertFalse(configuration.sortAscending)
        XCTAssertEqual(configuration.groupingMode, .kind)
        XCTAssertTrue(configuration.foldersFirst)
        XCTAssertEqual(FolderDisplayRules(configuration), rules)
    }

    func testPaneStateDecodesWithoutBaseline() throws {
        let state = BrowserPaneState(destination: .directory(URL(fileURLWithPath: "/tmp")))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "folderDisplayBaseline")
        let decoded = try JSONDecoder().decode(BrowserPaneState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.folderDisplayBaseline)
    }
}
