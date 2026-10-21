import XCTest
@testable import DirDeskCore

final class ErrorLogTests: XCTestCase {
    func testRedactsNamesAndPaths() {
        XCTAssertEqual(ApplicationErrorLog.redact("“secret.txt” couldn’t be moved to /Users/me/Private."), "“…” couldn’t be moved to <path>.")
        XCTAssertEqual(ApplicationErrorLog.redact("无法读取“合同.pdf”。"), "无法读取“…”。")
        XCTAssertEqual(ApplicationErrorLog.redact("read/write permission denied at ~/Desktop/a b"), "read/write permission denied at <path> b")
        XCTAssertEqual(ApplicationErrorLog.redact("No space left"), "No space left")
    }

    func testCapacityReplacesOldestAndFlagsOverwrite() {
        let log = ApplicationErrorLog(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            log.record(message: "error \(index)", source: .fileOperation, date: start.addingTimeInterval(Double(index)))
        }
        XCTAssertTrue(log.overwritten)
        XCTAssertEqual(log.entries().map(\.summary), ["error 4", "error 3", "error 2"])
        XCTAssertEqual(log.entries(since: start.addingTimeInterval(3)).count, 2)
    }

    func testRecordsErrorDomainAndReport() throws {
        let log = ApplicationErrorLog()
        let entry = log.record(CocoaError(.fileWriteOutOfSpace), source: .fileOperation)
        XCTAssertEqual(entry.domain, NSCocoaErrorDomain)
        XCTAssertEqual(entry.code, CocoaError.fileWriteOutOfSpace.rawValue)
        XCTAssertEqual(entry.reference.count, 8)
        let report = log.report(since: nil, appVersion: "1.0", appBuild: "1")
        let decoded = try JSONDecoder.iso8601.decode(ApplicationErrorLog.Report.self, from: ApplicationErrorLog.encode(report))
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertFalse(decoded.overwritten)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
