import XCTest
import Foundation
import CryptoKit
import Darwin
import OilFindCore

final class DeduplicatedNameIndexTests: XCTestCase {
    func testContextualAliasesRoundTripAndCannotCrossKeyBoundaries() throws {
        let index=DeduplicatedNameIndex()
        try index.append("重庆音乐.txt");try index.append("重庆音乐.txt")
        let restored=try DeduplicatedNameIndex(serialized:index.serialized())
        for core in [index,restored] {
            for key in ["chongqing","zhongqing","cq","zq"] {
                XCTAssertEqual(try matches(core,[.init(value:key,excluded:false)]).map(\.id),[0,1])
                XCTAssertTrue(try matches(core,[.init(value:key,excluded:false),.init(value:key,excluded:true)]).isEmpty)
            }
            // The first alias ends in txt and the next starts in chongqing.
            for seam in ["txtchongqing","txt\0chongqing","txt�chongqing"] {
                XCTAssertTrue(try matches(core,[.init(value:seam,excluded:false)]).isEmpty,seam)
            }
            core.remove(0)
            XCTAssertEqual(try matches(core,[.init(value:"chongqing",excluded:false)]).map(\.id),[1])
        }
    }

    func testDecodedNamesOwnTheirBytesAfterInputIsOverwritten() throws {
        let source=DeduplicatedNameIndex()
        try source.append("数学分析.pdf");try source.append("readme.txt");try source.append("数学分析.pdf")
        let restored=try autoreleasepool { () throws -> DeduplicatedNameIndex in
            var bytes=source.serialized()
            let value=try DeduplicatedNameIndex(serialized:bytes)
            bytes.resetBytes(in:0..<bytes.count)
            return value
        }
        try restored.prepareNameOrder(cancelled:{false})
        XCTAssertEqual(try matches(restored,[.init(value:"shuxue",excluded:false)]),try matches(source,[.init(value:"shuxue",excluded:false)]))
        XCTAssertTrue(restored.nameEquals(1,"readme.txt"))
        try restored.append("readme.txt")
        XCTAssertEqual(restored.uniqueCount,2)
    }
    private struct Match: Equatable {
        let id: UInt32
        let score: Int32
    }
    private func matches(_ index: CompactNameIndex, _ terms: [CompactNameIndex.Term]) throws -> [Match] {
        var result: [Match] = []
        try index.forEachMatch(terms, cancelled: { false }) { result.append(Match(id: $0, score: $1)) }
        return result
    }
    private func matches(_ index: DeduplicatedNameIndex, _ terms: [CompactNameIndex.Term]) throws -> [Match] {
        var result: [Match] = []
        try index.forEachMatch(terms, cancelled: { false }) { result.append(Match(id: $0, score: $1)) }
        return result
    }
    private var samples: [String] {
        ["数学分析.pdf", "数学report课程.pdf", "重庆音乐.txt", "café.txt", "cafe\u{301}.txt",
         "👩‍💻资料.png", "foo\0bar", "", "---", ".a--", "abcd", "a.b.c", "a-b-c-d-e-f-g-h-i",
         "ab___cd.pdf", "report notes.txt", "\t-abc123-007z\n.txt", "123", "9-0",
         String(repeating: "q", count: 600) + "-word.txt", "\u{7f}..word..", "_x_", "efgh", "abcd\0"]
    }
    private var queries: [[CompactNameIndex.Term]] {
        var queries = ["", "数", "数学", "shuxue", "sx", "sxfx", "shuxuefenxipdf", "sxrkcp",
                       "cafe", "café", "cafe\u{301}", "👩‍💻", "foo\0bar", "\0", "abc", "def",
                       "abcdefghi", "acp", "rnt", "foobar", "qw", "q", "t", "0", "---", "_", "absent"]
            .map { [CompactNameIndex.Term(value: $0, excluded: false)] }
        queries += [[], [.init(value: "q", excluded: true)], [.init(value: "", excluded: true)],
                    [.init(value: "abc", excluded: false), .init(value: "pdf", excluded: false)],
                    [.init(value: "abc", excluded: false), .init(value: "acp", excluded: true)],
                    [.init(value: "数学", excluded: false), .init(value: "shuxue", excluded: false)],
                    [.init(value: "qw", excluded: true), .init(value: "t", excluded: false)],
                    [.init(value: "absent", excluded: true), .init(value: "---", excluded: true)],
                    [.init(value: "abc", excluded: false), .init(value: "abc", excluded: false)]]
        return queries
    }

