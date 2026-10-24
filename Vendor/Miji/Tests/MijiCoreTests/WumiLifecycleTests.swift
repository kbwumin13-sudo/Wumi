import XCTest
import Foundation
import Darwin
import CSQLite
@testable import MijiCore

final class WumiLifecycleTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wumi-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func database(large: Bool = false) throws -> SearchDatabase {
        let db = try SearchDatabase(url: root.appendingPathComponent("source.sqlite"))
        try db.saveRoot(IndexedRoot(id: "fixture", path: root.appendingPathComponent("offline").path, isOnline: false))
        if large { try db.execute("PRAGMA wal_autocheckpoint=0; CREATE TABLE lifecycle_payload AS SELECT zeroblob(4194304) AS payload") }
        return db
    }
    private func assertNoStaging(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.contains(".backup-") }, names.joined(separator: ", "), file: file, line: line)
    }
    func testCancelledBackupNeverPublishesAndRemovesStaging() throws {
        let db = try database(large: true)
        let final = root.appendingPathComponent("cancelled.sqlite")
        var checks = 0
        XCTAssertThrowsError(try SearchDatabase.backup(from: db.url, to: final, cancelled: {
            checks += 1
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "Final must not be visible during backup")
            return checks >= 3
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        try assertNoStaging()
        XCTAssertEqual(try db.roots().count, 1)
    }
    func testSuccessfulBackupReopensWithoutSidecarsAndIncludesCommittedWAL() throws {
        let db = try database(large: true)
        let final = root.appendingPathComponent("complete.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.url.path + "-wal"))
        try SearchDatabase.backup(from: db.url, to: final, cancelled: {
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "Publish must be the final step")
            return false
        })
        for suffix in ["-wal", "-shm", "-journal"] { XCTAssertFalse(FileManager.default.fileExists(atPath: final.path + suffix)) }
        try assertNoStaging()
        let reopened = try SearchDatabase(url: final, readOnly: true, immutable: true)
        XCTAssertEqual(try reopened.roots(), try db.roots())
        let statement = try reopened.prepare("SELECT length(payload) FROM lifecycle_payload")
        defer { sqlite3_finalize(statement) }
        XCTAssertTrue(try reopened.next(statement))
        XCTAssertEqual(sqlite3_column_int(statement, 0), 4_194_304)
        let integrity = try reopened.prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(integrity) }
        XCTAssertTrue(try reopened.next(integrity))
        XCTAssertEqual(String(cString: sqlite3_column_text(integrity, 0)), "ok")
    }
    func testBackupPublicationDoesNotClobberConcurrentDestination() throws {
        let db = try database()
        let final = root.appendingPathComponent("race.sqlite")
        let winner = Data("another invocation owns this destination".utf8)
        var checks = 0
        XCTAssertThrowsError(try SearchDatabase.backup(from: db.url, to: final, cancelled: {
            checks += 1
            if checks == 2 { try! winner.write(to: final, options: .withoutOverwriting) }
            return false
        }))
        XCTAssertEqual(try Data(contentsOf: final), winner)
        try assertNoStaging()
    }
    func testFailedBackupAndPreexistingDestinationRemainUntouched() throws {
        let source = root.appendingPathComponent("invalid.sqlite")
        try Data("not a sqlite database".utf8).write(to: source)
        let final = root.appendingPathComponent("failed.sqlite")
        XCTAssertThrowsError(try SearchDatabase.backup(from: source, to: final))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        try assertNoStaging()
        let existing = Data("existing destination".utf8)
        try existing.write(to: final)
        XCTAssertThrowsError(try SearchDatabase.backup(from: source, to: final))
        XCTAssertEqual(try Data(contentsOf: final), existing)
    }
    func testBackupDoesNotReplaceDanglingDestinationSymlink() throws {
        let db = try database()
        let final = root.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(atPath: final.path, withDestinationPath: "missing.sqlite")
        XCTAssertThrowsError(try SearchDatabase.backup(from: db.url, to: final))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: final.path), "missing.sqlite")
        try assertNoStaging()
    }

    /// The fixture helper deliberately uses Foundation again, like miji-extract launching mdimport.
    /// Its nested child therefore belongs to another process group; that shell also starts a sleep grandchild.
    private func nestedHelper() throws -> URL {
        let child = root.appendingPathComponent("nested.sh")
        try """
        #!/bin/sh
        echo $$ > "$1/child.pid"
        /bin/sleep 60 &
        echo $! > "$1/grandchild.pid"
        wait
        """.write(to: child, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("FixtureHelper.swift")
        try """
        import Foundation
        import Darwin
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func record(_ name: String, _ value: Int32) throws {
            try String(value).write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try record("helper.pid", getpid())
        try record("helper.pgid", getpgrp())
        let nested = Process()
        nested.executableURL = URL(fileURLWithPath: "/bin/sh")
        nested.arguments = [root.appendingPathComponent("nested.sh").path, root.path]
        nested.standardInput = FileHandle.nullDevice
        try nested.run()
        try record("child.pgid", getpgid(nested.processIdentifier))
        nested.waitUntilExit()
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("fixture-helper")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-O", "-module-cache-path", root.appendingPathComponent("module-cache").path, source.path, "-o", binary.path]
        let compilerLog = root.appendingPathComponent("compiler.log")
        FileManager.default.createFile(atPath: compilerLog.path, contents: nil)
        let output = try FileHandle(forWritingTo: compilerLog)
        compiler.standardOutput = output; compiler.standardError = output
        try compiler.run(); compiler.waitUntilExit()
        try output.close()
        guard compiler.terminationStatus == 0 else { throw NSError(domain: "FixtureCompiler", code: Int(compiler.terminationStatus), userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: compilerLog, encoding: .utf8)]) }
        return binary
    }
    private func recordedPID(_ name: String) throws -> pid_t {
        let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text), "Missing fixture PID: \(name)")
    }
    private func fixtureReady() -> Bool {
        ["helper.pid", "child.pid", "grandchild.pid", "child.pgid"].allSatisfy { name in
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return pid > 1
        }
    }
    private func isActive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let bytes = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size)) }
        return bytes > 0 && info.pbi_status != UInt32(SZOMB)
    }
    private func cleanupFixtureProcesses() {
        for name in ["grandchild.pid", "child.pid", "helper.pid"] {
            if let pid = try? recordedPID(name), pid > 1, pid != getpid(), isActive(pid) { kill(pid, SIGKILL) }
        }
    }
    private func assertNestedStopped(file: StaticString = #filePath, line: UInt = #line) throws {
        let pids = try ["helper.pid", "child.pid", "grandchild.pid"].map(recordedPID)
        let deadline = Date().addingTimeInterval(3)
        while pids.contains(where: isActive), Date() < deadline { usleep(10_000) }
        for pid in pids { XCTAssertFalse(isActive(pid), "Fixture process \(pid) still active", file: file, line: line) }
        let helperGroup = try recordedPID("helper.pgid"), childGroup = try recordedPID("child.pgid")
        XCTAssertNotEqual(helperGroup, getpgrp(), file: file, line: line)
        XCTAssertNotEqual(childGroup, getpgrp(), file: file, line: line)
        XCTAssertNotEqual(helperGroup, childGroup, "Fixture must exercise a nested Foundation process group", file: file, line: line)
    }
    func testSuccessfulExtractionStillReturnsOutput() throws {
        let result = try runExtractionProcess("/bin/echo", arguments: ["fixture-output"], limit: 1024,
                                              context: ExtractionContext(cancelled: { false }), timeout: 2)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "fixture-output\n")
        XCTAssertFalse(result.truncated)
    }
    func testCancellationStopsNestedFoundationHelperAndSleep() throws {
        let helper = try nestedHelper()
        defer { cleanupFixtureProcesses() }
        let context = ExtractionContext { self.fixtureReady() }
        XCTAssertThrowsError(try runExtractionProcess(helper.path, arguments: [root.path], limit: 1024, context: context, timeout: 5)) {
            XCTAssertEqual($0 as? ContentExtractionError, .cancelled)
        }
        try assertNestedStopped()
    }
    func testTimeoutStopsNestedFoundationHelperAndSleep() throws {
        let helper = try nestedHelper()
        defer { cleanupFixtureProcesses() }
        XCTAssertThrowsError(try runExtractionProcess(helper.path, arguments: [root.path], limit: 1024,
                                                     context: ExtractionContext(cancelled: { false }), timeout: 1)) {
            guard case .invalidDocument(let message) = $0 as? ContentExtractionError else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(message.contains("限制"))
        }
        try assertNestedStopped()
    }
    func testFallbackCleansDescendantsAndRejectsHostProcessGroup() throws {
        let helper = try nestedHelper()
        defer { cleanupFixtureProcesses() }
        let process = Process()
        process.executableURL = helper; process.arguments = [root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while !fixtureReady(), Date() < deadline { usleep(10_000) }
        // Passing the host group deliberately exercises the rejection path. The tree fallback must suffice.
        stopExtractionProcess(process, ownedGroup: getpgrp())
        XCTAssertFalse(process.isRunning)
        try assertNestedStopped()
        XCTAssertEqual(kill(getpid(), 0), 0, "The test host must remain alive")
    }
}
