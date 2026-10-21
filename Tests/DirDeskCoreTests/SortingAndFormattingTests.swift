import XCTest
@testable import DirDeskCore

final class SortingAndFormattingTests: XCTestCase {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil) -> FileItem {
        FileItem(id: FileIdentity(fallbackPath: "/x/\(name)"), url: URL(fileURLWithPath: "/x/\(name)"), name: name,
                 isDirectory: folder, size: size, modificationDate: modified)
    }

    func testNaturalSortingPutsFile2BeforeFile10() {
        let items = ["File 10.txt", "File 2.txt", "file 3.txt", "File 1.txt"].map { item($0) }
        let sorted = FileSorter.sort(items, options: FileSortOptions(key: .name, natural: true)).map(\.name)
        XCTAssertEqual(sorted, ["File 1.txt", "File 2.txt", "file 3.txt", "File 10.txt"])
        let plain = FileSorter.sort(items, options: FileSortOptions(key: .name, natural: false)).map(\.name)
        XCTAssertEqual(plain, ["File 1.txt", "File 10.txt", "File 2.txt", "file 3.txt"])
    }

    func testFoldersFirstAndPinnedFolders() {
        let items = [item("b.txt"), item("A", folder: true), item("c", folder: true), item("a.txt")]
        let foldersFirst = FileSorter.sort(items, options: FileSortOptions(key: .name, foldersFirst: true)).map(\.name)
        XCTAssertEqual(foldersFirst, ["A", "c", "a.txt", "b.txt"])
        let pinned = FileSorter.sort(items, options: FileSortOptions(key: .name, pinnedPaths: ["/x/c"])).map(\.name)
        XCTAssertEqual(pinned.first, "c")
    }

    func testSizeSortTiesBreakByName() {
        let items = [item("b", size: 10), item("a", size: 10), item("c", size: 5)]
        XCTAssertEqual(FileSorter.sort(items, options: FileSortOptions(key: .size)).map(\.name), ["c", "a", "b"])
        XCTAssertEqual(FileSorter.sort(items, options: FileSortOptions(key: .size, ascending: false)).map(\.name), ["b", "a", "c"])
    }

    func testDateAgeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DateAgeBucket.bucket(for: now.addingTimeInterval(-60), now: now), .minutes)
        XCTAssertEqual(DateAgeBucket.bucket(for: now.addingTimeInterval(-300), now: now), .hour)
        XCTAssertEqual(DateAgeBucket.bucket(for: now.addingTimeInterval(-3600), now: now), .day)
        XCTAssertEqual(DateAgeBucket.bucket(for: now.addingTimeInterval(-86_400), now: now), .week)
        XCTAssertEqual(DateAgeBucket.bucket(for: now.addingTimeInterval(-604_800), now: now), .older)
        XCTAssertNil(DateAgeBucket.bucket(for: now.addingTimeInterval(3600), now: now))
        XCTAssertNil(DateAgeBucket.bucket(for: nil, now: now))
    }

    func testFileSizeFormatting() {
        XCTAssertEqual(FileSizeFormatter.string(445), "445 B")
        XCTAssertEqual(FileSizeFormatter.string(999), "999 B")
        XCTAssertEqual(FileSizeFormatter.string(1000), "1 KB")
        XCTAssertEqual(FileSizeFormatter.string(1_500_000), "1.5 MB")
        // Item sizes use three significant digits, as observed in the original's list (reference 01-主窗口).
        XCTAssertEqual(FileSizeFormatter.string(76_190_000_000), "76.2 GB")
        XCTAssertEqual(FileSizeFormatter.string(5_560), "5.56 KB")
        XCTAssertEqual(FileSizeFormatter.string(98_374), "98.4 KB")
        XCTAssertEqual(FileSizeFormatter.string(734_000), "734 KB")
        XCTAssertEqual(FileSizeFormatter.string(1_230_000), "1.23 MB")
        XCTAssertEqual(FileSizeFormatter.string(157_000_000), "157 MB")
        XCTAssertEqual(FileSizeFormatter.string(999_600), "1 MB")
        XCTAssertEqual(FileSizeFormatter.string(9_996), "10 KB")
        // Volume capacity keeps up to two decimals ("剩余 74.55 GB").
        XCTAssertEqual(FileSizeFormatter.string(74_550_000_000, style: .capacity), "74.55 GB")
        XCTAssertEqual(FileSizeFormatter.string(59_800_000_000, style: .capacity), "59.8 GB")
        XCTAssertEqual(FileSizeFormatter.string(1024, unit: .binary), "1 KiB")
    }

    func testRelativeDateText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = FileDateFormatter(locale: Locale(identifier: "zh_Hans"))
        func text(_ offset: TimeInterval) -> String {
            formatter.string(now.addingTimeInterval(offset), now: now, justNow: "刚刚", minutesAgoFormat: "%lld分钟前",
                             yesterdayFormat: "昨天 %@", todayFormat: "今天 %@")
        }
        XCTAssertEqual(text(-30), "刚刚")
        XCTAssertEqual(text(-9 * 60), "9分钟前")
        // The original keeps counting minutes up to two hours ("75分钟前", "107分钟前").
        XCTAssertEqual(text(-75 * 60), "75分钟前")
        XCTAssertEqual(text(-119 * 60), "119分钟前")
        XCTAssertFalse(text(-3 * 3600).contains("分钟"))
    }

    func testDateGroupingBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let items = [
            item("today", modified: now.addingTimeInterval(-3600)),
            item("yesterday", modified: now.addingTimeInterval(-86_400)),
            item("week", modified: now.addingTimeInterval(-3 * 86_400)),
            item("month", modified: now.addingTimeInterval(-20 * 86_400)),
            item("future", modified: now.addingTimeInterval(86_400)),
            item("unknown"),
        ]
        let groups = FileGrouping.group(items, mode: .modified, now: now, calendar: calendar, locale: Locale(identifier: "en_US"),
                                        kind: { _ in "" }, application: { _ in nil })
        XCTAssertEqual(groups.map(\.title), ["Future", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Unknown Date"])
    }

    func testSizeGroupingUsesDecimalThresholds() {
        let items = [item("a", size: 999_999), item("b", size: 1_000_000), item("c", size: 1_000_000_000), item("d", folder: true)]
        let groups = FileGrouping.group(items, mode: .size, kind: { _ in "" }, application: { _ in nil })
        XCTAssertEqual(groups.map(\.title), ["Folders", "Less than 1 MB", "1 MB – 100 MB", "1 GB or Larger"])
    }

    func testKindColumnRule() {
        XCTAssertEqual(FileKindDescriber.describe(item("notes.txt"), folderTitle: "Folder", aliasTitle: "Alias"), "TXT")
        XCTAssertEqual(FileKindDescriber.describe(item("photo.jpg"), folderTitle: "Folder", aliasTitle: "Alias"), "JPEG")
        XCTAssertEqual(FileKindDescriber.describe(item("scan.tif"), folderTitle: "Folder", aliasTitle: "Alias"), "TIFF")
        XCTAssertEqual(FileKindDescriber.describe(item("data.unknownext"), folderTitle: "Folder", aliasTitle: "Alias"), "UNKNOWNEXT")
        XCTAssertEqual(FileKindDescriber.describe(item("Makefile"), folderTitle: "Folder", aliasTitle: "Alias", fileTitle: "File"), "File")
        XCTAssertEqual(FileKindDescriber.describe(item("Docs", folder: true), folderTitle: "Folder", aliasTitle: "Alias"), "Folder")
    }

    func testPathExpansion() throws {
        XCTAssertEqual(try PathUtilities.expand("~/a", environment: [:], home: "/Users/t"), "/Users/t/a")
        XCTAssertEqual(try PathUtilities.expand("$PROJ/x", environment: ["PROJ": "/p"], home: "/h"), "/p/x")
        XCTAssertEqual(try PathUtilities.expand("${HOME}/y", environment: [:], home: "/h"), "/h/y")
        XCTAssertThrowsError(try PathUtilities.expand("$NOPE/x", environment: [:], home: "/h"))
        XCTAssertThrowsError(try PathUtilities.expand("   ", environment: [:], home: "/h"))
    }
}