    func testDuplicateRowsMatchReferenceIDsOrderAndExactScores() throws {
        let reference = CompactNameIndex(), index = DeduplicatedNameIndex()
        let names = samples
        for i in 0..<35_123 {
            try reference.append(names[i % names.count]); try index.append(names[i % names.count])
        }
        for row: UInt32 in [0, 4095, 8191, 8192, 16383, 24575, 32767, 32768] {
            reference.remove(row); index.remove(row)
        }
        try reference.append("new-name.txt"); try index.append("new-name.txt")
        XCTAssertEqual(index.count, reference.count)
        XCTAssertEqual(index.uniqueCount, names.count + 1)
        for terms in queries {
            XCTAssertEqual(try matches(index, terms), try matches(reference, terms),
                           terms.map { ($0.excluded ? "-" : "") + $0.value }.joined(separator: " "))
        }
        // Check independently recognizable literal, full pinyin and initial scores.
        let cjk = DeduplicatedNameIndex()
        try cjk.append("数学分析.pdf"); try cjk.append("数学分析.pdf")
        XCTAssertEqual(try matches(cjk, [.init(value: "数学", excluded: false)]).map(\.score), [100, 100])
        XCTAssertEqual(try matches(cjk, [.init(value: "shuxue", excluded: false)]).map(\.score), [70, 70])
        XCTAssertEqual(try matches(cjk, [.init(value: "sxfx", excluded: false)]).map(\.score), [70, 70])
    }

    func testNameEqualityAndBinaryComparisonUseOriginalRowsIncludingNULAndUnicode() throws {
        let reference = CompactNameIndex(), index = DeduplicatedNameIndex()
        let names = samples + samples.reversed()
        for name in names { try reference.append(name); try index.append(name) }
        for (i, name) in names.enumerated() {
            XCTAssertTrue(index.nameEquals(UInt32(i), name))
            XCTAssertFalse(index.nameEquals(UInt32(i), name + "\0"))
            for j in names.indices {
                XCTAssertEqual(index.compareNames(UInt32(i), UInt32(j)), reference.compareNames(UInt32(i), UInt32(j)))
            }
        }
        // Swift String equality folds canonical equivalents; this byte index
        // intentionally preserves CompactNameIndex's already-normalized contract.
        XCTAssertFalse(index.nameEquals(3, "cafe\u{301}.txt"))
        XCTAssertNotEqual(index.compareNames(3, 4), 0)
    }

    func testDeletionReadditionKeepsRowsAndReusesUnreferencedName() throws {
        let index = DeduplicatedNameIndex(), reference = CompactNameIndex()
        for name in ["a.txt", "b.txt", "a.txt", "b.txt"] { try index.append(name); try reference.append(name) }
        for row: UInt32 in [0, 2, 0, 1, 3] { index.remove(row); reference.remove(row) }
        XCTAssertEqual(index.count, 4); XCTAssertEqual(index.uniqueCount, 2)
        XCTAssertTrue(try matches(index, []).isEmpty)
        for name in ["a.txt", "b.txt", "new.txt"] { try index.append(name); try reference.append(name) }
        XCTAssertEqual(index.count, 7); XCTAssertEqual(index.uniqueCount, 3)
        XCTAssertEqual(try matches(index, []), try matches(reference, []))
        XCTAssertEqual(try matches(index, []).map(\.id), [4, 5, 6])
    }

    func testPreparedNameOrderPreservesBinaryOrderingAcrossNewTailNamesAndCacheRestore() throws {
        let index = DeduplicatedNameIndex(), reference = CompactNameIndex()
        let original = ["z.txt", "a.txt", "数学.pdf", "foo\0bar", "café.txt", "cafe\u{301}.txt", "z.txt", ""]
        for name in original { try index.append(name); try reference.append(name) }
        let before = index.serialized()
        try index.prepareNameOrder(cancelled: { false })
        let prefixBytes = index.storageStatistics.orderBytes
        XCTAssertEqual(prefixBytes, index.uniqueCount * 4)
        XCTAssertEqual(index.serialized(), before, "派生排序序号不改变缓存格式")
        // New names sort before, between and after the immutable prepared prefix.
        for name in ["b.txt", "0.txt", "zz.txt", "数学.pdf", "a.txt", "💾.txt"] {
            try index.append(name); try reference.append(name)
        }
        index.remove(1); reference.remove(1)
        try index.prepareNameOrder(cancelled: { false })
        XCTAssertEqual(index.storageStatistics.orderBytes, prefixBytes, "普通追加不重排现有名称池")
        func assertOrder(_ actual: DeduplicatedNameIndex) {
            for i in 0..<reference.count {
                for j in 0..<reference.count {
                    XCTAssertEqual(actual.compareNames(UInt32(i), UInt32(j)).signum(),
                                   reference.compareNames(UInt32(i), UInt32(j)).signum())
                }
            }
        }
        assertOrder(index)
        let restored = try DeduplicatedNameIndex(serialized: index.serialized())
        try restored.prepareNameOrder(cancelled: { false })
        assertOrder(restored)
        XCTAssertEqual(try matches(restored, []), try matches(reference, []))
    }

