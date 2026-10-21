import XCTest
@testable import DirDeskCore

final class GitStatusTests: XCTestCase {
    func testParsesPorcelainV2() throws {
        let root = URL(fileURLWithPath: "/repo")
        let records = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa aaa modified.txt",
            "1 M. N... 100644 100644 100644 aaa bbb staged.txt",
            "1 MM N... 100644 100644 100644 aaa bbb sub/both.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 renamed.txt", "old.txt",
            "? untracked.txt",
            "! ignored.log",
            "",
        ]
        let data = Data(records.joined(separator: "\0").utf8)
        let status = try GitStatusService.parse(data, root: root)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.state(for: root.appendingPathComponent("modified.txt"), isDirectory: false), [.unstaged])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("staged.txt"), isDirectory: false), [.staged])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("sub/both.txt"), isDirectory: false), [.staged, .unstaged])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("conflict.txt"), isDirectory: false), [.conflict])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("renamed.txt"), isDirectory: false), [.staged])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("untracked.txt"), isDirectory: false), [.untracked])
        XCTAssertEqual(status.state(for: root.appendingPathComponent("sub"), isDirectory: true), [.unstaged], "folders show their strongest descendant state")
        XCTAssertTrue(status.state(for: root.appendingPathComponent("ignored.log"), isDirectory: false).isEmpty)
    }

    func testDetachedAndInitial() throws {
        let data = Data(["# branch.oid (initial)", "# branch.head (detached)", ""].joined(separator: "\0").utf8)
        let status = try GitStatusService.parse(data, root: URL(fileURLWithPath: "/r"))
        XCTAssertFalse(status.hasCommits)
        XCTAssertTrue(status.isDetached)
        XCTAssertNil(status.branch)
        XCTAssertTrue(status.isClean)
    }

    func testRealRepositoryWhenGitIsAvailable() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: GitStatusService.gitPath))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: GitStatusService.gitPath)
            p.arguments = ["-C", root.path] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q", "-b", "main")
        try Data("x".utf8).write(to: root.appendingPathComponent("new.txt"))
        let status = try GitStatusService.status(of: root)
        XCTAssertEqual(GitStatusService.repositoryRoot(for: root.appendingPathComponent("new.txt"))?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(status.state(for: root.appendingPathComponent("new.txt"), isDirectory: false), [.untracked])
        XCTAssertFalse(status.hasCommits)
    }
}

final class GitRepositoryRootTests: XCTestCase {
    /// URLs whose parent chain never reaches "/" (for example "/../") must not loop.
    func testRootLookupTerminates() {
        XCTAssertNil(GitStatusService.repositoryRoot(for: URL(fileURLWithPath: "/")))
        XCTAssertNil(GitStatusService.repositoryRoot(for: URL(string: "file:///../")!))
        XCTAssertNil(GitStatusService.repositoryRoot(for: URL(fileURLWithPath: "/private/var/empty/nowhere")))
    }
}
