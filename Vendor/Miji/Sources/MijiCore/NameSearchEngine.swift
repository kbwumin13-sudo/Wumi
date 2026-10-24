import Foundation
import CSQLite
import OilFindCore

public enum NameSearchEngineError: Error, LocalizedError {
    case notReady, invalidated, contentScope, invalidRelativePath
    public var errorDescription: String? {
        switch self {
        case .notReady: return "名称索引尚未加载或已失效"
        case .invalidated: return "名称索引构建期间已失效，请重新加载"
        case .contentScope: return "名称引擎不支持正文范围，请使用正文检索接口"
        case .invalidRelativePath: return "局部刷新需要规范的相对路径"
        }
    }
}

/// Share one instance across search connections. Load/refresh on a background
/// queue after writer commits. Search never loads implicitly and returns the
/// original files.id, ready for SearchDatabase to hydrate.
///
/// Names/metadata form a read-only SQLite snapshot; .all evaluates its name branch
/// here, while the caller merges content hits. Root availability is read live on
/// every search, so unplugging a disk needs no full rebuild.
public final class NameSearchEngine: @unchecked Sendable {
    private let databaseURL: URL
    private let immutable: Bool
    private let persistsCache: Bool
    private let operationLock = NSLock(), stateLock = NSLock()
    private var snapshot: NameSnapshot?
    private var revision: UInt64 = 0
    private var cachedRevision: Int64?
    /// Rows kept in ordinary memory before `compact()` moves them into a new cache mapping.
    static let defaultCompactionRows = 262_144
    var compactionRows = NameSearchEngine.defaultCompactionRows
    /// Rows outside the sorted base (renames, inserts) need an ID lookup table in memory;
    /// past this many the snapshot is rebuilt from SQLite instead of carried forward.
    var tailRebuildRows = 65_536
    private var compactionBackoff = Date.distantPast
    private func needsRebuild(_ value: NameSnapshot) -> Bool {
        value.deadCount > max(16_384, value.liveCount / 4)
            || value.ids.count - value.baseCount > max(tailRebuildRows, value.ids.count / 10)
    }