    func testMappedSectionsMatchTheInMemoryIndexAndAcceptChanges() throws {
        let index = DeduplicatedNameIndex(), reference = DeduplicatedNameIndex()
        let names = samples
        for i in 0..<20_000 { try index.append(names[i % names.count]); try reference.append(names[i % names.count]) }
        for row: UInt32 in [0, 7, 8191, 8192, 19_999] { index.remove(row); reference.remove(row) }
        try index.prepareNameOrder(cancelled: { false }); try reference.prepareNameOrder(cancelled: { false })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miji-mapped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let magic = Data("TESTMAP1".utf8)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let writer = try CacheFileWriter(descriptor: descriptor, magic: magic)
        try index.write(to: writer, prefix: "x.")
        try writer.finish(footer: JSONEncoder().encode(writer.sections))
        close(descriptor)
        func map() throws -> DeduplicatedNameIndex {
            let file = try MappedFile(url: url)
            let trailer = try CacheFileWriter.footer(of: file, magic: magic)
            let table = try JSONDecoder().decode([String: [Int]].self, from: trailer.footer)
            return try DeduplicatedNameIndex(mapped: MappedSections(file: file, table: table, limit: trailer.limit),
                                             prefix: "x.", rows: index.count, uniqueCount: index.uniqueCount)
        }
        let mapped = try map()
        XCTAssertEqual(mapped.serialized(), index.serialized())
        func assertSame(_ label: String) throws {
            for terms in queries {
                XCTAssertEqual(try matches(mapped, terms), try matches(reference, terms),
                               label + ": " + terms.map { ($0.excluded ? "-" : "") + $0.value }.joined(separator: " "))
            }
            for i in stride(from: 0, to: reference.count, by: 997) {
                for j in [1, 30, 8193, reference.count - 1, reference.count - 2] {
                    XCTAssertEqual(mapped.compareNames(UInt32(i), UInt32(j)).signum(),
                                   reference.compareNames(UInt32(i), UInt32(j)).signum(), "\(label) \(i) \(j)")
                }
            }
        }
        try assertSame("mapped")
        // Appended names (including one already in the mapping) and removed mapped rows.
        for name in ["new-name.txt", "数学分析.pdf", "zzz.txt", "zzz.txt"] { try mapped.append(name); try reference.append(name) }
        for row: UInt32 in [1, 19_998, 20_001] { mapped.remove(row); reference.remove(row) }
        XCTAssertEqual(mapped.count, reference.count)
        try assertSame("changed")
        // Those writes stay private to the process: a new mapping reads the original rows.
        XCTAssertEqual(try map().serialized(), index.serialized())
    }

