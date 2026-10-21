import Darwin
import Foundation
import XCTest
@testable import DirDeskCore

final class DirectorySizeTests: XCTestCase {
    private func temporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: url)
    }

    func testEmptyDirectory() throws {
        try temporaryDirectory { root in
            XCTAssertEqual(DirectorySizeCalculator.measure(root), .init(bytes: 0, isComplete: true))
        }
    }

    func testNestedHiddenPackageAndExactLogicalBytes() throws {
        try temporaryDirectory { root in
            try write(13, to: root.appendingPathComponent("visible"))
            try write(29, to: root.appendingPathComponent(".hidden/deep/file"))
            try write(43, to: root.appendingPathComponent("Demo.app/Contents/Resources/data"))
            try write(0, to: root.appendingPathComponent("empty"))
            XCTAssertEqual(DirectorySizeCalculator.measure(root), .init(bytes: 85, isComplete: true))
            XCTAssertEqual(DirectorySizeCalculator.measure(root.appendingPathComponent("visible")),
                           .init(bytes: 13, isComplete: true))
        }
    }

    func testSymlinkLoopAndDanglingLinkAreNotFollowed() throws {
        try temporaryDirectory { root in
            try write(31, to: root.appendingPathComponent("file"))
            let links = [("loop", "."), ("dangling", "missing"), ("file-link", "file")]
            for (name, target) in links {
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path,
                                                           withDestinationPath: target)
            }
            let linkBytes = Int64(links.reduce(0) { $0 + $1.1.utf8.count })
            XCTAssertEqual(DirectorySizeCalculator.measure(root), .init(bytes: 31 + linkBytes, isComplete: true))
            XCTAssertEqual(DirectorySizeCalculator.measure(root.appendingPathComponent("loop")),
                           .init(bytes: 1, isComplete: true))
        }
    }

    func testMissingPathIsIncomplete() throws {
        try temporaryDirectory { root in
            XCTAssertEqual(DirectorySizeCalculator.measure(root.appendingPathComponent("missing")),
                           .init(bytes: 0, isComplete: false))
        }
    }

    func testUnreadableDirectoryPreservesPartialBytes() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses POSIX directory permissions") }
        try temporaryDirectory { root in
            let locked = root.appendingPathComponent("locked")
            try write(101, to: locked.appendingPathComponent("unreadable"))
            try write(17, to: root.appendingPathComponent("readable"))
            XCTAssertEqual(chmod(locked.path, 0), 0)
            defer { chmod(locked.path, 0o700) }
            XCTAssertEqual(DirectorySizeCalculator.measure(root), .init(bytes: 17, isComplete: false))
            XCTAssertEqual(DirectorySizeCalculator.measure(locked), .init(bytes: 0, isComplete: false))
        }
    }

    func testImmediateAndMidScanCancellation() throws {
        try temporaryDirectory { root in
            for i in 0..<100 { try write(10, to: root.appendingPathComponent("file-\(i)")) }
            XCTAssertEqual(DirectorySizeCalculator.measure(root, isCancelled: { true }),
                           .init(bytes: 0, isComplete: false))
            var checks = 0
            var updates: [DirectorySizeMeasurement] = []
            let result = DirectorySizeCalculator.measure(root, isCancelled: {
                checks += 1
                return checks >= 20
            }, progress: { updates.append($0) })
            XCTAssertFalse(result.isComplete)
            XCTAssertGreaterThan(result.bytes, 0)
            XCTAssertLessThan(result.bytes, 1_000)
            XCTAssertLessThanOrEqual(checks, 21)
            XCTAssertEqual(updates.last, result)
        }
    }

    func testTimedProgressIsMonotonicAndCanCancel() throws {
        try temporaryDirectory { root in
            for i in 0..<180 { try write(3, to: root.appendingPathComponent("file-\(i)")) }
            var cancelled = false
            var updates: [DirectorySizeMeasurement] = []
            let result = DirectorySizeCalculator.measure(root, isCancelled: {
                Thread.sleep(forTimeInterval: 0.004)
                return cancelled
            }, progress: {
                updates.append($0)
                cancelled = true
            })
            XCTAssertGreaterThanOrEqual(updates.count, 2)
            XCTAssertFalse(result.isComplete)
            XCTAssertGreaterThan(result.bytes, 0)
            XCTAssertLessThan(result.bytes, 540)
            XCTAssertEqual(updates.last, result)
            XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.bytes <= $1.bytes })
            XCTAssertTrue(updates.allSatisfy { !$0.isComplete })
        }
    }

    func testSparseFileUsesLogicalSize() throws {
        try temporaryDirectory { root in
            let file = root.appendingPathComponent("sparse")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 8_388_609)
            XCTAssertEqual(DirectorySizeCalculator.measure(root), .init(bytes: 8_388_609, isComplete: true))
        }
    }
}
