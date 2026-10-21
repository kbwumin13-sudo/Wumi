import Foundation

/// Per-path Git state shown as badges. Order matters for folder aggregation (higher wins).
public enum GitFileState: Int, Comparable, Sendable {
    case untracked = 1, staged, unstaged, conflict

    public static func < (lhs: GitFileState, rhs: GitFileState) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GitRepositoryStatus: Sendable {
    public var root: URL
    public var branch: String?
    public var isDetached: Bool
    public var hasCommits: Bool
    public var ahead: Int
    public var behind: Int
    /// States keyed by absolute path; a path can be both staged and unstaged.
    public var states: [String: Set<GitFileState>]

    public var isClean: Bool { states.isEmpty }

    /// Badge for an item: its own states, or for folders the strongest state among descendants.
    public func state(for url: URL, isDirectory: Bool) -> Set<GitFileState> {
        let path = url.standardizedFileURL.path
        if let own = states[path] { return own }
        guard isDirectory else { return [] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var strongest: GitFileState?
        for (key, value) in states where key.hasPrefix(prefix) {
            if let maximum = value.max(), strongest.map({ maximum > $0 }) ?? true { strongest = maximum }
        }
        return strongest.map { [$0] } ?? []
    }
}

public enum GitStatusError: Error, Equatable, Sendable {
    case unavailable, timedOut, outputLimit, failed(String), invalidOutput
}

/// Runs `git status --porcelain=v2 -z --branch` with a time and output limit.
public enum GitStatusService {
    public static var gitPath = "/usr/bin/git"
    public static let timeout: TimeInterval = 3
    public static let outputLimit = 16 << 20

    /// Nearest ancestor (or the folder itself) containing `.git`, stopping at the volume root.
    /// Walks up path components (not URLs: for some URLs `deletingLastPathComponent()` of "/" yields "/../",
    /// which never stops) until a folder containing `.git` is found.
    public static func repositoryRoot(for url: URL) -> URL? {
        var components = url.standardizedFileURL.path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        let fm = FileManager.default
        for _ in 0..<256 {
            let path = "/" + components.joined(separator: "/")
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            guard !components.isEmpty else { return nil }
            components.removeLast()
        }
        return nil
    }

    public static func status(of repository: URL) throws -> GitRepositoryStatus {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { throw GitStatusError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repository.path, "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"]
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw GitStatusError.unavailable
        }
        var data = Data()
        let reader = output.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        let group = DispatchGroup()
        group.enter()
        let lock = NSLock()
        var overflow = false
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                if data.count > outputLimit { overflow = true }
                lock.unlock()
                if overflow { break }
            }
            group.leave()
        }
        if group.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0.01)) == .timedOut {
            process.terminate()
            throw GitStatusError.timedOut
        }
        if overflow {
            process.terminate()
            throw GitStatusError.outputLimit
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitStatusError.failed("git exited with \(process.terminationStatus)") }
        return try parse(data, root: repository)
    }

    /// Parses porcelain v2 `-z` output.
    public static func parse(_ data: Data, root: URL) throws -> GitRepositoryStatus {
        var status = GitRepositoryStatus(root: root.standardizedFileURL, branch: nil, isDetached: false, hasCommits: true, ahead: 0, behind: 0, states: [:])
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        func add(_ relative: String, _ state: GitFileState) {
            let path = root.appendingPathComponent(relative).standardizedFileURL.path
            status.states[path, default: []].insert(state)
        }
        while index < records.count {
            let record = records[index]
            index += 1
            if record.isEmpty { continue }
            if record.hasPrefix("# ") {
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.hasCommits = parts[2] != "(initial)"
                case "branch.head":
                    status.isDetached = parts[2] == "(detached)"
                    status.branch = status.isDetached ? nil : parts[2]
                case "branch.ab":
                    for token in parts[2].split(separator: " ") {
                        if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            let kind = record.first
            switch kind {
            case "1", "2":
                // "1 XY sub mH mI mW hH hI path" / "2 XY sub mH mI mW hH hI Xscore path" (+ origPath record)
                let fieldCount = kind == "1" ? 9 : 10
                let fields = record.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == fieldCount else { throw GitStatusError.invalidOutput }
                let xy = Array(fields[1])
                guard xy.count == 2 else { throw GitStatusError.invalidOutput }
                let path = fields[fieldCount - 1]
                if xy[0] != "." { add(path, .staged) }
                if xy[1] != "." { add(path, .unstaged) }
                if kind == "2" { index += 1 }
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard let path = fields.last else { throw GitStatusError.invalidOutput }
                add(path, .conflict)
            case "?":
                add(String(record.dropFirst(2)), .untracked)
            case "!":
                break
            default:
                throw GitStatusError.invalidOutput
            }
        }
        return status
    }
}