    /// immutable is only for a closed, checkpointed database used as a benchmark.
    /// With persistsCache, a snapshot built from SQLite (or read from an older cache)
    /// is written as a mappable cache right away and then used from that mapping.
    public init(databaseURL: URL, immutable: Bool = false, persistsCache: Bool = true) throws {
        self.databaseURL = databaseURL
        self.immutable = immutable
        self.persistsCache = persistsCache && !immutable
        _ = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: { false })
    }
    /// Whether enough rows live outside the cache mapping that `compact()` would return memory.
    public var needsCompaction: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard persistsCache, let current = snapshot, Date() >= compactionBackoff else { return false }
        return current.unmappedRows >= compactionRows || needsRebuild(current)
    }
    /// Rewrites the cache from the current snapshot and continues from its mapping.
    /// Searches wait for the rewrite, so call it from a quiet moment off the main thread.
    public func compact() throws {
        // Decide under the operation lock: refresh() changes the snapshot in place.
        operationLock.lock()
        stateLock.lock(); let current = snapshot, version = revision; stateLock.unlock()
        guard persistsCache, let current, Date() >= compactionBackoff else { operationLock.unlock(); return }
        if !needsRebuild(current) {
            defer { operationLock.unlock() }
            if current.unmappedRows >= compactionRows { try persistMapped(current, version: version) }
            return
        }
        operationLock.unlock()
        // Rebuild, save and map without the operation lock: searches keep using the
        // current snapshot meanwhile. Only the journal catch-up and swap wait for it.
        let rebuilt: NameSnapshot
        do {
            let reader = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: { false })
            try reader.execute("BEGIN")
            defer { try? reader.execute("ROLLBACK") }
            rebuilt = try rebuild(reader)
        }
        try rebuilt.core.prepareNameOrder(cancelled: { false })
        guard let saved = rebuilt.changeRevision else { return }
        try NameSnapshotCache.save(rebuilt, database: databaseURL)
        let mapped = try NameSnapshotCache.load(database: databaseURL, revision: saved)
        operationLock.lock(); defer { operationLock.unlock() }
        // An invalidated engine reloads on its own; this rebuild is then stale.
        stateLock.lock(); let unchanged = revision == version; stateLock.unlock()
        guard unchanged else { return }
        let reader = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: { false })
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }
        if let latest = try catalogRevision(reader) {
            // The journal keeps 100,000 revisions. A busier rebuild window keeps the
            // current snapshot and waits before trying again.
            guard latest >= saved, latest - saved <= 100_000 else {
                compactionBackoff = Date().addingTimeInterval(600)
                return
            }
            try applyJournal(mapped, latest: latest, reader: reader)
        }
        try publish(mapped, version: version, cancelled: { false })
        cachedRevision = saved
    }
    /// Caller holds operationLock.
    private func persistMapped(_ value: NameSnapshot, version: UInt64) throws {
        guard let saved = value.changeRevision else { return }
        try NameSnapshotCache.save(value, database: databaseURL)
        cachedRevision = saved
        let mapped = try NameSnapshotCache.load(database: databaseURL, revision: saved)
        try publish(mapped, version: version, cancelled: { false })
    }
    public var indexedCount: Int {
        operationLock.lock(); defer { operationLock.unlock() }
        stateLock.lock(); defer { stateLock.unlock() }
        return snapshot?.liveCount ?? 0
    }
    /// Starts reading a mapped snapshot back into memory, e.g. when a search panel opens.
    /// The system may have dropped its pages under memory pressure; this never blocks.
    public func prefetch() {
        stateLock.lock(); let mapping = snapshot?.mapping; stateLock.unlock()
        mapping?.prefetch()
    }
    /// Internal for fixtures: the published snapshot, whether it reads from a cache mapping, and its in-memory rows.
    var currentSnapshot: NameSnapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        return snapshot
    }
    var mappedState: (mapped: Bool, unmappedRows: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (snapshot?.mapping != nil, snapshot?.unmappedRows ?? 0)
    }
    public var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return snapshot != nil
    }
    public func invalidate() {
        stateLock.lock(); defer { stateLock.unlock() }
        revision &+= 1
        snapshot = nil
    }
    /// Idempotent while ready. Call invalidate first when a complete reload is needed.
    public func load(cancelled: @escaping () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        operationLock.lock(); defer { operationLock.unlock() }
        stateLock.lock()
        let version = revision, ready = snapshot != nil
        stateLock.unlock()
        if cancelled() { throw CancellationError() }
        if ready { return }
        let reader = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: cancelled)
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }
        let new:NameSnapshot
        cachedRevision=nil
        if !immutable,let latest=try catalogRevision(reader),
           let cached=try? NameSnapshotCache.load(database:databaseURL,revision:latest) {
            cachedRevision=cached.changeRevision
            try applyJournal(cached,latest:latest,reader:reader)
            if needsRebuild(cached) {
                new=try rebuild(reader);cachedRevision=nil
            } else {new=cached}
        } else {
            new=try rebuild(reader)
        }
        try publish(new, version: version, cancelled: cancelled)
        // Snapshots built in memory (from SQLite or an older cache) move into a
        // mapping now; a mapped one only when a long journal grew its memory part.
        if persistsCache, new.mapping == nil || new.unmappedRows >= compactionRows {
            try? persistMapped(new, version: version)
        }
    }

    /// Save only at quiet lifecycle boundaries, never for each filesystem event.
    public func saveCache() throws {
        guard !immutable else {return}
        operationLock.lock();defer {operationLock.unlock()}
        stateLock.lock();let current=snapshot;stateLock.unlock()
        guard let current,let value=current.changeRevision,value != cachedRevision else {return}
        try NameSnapshotCache.save(current,database:databaseURL)
        cachedRevision=value
    }

    /// Local events regenerate only affected names. An ID-only stream reconciles
    /// deleted rows throughout this root, including deleted subtree descendants.
    /// fullRescan refreshes this root; an empty path means the whole root.
    /// Failure/cancellation leaves isReady=false; recover with load().
    public func refresh(rootID: String, relativePaths: [String], fullRescan: Bool,
                        cancelled: @escaping () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        let paths = try Self.refreshPaths(relativePaths)
        operationLock.lock(); defer { operationLock.unlock() }
        if cancelled() { throw CancellationError() }
        stateLock.lock()
        guard let current = snapshot else { stateLock.unlock(); throw NameSearchEngineError.notReady }
        let version = revision
        snapshot = nil
        stateLock.unlock()
        let reader = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: cancelled)
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }
        if let previous = current.changeRevision, let latest = try catalogRevision(reader) {
            if latest-previous > 100_000 || latest < previous {
                let rebuilt = try rebuild(reader)
                try publish(rebuilt,version:version,cancelled:cancelled)
                return
            }
            try applyJournal(current,latest:latest,reader:reader)
            if current.deadCount > max(16_384,current.liveCount/4) {
                try publish(rebuild(reader),version:version,cancelled:cancelled)
            } else { try publish(current,version:version,cancelled:cancelled) }
            return
        }
        if let root = current.rootKeys[rootID] {
            let rows = try reader.prepare("SELECT id FROM files WHERE root_id=? ORDER BY id")
            defer { sqlite3_finalize(rows) }
            try reader.bind([rootID], to: rows)
            var surviving = [UInt64](repeating: 0, count: (current.ids.count + 63) / 64)
            var base = 0
            while try reader.next(rows) {
                let id = sqlite3_column_int64(rows, 0)
                while base < current.baseCount && current.ids[base] < id { base += 1 }
                let index = current.changedIDs[id] ?? (base < current.baseCount && current.ids[base] == id ? UInt32(base) : nil)
                if let index { surviving[Int(index) / 64] |= UInt64(1) << (Int(index) % 64) }
            }
            for i in current.ids.indices {
                if i % 4096 == 0, cancelled() { throw CancellationError() }
                if current.roots[i] == root && surviving[i / 64] & (UInt64(1) << (i % 64)) == 0 { current.remove(UInt32(i)) }
            }
        }
        if fullRescan || paths.contains("") {
            try refreshRows("root_id=?", values: [rootID], current: current, reader: reader)
        } else {
            for path in paths {
                // BINARY range for path + '/': '/' sorts immediately before '0'. The row
                // and its descendants are separate queries so both use the path index.
                try refreshRows("root_id=? AND relative_path=?", values: [rootID, path], current: current, reader: reader)
                try refreshRows("root_id=? AND relative_path>=? AND relative_path<?",
                                values: [rootID, path + "/", path + "0"], current: current, reader: reader)
            }
        }
        // Bound rename/deletion tombstones. Compaction is occasional, never per query.
        if current.deadCount > max(16_384, current.liveCount / 4) {
            let rebuilt = NameSnapshot()
            let rows = try reader.prepare("SELECT \(NameSnapshot.columns) FROM files ORDER BY id")
            defer { sqlite3_finalize(rows) }
            while try reader.next(rows) { try autoreleasepool { try rebuilt.upsert(rows, reader: reader, incremental: false) } }
            rebuilt.baseCount = rebuilt.ids.count
            rebuilt.changeRevision = try catalogRevision(reader)
            try publish(rebuilt, version: version, cancelled: cancelled)
        } else {
            try publish(current, version: version, cancelled: cancelled)
        }
    }

    public func search(_ query: String, options: SearchOptions = SearchOptions(),
                       cancelled: @escaping () -> Bool = { false }) throws -> [Int64] {
        if cancelled() { throw CancellationError() }
        operationLock.lock(); defer { operationLock.unlock() }
        if cancelled() { throw CancellationError() }
        stateLock.lock(); let current = snapshot; stateLock.unlock()
        guard let current else { throw NameSearchEngineError.notReady }
        guard options.scope != .content else { throw NameSearchEngineError.contentScope }
        guard options.limit > 0 else { return [] }
        let parsed = QueryParser.parse(query)
        let reader = try NameMetadataReader(url: databaseURL, immutable: immutable, cancelled: cancelled)
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }
        let allowedRoots = try availableRoots(current, options: options, reader: reader)
        if allowedRoots.isEmpty { return [] }
        let pathTerms = parsed.terms.filter { $0.field == .path }
        let paths = pathTerms.isEmpty ? nil : try pathMatches(pathTerms, current: current, options: options, reader: reader)
        // Resolve aliases and interned keys once, before visiting candidates.
        // Missing exclusions impose no restriction; missing positive keys can
        // never match. Still visit the core to retain its cancellation checks.
        var filters: [NameMetadataFilter] = []
        var filtersPossible = true
        for term in parsed.terms where term.field == .kind || term.field == .ext {
            let isKind = term.field == .kind
            let value = isKind ? current.kindKeys[QueryParser.kindValue(term.value)] : current.extensionKeys[term.value]
            guard let value else {
                if !term.isExcluded { filtersPossible = false }
                continue
            }
            filters.append(NameMetadataFilter(value: value, isKind: isKind, isExcluded: term.isExcluded))
        }
        let kind = options.kind.flatMap { current.kindKeys[$0.rawValue] }
        if options.kind != nil && kind == nil { return [] }
        let textTerms = parsed.terms.filter { $0.field == .text }.map { CompactNameIndex.Term(value: $0.value, excluded: $0.isExcluded) }
        var heap = NameHitHeap(capacity: min(options.limit, current.liveCount)) { a, b in
            switch options.sort {
            case .relevance: if a.score != b.score { return a.score > b.score }
            case .modified: if current.modified[Int(a.index)] != current.modified[Int(b.index)] { return current.modified[Int(a.index)] > current.modified[Int(b.index)] }
            case .size: if current.sizes[Int(a.index)] != current.sizes[Int(b.index)] { return current.sizes[Int(a.index)] > current.sizes[Int(b.index)] }
            case .name: break
            }
            let order = current.core.compareNames(a.index, b.index)
            return order == 0 ? current.ids[Int(a.index)] < current.ids[Int(b.index)] : order < 0
        }
        try current.core.forEachMatch(textTerms, cancelled: cancelled) { index, score in
            let i = Int(index)
            guard filtersPossible, allowedRoots.contains(current.roots[i]), kind == nil || current.kinds[i] == kind else { return }
            if let paths, paths[i / 64] & (UInt64(1) << (i % 64)) == 0 { return }
            for filter in filters {
                let match = (filter.isKind ? current.kinds[i] : current.extensions[i]) == filter.value
                if filter.isExcluded ? match : !match { return }
            }
            heap.insert(NameRankedHit(index: index, score: score))
        }
        if cancelled() { throw CancellationError() }
        return heap.sorted().map { current.ids[Int($0.index)] }
    }

    /// Visits every name/pinyin hit synchronously, without top-N truncation or a hit array.
    public func forEachNameMatch(literal: String, cancelled: @escaping () -> Bool = { false },
                                 body: (Int64) throws -> Void) throws {
        try forEachNameMatch(literals: [literal], cancelled: cancelled, body: body)
    }
    public func forEachNameMatch(literals: [String], cancelled: @escaping () -> Bool = { false },
                                 body: (Int64) throws -> Void) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        if cancelled() { throw CancellationError() }
        stateLock.lock(); let current = snapshot; stateLock.unlock()
        guard let current else { throw NameSearchEngineError.notReady }
        let terms = literals.map { CompactNameIndex.Term(value: QueryParser.normalize($0), excluded: false) }
        try current.core.forEachMatch(terms, cancelled: cancelled) { index, _ in
            try body(current.ids[Int(index)])
        }
    }

    private func publish(_ value: NameSnapshot, version: UInt64, cancelled: () -> Bool) throws {
        try value.core.prepareNameOrder(cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        stateLock.lock(); defer { stateLock.unlock() }
        guard version == revision else { throw NameSearchEngineError.invalidated }
        snapshot = value
    }
    private func catalogRevision(_ reader:NameMetadataReader) throws -> Int64? {
        let exists=try reader.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='catalog_state'")
        defer {sqlite3_finalize(exists)}
        guard try reader.next(exists) else {return nil}
        let row=try reader.prepare("SELECT revision FROM catalog_state WHERE id=1")
        defer {sqlite3_finalize(row)}
        return try reader.next(row) ? sqlite3_column_int64(row,0) : nil
    }
    private func applyJournal(_ current:NameSnapshot,latest:Int64,reader:NameMetadataReader)throws {
        guard let previous=current.changeRevision,latest != previous else {return}
        let columns=NameSnapshot.columns.split(separator:",").map {"f."+$0}.joined(separator:",")
        let rows=try reader.prepare("SELECT \(columns),c.file_id FROM name_changes c LEFT JOIN files f ON f.id=c.file_id WHERE c.revision>? ORDER BY c.revision")
        defer {sqlite3_finalize(rows)}
        sqlite3_bind_int64(rows,1,previous)
        while try reader.next(rows) {
            try autoreleasepool {
                if sqlite3_column_type(rows,0)==SQLITE_NULL {
                    if let index=current.index(sqlite3_column_int64(rows,7)) {current.remove(index)}
                } else {try current.upsert(rows,reader:reader,incremental:true)}
            }
        }
        current.changeRevision=latest
    }
    private func rebuild(_ reader:NameMetadataReader) throws -> NameSnapshot {
        let rebuilt=NameSnapshot()
        let rows=try reader.prepare("SELECT \(NameSnapshot.columns) FROM files ORDER BY id")
        defer {sqlite3_finalize(rows)}
        while try reader.next(rows) {try autoreleasepool {try rebuilt.upsert(rows,reader:reader,incremental:false)}}
        rebuilt.baseCount=rebuilt.ids.count
        rebuilt.changeRevision=try catalogRevision(reader)
        return rebuilt
    }
    private func refreshRows(_ predicate: String, values: [String], current: NameSnapshot, reader: NameMetadataReader) throws {
        let rows = try reader.prepare("SELECT \(NameSnapshot.columns) FROM files WHERE \(predicate) ORDER BY id")
        defer { sqlite3_finalize(rows) }
        try reader.bind(values, to: rows)
        while try reader.next(rows) { try autoreleasepool { try current.upsert(rows, reader: reader, incremental: true) } }
    }
    private static func refreshPaths(_ paths: [String]) throws -> [String] {
        for path in paths where !path.isEmpty {
            guard !path.hasPrefix("/"), !path.utf8.contains(0),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw NameSearchEngineError.invalidRelativePath }
        }
        let sorted = Set(paths).sorted()
        var result: [String] = []
        for path in sorted {
            if let parent = result.last, parent.isEmpty || path.hasPrefix(parent + "/") { continue }
            result.append(path)
        }
        return result
    }
    private func availableRoots(_ current: NameSnapshot, options: SearchOptions, reader: NameMetadataReader) throws -> Set<UInt32> {
        let rows = try reader.prepare("SELECT id,online FROM roots")
        defer { sqlite3_finalize(rows) }
        var allowed: Set<UInt32> = []
        while try reader.next(rows) {
            let id = reader.text(rows, 0)
            guard options.rootID == nil || options.rootID == id,
                  !options.onlineOnly || sqlite3_column_int(rows, 1) == 1,
                  let index = current.rootKeys[id] else { continue }
            allowed.insert(index)
        }
        return allowed
    }
    private func pathMatches(_ terms: [QueryTerm], current: NameSnapshot, options: SearchOptions, reader: NameMetadataReader) throws -> [UInt64] {
        var sql = "SELECT id,relative_path FROM files"
        if options.rootID != nil { sql += " WHERE root_id=?" }
        sql += " ORDER BY id"
        let rows = try reader.prepare(sql)
        defer { sqlite3_finalize(rows) }
        if let root = options.rootID { try reader.bind([root], to: rows) }
        var bits = [UInt64](repeating: 0, count: (current.ids.count + 63) / 64)
        while try reader.next(rows) {
            autoreleasepool {
                let path = QueryParser.normalize(reader.text(rows, 1))
                if terms.allSatisfy({ $0.isExcluded != path.contains($0.value) }),
                   let index = current.index(sqlite3_column_int64(rows, 0)) {
                    bits[Int(index) / 64] |= UInt64(1) << (Int(index) % 64)
                }
            }
        }
        return bits
    }
}

private struct NameMetadataFilter {
    let value: UInt32
    let isKind: Bool
    let isExcluded: Bool
}
private struct NameRankedHit { let index: UInt32; let score: Int32 }
/// Worst hit at the root. Memory is O(limit), even for an empty/one-character query.
private struct NameHitHeap {
    private var items: [NameRankedHit] = []
    let capacity: Int
    let better: (NameRankedHit, NameRankedHit) -> Bool
    mutating func insert(_ hit: NameRankedHit) {
        guard capacity > 0 else { return }
        if items.count < capacity {
            items.append(hit)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if !better(items[parent], items[child]) { break }
                items.swapAt(parent, child); child = parent
            }
        } else if better(hit, items[0]) {
            items[0] = hit
            var parent = 0
            while parent * 2 + 1 < items.count {
                var child = parent * 2 + 1
                if child + 1 < items.count && better(items[child], items[child + 1]) { child += 1 }
                if !better(items[parent], items[child]) { break }
                items.swapAt(parent, child); parent = child
            }
        }
    }
    func sorted() -> [NameRankedHit] { items.sorted(by: better) }
}