    func testPreparingNameOrderCanCancelWithoutPublishingPartialRanks() throws {
        let index = DeduplicatedNameIndex()
        for i in 0..<10_000 { try index.append("name-\(i).txt") }
        var checks = 0
        XCTAssertThrowsError(try index.prepareNameOrder(cancelled: { checks += 1; return checks == 2 })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(index.storageStatistics.orderBytes, 0)
        try index.prepareNameOrder(cancelled: { false })
        XCTAssertEqual(index.storageStatistics.orderBytes, 40_000)
        XCTAssertLessThan(index.compareNames(1, 2), 0)
    }

    func testHashBucketCollisionsAndResizingNeverMergeDifferentNames() throws {
        let reference = CompactNameIndex(), index = DeduplicatedNameIndex()
        var buckets: [UInt64: String] = [:]
        var colliding: [String] = []
        for i in 0..<100 {
            let name = "collision-\(i).txt"
            try reference.append(name)
            let bucket = reference.normalizedNameHash(UInt32(i)) & 15
            if let previous = buckets[bucket] { colliding = [previous, name]; break }
            buckets[bucket] = name
        }
        XCTAssertEqual(colliding.count, 2)
        for name in colliding + colliding { try index.append(name) }
        XCTAssertEqual(index.uniqueCount, 2)
        for i in 0..<4 { XCTAssertTrue(index.nameEquals(UInt32(i), colliding[i % 2])) }
        for i in 0..<2_000 { try index.append("unique-\(i).txt") }
        for name in colliding { try index.append(name) }
        XCTAssertEqual(index.uniqueCount, 2_002)
        XCTAssertEqual(index.count, 2_006)
        let restored = try DeduplicatedNameIndex(serialized: index.serialized())
        for i in 0..<2_000 { try restored.append("unique-\(i).txt") }
        XCTAssertEqual(restored.uniqueCount, index.uniqueCount)
        for name in colliding { try restored.append(name) }
        XCTAssertEqual(restored.uniqueCount, index.uniqueCount)
    }

    func testUniqueNameScanCrossesParallelBatchBoundaries() throws {
        let reference = CompactNameIndex(), index = DeduplicatedNameIndex()
        for i in 0..<35_123 {
            let name = "report-\(i).txt"
            try reference.append(name); try index.append(name)
        }
        for row: UInt32 in [4095, 32767, 32768] { reference.remove(row); index.remove(row) }
        XCTAssertEqual(index.uniqueCount, index.count)
        for terms: [CompactNameIndex.Term] in [[], [.init(value: "rt", excluded: false)],
                                               [.init(value: "32768", excluded: false)],
                                               [.init(value: "report", excluded: true)]] {
            XCTAssertEqual(try matches(index, terms), try matches(reference, terms))
        }
    }

    func testCancellationAndCallbackErrorsAreSynchronousAndLeaveIndexUsable() throws {
        let index = DeduplicatedNameIndex()
        for _ in 0..<40_001 { try index.append("report notes.txt") }
        let caller = pthread_self()
        var callbacks = 0, stop = false
        XCTAssertThrowsError(try index.forEachMatch([.init(value: "rnt", excluded: false)], cancelled: {
            XCTAssertNotEqual(pthread_equal(caller, pthread_self()), 0)
            return stop
        }) { id, score in
            XCTAssertNotEqual(pthread_equal(caller, pthread_self()), 0)
            XCTAssertEqual(id, UInt32(callbacks)); XCTAssertEqual(score, 70)
            callbacks += 1; stop = true
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(callbacks, 4096)
        callbacks = 0
        XCTAssertThrowsError(try index.forEachMatch([], cancelled: { true }) { _, _ in callbacks += 1 }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(callbacks, 0)
        var checks = 0
        XCTAssertThrowsError(try index.forEachMatch([], cancelled: { checks += 1; return checks == 2 }) { _, _ in
            callbacks += 1
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(callbacks, 0)
        enum Stop: Error { case callback }
        XCTAssertThrowsError(try index.forEachMatch([], cancelled: { false }) { _, _ in
            callbacks += 1; throw Stop.callback
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(callbacks, 1)
        index.remove(0)
        XCTAssertEqual(try matches(index, []).first?.id, 1)
        XCTAssertEqual(try matches(index, [.init(value: "absent", excluded: false)]).count, 0)
        checks = 0
        XCTAssertThrowsError(try index.forEachMatch([.init(value: "absent", excluded: false)], cancelled: {
            checks += 1; return checks == 6
        }) { _, _ in XCTFail("Unexpected callback") }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testEmptyIndexAndEndOfScanCancellation() throws {
        let index = DeduplicatedNameIndex()
        XCTAssertEqual(index.count, 0); XCTAssertEqual(index.uniqueCount, 0)
        XCTAssertEqual(try matches(index, []), [])
        var checks = 0
        XCTAssertThrowsError(try index.forEachMatch([], cancelled: { checks += 1; return checks == 2 }) { _, _ in
            XCTFail("Unexpected callback")
        }) { XCTAssertTrue($0 is CancellationError) }
        let restored = try DeduplicatedNameIndex(serialized: index.serialized())
        XCTAssertEqual(restored.count, 0); XCTAssertEqual(restored.uniqueCount, 0)
        try restored.append(""); XCTAssertEqual(try matches(restored, []).map(\.id), [0])
    }

    func testSerializationRoundTripAndAppendAfterRestoringAllDeadNames() throws {
        let index = DeduplicatedNameIndex(), reference = CompactNameIndex()
        let names = samples + samples
        for name in names { try index.append(name); try reference.append(name) }
        for row in names.indices where row % 3 == 0 { index.remove(UInt32(row)); reference.remove(UInt32(row)) }
        let data = index.serialized()
        let restored = try DeduplicatedNameIndex(serialized: data)
        XCTAssertEqual(restored.serialized(), data)
        XCTAssertEqual(restored.count, names.count); XCTAssertEqual(restored.uniqueCount, samples.count)
        for terms in queries { XCTAssertEqual(try matches(restored, terms), try matches(reference, terms)) }
        for row in names.indices { restored.remove(UInt32(row)); reference.remove(UInt32(row)) }
        let dead = try DeduplicatedNameIndex(serialized: restored.serialized())
        for name in samples + ["new-name.txt"] { try dead.append(name); try reference.append(name) }
        XCTAssertEqual(dead.uniqueCount, samples.count + 1)
        for terms in queries { XCTAssertEqual(try matches(dead, terms), try matches(reference, terms)) }
        XCTAssertEqual(try DeduplicatedNameIndex(serialized: dead.serialized()).serialized(), dead.serialized())
    }

    func testStorageAccountingExcludesTemporaryDataAndShowsDuplicateSavings() throws {
        let reference = CompactNameIndex(), index = DeduplicatedNameIndex()
        for _ in 0..<12_000 {
            try reference.append("数学分析report notes.txt"); try index.append("数学分析report notes.txt")
        }
        let stats = index.storageStatistics
        XCTAssertEqual(stats.rowIDBytes, 12_000 * 4)
        XCTAssertEqual(stats.liveBytes, 12_000)
        XCTAssertEqual(stats.lookupBytes, 16 * 4)
        XCTAssertGreaterThan(stats.uniqueNameBytes, 0)
        XCTAssertEqual(index.storageBytes, stats.uniqueNameBytes + 60_000 + 64)
        XCTAssertGreaterThanOrEqual(index.allocatedStorageBytes, index.storageBytes)
        XCTAssertGreaterThanOrEqual(reference.allocatedStorageBytes, reference.storageBytes)
        XCTAssertLessThan(index.storageBytes, reference.storageBytes / 4)
        XCTAssertLessThan(index.allocatedStorageBytes, reference.allocatedStorageBytes / 4)
        let data = index.serialized()
        _ = try matches(index, [])
        XCTAssertEqual(index.storageBytes, stats.totalBytes)
        XCTAssertEqual(index.allocatedStorageBytes, stats.allocatedBytes)
        XCTAssertFalse(data.isEmpty)
    }

    private func rehashed(_ data: Data) -> Data {
        var result = Data(data.dropLast(32))
        result.append(contentsOf: SHA256.hash(data: result))
        return result
    }
    private func uint32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }

    func testRejectsCorruptTruncatedIncompatibleAndStructurallyInvalidCaches() throws {
        let index = DeduplicatedNameIndex()
        for name in ["abcd", "x", "abcd"] { try index.append(name) }
        let valid = index.serialized()
        let uniqueLength = uint32(valid, 16)
        let rowOffset = 24 + uniqueLength
        func reject(_ offset: Int, _ value: UInt8, rehash: Bool = true) {
            var data = valid; data[offset] = value
            XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: rehash ? rehashed(data) : data), "offset \(offset)") {
                guard case CompactNameIndex.BuildError.invalidSerializedData = $0 else { return XCTFail("\($0)") }
            }
        }
        reject(0, 0); reject(8, 2); reject(12, 255); reject(16, 255); reject(20, 255)
        reject(rowOffset, 2); reject(rowOffset + 12, 2)
        reject(24 + 21, 122, rehash: false)
        reject(24 + 21, 122) // Outer digest valid, nested digest invalid.
        for cut in [0, 8, 24, rowOffset, valid.count - 1, valid.count - 32] {
            XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: Data(valid.prefix(cut))))
        }
        var extra = valid; extra.insert(0, at: extra.count - 32)
        XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: rehashed(extra)))
        XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: CompactNameIndex().serialized()))
        XCTAssertThrowsError(try CompactNameIndex(serialized: valid))
        var unreferenced = valid
        unreferenced[rowOffset + 4] = 0
        XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: rehashed(unreferenced)))
        // Repair both hashes to exercise nested tombstone/duplicate validation.
        var deadUnique = valid
        deadUnique[24 + uniqueLength - 32 - 4] = 0
        let inner = rehashed(Data(deadUnique[24..<(24 + uniqueLength)]))
        deadUnique.replaceSubrange(24..<(24 + uniqueLength), with: inner)
        XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: rehashed(deadUnique)))
        // Equal-length distinct names make a duplicate-name mutation possible
        // without changing offsets, lengths or the row mapping.
        let sameLength = DeduplicatedNameIndex()
        try sameLength.append("aa"); try sameLength.append("bb")
        var duplicate = sameLength.serialized()
        let innerSize = uint32(duplicate, 16)
        duplicate[24 + 23] = 97; duplicate[24 + 24] = 97
        let duplicateInner = rehashed(Data(duplicate[24..<(24 + innerSize)]))
        duplicate.replaceSubrange(24..<(24 + innerSize), with: duplicateInner)
        XCTAssertThrowsError(try DeduplicatedNameIndex(serialized: rehashed(duplicate)))
    }
}
