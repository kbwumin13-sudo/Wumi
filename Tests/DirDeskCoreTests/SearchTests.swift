import XCTest
@testable import DirDeskCore

final class SearchTests: XCTestCase {
    private var root: URL!
    private var rootPath: String { root.path }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    /// Wednesday 2026-03-18 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_773_835_200)
    private let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // FSEvents and the index report real paths (/private/var/...), so the fixture uses them too.
        root = URL(fileURLWithPath: LightningIndex.canonicalPath(temporary.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixture

    @discardableResult
    private func file(_ relative: String, _ contents: String = "", size: Int? = nil, modified: Date? = nil, created: Date? = nil,
                      tags: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(contents.utf8)
        if let size { data = Data(repeating: 0x61, count: size) }
        try data.write(to: url)
        try setDates(url, modified: modified, created: created)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        return url
    }

    @discardableResult
    private func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setDates(_ url: URL, modified: Date?, created: Date?) throws {
        // Separate calls: an earlier modification date set together with the creation date pulls the
        // creation date back with it.
        try FileManager.default.setAttributes([.modificationDate: modified ?? old], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.creationDate: created ?? old], ofItemAtPath: url.path)
    }

    /// Builds the standard tree; every date is 2020-01-01 unless a test sets it.
    private func makeFixture() throws {
        try file("Documents/Report 2026.pdf", size: 2_000, modified: date(2026, 3, 17, 10))
        try file("Documents/report-draft.docx", size: 50_000, modified: date(2026, 3, 18, 8))
        try file("Documents/Notes.md", "TODO: write tests\n", created: date(2026, 3, 2), tags: ["Work", "Important"])
        try file("Documents/Archive/old-report.zip", size: 2_000_000, modified: date(2025, 6, 1, 9))
        try file("Documents/Archive/photos/IMG_0001.JPG", size: 300)
        try file("Documents/Archive/photos/IMG_0002.png", size: 400)
        try file("src/main.swift", "print(\"hello\")\n")
        try file("src/Makefile", "all:\n")
        try file("src/Utils/helpers.swift", "func help() {}\n")
        try file("src/node_modules/lib.js", "module.exports = 1\n")
        try file("Music/song.mp3", size: 5_000_000, tags: ["Personal"])
        try file("Music/Cafe\u{301}.txt", "menu")
        try file(".hidden/secret.txt", "s")
        try file("empty.txt", size: 0)
        try file("App.app/Contents/Info.plist", "<plist/>")
        for relative in ["Documents", "Documents/Archive", "Documents/Archive/photos", "src", "src/Utils", "src/node_modules",
                         "Music", ".hidden", "App.app", "App.app/Contents", ""] {
            try setDates(root.appendingPathComponent(relative), modified: nil, created: nil)
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeIndex(snapshot: URL? = nil, configure: (inout LightningIndexConfiguration) -> Void = { _ in }) -> LightningIndex {
        var configuration = LightningIndexConfiguration(roots: [root], autosaveInterval: nil)
        configure(&configuration)
        return LightningIndex(configuration: configuration, snapshotURL: snapshot)
    }

    private func makeEngine(_ index: LightningIndex) -> LightningSearchEngine {
        let fixed = now
        return LightningSearchEngine(index: index, calendar: utc, homeDirectory: rootPath, now: { fixed })
    }

    private func builtEngine() throws -> LightningSearchEngine {
        try makeFixture()
        let index = makeIndex()
        XCTAssertEqual(index.rebuild().stage, .ready)
        return makeEngine(index)
    }

    private func names(_ engine: LightningSearchEngine, _ expression: String, scope: LightningScope = .computer,
                       caseSensitive: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        do {
            let result = try engine.search(expression, scope: scope, caseSensitive: caseSensitive, sort: .name, limit: 10_000)
            return result.rows.map { $0.name.precomposedStringWithCanonicalMapping }
        } catch {
            XCTFail("\(expression): \(error)", file: file, line: line)
            return []
        }
    }

    // MARK: In-pane search: parser

    func testInPaneKeywordWildcardAndRegexModes() throws {
        let keyword = try SearchQueryParser.parse("  foo bar ", mode: .keyword)
        XCTAssertEqual(keyword.tokens, [
            SearchToken(field: .name, comparison: .contains, value: "foo", sourceRange: 2..<5),
            SearchToken(field: .name, comparison: .contains, value: "bar", sourceRange: 6..<9),
        ])
        let wildcard = try SearchQueryParser.parse("*.swift", mode: .wildcard)
        XCTAssertEqual(wildcard.tokens.map(\.comparison), [.wildcard])
        XCTAssertTrue(try SearchQueryParser.parse("   ", mode: .wildcard).isEmpty)
        XCTAssertEqual(try SearchQueryParser.parse("^re.*t$", mode: .regularExpression).tokens.map(\.comparison), [.regularExpression])
        XCTAssertThrowsError(try SearchQueryParser.parse("a(", mode: .regularExpression)) { error in
            XCTAssertEqual((error as? SearchSyntaxError)?.message, "Invalid regular expression.")
        }
    }

    func testInPaneAdvancedSyntax() throws {
        let query = try SearchQueryParser.parse(#"name:report -ext:pdf size:>=1MB modified:today tag:* "two words" kind:=folder *.md"#,
                                                mode: .advanced)
        XCTAssertEqual(query.tokens.map(\.field), [.name, .ext, .size, .modified, .tag, .name, .kind, .name])
        XCTAssertEqual(query.tokens.map(\.comparison), [.contains, .equal, .greaterThanOrEqual, .equal, .isPresent, .contains, .equal, .wildcard])
        XCTAssertEqual(query.tokens.map(\.value), ["report", "pdf", "1MB", "today", "", "two words", "folder", "*.md"])
        XCTAssertEqual(query.tokens.map(\.isNegated), [false, true, false, false, false, false, false, false])
        XCTAssertEqual(query.tokens[1].sourceRange, 12..<20)
        XCTAssertEqual(SearchValueParser.byteCount("1.5MB"), 1_500_000)
        XCTAssertEqual(SearchValueParser.byteCount("2 kb"), 2_000)
        XCTAssertEqual(SearchValueParser.byteCount("1KiB"), 1_024)
        XCTAssertNil(SearchValueParser.byteCount("-1"))
        let range = try XCTUnwrap(SearchValueParser.dateInterval("this-week", now: now, calendar: utc))
        XCTAssertEqual(range, date(2026, 3, 16)..<date(2026, 3, 23))
    }

    func testInPaneSyntaxErrors() {
        func error(_ text: String) -> SearchSyntaxError? {
            do {
                _ = try SearchQueryParser.parse(text, mode: .advanced)
                return nil
            } catch {
                return error as? SearchSyntaxError
            }
        }
        XCTAssertEqual(error("a foo:bar"), SearchSyntaxError(fragment: "foo", offset: 2, message: "Unknown field"))
        XCTAssertEqual(error(#"name:"abc"#), SearchSyntaxError(fragment: #""abc"#, offset: 5, message: "Unterminated quote"))
        XCTAssertEqual(error("size:")?.message, "Missing value")
        XCTAssertEqual(error("size:>")?.message, "Missing value")
        XCTAssertEqual(error("size:>big")?.message, SearchSyntaxError.invalidSize)
        XCTAssertEqual(error("modified:2024-02-30")?.message, SearchSyntaxError.invalidDate)
        XCTAssertNil(error("12:30 -"))
    }

    // MARK: In-pane search: service

    func testInPaneSearchMatchesFieldsRecursively() throws {
        try makeFixture()
        func run(_ text: String, mode: SearchInputMode = .advanced, recursive: Bool = true, hidden: Bool = false) throws -> [String] {
            var found: [String] = []
            let stop = SearchService.search(root: root, query: try SearchQueryParser.parse(text, mode: mode), recursive: recursive,
                                            includeHidden: hidden, now: now, calendar: utc) { found += $0.map(\.name) }
            XCTAssertNil(stop)
            return found.map { $0.precomposedStringWithCanonicalMapping }.sorted()
        }
        XCTAssertEqual(try run("report", mode: .keyword), ["Report 2026.pdf", "old-report.zip", "report-draft.docx"])
        XCTAssertEqual(try run("report", mode: .keyword, recursive: false), [])
        XCTAssertEqual(try run("*.swift", mode: .wildcard), ["helpers.swift", "main.swift"])
        XCTAssertEqual(try run("^IMG_\\d+", mode: .regularExpression), ["IMG_0001.JPG", "IMG_0002.png"])
        XCTAssertEqual(try run("ext:swift -name:help"), ["main.swift"])
        XCTAssertEqual(try run("kind:folder name:s"), ["Documents", "Music", "Utils", "node_modules", "photos", "src"])
        XCTAssertEqual(try run("kind:jpg"), ["IMG_0001.JPG"])
        XCTAssertEqual(try run("tag:work"), ["Notes.md"])
        XCTAssertEqual(try run("tag:*"), ["Notes.md", "song.mp3"])
        XCTAssertEqual(try run("size:>1MB"), ["old-report.zip", "song.mp3"])
        XCTAssertEqual(try run("modified:today"), ["report-draft.docx"])
        XCTAssertEqual(try run("modified:>=2026-03-17"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(try run("café"), ["Café.txt"])
        XCTAssertEqual(try run("secret"), [])
        XCTAssertEqual(try run("secret", hidden: true), ["secret.txt"])
        // Package contents are not searched.
        XCTAssertEqual(try run("Info", mode: .keyword), [])
    }

    func testInPaneSearchBudgetsAndCancellation() throws {
        try makeFixture()
        let everything = try SearchQueryParser.parse("*", mode: .wildcard)
        func run(_ budget: SearchBudget, cancelled: Bool = false) -> (SearchStopReason?, Int) {
            var count = 0
            let stop = SearchService.search(root: root, query: everything, budget: budget, batchSize: 1, isCancelled: { cancelled }) {
                count += $0.count
            }
            return (stop, count)
        }
        var budget = SearchBudget.default
        XCTAssertEqual(budget.maximumDepth, 32)
        XCTAssertEqual(budget.maximumElapsedTime, .seconds(3))
        XCTAssertNil(run(budget).0)
        budget.maximumResults = 2
        XCTAssertEqual(run(budget).0, .results)
        XCTAssertEqual(run(budget).1, 2)
        budget = .default
        budget.maximumDepth = 1
        XCTAssertEqual(run(budget).0, .depth)
        budget = .default
        budget.maximumDirectories = 1
        XCTAssertEqual(run(budget).0, .folderCount)
        budget = .default
        budget.maximumInspectedEntries = 3
        XCTAssertEqual(run(budget).0, .inspected)
        budget = .default
        budget.maximumElapsedTime = .zero
        for index in 0..<70 { try file("bulk/\(index).txt") }
        XCTAssertEqual(run(budget).0, .time)
        for index in 0..<70 { try file("more/\(index).txt") }
        XCTAssertEqual(run(.default, cancelled: true).0, .cancelled)
        XCTAssertEqual(SearchStopReason.time.message, "Search stopped at its time limit.")
    }

    // MARK: Lightning: parser

    func testLightningPrecedenceAndGrouping() throws {
        func term(_ text: String) -> LightningQuery { .term(LightningTerm(text)) }
        XCTAssertEqual(try LightningQueryParser.parse(""), .everything)
        XCTAssertEqual(try LightningQueryParser.parse("a b|c"), .and([term("a"), .or([term("b"), term("c")])]))
        XCTAssertEqual(try LightningQueryParser.parse("!a | b"), .or([.not(term("a")), term("b")]))
        XCTAssertEqual(try LightningQueryParser.parse("NOT a OR b AND c"), .and([.or([.not(term("a")), term("b")]), term("c")]))
        XCTAssertEqual(try LightningQueryParser.parse("(a b) | c"), .or([.and([term("a"), term("b")]), term("c")]))
        XCTAssertEqual(try LightningQueryParser.parse(#""annual report" 2026"#), .and([term("annual report"), term("2026")]))
        XCTAssertEqual(try LightningQueryParser.parse("a | "), term("a"))
        XCTAssertEqual(try LightningQueryParser.parse("(a"), term("a"))
        XCTAssertEqual(try LightningQueryParser.parse("report(1)"), term("report(1)"))
        XCTAssertEqual(try LightningQueryParser.parse("and or"), .and([term("and"), term("or")]))
        XCTAssertEqual(try LightningQueryParser.parse("!!a"), term("a"))
        XCTAssertEqual(try LightningQueryParser.parse("case:Foo bar"), .and([.matchCase(true, term("Foo")), term("bar")]))
        XCTAssertEqual(try LightningQueryParser.parse("Foo case:"), .matchCase(true, term("Foo")))
        XCTAssertEqual(try LightningQueryParser.parse("case:(A|B)"), .matchCase(true, .or([term("A"), term("B")])))
        XCTAssertEqual(try LightningQueryParser.parse("regex:^(a|b)$"), .filter(.regex("^(a|b)$")))
    }

    func testLightningFilterParsing() throws {
        XCTAssertEqual(try LightningQueryParser.parse("ext:.JPG;png"), .filter(.extension(["jpg", "png"])))
        XCTAssertEqual(try LightningQueryParser.parse("ext:"), .filter(.extension([])))
        XCTAssertEqual(try LightningQueryParser.parse("type:images;MOVIE;text"), .filter(.type([.picture, .video, .document])))
        XCTAssertEqual(try LightningQueryParser.parse("folder:"), .filter(.folder(nil)))
        XCTAssertEqual(try LightningQueryParser.parse("file:src"), .filter(.file(LightningTerm("src"))))
        XCTAssertEqual(try LightningQueryParser.parse("size:>1mb;empty;giant"),
                       .filter(.size([.compare(.greater, 1_000_000), .named(.empty), .named(.gigantic)])))
        XCTAssertEqual(try LightningQueryParser.parse("size:1KiB..2.5MB"), .filter(.size([.range(1_024, 2_500_000)])))
        XCTAssertEqual(try LightningQueryParser.parse("size:!=0"), .filter(.size([.compare(.notEqual, 0)])))
        XCTAssertEqual(try LightningQueryParser.parse("size:..1pb"), .filter(.size([.range(nil, 1_000_000_000_000_000)])))
        XCTAssertEqual(try LightningQueryParser.parse("dm:today;lastweek"), .filter(.dateModified([.compare(.equal, .today), .compare(.equal, .lastWeek)])))
        XCTAssertEqual(try LightningQueryParser.parse("datecreated:>=2024-01-15"),
                       .filter(.dateCreated([.compare(.greaterOrEqual, .day(year: 2024, month: 1, day: 15))])))
        XCTAssertEqual(try LightningQueryParser.parse("dc:2024/01..2024"),
                       .filter(.dateCreated([.range(.month(year: 2024, month: 1), .year(2024))])))
        XCTAssertEqual(try LightningQueryParser.parse(#"infolder:"~/My Docs";/tmp"#), .filter(.inFolder(["~/My Docs", "/tmp"])))
        XCTAssertEqual(try LightningQueryParser.parse("parent:~"), .filter(.inFolder(["~"])))
        XCTAssertEqual(try LightningQueryParser.parse("in:~/Documents"), .filter(.inFolder(["~/Documents"])))
        XCTAssertEqual(try LightningQueryParser.parse("nosubfolders:/Users"), .filter(.noSubfolders(["/Users"])))
        XCTAssertEqual(try LightningQueryParser.parse(#"content:"a b";c"#), .filter(.content(["a b", "c"])))
        XCTAssertEqual(try LightningQueryParser.parse("tag:red tag:blue"), .and([.filter(.tag(["red"])), .filter(.tag(["blue"]))]))
        XCTAssertEqual(try LightningQueryParser.parse(#"tagexact:"Work Items";Red"#), .filter(.tagExact(["Work Items", "Red"])))
        XCTAssertEqual(try LightningQueryParser.parse("audio:beatles"), .and([.filter(.type([.audio])), .term(LightningTerm("beatles"))]))
        XCTAssertEqual(LightningFileType.named("Excel"), .spreadsheet)
        XCTAssertEqual(LightningFileType.named("program"), .executable)
    }

    func testLightningSyntaxErrors() {
        func error(_ text: String) -> LightningSyntaxError? {
            do {
                _ = try LightningQueryParser.parse(text)
                return nil
            } catch {
                return error as? LightningSyntaxError
            }
        }
        XCTAssertEqual(error("a foo:bar"), LightningSyntaxError(message: LightningSyntaxError.unknownFilter, fragment: "foo", offset: 2))
        XCTAssertEqual(error("regex:[")?.message, LightningSyntaxError.invalidRegularExpression)
        XCTAssertEqual(error("size:>abc")?.message, LightningSyntaxError.invalidSize)
        XCTAssertEqual(error("size:")?.message, LightningSyntaxError.missingValue)
        XCTAssertEqual(error("size:10mb..1mb")?.message, LightningSyntaxError.reversedRange)
        XCTAssertEqual(error("dm:2024-13-01")?.message, LightningSyntaxError.invalidDate)
        XCTAssertEqual(error("dm:2024-02-30")?.message, LightningSyntaxError.invalidDate)
        XCTAssertEqual(error("dm:2024-03..2024-02-01")?.message, LightningSyntaxError.reversedRange)
        XCTAssertEqual(error("type:blah")?.message, LightningSyntaxError.unknownType)
        XCTAssertEqual(error("infolder:relative/path")?.message, LightningSyntaxError.invalidFolder)
        XCTAssertEqual(error("in:relative")?.message, LightningSyntaxError.invalidFolder)
        XCTAssertEqual(error("tagexact:")?.message, LightningSyntaxError.missingValue)
        XCTAssertNil(error("12:30 \"http://x\""))
    }

    func testSizeAndDateKeywordsResolveAgainstInjectedNow() {
        XCTAssertEqual(LightningSizeClass.tiny.bounds.lower, 1)
        XCTAssertEqual(LightningSizeClass.medium.bounds.upper, 1_000_000)
        XCTAssertNil(LightningSizeClass.gigantic.bounds.upper)
        XCTAssertEqual(LightningQueryParser.byteCount("1pb"), 1_000_000_000_000_000)
        XCTAssertEqual(LightningQueryParser.byteCount("3mib"), 3_145_728)
        let calendar = utc
        XCTAssertEqual(LightningDateValue.today.interval(now: now, calendar: calendar), date(2026, 3, 18)..<date(2026, 3, 19))
        XCTAssertEqual(LightningDateValue.yesterday.interval(now: now, calendar: calendar), date(2026, 3, 17)..<date(2026, 3, 18))
        XCTAssertEqual(LightningDateValue.thisWeek.interval(now: now, calendar: calendar), date(2026, 3, 16)..<date(2026, 3, 23))
        XCTAssertEqual(LightningDateValue.lastWeek.interval(now: now, calendar: calendar), date(2026, 3, 9)..<date(2026, 3, 16))
        XCTAssertEqual(LightningDateValue.lastMonth.interval(now: now, calendar: calendar), date(2026, 2, 1)..<date(2026, 3, 1))
        XCTAssertEqual(LightningDateValue.thisYear.interval(now: now, calendar: calendar), date(2026, 1, 1)..<date(2027, 1, 1))
        XCTAssertEqual(LightningDateValue.pastWeek.interval(now: now, calendar: calendar).lowerBound, date(2026, 3, 11, 12))
        XCTAssertEqual(LightningDateValue.month(year: 2024, month: 2).interval(now: now, calendar: calendar), date(2024, 2, 1)..<date(2024, 3, 1))
    }

    // MARK: Lightning: matching

    func testNamesWildcardsAndCaseSensitivity() throws {
        let engine = try builtEngine()
        XCTAssertEqual(names(engine, "report"), ["old-report.zip", "Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "Report", caseSensitive: true), ["Report 2026.pdf"])
        XCTAssertEqual(names(engine, "case:report"), ["old-report.zip", "report-draft.docx"])
        XCTAssertEqual(names(engine, "nocase:REPORT", caseSensitive: true).count, 3)
        XCTAssertEqual(names(engine, "*.swift"), ["helpers.swift", "main.swift"])
        XCTAssertEqual(names(engine, "img_000?.*"), ["IMG_0001.JPG", "IMG_0002.png"])
        XCTAssertEqual(names(engine, "rep*"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "report !zip"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "song | notes"), ["Notes.md", "song.mp3"])
        XCTAssertEqual(names(engine, "\"report 2026\""), ["Report 2026.pdf"])
        XCTAssertEqual(names(engine, "CAFÉ"), ["Café.txt"])
        XCTAssertEqual(names(engine, "secret"), ["secret.txt"])
        // node_modules is indexed itself but not its contents; packages are not descended into.
        XCTAssertEqual(names(engine, "node_modules"), ["node_modules"])
        XCTAssertEqual(names(engine, "lib.js"), [])
        XCTAssertEqual(names(engine, "info.plist"), [])
        XCTAssertEqual(names(engine, "app.app"), ["App.app"])
    }

    func testPathSegments() throws {
        let engine = try builtEngine()
        XCTAssertEqual(names(engine, "src/main"), ["main.swift"])
        XCTAssertEqual(names(engine, "ments/rep"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "/utils/"), ["Utils"])
        XCTAssertEqual(names(engine, "/util"), ["Utils"])
        XCTAssertEqual(names(engine, "tils/"), ["Utils"])
        XCTAssertEqual(names(engine, "src/**"), ["helpers.swift", "main.swift", "Makefile", "node_modules", "Utils"])
        XCTAssertEqual(names(engine, "src/**/help"), ["helpers.swift"])
        XCTAssertEqual(names(engine, "documents/**/*.png"), ["IMG_0002.png"])
        XCTAssertEqual(names(engine, "archive/*/img_0001.jpg"), ["IMG_0001.JPG"])
        XCTAssertEqual(names(engine, "/Archive/photos/"), ["photos"])
        // Components above the watched root are matched too (the root is a real absolute path).
        let rootName = root.lastPathComponent
        XCTAssertEqual(names(engine, "/\(rootName)/src/"), ["src"])
        XCTAssertEqual(names(engine, "src/main", caseSensitive: true), ["main.swift"])
        XCTAssertEqual(names(engine, "SRC/main", caseSensitive: true), [])
    }

    func testFilters() throws {
        let engine = try builtEngine()
        XCTAssertEqual(names(engine, "ext:pdf;ZIP"), ["old-report.zip", "Report 2026.pdf"])
        XCTAssertEqual(names(engine, "ext:"), ["Makefile"])
        XCTAssertEqual(names(engine, "type:picture"), ["IMG_0001.JPG", "IMG_0002.png"])
        XCTAssertEqual(names(engine, "type:audio;exe"), ["App.app", "song.mp3"])
        // The watched root is a searchable folder too.
        let rootName = root.lastPathComponent
        XCTAssertEqual(names(engine, "type:folder"), [".hidden", "Archive", rootName, "Documents", "Music", "node_modules", "photos", "src", "Utils"])
        XCTAssertEqual(names(engine, "folder:s"), [rootName, "Documents", "Music", "node_modules", "photos", "src", "Utils"])
        XCTAssertEqual(names(engine, "file: app"), ["App.app"])
        XCTAssertEqual(names(engine, "doc: report"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "size:>1mb"), ["old-report.zip", "song.mp3"])
        XCTAssertEqual(names(engine, "size:empty"), ["empty.txt"])
        XCTAssertEqual(names(engine, "size:1kb..100kb"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "size:medium;huge"), [])
        XCTAssertEqual(names(engine, "size:small"), ["report-draft.docx"])
        XCTAssertEqual(names(engine, "size:large"), ["old-report.zip", "song.mp3"])
        XCTAssertEqual(names(engine, "size:<=300 ext:jpg"), ["IMG_0001.JPG"])
        XCTAssertEqual(names(engine, "size:!=0 ext:txt"), ["Café.txt", "secret.txt"])
        XCTAssertEqual(names(engine, "regex:^IMG_\\d+\\.jpg$"), ["IMG_0001.JPG"])
        XCTAssertEqual(names(engine, "case:regex:^IMG_\\d+\\.jpg$"), [])
        XCTAssertEqual(names(engine, "regex:^(main|helpers)\\.swift$"), ["helpers.swift", "main.swift"])
        XCTAssertEqual(names(engine, "infolder:\(rootPath)/Documents/Archive"), ["IMG_0001.JPG", "IMG_0002.png", "old-report.zip", "photos"])
        XCTAssertEqual(names(engine, "parent:~/Documents/Archive ext:zip"), ["old-report.zip"])
        XCTAssertEqual(names(engine, "nosubfolders:~/Documents"), ["Archive", "Notes.md", "Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "infolder:/does/not/exist"), [])
    }

    func testDateFilters() throws {
        let engine = try builtEngine()
        XCTAssertEqual(names(engine, "dm:today"), ["report-draft.docx"])
        XCTAssertEqual(names(engine, "dm:yesterday"), ["Report 2026.pdf"])
        XCTAssertEqual(names(engine, "dm:thisweek"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "dm:pastweek"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "dm:lastyear"), ["old-report.zip"])
        XCTAssertEqual(names(engine, "datemodified:2025-06-01"), ["old-report.zip"])
        XCTAssertEqual(names(engine, "dm:>2026-03-17"), ["report-draft.docx"])
        XCTAssertEqual(names(engine, "dm:>=2026-03-17"), ["Report 2026.pdf", "report-draft.docx"])
        XCTAssertEqual(names(engine, "dm:2025..2026-03-17"), ["old-report.zip", "Report 2026.pdf"])
        XCTAssertEqual(names(engine, "dm:pastyear !dm:thisweek"), ["old-report.zip"])
        XCTAssertEqual(names(engine, "dc:thismonth"), ["Notes.md"])
        XCTAssertEqual(names(engine, "dc:!=2020 file:"), ["Notes.md"])
    }

    func testContentAndTags() throws {
        let engine = try builtEngine()
        XCTAssertEqual(names(engine, "content:TODO"), ["Notes.md"])
        XCTAssertEqual(names(engine, "content:todo"), ["Notes.md"])
        XCTAssertEqual(names(engine, "content:todo", caseSensitive: true), [])
        XCTAssertEqual(names(engine, "content:hello;TODO"), ["main.swift", "Notes.md"])
        XCTAssertEqual(names(engine, "content:\"write tests\" ext:md"), ["Notes.md"])
        engine.contentByteLimit = 4
        XCTAssertEqual(names(engine, "content:TODO"), [])
        XCTAssertEqual(names(engine, "tag:work"), ["Notes.md"])
        XCTAssertEqual(names(engine, "tag:WORK tag:import"), ["Notes.md"])
        XCTAssertEqual(names(engine, "tag:work tag:personal"), [])
        XCTAssertEqual(names(engine, "tag:work;personal"), ["Notes.md", "song.mp3"])
        XCTAssertEqual(names(engine, "tag:"), ["Notes.md", "song.mp3"])
        XCTAssertEqual(names(engine, "tag:Work", caseSensitive: true), ["Notes.md"])
        XCTAssertEqual(names(engine, "tag:work", caseSensitive: true), [])
        // tagexact: compares whole tag names.
        XCTAssertEqual(names(engine, "tagexact:work"), ["Notes.md"])
        XCTAssertEqual(names(engine, "tagexact:wor"), [])
        XCTAssertEqual(names(engine, "tagexact:Important;Personal"), ["Notes.md", "song.mp3"])
        XCTAssertEqual(names(engine, "tagexact:work tagexact:important"), ["Notes.md"])
        XCTAssertEqual(names(engine, "tagexact:work", caseSensitive: true), [])
        XCTAssertEqual(names(engine, "in:~/Music"), names(engine, "infolder:~/Music"))
        XCTAssertEqual(names(engine, "in:~/Music"), ["Café.txt", "song.mp3"])
    }

    func testScopes() throws {
        let engine = try builtEngine()
        let documents = root.appendingPathComponent("Documents")
        XCTAssertEqual(names(engine, "report", scope: .folder(documents)).count, 3)
        XCTAssertEqual(names(engine, "report", scope: .folder(root.appendingPathComponent("src"))), [])
        XCTAssertEqual(names(engine, "", scope: .folder(root.appendingPathComponent("Documents/Archive/photos"))),
                       ["IMG_0001.JPG", "IMG_0002.png"])
        XCTAssertEqual(names(engine, "o", scope: .folders([root.appendingPathComponent("Documents/Archive"), root.appendingPathComponent("Music"),
                                                          root.appendingPathComponent("Documents/Archive/photos")])),
                       ["old-report.zip", "photos", "song.mp3"])
        // A folder outside the watched roots is crawled on demand.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("x".utf8).write(to: outside.appendingPathComponent("inner/report-outside.txt"))
        XCTAssertEqual(names(engine, "report", scope: .folder(outside)), ["report-outside.txt"])
        XCTAssertEqual(names(engine, "report", scope: .folders([outside, documents])).count, 4)
        // Folders whose contents the index skips are crawled on demand as well.
        XCTAssertEqual(names(engine, "", scope: .folder(root.appendingPathComponent("App.app"))), ["Contents", "Info.plist"])
        XCTAssertEqual(names(engine, "lib", scope: .folder(root.appendingPathComponent("src/node_modules"))), ["lib.js"])
    }

    func testSortingLimitAndTruncation() throws {
        let engine = try builtEngine()
        let documentsFiles = "file: infolder:\(rootPath)/Documents"
        let bySize = try engine.search(documentsFiles, sort: .size, descending: true, limit: 2)
        XCTAssertEqual(bySize.rows.map(\.name), ["old-report.zip", "report-draft.docx"])
        XCTAssertEqual(bySize.totalCount, 6)
        XCTAssertTrue(bySize.truncated)
        let ascending = try engine.search(documentsFiles, sort: .size, limit: 3)
        XCTAssertEqual(ascending.rows.map(\.name), ["Notes.md", "IMG_0001.JPG", "IMG_0002.png"])
        let byName = try engine.search(documentsFiles, sort: .name, descending: true)
        XCTAssertEqual(byName.rows.map(\.name), ["report-draft.docx", "Report 2026.pdf", "old-report.zip", "Notes.md", "IMG_0002.png", "IMG_0001.JPG"])
        XCTAssertFalse(byName.truncated)
        let byModified = try engine.search(documentsFiles, sort: .modified, descending: true, limit: 3)
        XCTAssertEqual(byModified.rows.map(\.name), ["report-draft.docx", "Report 2026.pdf", "old-report.zip"])
        let byCreated = try engine.search(documentsFiles, sort: .created, descending: true, limit: 1)
        XCTAssertEqual(byCreated.rows.map(\.name), ["Notes.md"])
        let byPath = try engine.search("infolder:\(rootPath)/Documents", sort: .path)
        XCTAssertEqual(byPath.rows.map(\.name), ["Archive", "Notes.md", "Report 2026.pdf", "report-draft.docx",
                                                 "old-report.zip", "photos", "IMG_0001.JPG", "IMG_0002.png"])
        let byPathDescending = try engine.search("infolder:\(rootPath)/Documents", sort: .path, descending: true, limit: 2)
        XCTAssertEqual(byPathDescending.rows.map(\.name), ["IMG_0002.png", "IMG_0001.JPG"])
        let row = try XCTUnwrap(try engine.search("old-report").rows.first)
        XCTAssertEqual(row.path, rootPath + "/Documents/Archive/old-report.zip")
        XCTAssertEqual(row.size, 2_000_000)
        XCTAssertFalse(row.isDirectory)
        XCTAssertEqual(row.modified, date(2025, 6, 1, 9))
        let folderRow = try XCTUnwrap(try engine.search("/photos/").rows.first)
        XCTAssertTrue(folderRow.isDirectory)
        XCTAssertNil(folderRow.size)
        let cancelled = try engine.search("report", isCancelled: { true })
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.truncated)
        XCTAssertEqual(LightningSearchEngine.smallest(3, of: [9, 1, 8, 2, 7, 3], by: <), [1, 2, 3])
    }

    // MARK: Lightning: index lifecycle

    func testIncrementalUpdates() throws {
        try makeFixture()
        let index = makeIndex()
        index.rebuild()
        let engine = makeEngine(index)
        let initialCount = index.count
        // A crawl records the current FSEvents id; events continue from there.
        let base = index.lastEventID
        XCTAssertGreaterThan(base, 0)

        // Created file.
        try file("Documents/new-file.txt", "fresh")
        index.apply([LightningFileEvent(path: rootPath + "/Documents/new-file.txt", flags: [.itemCreated, .itemIsFile], eventID: base + 10)])
        XCTAssertEqual(names(engine, "new-file"), ["new-file.txt"])
        XCTAssertEqual(index.count, initialCount + 1)
        XCTAssertEqual(index.lastEventID, base + 10)

        // Deleted file.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents/Notes.md"))
        index.apply([LightningFileEvent(path: rootPath + "/Documents/Notes.md", flags: [.itemRemoved, .itemIsFile], eventID: base + 11)])
        XCTAssertEqual(names(engine, "notes"), [])

        // Renamed folder: the old subtree disappears, the new one carries the contents.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Documents/Archive"),
                                         to: root.appendingPathComponent("Documents/Archive 2"))
        index.apply([
            LightningFileEvent(path: rootPath + "/Documents/Archive", flags: [.itemRenamed, .itemIsDirectory], eventID: base + 12),
            LightningFileEvent(path: rootPath + "/Documents/Archive 2", flags: [.itemRenamed, .itemIsDirectory], eventID: base + 13),
        ])
        let moved = try engine.search("old-report")
        XCTAssertEqual(moved.rows.map(\.path), [rootPath + "/Documents/Archive 2/old-report.zip"])
        XCTAssertEqual(names(engine, "/Archive/"), [])
        XCTAssertEqual(names(engine, "\"archive 2/photos/**\""), ["IMG_0001.JPG", "IMG_0002.png"])

        // A new folder with contents reported by a single event.
        try file("new/sub/deep.txt", "deep")
        index.apply([LightningFileEvent(path: rootPath + "/new", flags: [.itemCreated, .itemIsDirectory], eventID: base + 14)])
        XCTAssertEqual(names(engine, "deep"), ["deep.txt"])

        // Lost events: the subtree is rescanned.
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/main.swift"))
        try file("src/Utils/added.swift", "x")
        index.apply([LightningFileEvent(path: rootPath + "/src", flags: [.mustScanSubdirectories], eventID: base + 15)])
        XCTAssertEqual(names(engine, "*.swift"), ["added.swift", "helpers.swift"])

        // Case-only rename and a size change.
        XCTAssertEqual(rename(rootPath + "/Music/song.mp3", rootPath + "/Music/Song.mp3"), 0)
        index.apply([
            LightningFileEvent(path: rootPath + "/Music/song.mp3", flags: [.itemRenamed, .itemIsFile], eventID: base + 16),
            LightningFileEvent(path: rootPath + "/Music/Song.mp3", flags: [.itemRenamed, .itemIsFile], eventID: base + 17),
        ])
        XCTAssertEqual(names(engine, "song"), ["Song.mp3"])
        try Data(repeating: 1, count: 1_234).write(to: root.appendingPathComponent("empty.txt"))
        index.apply([LightningFileEvent(path: rootPath + "/empty.txt", flags: [.itemModified, .itemIsFile], eventID: base + 18)])
        XCTAssertEqual(try engine.search("empty.txt").rows.first?.size, 1_234)

        // Events inside excluded or package folders are ignored; events outside the roots too.
        try file("src/node_modules/extra.js", "x")
        index.apply([LightningFileEvent(path: rootPath + "/src/node_modules/extra.js", flags: [.itemCreated, .itemIsFile], eventID: base + 19),
                     LightningFileEvent(path: "/elsewhere/file.txt", flags: [.itemCreated], eventID: base + 20)])
        XCTAssertEqual(names(engine, "extra"), [])
        XCTAssertEqual(index.lastEventID, base + 20)

        // The whole index agrees with a fresh crawl.
        let fresh = makeIndex()
        fresh.rebuild()
        let expected = try makeEngine(fresh).search("", sort: .path, limit: 100_000).rows.map(\.path)
        XCTAssertEqual(try engine.search("", sort: .path, limit: 100_000).rows.map(\.path), expected)
    }

    func testManyEventsInOneFolderAndCompaction() throws {
        try folder("bulk")
        let index = makeIndex()
        index.rebuild()
        let engine = makeEngine(index)
        var events: [LightningFileEvent] = []
        for number in 0..<40 {
            try file("bulk/item-\(number).txt", "x")
            events.append(LightningFileEvent(path: rootPath + "/bulk/item-\(number).txt", flags: [.itemCreated, .itemIsFile]))
        }
        index.apply(events)
        XCTAssertEqual(try engine.search("item-").totalCount, 40)
        var storage = index.snapshot()
        for number in 0..<20 { storage.removeSubtree(try XCTUnwrap(storage.lookup(path: rootPath + "/bulk/item-\(number).txt"))) }
        let compacted = storage.compacted()
        XCTAssertEqual(compacted.count, storage.count - 20)
        XCTAssertEqual(compacted.searchableCount, storage.searchableCount)
        XCTAssertEqual(compacted.path(try XCTUnwrap(compacted.lookup(path: rootPath + "/bulk/item-30.txt"))), rootPath + "/bulk/item-30.txt")
    }

    func testSnapshotRoundTripAndCorruptFallback() throws {
        try makeFixture()
        let snapshot = root.appendingPathComponent("state/index.snapshot")
        let index = makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }
        XCTAssertEqual(index.prepare().stage, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let eventID = index.lastEventID + 4242
        index.apply([LightningFileEvent(path: rootPath + "/Music", flags: [.itemInodeMetadataModified, .itemIsDirectory], eventID: eventID)])
        try index.saveSnapshot()
        let expected = try makeEngine(index).search("", sort: .path, limit: 100_000).rows

        let loaded = makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }
        try loaded.loadSnapshot()
        XCTAssertEqual(loaded.status.stage, .ready)
        XCTAssertEqual(loaded.lastEventID, eventID)
        XCTAssertEqual(loaded.count, index.count)
        XCTAssertEqual(try makeEngine(loaded).search("", sort: .path, limit: 100_000).rows, expected)
        XCTAssertEqual(names(makeEngine(loaded), "ext:pdf;zip"), ["old-report.zip", "Report 2026.pdf"])

        // A snapshot written for other rules is not reused.
        let other = makeIndex(snapshot: snapshot) { $0.includesHiddenFiles = false; $0.excludedPaths = [self.rootPath + "/state"] }
        XCTAssertThrowsError(try other.loadSnapshot()) { XCTAssertEqual($0 as? LightningSnapshotError, .incompatible) }

        // Truncated and garbage snapshots are rejected; prepare() moves them aside and rebuilds.
        let data = try Data(contentsOf: snapshot)
        try data.prefix(data.count / 2).write(to: snapshot)
        XCTAssertThrowsError(try makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }.loadSnapshot()) {
            guard case .corrupt? = $0 as? LightningSnapshotError else { return XCTFail("\($0)") }
        }
        var flipped = data
        flipped[24] ^= 0xFF // stored CRC-32 of the payload
        try flipped.write(to: snapshot)
        XCTAssertThrowsError(try makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }.loadSnapshot()) {
            XCTAssertEqual($0 as? LightningSnapshotError, .corrupt("checksum"))
        }
        try Data("not an index".utf8).write(to: snapshot)
        let recovered = makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }
        XCTAssertEqual(recovered.prepare().stage, .ready)
        XCTAssertEqual(recovered.count, index.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path + ".corrupt"))
        XCTAssertNoThrow(try makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }.loadSnapshot())
    }

    func testDecodeRejectsInconsistentPayload() throws {
        var storage = LightningStorage()
        let parent = storage.append(name: "folder", parent: -1, flags: LightningEntryFlag.directory)
        storage.append(name: "child.txt", parent: parent, flags: 0, size: 3)
        let header = LightningSnapshotHeader(fingerprint: 1, lastEventID: 2, savedAt: 3, limit: .memory, roots: ["/x"], volumeUUIDs: [""])
        let payload = LightningSnapshot.encode(storage, header: header)
        let (decoded, decodedHeader) = try LightningSnapshot.decode(payload)
        XCTAssertEqual(decodedHeader, header)
        XCTAssertEqual(decoded.path(1), "/folder/child.txt")
        var broken = storage
        broken.parent[1] = 5
        XCTAssertThrowsError(try LightningSnapshot.decode(LightningSnapshot.encode(broken, header: header)))
        broken = storage
        broken.nameOffset[1] = UInt32(storage.bytes.count)
        XCTAssertThrowsError(try LightningSnapshot.decode(LightningSnapshot.encode(broken, header: header)))
    }

    func testLimitsAndStatus() throws {
        try makeFixture()
        let limited = makeIndex { $0.maximumEntries = 5 }
        let collected = StatusCollector()
        limited.statusHandler = { collected.append($0) }
        XCTAssertEqual(limited.rebuild().stage, .limited(.entries))
        XCTAssertLessThanOrEqual(limited.count, 5)
        XCTAssertTrue(collected.stages.contains(.indexing))
        let memory = makeIndex { $0.maximumMemoryBytes = 1 }
        // The memory limit is checked every few folders; with 32 or fewer folders the crawl may finish first.
        for number in 0..<40 { try folder("many/\(number)") }
        XCTAssertEqual(memory.rebuild().stage, .limited(.memory))
        let missing = LightningIndex(configuration: LightningIndexConfiguration(roots: [root.appendingPathComponent("nope")]))
        XCTAssertEqual(missing.rebuild().stage, .failed("Search index unavailable"))
        XCTAssertEqual(missing.count, 0)
        XCTAssertEqual(try makeEngine(missing).search("x").totalCount, 0)
        let unbuilt = makeIndex()
        XCTAssertEqual(unbuilt.status.stage, .idle)
        XCTAssertEqual(try makeEngine(unbuilt).search("report").rows, [])
        var configuration = LightningIndexConfiguration.default
        XCTAssertFalse(configuration.indexesGitInternals)
        configuration.indexesGitInternals = true
        XCTAssertFalse(configuration.contentsExcludedNames.contains(".git"))
        XCTAssertEqual(configuration.maximumEntries, 2_000_000)
    }

    func testWatchingPicksUpRealChanges() throws {
        try makeFixture()
        let index = makeIndex { $0.eventLatency = 0.05 }
        index.rebuild()
        index.startWatching()
        defer { index.stop() }
        let engine = makeEngine(index)
        Thread.sleep(forTimeInterval: 0.3)
        try file("Documents/watched-file.txt", "w")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, names(engine, "watched-file").isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(names(engine, "watched-file"), ["watched-file.txt"])
        XCTAssertGreaterThan(index.lastEventID, 0)
    }

    func testStartLoadsOrBuildsThenWatches() throws {
        try makeFixture()
        let snapshot = root.appendingPathComponent("state/index.snapshot")
        let index = makeIndex(snapshot: snapshot) {
            $0.excludedPaths = [self.rootPath + "/state"]
            $0.eventLatency = 0.05
        }
        index.start()
        defer { index.stop() }
        var deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !index.status.stage.isSearchable { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(index.status.stage, .ready)
        let engine = makeEngine(index)
        XCTAssertEqual(names(engine, "notes"), ["Notes.md"])
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !FileManager.default.fileExists(atPath: snapshot.path) { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents/Notes.md"))
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !names(engine, "notes").isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(names(engine, "notes"), [])
        // A second index with the same snapshot starts from it instead of crawling.
        index.stop()
        try index.saveSnapshot()
        let second = makeIndex(snapshot: snapshot) { $0.excludedPaths = [self.rootPath + "/state"] }
        let collected = StatusCollector()
        second.statusHandler = { collected.append($0) }
        XCTAssertEqual(second.prepare().stage, .ready)
        XCTAssertTrue(collected.stages.contains(.loadingSnapshot))
        XCTAssertFalse(collected.stages.contains(.indexing))
        XCTAssertEqual(second.count, index.count)
    }

    // MARK: Performance (DIRDESK_PERF=1)

    func testPerformanceSyntheticMillionEntries() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIRDESK_PERF"] == "1", "Set DIRDESK_PERF=1 to run")
        let clock = ContinuousClock()
        let words = ["report", "invoice", "photo", "notes", "draft", "budget", "main", "readme", "index", "data", "Résumé", "设计"]
        let extensions = ["pdf", "txt", "jpg", "swift", "md", "docx", "png", "zip", "mp3", "json"]
        let buildStart = clock.now
        var storage = LightningStorage()
        storage.reserveCapacity(1_001_100, nameBytes: 32_000_000)
        let top = storage.append(name: "Synthetic", parent: -1, flags: LightningEntryFlag.root | LightningEntryFlag.directory)
        var folders: [Int32] = []
        for number in 0..<1_000 {
            let parent = number < 100 ? top : folders[number % 100]
            folders.append(storage.append(name: "folder \(number) \(words[number % words.count])", parent: parent,
                                          flags: LightningEntryFlag.directory, modified: 1_700_000_000, created: 1_600_000_000))
        }
        var generator = SystemRandomNumberGenerator()
        for number in 0..<1_000_000 {
            let word = words[number % words.count], ext = extensions[(number / 7) % extensions.count]
            storage.append(name: "\(word)_\(number) v\(number % 13).\(ext)", parent: folders[number % folders.count], flags: 0,
                           size: Int64(generator.next() % 50_000_000), modified: 1_600_000_000 + Double(number % 90_000_000),
                           created: 1_500_000_000 + Double(number))
        }
        let buildTime = clock.now - buildStart
        let index = makeIndex()
        index.install(storage, stage: .ready, eventID: 0)
        let engine = makeEngine(index)
        var report = ["entries: \(storage.count)", "build: \(buildTime)",
                      "memory estimate: \(storage.estimatedMemoryBytes / 1_048_576) MiB"]
        func measure(_ label: String, _ expression: String, sort: LightningSortKey = .none, limit: Int = 500) throws {
            _ = try engine.search(expression, sort: sort, limit: limit)
            let start = clock.now
            let result = try engine.search(expression, sort: sort, limit: limit)
            report.append("\(label) [\(expression)] sort=\(sort.rawValue): \(clock.now - start), \(result.totalCount) matches")
        }
        try measure("substring", "report")
        try measure("rare substring", "report_99999")
        try measure("no match", "zzzzzz")
        try measure("unicode", "résumé")
        try measure("wildcard", "notes_1*.md")
        try measure("two terms", "budget v7")
        try measure("or + not", "photo|draft !jpg")
        try measure("ext", "ext:pdf;zip")
        try measure("type", "type:picture")
        try measure("size", "size:>40mb")
        try measure("date", "dm:2023")
        try measure("path", "invoice/**")
        try measure("everything sorted by name", "", sort: .name)
        try measure("substring sorted by size", "report", sort: .size)
        try measure("substring sorted by path", "report", sort: .path)
        try measure("regex", "regex:^readme_\\d+5 v")
        let snapshot = root.appendingPathComponent("perf.snapshot")
        let saveStart = clock.now
        try LightningSnapshot.write(storage, header: LightningSnapshotHeader(fingerprint: 0, lastEventID: 0, savedAt: 0, limit: nil,
                                                                              roots: [], volumeUUIDs: []), to: snapshot)
        let saveTime = clock.now - saveStart
        let loadStart = clock.now
        let (loaded, _) = try LightningSnapshot.read(from: snapshot)
        let loadTime = clock.now - loadStart
        let fileSize = (try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? Int) ?? 0
        report.append("snapshot save: \(saveTime), load: \(loadTime), file: \(fileSize / 1_048_576) MiB, entries: \(loaded.count)")
        let rankStart = clock.now
        _ = LightningIndex.computeFolderRanks(storage)
        report.append("folder ranks for path sort (cold): \(clock.now - rankStart)")
        // A real crawl of a large read-only tree (never the home folder).
        let system = LightningIndex(configuration: LightningIndexConfiguration(
            roots: [URL(fileURLWithPath: "/usr")], excludedPaths: [], descendsIntoPackages: true, autosaveInterval: nil))
        let crawlStart = clock.now
        let crawled = system.rebuild()
        report.append("crawl /usr: \(clock.now - crawlStart), \(system.count) entries, stage \(crawled.stage), unreadable folders \(crawled.unreadableFolderCount)")
        let systemEngine = makeEngine(system)
        _ = try systemEngine.search("plist")
        let systemStart = clock.now
        let systemResult = try systemEngine.search("plist")
        report.append("crawled index substring [plist]: \(clock.now - systemStart), \(systemResult.totalCount) matches")
        print("LIGHTNING-PERF\n" + report.joined(separator: "\n"))
        XCTAssertEqual(loaded.count, storage.count)
    }
}

private final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LightningIndexStatus] = []

    func append(_ status: LightningIndexStatus) {
        lock.lock()
        values.append(status)
        lock.unlock()
    }

    var stages: [LightningIndexStage] {
        lock.lock()
        defer { lock.unlock() }
        return values.map(\.stage)
    }
}

final class LightningVolumeTests: XCTestCase {
    /// Changes on the data volume are reported below its mount point when "/" is watched.
    func testDataVolumeEventPathsMapToFirmlinkedLocations() {
        XCTAssertEqual(LightningIndex.normalizedEventPath("/System/Volumes/Data/Users/me/a.txt"), "/Users/me/a.txt")
        XCTAssertEqual(LightningIndex.normalizedEventPath("/Users/me/folder/"), "/Users/me/folder")
        XCTAssertEqual(LightningIndex.normalizedEventPath("/System/Volumes/Data"), "/System/Volumes/Data")
    }

    /// A crawl from "/" passes between the system and data volumes but skips the data volume's mount point.
    func testSystemAndDataVolumesFormOneTree() throws {
        let rules = LightningCrawlRules(excludedPaths: [], excludedNames: [], contentsExcludedNames: [],
                                        includesHiddenFiles: true, descendsIntoPackages: false)
        var system = stat(), users = stat(), vm = stat()
        XCTAssertEqual(stat("/", &system), 0)
        XCTAssertEqual(stat("/Users", &users), 0)
        guard FileManager.default.fileExists(atPath: LightningCrawlRules.dataVolumePath) else { throw XCTSkip("no data volume") }
        XCTAssertTrue(rules.sameTree(users.st_dev, as: system.st_dev))
        XCTAssertTrue(rules.excludedPaths.contains(LightningCrawlRules.dataVolumePath))
        XCTAssertEqual(rules.excludedChildren["/System/Volumes"], [Array("Data".utf8)])
        if stat("/System/Volumes/VM", &vm) == 0, vm.st_dev != system.st_dev {
            XCTAssertFalse(rules.sameTree(vm.st_dev, as: system.st_dev))
        }
    }
}