final class DirectoryLoaderTagTests: XCTestCase {
    func testTagsSurviveBulkResourceKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tagged.txt")
        try Data("x".utf8).write(to: file)
        try (file as NSURL).setResourceValue(["Blue", "Project"], forKey: .tagNamesKey)
        let loaded = try DirectoryLoader.load(directory: directory, policy: .local)
        XCTAssertEqual(Set(loaded.items.first?.tags ?? []), ["Blue", "Project"])
    }
}

final class LargeFolderPerformanceTests: XCTestCase {
    /// Set DIRDESK_PERF=1 to run: loads, sorts and groups a 100,000-file folder.
    func testHundredThousandItemFolder() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIRDESK_PERF"] == "1", "performance test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<100_000 {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("item-\(index).txt").path, contents: nil)
        }
        var start = Date()
        let loaded = try DirectoryLoader.load(directory: directory, policy: .local)
        let loadTime = Date().timeIntervalSince(start)
        start = Date()
        let sorted = FileSorter.sort(loaded.items, options: FileSortOptions(key: .name, ascending: true, foldersFirst: false, natural: true))
        let sortTime = Date().timeIntervalSince(start)
        start = Date()
        _ = FileGrouping.group(sorted, mode: .modified, kind: { $0.fileExtension.uppercased() }, application: { _ in nil })
        let groupTime = Date().timeIntervalSince(start)
        print(String(format: "PERF load %.2fs (%d items, truncated %@) sort %.2fs group %.2fs", loadTime, loaded.items.count, loaded.truncated ? "yes" : "no", sortTime, groupTime))
        XCTAssertEqual(loaded.items.count, 100_000)
    }
}

final class FastDirectoryReaderTests: XCTestCase {
    /// The bulk reader must describe items exactly like the resource-value path (identity, kind, dates, flags).
    func testMatchesResourceValuePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-fast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Report 2.pdf")
        try Data(repeating: 7, count: 4097).write(to: file)
        try (file as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: file)

        var fast = try XCTUnwrap(FastDirectoryReader.read(directory, limit: 100))
        DirectoryLoader.fillTags(&fast.items)
        XCTAssertEqual(fast.total, 5)
        for item in fast.items {
            let slow = try XCTUnwrap(DirectoryLoader.item(at: item.url), item.name)
            XCTAssertEqual(item.id, slow.id, item.name)
            XCTAssertEqual(item.id.hashValue, slow.id.hashValue, item.name)
            XCTAssertEqual(item.isDirectory, slow.isDirectory, item.name)
            XCTAssertEqual(item.isPackage, slow.isPackage, item.name)
            XCTAssertEqual(item.isSymbolicLink, slow.isSymbolicLink, item.name)
            XCTAssertEqual(item.isHidden, slow.isHidden, item.name)
            XCTAssertEqual(item.size, slow.size, item.name)
            XCTAssertEqual(item.tags, slow.tags, item.name)
            XCTAssertEqual(item.modificationDate, slow.modificationDate, item.name)
            XCTAssertEqual(item.isBrowsableFolder, slow.isBrowsableFolder, item.name)
        }
        XCTAssertEqual(fast.items.first { $0.name == "Report 2.pdf" }?.contentTypeIdentifier, "com.adobe.pdf")
    }
}
