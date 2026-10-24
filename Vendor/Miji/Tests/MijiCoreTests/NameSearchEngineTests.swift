import XCTest
import Foundation
import CSQLite
import OilFindCore
import Darwin
import CryptoKit
@testable import MijiCore

final class NameSearchEngineTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var writer: OpaquePointer!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-name-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("metadata.sqlite")
        XCTAssertEqual(sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        // Intentionally no bodies, pinyin columns, name_search or name_fts.
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE roots(id TEXT PRIMARY KEY,payload TEXT NOT NULL,online INTEGER NOT NULL,enabled INTEGER NOT NULL);
            CREATE TABLE files(id INTEGER PRIMARY KEY,root_id TEXT NOT NULL,relative_path TEXT NOT NULL,name TEXT NOT NULL,
              extension TEXT NOT NULL,kind TEXT NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,inode INTEGER NOT NULL DEFAULT 0,
              content_state TEXT NOT NULL DEFAULT 'done',content_error TEXT,generation INTEGER NOT NULL DEFAULT 1);
            CREATE INDEX files_root_path ON files(root_id,relative_path);
            INSERT INTO roots VALUES('local','{}',1,1),('disk','{}',0,1);
            """)
    }
    override func tearDownWithError() throws {
        sqlite3_close(writer); writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    @discardableResult
    private func add(_ id: Int64, _ path: String, root: String = "local", name: String? = nil,
                     ext: String? = nil, kind: FileKind = .document, size: Int64 = 1, modified: Double = 1) throws -> Int64 {
        let rows = try prepare("INSERT INTO files(id,root_id,relative_path,name,extension,kind,size,modified) VALUES(?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(rows) }
        sqlite3_bind_int64(rows, 1, id)
        let filename = name ?? URL(fileURLWithPath: path).lastPathComponent
        for (i, value) in [root,path,filename,ext ?? URL(fileURLWithPath: filename).pathExtension.lowercased(),kind.rawValue].enumerated() {
            bind(value, to: rows, at: Int32(i + 2))
        }
        sqlite3_bind_int64(rows, 7, size); sqlite3_bind_double(rows, 8, modified)
        XCTAssertEqual(sqlite3_step(rows), SQLITE_DONE, String(cString: sqlite3_errmsg(writer)))
        return id
    }
    private func engine() throws -> NameSearchEngine {
        let e = try NameSearchEngine(databaseURL: url)
        XCTAssertFalse(e.isReady)
        try e.load()
        XCTAssertTrue(e.isReady)
        return e
    }

    func testMetadataOnlyChineseShortWordsPinyinAndOriginalSQLiteIDs() throws {
        let largeID = Int64(UInt32.max) + 177
        try add(largeID, "课程/数学分析.pdf", root: "disk")
        try add(81, "课程/几何.png", kind: .image)
        let e = try engine()
        for term in ["数", "数学", "数学分析", "shuxue", "sx", "sxfx", "shuxuefenxipdf"] {
            XCTAssertEqual(try e.search(term, options: SearchOptions(scope: .name)), [largeID], term)
        }
        XCTAssertEqual(try e.search("shuxue", options: SearchOptions(scope: .all)), [largeID])
        XCTAssertTrue(try e.search("正文不存在").isEmpty)
        XCTAssertThrowsError(try e.search("数学", options: SearchOptions(scope: .content)))
        let schema = try strings("SELECT name FROM sqlite_master ORDER BY name")
        XCTAssertFalse(schema.contains("name_fts"))
        XCTAssertEqual(try strings("SELECT content_state FROM files ORDER BY id"), ["done", "done"])
    }

    func testContextualAndCharacterPinyinWithoutLegacyPinyinColumns() throws {
        try add(301, "重庆音乐.txt")
        let e=try engine()
        for key in ["chongqing","zhongqing","cq","zq"] {
            XCTAssertEqual(try e.search(key),[301],key)
            var ids:[Int64]=[]
            try e.forEachNameMatch(literal:key) {ids.append($0)}
            XCTAssertEqual(ids,[301],key)
            XCTAssertTrue(try e.search("\(key) -\(key)").isEmpty)
        }
        try add(302,"重庆音乐.txt",root:"disk")
        try e.refresh(rootID:"disk",relativePaths:[""],fullRescan:true)
        XCTAssertEqual(Set(try e.search("chongqing")),[301,302])
        XCTAssertEqual(try e.search("zhongqing",options:SearchOptions(onlineOnly:true)),[301])
    }

    func testQueryParserLiteralsQuotesExclusionsAndAllFilters() throws {
        try add(11, "课程/数学分析.pdf")
        try add(12, "旧课/数学分析草稿.pdf")
        try add(13, "课程/数学截图.png", kind: .image)
        try add(14, "课程/lecture notes.pdf")
        try add(15, "其它/ext:pdf.txt")
        let e = try engine()
        XCTAssertEqual(try e.search("数学 ext:.PDF kind:文档 path:课程 -草稿"), [11])
        XCTAssertEqual(try e.search("数学 -ext:pdf"), [13])
        XCTAssertEqual(try e.search("数学 -kind:图片 -path:旧课"), [11])
        XCTAssertEqual(try e.search("\"lecture notes\" ext:pdf"), [14])
        XCTAssertEqual(try e.search("\"ext:pdf\""), [15])
        XCTAssertTrue(try e.search("数学 ext:png", options: SearchOptions(kind: .document)).isEmpty)
        XCTAssertTrue(try e.search("kind:unknown").isEmpty)
        XCTAssertEqual(try e.search("数学", options: SearchOptions(kind: .image)), [13])
        XCTAssertEqual(try e.search("rnt"), [])
        try add(16, "report notes.txt")
        try e.refresh(rootID: "local", relativePaths: ["report notes.txt"], fullRescan: false)
        XCTAssertEqual(try e.search("rnt"), [16])
        try add(17, "数学Report课程.pdf")
        try e.refresh(rootID: "local", relativePaths: ["数学Report课程.pdf"], fullRescan: false)
        XCTAssertEqual(try e.search("sxrkcp"), [17])
    }

    func testCompiledTypeFiltersResolveChineseAliasesAndRawKinds() throws {
        let kinds: [FileKind] = [.document, .folder, .image, .audio, .video, .archive, .application, .code, .other]
        for (i, kind) in kinds.enumerated() {
            try add(Int64(i + 1), "item\(i)", name: "条目", ext: "bin", kind: kind)
        }
        let e = try engine()
        let aliases: [(String, Int64)] = [
            ("文档", 1), ("文件夹", 2), ("目录", 2), ("图片", 3), ("图像", 3),
            ("音频", 4), ("视频", 5), ("压缩包", 6), ("应用", 7), ("代码", 8), ("其他", 9)
        ]
        let all = (1...9).map { Int64($0) }
        for (alias, id) in aliases {
            XCTAssertEqual(try e.search("kind:\(alias)"), [id], alias)
            XCTAssertEqual(try e.search("-kind:\(alias)"), all.filter { $0 != id }, alias)
        }
        for (i, kind) in kinds.enumerated() {
            XCTAssertEqual(try e.search("kind:\(kind.rawValue.uppercased())"), [Int64(i + 1)])
        }
    }

    func testCompiledTypeFiltersKeepUnknownAndCustomMetadataSemantics() throws {
        try add(1, "first", name: "条目", ext: "pdf")
        try add(2, "second", name: "条目", ext: "png", kind: .image)
        try add(3, "third", name: "条目", ext: "", kind: .other)
        try add(4, "fourth", name: "条目", ext: "cafe\u{301}")
        // Unknown to FileKind but present in the snapshot must remain searchable.
        try exec("UPDATE files SET kind='custom-kind' WHERE id=4")
        let e = try engine()
        for query in ["kind:missing", "ext:missing", "-kind:missing ext:missing", "kind:missing -ext:missing"] {
            XCTAssertEqual(try e.search(query), [], query)
        }
        for query in ["-kind:missing", "-ext:missing", "-kind:missing -ext:missing"] {
            XCTAssertEqual(try e.search(query), [1,2,3,4], query)
        }
        XCTAssertEqual(try e.search("kind:custom-kind"), [4])
        XCTAssertEqual(try e.search("-kind:custom-kind"), [1,2,3])
        XCTAssertEqual(try e.search("kind:其他"), [3])
        XCTAssertEqual(try e.search("-kind:其他 -ext:pdf -ext:png"), [4])
        XCTAssertEqual(try e.search("ext:.CAFÉ kind:custom-kind -kind:missing"), [4])
        XCTAssertEqual(try e.search("-ext:café"), [1,2,3])
        // Empty filter values are ignored by the existing parser.
        XCTAssertEqual(try e.search("ext:. kind:"), [1,2,3,4])
        XCTAssertEqual(try e.search("kind:missing", options: SearchOptions(limit: 0)), [])
    }

    func testCompiledTypeFiltersIntersectRepeatedAndContradictoryTerms() throws {
        try add(1, "a.pdf")
        try add(2, "b.txt")
        try add(3, "c.png", kind: .image)
        let e = try engine()
        XCTAssertEqual(try e.search("kind:文档 kind:document ext:.PDF ext:pdf -kind:图片 -ext:png"), [1])
        XCTAssertEqual(try e.search("-kind:图像 -kind:image -ext:png -ext:png"), [1,2])
        for query in [
            "kind:document kind:image", "ext:pdf ext:txt",
            "kind:文档 -kind:document", "ext:.PDF -ext:pdf",
            "kind:文档 ext:pdf -kind:图片 -ext:pdf",
            "kind:missing -kind:missing", "ext:missing -ext:missing"
        ] {
            XCTAssertEqual(try e.search(query), [], query)
        }
        XCTAssertEqual(try e.search("kind:图片", options: SearchOptions(kind: .document)), [])
        XCTAssertEqual(try e.search("-kind:文档", options: SearchOptions(kind: .document)), [])
        XCTAssertEqual(try e.search("-kind:missing ext:pdf", options: SearchOptions(kind: .document)), [1])
        XCTAssertEqual(try e.search("-kind:missing", options: SearchOptions(kind: .audio)), [])
    }

    func testCompiledTypeFiltersPreserveRootPathOfflineSortAndLimit() throws {
        try add(1, "课程/a.pdf", size: 2, modified: 10)
        try add(2, "课程/b.pdf", root: "disk", size: 3, modified: 30)
        try add(3, "课程/c.pdf", size: 1, modified: 20)
        try add(4, "课程/d.png", kind: .image, size: 90, modified: 90)
        try add(5, "课程/e.txt", size: 80, modified: 80)
        try add(6, "其它/z.pdf", size: 70, modified: 70)
        let e = try engine()
        let query = "kind:文档 ext:pdf -kind:图片 -ext:txt -kind:missing -ext:missing path:课程"
        XCTAssertEqual(try e.search(query), [1,2,3])
        XCTAssertEqual(try e.search(query, options: SearchOptions(kind: .document, sort: .name)), [1,2,3])
        XCTAssertEqual(try e.search(query, options: SearchOptions(sort: .modified)), [2,3,1])
        XCTAssertEqual(try e.search(query, options: SearchOptions(sort: .size, limit: 2)), [2,1])
        XCTAssertEqual(try e.search(query, options: SearchOptions(rootID: "local", onlineOnly: true)), [1,3])
        XCTAssertEqual(try e.search(query, options: SearchOptions(rootID: "disk")), [2])
        XCTAssertEqual(try e.search(query, options: SearchOptions(rootID: "disk", onlineOnly: true)), [])
        XCTAssertEqual(try e.search(query, options: SearchOptions(kind: .image)), [])
        XCTAssertEqual(try e.search(query + " -path:课程/b"), [1,3])
        try exec("UPDATE roots SET online=1 WHERE id='disk'")
        XCTAssertEqual(try e.search(query, options: SearchOptions(rootID: "disk", onlineOnly: true)), [2])
    }

    func testMultiRootOfflineAndAvailabilityWithoutReload() throws {
        try add(21, "数学.pdf"); try add(22, "数学.pdf", root: "disk")
        let e = try engine()
        XCTAssertEqual(try e.search("数学"), [21,22])
        XCTAssertEqual(try e.search("数学", options: SearchOptions(rootID: "disk")), [22])
        XCTAssertEqual(try e.search("数学", options: SearchOptions(onlineOnly: true)), [21])
        try exec("UPDATE roots SET online=1,enabled=0 WHERE id='disk'")
        XCTAssertEqual(try e.search("数学", options: SearchOptions(onlineOnly: true)), [21,22])
        try exec("DELETE FROM roots WHERE id='disk'")
        XCTAssertEqual(try e.search("数学"), [21])
        XCTAssertTrue(try e.search("数学", options: SearchOptions(rootID: "missing")).isEmpty)
    }

    func testStableSortingExactSizesAndFractionalTimes() throws {
        try add(30, "a2.pdf", size: 4_000_000_000_001, modified: 8.25)
        try add(31, "a10.pdf", size: 4_000_000_000_002, modified: 8.75)
        try add(32, "a2.pdf", root: "disk", size: 1, modified: 8.5)
        let e = try engine()
        XCTAssertEqual(try e.search("", options: SearchOptions(sort: .name)), [31,30,32])
        XCTAssertEqual(try e.search("", options: SearchOptions(sort: .size)), [31,30,32])
        XCTAssertEqual(try e.search("", options: SearchOptions(sort: .modified)), [31,32,30])
        XCTAssertEqual(try e.search("", options: SearchOptions(limit: 2)), [31,30])
        XCTAssertEqual(try e.search("", options: SearchOptions(limit: 0)), [])
        XCTAssertEqual(try e.search("", options: SearchOptions(limit: -1)), [])
    }

    func testUnicodeNormalizationEmbeddedNULAndNoCrossNameBoundaryMatch() throws {
        try add(41, "cafe.txt", name: "CAFE\u{301}.TXT")
        try add(42, "first", name: "abcd")
        try add(43, "second", name: "efgh")
        try add(44, "nul", name: "foo\0bar")
        let e = try engine()
        XCTAssertEqual(try e.search("café"), [41])
        XCTAssertEqual(try e.search("cafe"), [41])
        XCTAssertTrue(try e.search("def").isEmpty)
        XCTAssertEqual(try e.search("\"foo\0bar\""), [44])
    }

    func testLazyASCIIKeysAndScoresMatchLiteralReference() throws {
        let filenames = ["ABCD-efgh.123.txt", "Ab_Cd.pdf", "zzabcdgh.txt", "lecture notes.txt", "a123-007z.txt", "txt", String(repeating: "q", count: 600) + "-word.txt"]
        for (i, name) in filenames.enumerated() { try add(Int64(100 + i), "item\(i)", name: name) }
        let e = try engine()
        let reference = filenames.enumerated().map { i, source -> (id: Int64, name: String, full: String, initials: String) in
            let name = source.lowercased()
            let words = name.split { !$0.isLetter && !$0.isNumber }
            return (Int64(100 + i), name, words.joined(), String(words.compactMap(\.first)))
        }
        for needle in ["abcd", "cdef", "ae1t", "acp", "cdp", "z", "txt", "-", ".", "_", "999", "notfound", "qw"] {
            let scored = reference.compactMap { row -> (id: Int64, name: String, score: Int)? in
                let score = (row.name.contains(needle) ? 100 : 0) + (row.full.contains(needle) ? 70 : 0) + (row.initials.contains(needle) ? 70 : 0)
                return score == 0 ? nil : (row.id, row.name, score)
            }.sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
            XCTAssertEqual(try e.search(needle), scored.map(\.id), needle)
        }
    }

    func testCompactASCIIAliasesScoresAndBooleanTermsAcrossParallelBatches() throws {
        let samples = ["", "---", ".a--", "abcd", "a.b.c", "a-b-c-d-e-f-g-h-i", "ab___cd.pdf",
                       "report notes.txt", "foo\0bar", "\t-abc123-007z\n.txt", "123", "9-0",
                       String(repeating: "q", count: 600) + "-word.txt", "\u{7f}..word..", "_x_"]
        let core = CompactNameIndex()
        for i in 0..<35_123 { try core.append(samples[i % samples.count]) }
        // Include tombstones at worker and batch boundaries, then append again.
        let removed: Set<UInt32> = [0, 4095, 8191, 8192, 16383, 24575, 32767, 32768]
        for id in removed { core.remove(id) }
        try core.append("new-name.txt")
        let keys = (samples + ["new-name.txt"]).map { name -> (String, String, String) in
            let words = name.split { !$0.isLetter && !$0.isNumber }
            return (name, words.joined(), String(words.compactMap(\.first)))
        }
        var queries = ["", "abc", "cdef", "abcdefghi", "acp", "rnt", "foobar", "qw", "q", "t", "0", "---", "_", "\0", "notfound"]
            .map { [CompactNameIndex.Term(value: $0, excluded: false)] }
        queries += [[], [.init(value: "q", excluded: true)],
                    [.init(value: "abc", excluded: false), .init(value: "pdf", excluded: false)],
                    [.init(value: "abc", excluded: false), .init(value: "acp", excluded: true)],
                    [.init(value: "qw", excluded: true), .init(value: "t", excluded: false)],
                    [.init(value: "", excluded: true)]]
        for terms in queries {
            var expectedIDs: [UInt32] = [], expectedScores: [Int32] = []
            for i in 0..<core.count where !removed.contains(UInt32(i)) {
                let (name, full, initials) = keys[i == 35_123 ? samples.count : i % samples.count]
                var score: Int32 = 0, accepted = true
                for term in terms {
                    // The historical ASCII path treats the empty needle as a
                    // key match only when a word exists, unlike String.contains.
                    let a = term.value.isEmpty || name.contains(term.value)
                    let b = !full.isEmpty && (term.value.isEmpty || full.contains(term.value))
                    let c = !initials.isEmpty && (term.value.isEmpty || initials.contains(term.value))
                    if term.excluded ? (a || b || c) : !(a || b || c) { accepted = false; break }
                    if !term.excluded { score += (a ? 100 : 0) + (b ? 70 : 0) + (c ? 70 : 0) }
                }
                if accepted { expectedIDs.append(UInt32(i)); expectedScores.append(score) }
            }
            var ids: [UInt32] = [], scores: [Int32] = []
            try core.forEachMatch(terms, cancelled: { false }) { id, score in ids.append(id); scores.append(score) }
            let label = terms.map { ($0.excluded ? "-" : "") + $0.value }.joined(separator: " ")
            XCTAssertEqual(ids.count, expectedIDs.count, label)
            XCTAssertTrue(ids.elementsEqual(expectedIDs), "IDs: " + label)
            XCTAssertTrue(scores.elementsEqual(expectedScores), "Scores: " + label)
        }
    }

    func testParallelScanCallbacksCancellationAndThrownErrorsStayOnCaller() throws {
        let core = CompactNameIndex()
        for _ in 0..<40_001 { try core.append("report notes.txt") }
        let thread = pthread_self()
        var callbacks = 0, stop = false
        XCTAssertThrowsError(try core.forEachMatch([.init(value: "rnt", excluded: false)], cancelled: {
            XCTAssertNotEqual(pthread_equal(thread, pthread_self()), 0)
            return stop
        }) { id, score in
            XCTAssertNotEqual(pthread_equal(thread, pthread_self()), 0)
            XCTAssertEqual(id, UInt32(callbacks))
            XCTAssertEqual(score, 70)
            callbacks += 1
            if callbacks == 1 { stop = true }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(callbacks, 4096)
        enum CallbackError: Error { case stopped }
        callbacks = 0
        XCTAssertThrowsError(try core.forEachMatch([.init(value: "report", excluded: false)], cancelled: { false }) { _, _ in
            callbacks += 1
            throw CallbackError.stopped
        }) { XCTAssertTrue($0 is CallbackError) }
        XCTAssertEqual(callbacks, 1)
        // The joined scan has no work left referencing its buffers after errors.
        core.remove(0)
        var first: UInt32?
        try core.forEachMatch([.init(value: "rnt", excluded: false)], cancelled: { false }) { id, _ in
            if first == nil { first = id }
        }
        XCTAssertEqual(first, 1)
    }

    func testCompactSerializationRoundTripUnicodeAliasesAndDeletedRows() throws {
        let core = CompactNameIndex()
        let names = ["数学分析.pdf", "café.txt", "foo\0bar", "abcd", ".a--", "a.b.c", "---", "",
                     "report notes.txt", "a-b-c-d-e-f-g-h-i", "👩‍💻资料.png"]
        for name in names { try core.append(name) }
        core.remove(2); core.remove(8)
        let bytes = core.serialized()
        let restored = try CompactNameIndex(serialized: bytes)
        XCTAssertEqual(restored.count, names.count)
        XCTAssertEqual(restored.serialized(), bytes)
        XCTAssertEqual(try CompactNameIndex(serialized: CompactNameIndex().serialized()).count, 0)
        for (i, name) in names.enumerated() {
            XCTAssertTrue(restored.nameEquals(UInt32(i), name))
            for j in names.indices {
                XCTAssertEqual(restored.compareNames(UInt32(i), UInt32(j)), core.compareNames(UInt32(i), UInt32(j)))
            }
        }
        for needle in ["", "数", "数学", "sx", "shuxue", "cafe", "café", "abc", "abcdefghi", "rnt", "foo\0bar", "---"] {
            for excluded in [false, true] {
                let terms = [CompactNameIndex.Term(value: needle, excluded: excluded)]
                var ids: [UInt32] = [], scores: [Int32] = []
                try core.forEachMatch(terms, cancelled: { false }) { ids.append($0); scores.append($1) }
                var restoredIDs: [UInt32] = [], restoredScores: [Int32] = []
                try restored.forEachMatch(terms, cancelled: { false }) { restoredIDs.append($0); restoredScores.append($1) }
                XCTAssertEqual(restoredIDs, ids, needle); XCTAssertEqual(restoredScores, scores, needle)
            }
        }
        // Appending after restoration must preserve all column boundaries.
        try restored.append("new-name.txt")
        restored.remove(0)
        let again = try CompactNameIndex(serialized: restored.serialized())
        XCTAssertEqual(again.count, names.count + 1)
        XCTAssertTrue(again.nameEquals(UInt32(names.count), "new-name.txt"))
    }

    func testCompactSerializationRejectsDamageAndInvalidColumnStructure() throws {
        let core = CompactNameIndex()
        try core.append("abcd")
        let valid = core.serialized()
        // magic 0..7, version 8..11, count 12..15, names length 16..19,
        // names bytes 20..24, names offsets 25..32, full length 33..36,
        // full bytes 37, full offsets 38..45, initials length 46..49,
        // initials bytes 50..51, initials offsets 52..59, live 60, alias 61.
        func reject(_ position: Int, _ value: UInt8, rehash: Bool = true) {
            var damaged = valid
            damaged[position] = value
            if rehash {
                damaged.removeLast(32)
                damaged.append(contentsOf: SHA256.hash(data: damaged))
            }
            XCTAssertThrowsError(try CompactNameIndex(serialized: damaged), "byte \(position)") {
                guard case CompactNameIndex.BuildError.invalidSerializedData = $0 else { return XCTFail("\($0)") }
            }
        }
        reject(0, 0); reject(8, 2); reject(12, 255) // header/count
        reject(16, 255); reject(20, 1) // length/sentinel
        reject(25, 0); reject(29, 255); reject(29, 4) // first/out-of-bounds/final offset
        reject(60, 2); reject(61, 128); reject(61, 16); reject(61, 31) // flags
        reject(21, 255) // ASCII row containing non-ASCII bytes
        reject(51, 45) // ASCII initial key containing punctuation
        reject(21, 122, rehash: false) // otherwise valid key byte changed
        for cut in [0, 8, 16, 33, valid.count - 1, valid.count - 32] {
            XCTAssertThrowsError(try CompactNameIndex(serialized: Data(valid.prefix(cut))))
        }
        var extra = valid
        extra.insert(0, at: extra.count - 32)
        extra.removeLast(32)
        extra.append(contentsOf: SHA256.hash(data: extra))
        XCTAssertThrowsError(try CompactNameIndex(serialized: extra))
        let multiple = CompactNameIndex()
        try multiple.append("abcdef"); try multiple.append("x")
        var decreasing = multiple.serialized()
        // names bytes occupy 20..27; offsets [1,7,8] at 28,32,36.
        decreasing[32] = 8; decreasing[36] = 7
        decreasing.removeLast(32)
        decreasing.append(contentsOf: SHA256.hash(data: decreasing))
        XCTAssertThrowsError(try CompactNameIndex(serialized: decreasing))
    }

    /// Explicit opt-in: only synthetic metadata, never a production database.
    func testControlledLargeFixtureBenchmark() throws {
        guard let value = ProcessInfo.processInfo.environment["MIJI_NAME_BENCHMARK_ROWS"],
              let count = Int(value), (500_000...1_000_000).contains(count) else {
            throw XCTSkip("Set MIJI_NAME_BENCHMARK_ROWS=500000...1000000 for the controlled benchmark")
        }
        try exec("BEGIN")
        let row = try prepare("INSERT INTO files(id,root_id,relative_path,name,extension,kind,size,modified) VALUES(?,'local',?,?,'txt','document',?,?)")
        defer { sqlite3_finalize(row) }
        for i in 0..<count {
            let name: String
            switch i % 20 {
            case 0: name = "数学分析\(i).pdf"
            case 1: name = "miji-source-\(i).swift"
            case 2: name = "readme-\(i).md"
            case 3: name = "report notes\(i).txt"
            case 4: name = "src_component_name_\(i).tsx"
            case 5: name = "abcdef\(i)"
            case 6: name = ".hidden-cache-\(i).json"
            case 7: name = "package-lock-\(i).json"
            case 8: name = "long-resource-file-\(i).pdf"
            default: name = "resource-file-\(i).txt"
            }
            sqlite3_reset(row)
            sqlite3_bind_int64(row, 1, Int64(i + 1))
            bind(name, to: row, at: 2); bind(name, to: row, at: 3)
            sqlite3_bind_int64(row, 4, Int64(i)); sqlite3_bind_double(row, 5, Double(i))
            XCTAssertEqual(sqlite3_step(row), SQLITE_DONE)
        }
        try exec("COMMIT")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let start = DispatchTime.now().uptimeNanoseconds
        let e = try engine()
        let loadMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        var results: [[String: Any]] = []
        for query in ["数学", "数学分析", "Miji", "README", "pdf", "shuxue", "sx", "rnt", "q", "不存在的文件-zz981"] {
            let expected = try e.search(query, options: SearchOptions(scope: .name, limit: 500))
            var times: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                let found = try e.search(query, options: SearchOptions(scope: .name, limit: 500))
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                XCTAssertEqual(found, expected, query)
            }
            let sorted = times.sorted()
            results.append(["query": query, "count": expected.count, "p50_ms": sorted[9], "p95_ms": sorted[18], "ms": times])
        }
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        let json = try JSONSerialization.data(withJSONObject: ["rows": count, "ascii_percent": 95, "limit": 500,
            "load_ms": loadMS, "max_rss_bytes": usage.ru_maxrss, "results": results], options: [.sortedKeys])
        print("MIJI_NAME_BENCHMARK_JSON " + String(decoding: json, as: UTF8.self))
    }

    func testPartialRefreshRenameDeleteSubtreeAndPreserveOtherRoot() throws {
        try add(51, "课程/数学.pdf")
        try add(52, "课程/下级/旧.pdf")
        try add(53, "课程额外/保留.pdf")
        try add(54, "课程/数学.pdf", root: "disk")
        let e = try engine()
        try exec("DELETE FROM files WHERE id=52; UPDATE files SET name='代数.pdf',modified=20.5,size=900 WHERE id=51")
        try add(55, "课程/下级/新增.pdf")
        try e.refresh(rootID: "local", relativePaths: ["课程", "课程/下级", "课程"], fullRescan: false)
        XCTAssertEqual(try e.search("数学"), [54])
        XCTAssertEqual(try e.search("代数"), [51])
        XCTAssertEqual(try e.search("旧"), [])
        XCTAssertEqual(try e.search("新增"), [55])
        XCTAssertEqual(try e.search("保留"), [53])
        XCTAssertEqual(try e.search("path:课程/下级"), [55])
        XCTAssertEqual(try e.search("", options: SearchOptions(sort: .modified, limit: 1)), [51])
        // Same ID remains stable through repeated name replacements.
        try exec("UPDATE files SET name='几何.pdf' WHERE id=51")
        try e.refresh(rootID: "local", relativePaths: ["课程/数学.pdf"], fullRescan: false)
        XCTAssertEqual(try e.search("代数"), [])
        XCTAssertEqual(try e.search("几何"), [51])
        try exec("DELETE FROM files WHERE id=51")
        try e.refresh(rootID: "local", relativePaths: ["课程/数学.pdf"], fullRescan: false)
        XCTAssertEqual(try e.search("几何"), [])
    }

    func testRefreshUpdatesKindExtensionSizeAndNewRoots() throws {
        try add(61, "资料.txt")
        let e = try engine()
        try exec("UPDATE files SET kind='image',extension='png',size=999,modified=99 WHERE id=61")
        try e.refresh(rootID: "local", relativePaths: ["资料.txt"], fullRescan: false)
        XCTAssertEqual(try e.search("资料 ext:png kind:图片"), [61])
        XCTAssertEqual(try e.search("资料 ext:txt"), [])
        try exec("INSERT INTO roots VALUES('new','{}',0,1)")
        try add(62, "新根/新资料.pdf", root: "new")
        try e.refresh(rootID: "new", relativePaths: [], fullRescan: true)
        XCTAssertEqual(try e.search("新资料", options: SearchOptions(rootID: "new")), [62])
        try exec("DELETE FROM files WHERE root_id='local'")
        try e.refresh(rootID: "local", relativePaths: [""], fullRescan: false)
        XCTAssertEqual(try e.search("资料"), [62])
        XCTAssertThrowsError(try e.refresh(rootID: "new", relativePaths: ["../escape"], fullRescan: false))
        XCTAssertTrue(e.isReady)
    }

    func testCancellationInvalidationAndRefreshRecovery() throws {
        try populate(12_000)
        let e = try NameSearchEngine(databaseURL: url)
        var polls = 0
        XCTAssertThrowsError(try e.load(cancelled: { polls += 1; return polls >= 30 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(e.isReady)
        try e.load()
        for query in ["不匹配", "kind:文档 ext:pdf", "kind:missing", "ext:missing", "kind:文档 -kind:文档"] {
            polls = 0
            XCTAssertThrowsError(try e.search(query, cancelled: { polls += 1; return polls >= 8 }), query) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertTrue(e.isReady)
        XCTAssertEqual(try e.search("数学000001"), [1])
        polls = 0
        XCTAssertThrowsError(try e.refresh(rootID: "local", relativePaths: ["数学000001.pdf"], fullRescan: false,
                                          cancelled: { polls += 1; return polls >= 20 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(e.isReady)
        XCTAssertThrowsError(try e.search("数学"))
        try e.load()
        XCTAssertTrue(e.isReady)
        e.invalidate()
        XCTAssertFalse(e.isReady)
        polls = 0
        XCTAssertThrowsError(try e.load(cancelled: {
            polls += 1
            if polls == 25 { e.invalidate() }
            return false
        })) { error in
            guard case NameSearchEngineError.invalidated = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(e.isReady)
        try e.load()
        XCTAssertEqual(try e.search("数学000001"), [1])
    }

    func testReadOnlyLoadDoesNotBlockWriterOrChangeSchema() throws {
        try add(71, "只读.pdf")
        let before = try strings("SELECT sql FROM sqlite_master ORDER BY name")
        try exec("BEGIN IMMEDIATE")
        let e = try engine()
        XCTAssertEqual(try e.search("只读"), [71])
        try exec("ROLLBACK")
        XCTAssertEqual(try strings("SELECT sql FROM sqlite_master ORDER BY name"), before)
        let missing = directory.appendingPathComponent("missing/not-created.sqlite")
        XCTAssertThrowsError(try NameSearchEngine(databaseURL: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testConcurrentSearchesShareReadyIndexAndProduceStableResults() throws {
        try populate(500)
        let e = try engine()
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { n in
            do {
                let id = Int64(n + 1)
                let query = String(format: "数学%06d", n + 1)
                let found = try e.search(query)
                if found != [id] { lock.lock(); failures.append("\(query): \(found)"); lock.unlock() }
            } catch { lock.lock(); failures.append(String(describing: error)); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertTrue(e.isReady)
    }

    func testImmutableClosedCheckpointedWALDatabaseNeedsNoSidecars() throws {
        try add(77, "关闭库数学.pdf", root: "disk")
        XCTAssertEqual(try intIDs("PRAGMA wal_checkpoint(TRUNCATE)"), [0])
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        writer = nil
        // SQLite may persist empty sidecars on this platform. Move only the
        // closed/checkpointed fixture main file to an escaped, sidecar-free URL.
        let closedURL = directory.appendingPathComponent("关闭 库?#.sqlite")
        try FileManager.default.moveItem(at: url, to: closedURL)
        url = closedURL
        let shm = url.path + "-shm", wal = url.path + "-wal"
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal))
        let bytes = try Data(contentsOf: url)
        let e = try NameSearchEngine(databaseURL: url, immutable: true)
        try e.load()
        XCTAssertEqual(try e.search("数学"), [77])
        XCTAssertEqual(try e.search("sx"), [77])
        XCTAssertEqual(try e.search("path:关闭库"), [77])
        XCTAssertEqual(try e.search("数学", options: SearchOptions(onlineOnly: true)), [])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal))
    }

    func testBoundedTopKMatchesSQLiteReferenceAndSmallScaleTiming() throws {
        try populate(20_000)
        let start = Date()
        let e = try engine()
        let load = Date().timeIntervalSince(start)
        let expected = try intIDs("SELECT id FROM files ORDER BY modified DESC,name,id LIMIT 17")
        XCTAssertEqual(try e.search("数学", options: SearchOptions(sort: .modified, limit: 17)), expected)
        let names = try intIDs("SELECT id FROM files ORDER BY name,id LIMIT 17")
        let searchStart = Date()
        XCTAssertEqual(try e.search("数", options: SearchOptions(limit: 17)), names)
        let search = Date().timeIntervalSince(searchStart)
        XCTAssertEqual(try e.search("", options: SearchOptions(sort: .size, limit: 17)),
                       try intIDs("SELECT id FROM files ORDER BY size DESC,name,id LIMIT 17"))
        print("Name engine fixture: 20000 metadata rows, load=\(load)s, single-Han top17=\(search)s")
    }

    private func populate(_ count: Int) throws {
        try exec("BEGIN")
        let row = try prepare("INSERT INTO files(id,root_id,relative_path,name,extension,kind,size,modified) VALUES(?,'local',?,?,'pdf','document',?,?)")
        defer { sqlite3_finalize(row) }
        for i in 1...count {
            sqlite3_reset(row); sqlite3_clear_bindings(row)
            let name = String(format: "数学%06d.pdf", count + 1 - i)
            sqlite3_bind_int64(row, 1, Int64(count + 1 - i))
            bind(name, to: row, at: 2); bind(name, to: row, at: 3)
            sqlite3_bind_int64(row, 4, Int64(i % 101)); sqlite3_bind_double(row, 5, Double(i % 89) + Double(i) / 100_000)
            XCTAssertEqual(sqlite3_step(row), SQLITE_DONE)
        }
        try exec("COMMIT")
    }
    private func bind(_ value: String, to row: OpaquePointer, at i: Int32) {
        value.utf8CString.withUnsafeBufferPointer {
            XCTAssertEqual(sqlite3_bind_text(row, i, $0.baseAddress, Int32($0.count - 1), unsafeBitCast(-1, to: sqlite3_destructor_type.self)), SQLITE_OK)
        }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &row, nil) == SQLITE_OK, let row else { throw SearchDatabaseError(message: String(cString: sqlite3_errmsg(writer))) }
        return row
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else { throw SearchDatabaseError(message: String(cString: sqlite3_errmsg(writer))) }
    }
    private func strings(_ sql: String) throws -> [String] {
        let row = try prepare(sql); defer { sqlite3_finalize(row) }
        var result: [String] = []
        while sqlite3_step(row) == SQLITE_ROW { result.append(sqlite3_column_text(row, 0).map { String(cString: $0) } ?? "") }
        return result
    }
    private func intIDs(_ sql: String) throws -> [Int64] {
        let row = try prepare(sql); defer { sqlite3_finalize(row) }
        var result: [Int64] = []
        while sqlite3_step(row) == SQLITE_ROW { result.append(sqlite3_column_int64(row, 0)) }
        return result
    }
}
