import Foundation
import Darwin

/// Paths are relative to the owning root, including an empty path for a whole
/// root. Consumers can refresh these subtrees after committed metadata batches.
public struct IndexChange: Sendable {
    public var rootID: String
    public var relativePaths: [String]
    public var fullRescan: Bool
    public init(rootID: String, relativePaths: [String], fullRescan: Bool) {
        self.rootID=rootID; self.relativePaths=relativePaths; self.fullRescan=fullRescan
    }
}

enum IndexRelativePath {
    static func validated(_ path: String) -> Bool {
        path.isEmpty || (!path.hasPrefix("/") && !path.utf8.contains(0) && !path.split(separator:"/",omittingEmptySubsequences:false).contains { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    static func from(_ path: String, root: String) -> String? {
        // Compare complete components, rather than dropping root.count from a
        // Foundation URL that may contain // or a physical Data-volume alias.
        from(canonical:IndexPathFilter.canonicalPath(path),canonicalRoot:IndexPathFilter.canonicalPath(root))
    }
    /// Both paths already passed through `IndexPathFilter.canonicalPath`.
    static func from(canonical candidate: String, canonicalRoot base: String) -> String? {
        if candidate == base { return "" }
        let prefix=base == "/" ? "/" : base + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        let relative=String(candidate.dropFirst(prefix.count))
        return validated(relative) ? relative : nil
    }
    static func contains(_ parent: String, _ child: String) -> Bool {
        parent.isEmpty || parent == child || child.hasPrefix(parent + "/")
    }
    static func coalescing(_ paths: [String]) -> [String] {
        let unique=Set(paths.filter(validated))
        if unique.contains("") { return [""] }
        return unique.filter { path in
            var parent=(path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if unique.contains(parent) { return false }
                parent=(parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }
    /// Under pressure widen only to affected subdirectories, never to the
    /// watched root merely because a numeric queue limit was crossed. Folding
    /// also stops at `minimumDepth` components: a few changed files must not turn
    /// into a rescan of a whole home folder. The result can exceed `limit`.
    static func compacting(_ paths: [String], limit: Int = 8_192, minimumDepth: Int = 4) -> [String] {
        let paths=coalescing(paths)
        guard paths.count > limit else { return paths }
        var counts:[String:Int]=[:]
        for path in paths {
            var parent=(path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if parent.split(separator:"/").count >= minimumDepth { counts[parent,default:0] += 1 }
                parent=(parent as NSString).deletingLastPathComponent
            }
        }
        let candidates=counts.keys.filter {counts[$0]! > 1}.sorted {
            let a=$0.split(separator:"/").count,b=$1.split(separator:"/").count
            if a != b {return a > b}
            if counts[$0] != counts[$1] {return counts[$0]! > counts[$1]!}
            return $0 < $1
        }
        var selected=Set<String>(),reductions:[String:Int]=[:],remaining=paths.count
        for parent in candidates where remaining > limit {
            // Carry each reduction to its ancestors once. Comparing against
            // every selected sibling made wide event storms quadratic while
            // the service lock was held.
            let covered=counts[parent]! - (reductions[parent] ?? 0)
            guard covered > 1 else {continue}
            remaining -= covered-1
            selected.insert(parent)
            var ancestor=(parent as NSString).deletingLastPathComponent
            while !ancestor.isEmpty {
                reductions[ancestor,default:0] += covered-1
                ancestor=(ancestor as NSString).deletingLastPathComponent
            }
        }
        // A root with thousands of direct child files has no narrower common
        // directory. Keep their exact paths instead of inventing a full scan.
        return coalescing(paths + selected)
    }
    /// Package children contribute to the package signature, not separate rows.
    static func packageScope(_ relative: String) -> String {
        var parts:[String]=[]
        for part in relative.split(separator:"/") {
            parts.append(String(part))
            if ["app","pages","numbers","key","keynote","rtfd","bundle","framework"].contains((String(part) as NSString).pathExtension.lowercased()) { break }
        }
        return parts.joined(separator:"/")
    }
}

/// A durable inbox: advancing an event cursor and recording its paths is one
/// atomic write. Paths remain here until a complete scan commits. A crash during
/// enumeration therefore replays work without losing deletions or new files.
struct IncrementalIndexState: Codable {
    /// A whole-root reconciliation, kept apart from the path inbox so that ordinary
    /// changes keep flowing while it waits. Automatic requests (dropped events, a
    /// changed stream root) wait for the cool-down after the previous whole scan;
    /// immediate ones (new or reconnected root, explicit rebuild) do not.
    struct FullRescan: Codable, Equatable {
        var requested: Double
        var immediate: Bool
        var reason: String
    }
    struct Root: Codable {
        var path: String
        var cursor: UInt64
        var pending: [String]
        var inFlight: [String] = []
        /// Written by earlier versions only. Interrupted scans now restart from their scope.
        var scan: FileScanCheckpoint? = nil
        var fullRescan: FullRescan? = nil
        /// The request behind a whole-root scan that is running, so an interrupted
        /// scan comes back with the same urgency after a relaunch.
        var runningFull: FullRescan? = nil
        /// When the last whole-root scan of this root completed (seconds since 1970).
        var lastFullScan: Double? = nil
    }
    var roots: [String:Root] = [:]
    /// Whole-root requests made or upgraded since the owner last logged them. Not saved.
    var announcements: [(rootID: String, immediate: Bool, reason: String)] = []
    enum CodingKeys: String, CodingKey { case roots }
    static func read(_ url: URL) -> IncrementalIndexState {
        (try? JSONDecoder().decode(Self.self,from:Data(contentsOf:url))) ?? Self()
    }
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func write(_ data: Data, to url: URL) throws {
        // A predictable sibling is excluded from events and enumeration too.
        // Foundation's .atomic uses random temporary names, which can otherwise
        // turn the index's own journal writes into an endless event feedback loop.
        let staging=url.appendingPathExtension("tmp")
        try data.write(to:staging)
        guard rename(staging.path,url.path) == 0 else {
            let code=errno
            try? FileManager.default.removeItem(at:staging)
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
    }
    func write(_ url: URL) throws { try Self.write(encoded(),to:url) }
    /// Paths only. A whole root ("") becomes a separate full-rescan request.
    /// Appending is cheap; duplicates and nested paths are folded when the inbox is
    /// taken (`takePending`) or grows large, not for every event batch.
    mutating func enqueue(_ paths: [String], rootID: String) {
        guard var root=roots[rootID] else { return }
        let scoped=paths.filter { !$0.isEmpty }
        if scoped.count != paths.count {
            requestFull(rootID:rootID,immediate:false,reason:"整盘范围的变更事件")
            root=roots[rootID] ?? root
        }
        root.pending.append(contentsOf:scoped)
        roots[rootID]=root
        if root.pending.count > Self.pendingCap { foldPending(rootID) }
    }
    /// Paths an inbox may hold after folding; beyond this, changes are everywhere.
    static let pendingCap = 16_384
    /// Folds a root's inbox. One that stays this large even after folding into
    /// directories becomes a whole-root reconciliation instead of a near-full scan.
    mutating func foldPending(_ rootID: String) {
        guard var root=roots[rootID], !root.pending.isEmpty else { return }
        root.pending=IndexRelativePath.compacting(root.pending)
        let overflow=root.pending.count > Self.pendingCap
        if overflow { root.pending=[] }
        roots[rootID]=root
        if overflow { requestFull(rootID:rootID,immediate:false,reason:"变更路径过多，改为整盘核对") }
    }
    /// Folds every inbox longer than `threshold` paths, e.g. before it is written.
    mutating func compactPending(above threshold: Int) {
        for (id,root) in roots where root.pending.count > threshold { foldPending(id) }
    }
    /// An immediate request upgrades a waiting automatic one; the first reason is kept otherwise.
    @discardableResult
    mutating func requestFull(rootID: String, immediate: Bool, reason: String, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard var root=roots[rootID] else { return false }
        if var existing=root.fullRescan {
            guard immediate && !existing.immediate else { return false }
            existing.immediate=true; existing.reason=reason
            root.fullRescan=existing
        } else {
            root.fullRescan=FullRescan(requested:now,immediate:immediate,reason:reason)
        }
        roots[rootID]=root
        announcements.append((rootID,immediate,reason))
        return true
    }
    /// Earlier versions kept a whole root in the path inbox and resumed scans from a
    /// saved traversal. Fold both into the current model: a full request plus paths.
    mutating func migrateInterruptedScans(now: Double = Date().timeIntervalSince1970) {
        for (id,var root) in roots {
            let wholeRoot=root.pending.contains("") || root.inFlight.contains("")
            let running=root.runningFull
            root.pending=IndexRelativePath.compacting((root.pending + root.inFlight).filter { !$0.isEmpty })
            root.inFlight=[]
            root.scan=nil
            root.runningFull=nil
            roots[id]=root
            if wholeRoot {
                requestFull(rootID:id,immediate:running?.immediate ?? false,reason:running?.reason ?? "继续上次未完成的整盘扫描",now:now)
            }
            foldPending(id)
        }
    }
}
