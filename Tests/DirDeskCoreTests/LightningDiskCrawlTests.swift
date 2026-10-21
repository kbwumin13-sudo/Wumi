import DirDeskCore
import XCTest

/// Opt-in measurement (DIRDESK_DISK_CRAWL=1): crawls "/" with the default ignored folders plus the
/// privacy-protected parts of the home folder, so no access prompt can appear.
final class LightningDiskCrawlTests: XCTestCase {
    func testWholeDiskCrawlWithoutProtectedFolders() throws {
        guard ProcessInfo.processInfo.environment["DIRDESK_DISK_CRAWL"] == "1" else { throw XCTSkip("set DIRDESK_DISK_CRAWL=1") }
        let home = NSHomeDirectory()
        let ignored = ["/Volumes", "/Library/Caches", "/System/Library/Caches", "/private/var", "/private/tmp"]
            + ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", ".Trash"].map { home + "/" + $0 }
        let configuration = LightningIndexConfiguration(roots: [URL(fileURLWithPath: "/")], excludedPaths: ignored,
                                                        maximumEntries: 4_000_000, maximumMemoryBytes: 768 << 20)
        let index = LightningIndex(configuration: configuration)
        let before = ProcessUsage.current()?.footprintBytes ?? 0
        let started = Date()
        let status = index.prepare()
        let elapsed = Date().timeIntervalSince(started)
        let grown = Int64(ProcessUsage.current()?.footprintBytes ?? 0) - Int64(before)
        print("disk crawl: \(status.indexedCount) entries, \(status.stage), \(String(format: "%.2f", elapsed)) s, unreadable \(status.unreadableFolderCount), footprint +\(grown >> 20) MB")
        // Searching the whole index for a common fragment stays interactive.
        let query = Date()
        let hits = try LightningSearchEngine(index: index).search("config", limit: 200)
        print("query 'config': \(hits.totalCount) matches in \(String(format: "%.3f", Date().timeIntervalSince(query))) s")
        let sorted = Date()
        let byDate = try LightningSearchEngine(index: index).search("ext:json", sort: .modified, descending: true, limit: 200)
        print("query 'ext:json' sorted by date: \(byDate.totalCount) matches in \(String(format: "%.3f", Date().timeIntervalSince(sorted))) s")
        XCTAssertTrue(status.stage.isSearchable)
    }
}
