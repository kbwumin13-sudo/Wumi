import Darwin
import Foundation

/// Where Lightning Search looks. Folder scopes include subfolders; the folder itself is not a result.
public enum LightningScope: Equatable, Sendable {
    /// Every watched, accessible folder ("This Computer").
    case computer
    case folder(URL)
    case folders([URL])
}

public enum LightningSortKey: String, CaseIterable, Sendable {
    /// Index order: fastest, no sorting cost.
    case none
    case name
    /// By containing folder (in path order), then by name.
    case path
    case size
    case modified
    case created
}

public struct LightningRow: Hashable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isPackage: Bool
    /// Logical size in bytes; nil for folders and packages.
    public var size: Int64?
    public var modified: Date?
    public var created: Date?

    public init(path: String, name: String, isDirectory: Bool, isPackage: Bool = false, size: Int64?, modified: Date?, created: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.created = created
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

public struct LightningSearchResult: Equatable, Sendable {
    public var rows: [LightningRow]
    /// All matches, including those beyond the limit.
    public var totalCount: Int
    public var elapsedMilliseconds: Int
    /// True when rows do not hold every match (limit reached or the search was cancelled).
    public var truncated: Bool
    public var cancelled: Bool

    public init(rows: [LightningRow] = [], totalCount: Int = 0, elapsedMilliseconds: Int = 0, truncated: Bool = false, cancelled: Bool = false) {
        self.rows = rows
        self.totalCount = totalCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.truncated = truncated
        self.cancelled = cancelled
    }
}

/// Runs Lightning queries against a `LightningIndex`.
///
/// Name matching scans the folded name column in parallel chunks (`DispatchQueue.concurrentPerform`);
/// conditions are ordered from cheap (kind, extension, size, dates, names) to expensive (regex, tags,
/// file contents) so the expensive ones only see survivors. Folder scopes outside the index are crawled
/// on demand into a short-lived index of their own.
public final class LightningSearchEngine: @unchecked Sendable {
    public let index: LightningIndex
    /// Files larger than this are skipped by `content:`.
    public var contentByteLimit: Int
    public let calendar: Calendar
    public let homeDirectory: String
    private let now: @Sendable () -> Date
    private let ephemeralLock = NSLock()
    private var ephemeral: [String: (index: LightningIndex, built: ContinuousClock.Instant)] = [:]

    public init(index: LightningIndex, contentByteLimit: Int = 16 << 20, calendar: Calendar = .current,
                homeDirectory: String = NSHomeDirectory(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.index = index
        self.contentByteLimit = contentByteLimit
        self.calendar = calendar
        self.homeDirectory = homeDirectory
        self.now = now
    }

    /// Parses `expression` and runs it.
    public func search(_ expression: String, scope: LightningScope = .computer, caseSensitive: Bool = false,
                       sort: LightningSortKey = .none, descending: Bool = false, limit: Int = 1_000,
                       isCancelled: () -> Bool = { false }) throws -> LightningSearchResult {
        try search(LightningQueryParser.parse(expression), scope: scope, caseSensitive: caseSensitive, sort: sort,
                   descending: descending, limit: limit, isCancelled: isCancelled)
    }

    /// Runs a query synchronously; call off the main thread. `isCancelled` may be called from several
    /// threads at once during long content or tag scans, so it should read thread-safe state.
    public func search(_ query: LightningQuery, scope: LightningScope = .computer, caseSensitive: Bool = false,
                       sort: LightningSortKey = .none, descending: Bool = false, limit: Int = 1_000,
                       isCancelled: () -> Bool = { false }) -> LightningSearchResult {
        let started = ContinuousClock.now
        let cancellation = LightningCancellation()
        let date = now()
        var parts: [(rows: [LightningRow], total: Int)] = []
        withoutActuallyEscaping(isCancelled) { isCancelled in
            for (storage, scopeEntries) in storages(for: scope, isCancelled: isCancelled) {
                guard !cancellation.isCancelled(isCancelled) else { break }
                parts.append(search(query, in: storage, scopeEntries: scopeEntries, caseSensitive: caseSensitive, date: date,
                                    sort: sort, descending: descending, limit: limit, cancellation: cancellation,
                                    isCancelled: isCancelled))
            }
        }
        var rows: [LightningRow]
        if parts.count == 1 {
            rows = parts[0].rows
        } else {
            rows = parts.flatMap(\.rows)
            if sort != .none {
                rows.sort { Self.rowPrecedes($0, $1, sort: sort, descending: descending) }
            }
            rows = Array(rows.prefix(max(limit, 0)))
        }
        let total = parts.reduce(0) { $0 + $1.total }
        let cancelled = cancellation.flag
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return LightningSearchResult(rows: rows, totalCount: total, elapsedMilliseconds: milliseconds,
                                     truncated: cancelled || rows.count < total, cancelled: cancelled)
    }

    // MARK: Scopes

    /// Storages to search and, for folder scopes, the folders inside each (nil = everything).
    private func storages(for scope: LightningScope, isCancelled: () -> Bool) -> [(LightningStorage, [Int32]?)] {
        let main = index.snapshot()
        let folders: [URL]
        switch scope {
        case .computer:
            return [(main, nil)]
        case let .folder(url):
            folders = [url]
        case let .folders(urls):
            folders = urls
        }
        let paths = LightningIndex.outermost(folders.map { LightningIndex.canonicalPath($0.path) })
        var indexed: [Int32] = []
        var result: [(LightningStorage, [Int32]?)] = []
        for path in paths {
            if let entry = main.lookup(path: path), Self.coversContents(of: entry, in: main, index: index) {
                indexed.append(entry)
            } else if let temporary = ephemeralIndex(for: path, isCancelled: isCancelled) {
                let storage = temporary.snapshot()
                if let entry = storage.lookup(path: path) { result.append((storage, [entry])) }
            }
        }
        if !indexed.isEmpty { result.insert((main, indexed), at: 0) }
        return result
    }

    /// Whether the index holds the contents of folder `entry` (not a package or a node_modules-style folder).
    private static func coversContents(of entry: Int32, in storage: LightningStorage, index: LightningIndex) -> Bool {
        let flags = storage.flags[Int(entry)]
        guard flags & LightningEntryFlag.directory != 0 else { return false }
        if flags & LightningEntryFlag.ancestor != 0 || flags & LightningEntryFlag.root != 0 { return true }
        if flags & LightningEntryFlag.package != 0, !index.configuration.descendsIntoPackages { return false }
        return !index.rules.contentsExcludedNames.contains(Array(storage.rawName(entry)))
    }

    /// A short-lived index for a folder the main index does not cover (outside the watched roots, excluded,
    /// or a folder whose contents are not indexed).
    private func ephemeralIndex(for path: String, isCancelled: () -> Bool) -> LightningIndex? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        ephemeralLock.lock()
        if let cached = ephemeral[path], ContinuousClock.now - cached.built < .seconds(30) {
            ephemeralLock.unlock()
            return cached.index
        }
        ephemeralLock.unlock()
        var configuration = index.configuration
        configuration.roots = [URL(fileURLWithPath: path)]
        configuration.excludedPaths = configuration.excludedPaths.filter { !LightningIndex.isPath(path, inside: LightningIndex.canonicalPath($0)) }
        configuration.maximumEntries = min(configuration.maximumEntries, 500_000)
        configuration.maximumElapsedTime = .seconds(15)
        configuration.autosaveInterval = nil
        let temporary = LightningIndex(configuration: configuration)
        temporary.rebuild(isCancelled: isCancelled)
        guard temporary.status.stage.isSearchable else { return nil }
        ephemeralLock.lock()
        ephemeral[path] = (temporary, ContinuousClock.now)
        if ephemeral.count > 4, let oldest = ephemeral.min(by: { $0.value.built < $1.value.built })?.key {
            ephemeral.removeValue(forKey: oldest)
        }
        ephemeralLock.unlock()
        return temporary
    }

    /// Forgets on-demand folder indexes so the next search rescans those folders.
    public func discardTemporaryIndexes() {
        ephemeralLock.lock()
        ephemeral.removeAll()
        ephemeralLock.unlock()
    }

    // MARK: Evaluation

    private func search(_ query: LightningQuery, in storage: LightningStorage, scopeEntries: [Int32]?, caseSensitive: Bool,
                        date: Date, sort: LightningSortKey, descending: Bool, limit: Int,
                        cancellation: LightningCancellation, isCancelled: () -> Bool) -> (rows: [LightningRow], total: Int) {
        guard storage.count > 0 else { return ([], 0) }
        let compiler = LightningPlanCompiler(storage: storage, now: date, calendar: calendar, homeDirectory: homeDirectory,
                                             contentByteLimit: contentByteLimit)
        let plan = compiler.compile(query, caseSensitive: caseSensitive)
        if plan is LightningNothingNode { return ([], 0) }
        let candidates = scopeEntries.map { Self.descendants(of: $0, in: storage) }
        let ranks = sort == .path ? index.folderRanks(for: storage) : []
        return storage.withView { view -> ([LightningRow], Int) in
            let matches = evaluate(plan, candidates: candidates, view: view, cancellation: cancellation, isCancelled: isCancelled)
            let selected = select(matches, sort: sort, descending: descending, limit: limit, view: view, ranks: ranks)
            return (selected.map { Self.row(Int($0), view) }, matches.count)
        }
    }

    /// Descendants of the scope folders (the folders themselves excluded), depth first.
    private static func descendants(of folders: [Int32], in storage: LightningStorage) -> [Int32] {
        var result: [Int32] = []
        var stack: [Int32] = []
        for folder in folders {
            var child = storage.firstChild[Int(folder)]
            while child >= 0 {
                stack.append(child)
                child = storage.nextSibling[Int(child)]
            }
        }
        while let entry = stack.popLast() {
            result.append(entry)
            var child = storage.firstChild[Int(entry)]
            while child >= 0 {
                stack.append(child)
                child = storage.nextSibling[Int(child)]
            }
        }
        return result
    }

    private func evaluate(_ plan: LightningPlanNode, candidates: [Int32]?, view: LightningStorageView,
                          cancellation: LightningCancellation, isCancelled: () -> Bool) -> [Int32] {
        let total = candidates?.count ?? view.count
        guard total > 0 else { return [] }
        let expensive = plan.cost >= LightningPlanNode.expensiveCost
        let chunkSize = expensive ? 256 : 16_384
        let chunkCount = (total + chunkSize - 1) / chunkSize
        let waveSize = max(ProcessInfo.processInfo.activeProcessorCount * (expensive ? 2 : 4), 4)
        var chunks = [[Int32]](repeating: [], count: chunkCount)
        let candidateBuffer = UnsafeMutableBufferPointer<Int32>.allocate(capacity: candidates?.count ?? 0)
        defer { candidateBuffer.deallocate() }
        if let candidates { _ = candidateBuffer.initialize(from: candidates) }
        let candidateView: UnsafeBufferPointer<Int32>? = candidates == nil ? nil : UnsafeBufferPointer(candidateBuffer)
        var next = 0
        while next < chunkCount {
            if cancellation.isCancelled(isCancelled) { break }
            let base = next, end = min(next + waveSize, chunkCount)
            chunks.withUnsafeMutableBufferPointer { results in
                DispatchQueue.concurrentPerform(iterations: end - base) { offset in
                    let chunk = base + offset
                    // A private copy of the plan: sharing node objects across threads makes every
                    // retain and release contend on the same cache line.
                    let plan = plan.copy()
                    let context = LightningEvalContext(view: view)
                    let lower = chunk * chunkSize, upper = min(lower + chunkSize, total)
                    var local: [Int32] = []
                    func visit(_ position: Int, _ entry: Int) -> Bool {
                        if expensive, position & 31 == 0, cancellation.isCancelled(isCancelled) { return false }
                        if view.flags[entry] & LightningEntryFlag.notSearchable == 0, plan.matches(entry, context) {
                            local.append(Int32(entry))
                        }
                        return true
                    }
                    if let candidateView {
                        for position in lower..<upper where !visit(position, Int(candidateView[position])) { break }
                    } else {
                        for entry in lower..<upper where !visit(entry, entry) { break }
                    }
                    results[chunk] = local
                }
            }
            next = end
        }
        return chunks.flatMap { $0 }
    }

    // MARK: Sorting

    private func select(_ matches: [Int32], sort: LightningSortKey, descending: Bool, limit: Int,
                        view: LightningStorageView, ranks: [UInt32]) -> [Int32] {
        guard limit > 0 else { return [] }
        if sort == .none { return Array(matches.prefix(limit)) }
        let precedes = Self.comparator(sort: sort, descending: descending, view: view, ranks: ranks)
        if matches.count <= limit { return matches.sorted(by: precedes) }
        return Self.smallest(limit, of: matches, by: precedes)
    }

    static func comparator(sort: LightningSortKey, descending: Bool, view: LightningStorageView,
                           ranks: [UInt32]) -> (Int32, Int32) -> Bool {
        func byName(_ a: Int, _ b: Int) -> Bool {
            let order = LightningBytes.compare(view.folded(a), view.folded(b))
            if order != 0 { return order < 0 }
            let raw = LightningBytes.compare(view.raw(a), view.raw(b))
            return raw != 0 ? raw < 0 : a < b
        }
        switch sort {
        case .none:
            return { $0 < $1 }
        case .name:
            return { a, b in
                let order = LightningBytes.compare(view.folded(Int(a)), view.folded(Int(b)))
                if order != 0 { return descending ? order > 0 : order < 0 }
                return byName(Int(a), Int(b))
            }
        case .path:
            return { a, b in
                let pa = Int(view.parent[Int(a)]), pb = Int(view.parent[Int(b)])
                if pa != pb {
                    let ra = pa >= 0 ? Int64(ranks[pa]) : -1, rb = pb >= 0 ? Int64(ranks[pb]) : -1
                    if ra != rb { return descending ? ra > rb : ra < rb }
                }
                let order = LightningBytes.compare(view.folded(Int(a)), view.folded(Int(b)))
                if order != 0 { return descending ? order > 0 : order < 0 }
                return byName(Int(a), Int(b))
            }
        case .size:
            return { a, b in
                let fa = view.isDirectory(Int(a)), fb = view.isDirectory(Int(b))
                if fa != fb { return !fa }
                if !fa {
                    let sa = view.size[Int(a)], sb = view.size[Int(b)]
                    if sa != sb { return descending ? sa > sb : sa < sb }
                }
                return byName(Int(a), Int(b))
            }
        case .modified, .created:
            let dates = sort == .modified ? view.modified : view.created
            return { a, b in
                let da = dates[Int(a)], db = dates[Int(b)]
                if da.isNaN != db.isNaN { return !da.isNaN }
                if !da.isNaN, da != db { return descending ? da > db : da < db }
                return byName(Int(a), Int(b))
            }
        }
    }

    /// The first `count` items in `precedes` order, via a bounded heap (O(n log count)).
    static func smallest(_ count: Int, of items: [Int32], by precedes: (Int32, Int32) -> Bool) -> [Int32] {
        var heap: [Int32] = []
        heap.reserveCapacity(count)
        // heap[0] is the item that comes last among those kept.
        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }
        func siftDown() {
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var latest = parent
                if left < heap.count, precedes(heap[latest], heap[left]) { latest = left }
                if right < heap.count, precedes(heap[latest], heap[right]) { latest = right }
                if latest == parent { return }
                heap.swapAt(parent, latest)
                parent = latest
            }
        }
        for item in items {
            if heap.count < count {
                heap.append(item)
                siftUp(heap.count - 1)
            } else if precedes(item, heap[0]) {
                heap[0] = item
                siftDown()
            }
        }
        return heap.sorted(by: precedes)
    }

    /// Orders rows of different storages (folder scopes outside the index) consistently with `comparator`.
    static func rowPrecedes(_ a: LightningRow, _ b: LightningRow, sort: LightningSortKey, descending: Bool) -> Bool {
        func names() -> Int { compareFolded(a.name, b.name) }
        func ordered(_ order: Int) -> Bool { descending ? order > 0 : order < 0 }
        switch sort {
        case .none:
            return false
        case .name:
            let order = names()
            return order != 0 ? ordered(order) : a.path < b.path
        case .path:
            let folders = comparePaths((a.path as NSString).deletingLastPathComponent, (b.path as NSString).deletingLastPathComponent)
            if folders != 0 { return ordered(folders) }
            let order = names()
            return order != 0 ? ordered(order) : a.path < b.path
        case .size:
            if (a.size == nil) != (b.size == nil) { return a.size != nil }
            if let sa = a.size, let sb = b.size, sa != sb { return descending ? sa > sb : sa < sb }
            return names() < 0
        case .modified, .created:
            let da = sort == .modified ? a.modified : a.created, db = sort == .modified ? b.modified : b.created
            if (da == nil) != (db == nil) { return da != nil }
            if let da, let db, da != db { return descending ? da > db : da < db }
            return names() < 0
        }
    }

    private static func compareFolded(_ a: String, _ b: String) -> Int {
        let fa = LightningText.fold(string: a), fb = LightningText.fold(string: b)
        return fa.withUnsafeBufferPointer { pa in fb.withUnsafeBufferPointer { pb in LightningBytes.compare(pa, pb) } }
    }

    private static func comparePaths(_ a: String, _ b: String) -> Int {
        let ca = a.split(separator: "/"), cb = b.split(separator: "/")
        for (x, y) in zip(ca, cb) {
            let order = compareFolded(String(x), String(y))
            if order != 0 { return order }
        }
        return ca.count - cb.count
    }

    static func row(_ index: Int, _ view: LightningStorageView) -> LightningRow {
        let flags = view.flags[index]
        let isDirectory = flags & LightningEntryFlag.directory != 0
        func date(_ value: Double) -> Date? { value.isNaN ? nil : Date(timeIntervalSince1970: value) }
        return LightningRow(path: view.path(index), name: String(decoding: view.raw(index), as: UTF8.self),
                            isDirectory: isDirectory, isPackage: flags & LightningEntryFlag.package != 0,
                            size: isDirectory ? nil : view.size[index],
                            modified: date(view.modified[index]), created: date(view.created[index]))
    }
}

/// Shared stop flag: once any thread observes cancellation, every thread stops.
final class LightningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var flag: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func isCancelled(_ check: () -> Bool) -> Bool {
        if flag { return true }
        guard check() else { return false }
        lock.lock()
        cancelled = true
        lock.unlock()
        return true
    }
}

// MARK: - Plan

/// Per-chunk evaluation state: the storage view and a lazily allocated read buffer for `content:`.
final class LightningEvalContext {
    let view: LightningStorageView
    private(set) var buffer: UnsafeMutableRawPointer?
    private(set) var bufferSize = 0

    init(view: LightningStorageView) {
        self.view = view
    }

    deinit { buffer?.deallocate() }

    func readBuffer(size: Int) -> UnsafeMutableRawPointer {
        if let buffer, bufferSize >= size { return buffer }
        buffer?.deallocate()
        let allocated = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        buffer = allocated
        bufferSize = size
        return allocated
    }
}

/// A compiled condition. Subclasses are immutable and safe to share across threads.
class LightningPlanNode {
    static let expensiveCost = 6

    /// Relative evaluation cost; AND/OR evaluate cheaper children first.
    var cost: Int { 1 }

    func matches(_ index: Int, _ context: LightningEvalContext) -> Bool { true }

    /// A deep copy that shares no reference-counted storage with the original (one per worker chunk).
    func copy() -> LightningPlanNode { fatalError("\(type(of: self)) must implement copy()") }
}

final class LightningAllNode: LightningPlanNode {
    override func copy() -> LightningPlanNode { LightningAllNode() }
}

final class LightningNothingNode: LightningPlanNode {
    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool { false }

    override func copy() -> LightningPlanNode { LightningNothingNode() }
}

final class LightningNameNode: LightningPlanNode {
    let matcher: LightningNameMatcher

    init(_ matcher: LightningNameMatcher) {
        self.matcher = matcher
    }

    override var cost: Int { 2 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        matcher.matches(entry: index, in: context.view)
    }

    override func copy() -> LightningPlanNode { LightningNameNode(matcher.copy()) }
}

final class LightningPathNode: LightningPlanNode {
    let pattern: LightningPathPattern

    init(_ pattern: LightningPathPattern) {
        self.pattern = pattern
    }

    override var cost: Int { 4 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        pattern.matches(entry: index, in: context.view)
    }

    override func copy() -> LightningPlanNode { LightningPathNode(pattern.copy()) }
}

/// `folder:` / `file:` / `type:folder` / `type:file`. Packages count as files.
final class LightningKindNode: LightningPlanNode {
    let folders: Bool

    init(folders: Bool) {
        self.folders = folders
    }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        context.view.isFolder(index) == folders
    }

    override func copy() -> LightningPlanNode { LightningKindNode(folders: folders) }
}

/// Extension membership through the extension id table; plain folders have no extension.
final class LightningExtensionNode: LightningPlanNode {
    private let accepted: [Bool]
    private let acceptedNames: Set<[UInt8]>
    private let wantsNone: Bool

    /// `names` are lowercased extensions; an empty list selects items without an extension.
    init(names: [String], table: LightningExtensionTable) {
        let bytes = Set(names.map { LightningText.fold(string: $0) })
        var accepted = [Bool](repeating: false, count: table.count)
        for name in bytes {
            if let id = table.lookup(name), Int(id) < accepted.count { accepted[Int(id)] = true }
        }
        self.accepted = accepted
        acceptedNames = bytes
        wantsNone = names.isEmpty
    }

    private init(accepted: [Bool], acceptedNames: Set<[UInt8]>, wantsNone: Bool) {
        self.accepted = accepted
        self.acceptedNames = acceptedNames
        self.wantsNone = wantsNone
    }

    override func copy() -> LightningPlanNode {
        LightningExtensionNode(accepted: accepted.map { $0 }, acceptedNames: Set(acceptedNames.map { $0.map { $0 } }), wantsNone: wantsNone)
    }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let view = context.view
        if view.isFolder(index) { return false }
        let id = view.extensionID[index]
        if wantsNone { return id == LightningExtensionTable.none }
        if id == LightningExtensionTable.overflow {
            let folded = view.folded(index)
            guard let range = LightningExtensionTable.extensionRange(of: folded) else { return false }
            return acceptedNames.contains(Array(folded[range]))
        }
        return Int(id) < accepted.count && accepted[Int(id)]
    }
}

/// Inclusive byte ranges; folders and packages never match.
final class LightningSizeNode: LightningPlanNode {
    let ranges: [(Int64, Int64)]

    init(ranges: [(Int64, Int64)]) {
        self.ranges = ranges
    }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let view = context.view
        if view.isDirectory(index) { return false }
        let size = view.size[index]
        for (lower, upper) in ranges where size >= lower && size <= upper { return true }
        return false
    }

    override func copy() -> LightningPlanNode { LightningSizeNode(ranges: ranges.map { $0 }) }
}

/// Half-open ranges of seconds since 1970; unknown dates never match.
final class LightningDateNode: LightningPlanNode {
    let modified: Bool
    let ranges: [(Double, Double)]

    init(modified: Bool, ranges: [(Double, Double)]) {
        self.modified = modified
        self.ranges = ranges
    }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let value = modified ? context.view.modified[index] : context.view.created[index]
        for (lower, upper) in ranges where value >= lower && value < upper { return true }
        return false
    }

    override func copy() -> LightningPlanNode { LightningDateNode(modified: modified, ranges: ranges.map { $0 }) }
}

/// `infolder:` / `parent:`: some proper ancestor is one of the folders.
final class LightningUnderNode: LightningPlanNode {
    let folders: Set<Int32>

    init(folders: Set<Int32>) {
        self.folders = folders
    }

    override var cost: Int { 3 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let parents = context.view.parent
        var current = parents[index]
        while current >= 0 {
            if folders.contains(current) { return true }
            current = parents[Int(current)]
        }
        return false
    }

    override func copy() -> LightningPlanNode { LightningUnderNode(folders: Set(folders.map { $0 })) }
}

/// `nosubfolders:`: the parent is one of the folders.
final class LightningChildNode: LightningPlanNode {
    let folders: Set<Int32>

    init(folders: Set<Int32>) {
        self.folders = folders
    }

    override var cost: Int { 2 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        folders.contains(context.view.parent[index])
    }

    override func copy() -> LightningPlanNode { LightningChildNode(folders: Set(folders.map { $0 })) }
}

final class LightningRegexNode: LightningPlanNode {
    let regex: NSRegularExpression

    init(_ regex: NSRegularExpression) {
        self.regex = regex
    }

    override var cost: Int { 6 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        autoreleasepool {
            let name = String(decoding: context.view.raw(index), as: UTF8.self).precomposedStringWithCanonicalMapping
            return regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil
        }
    }

    override func copy() -> LightningPlanNode {
        LightningRegexNode((try? NSRegularExpression(pattern: regex.pattern, options: regex.options)) ?? regex)
    }
}

/// Finder tags, read at query time. An empty value list matches any tagged item. `exact` compares whole
/// tag names instead of looking for the value inside them.
final class LightningTagNode: LightningPlanNode {
    let values: [String]
    let caseSensitive: Bool
    let exact: Bool

    init(values: [String], caseSensitive: Bool, exact: Bool = false) {
        self.values = values
        self.caseSensitive = caseSensitive
        self.exact = exact
    }

    override var cost: Int { 8 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let path = context.view.path(index)
        // Cheap pre-check: untagged items have no tag attribute at all.
        guard getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) > 0 else { return false }
        return autoreleasepool {
            let tags = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            if values.isEmpty { return !tags.isEmpty }
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return tags.contains { tag in
                values.contains { value in
                    exact ? tag.compare(value, options: options) == .orderedSame : tag.range(of: value, options: options) != nil
                }
            }
        }
    }

    override func copy() -> LightningPlanNode {
        LightningTagNode(values: values.map { String($0) }, caseSensitive: caseSensitive, exact: exact)
    }
}

/// Literal bytes inside regular files up to a size limit. Case-insensitive matching folds ASCII only.
final class LightningContentNode: LightningPlanNode {
    let needles: [[UInt8]]
    let caseSensitive: Bool
    let byteLimit: Int
    private let blockSize = 1 << 20

    init(values: [String], caseSensitive: Bool, byteLimit: Int) {
        needles = values.map { value in
            let bytes = LightningText.normalize(string: value)
            return caseSensitive ? bytes : bytes.map(LightningText.asciiLower)
        }.filter { !$0.isEmpty }
        self.caseSensitive = caseSensitive
        self.byteLimit = byteLimit
    }

    private init(needles: [[UInt8]], caseSensitive: Bool, byteLimit: Int) {
        self.needles = needles
        self.caseSensitive = caseSensitive
        self.byteLimit = byteLimit
    }

    override func copy() -> LightningPlanNode {
        LightningContentNode(needles: needles.map { $0.map { $0 } }, caseSensitive: caseSensitive, byteLimit: byteLimit)
    }

    override var cost: Int { 10 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        let view = context.view
        guard view.flags[index] & (LightningEntryFlag.directory | LightningEntryFlag.symlink) == 0,
              view.size[index] > 0, view.size[index] <= Int64(byteLimit), let longest = needles.map(\.count).max() else {
            return false
        }
        let path = view.path(index)
        // Cloud-only (dataless) files would be downloaded by reading them.
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & 0x4000_0000 == 0 else { return false }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let buffer = context.readBuffer(size: blockSize + longest)
        var carried = 0
        var total = 0
        while total <= byteLimit {
            let count = read(descriptor, buffer + carried, blockSize)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let bytes = buffer.assumingMemoryBound(to: UInt8.self)
            if !caseSensitive {
                for offset in carried..<(carried + count) { bytes[offset] = LightningText.asciiLower(bytes[offset]) }
            }
            let available = carried + count
            for needle in needles where needle.count <= available {
                if needle.withUnsafeBytes({ memmem(buffer, available, $0.baseAddress!, needle.count) }) != nil { return true }
            }
            carried = min(longest - 1, available)
            memmove(buffer, buffer + (available - carried), carried)
            total += count
        }
        return false
    }
}

final class LightningNotNode: LightningPlanNode {
    let child: LightningPlanNode

    init(_ child: LightningPlanNode) {
        self.child = child
    }

    override var cost: Int { child.cost }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        !child.matches(index, context)
    }

    override func copy() -> LightningPlanNode { LightningNotNode(child.copy()) }
}

final class LightningAndNode: LightningPlanNode {
    let children: [LightningPlanNode]

    init(_ children: [LightningPlanNode]) {
        self.children = children.sorted { $0.cost < $1.cost }
    }

    override var cost: Int { children.map(\.cost).max() ?? 1 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        for child in children where !child.matches(index, context) { return false }
        return true
    }

    override func copy() -> LightningPlanNode { LightningAndNode(children.map { $0.copy() }) }
}

final class LightningOrNode: LightningPlanNode {
    let children: [LightningPlanNode]

    init(_ children: [LightningPlanNode]) {
        self.children = children.sorted { $0.cost < $1.cost }
    }

    override var cost: Int { children.map(\.cost).max() ?? 1 }

    override func matches(_ index: Int, _ context: LightningEvalContext) -> Bool {
        for child in children where child.matches(index, context) { return true }
        return false
    }

    override func copy() -> LightningPlanNode { LightningOrNode(children.map { $0.copy() }) }
}

/// Turns a query into plan nodes, resolving dates, folders and extensions against one storage.
struct LightningPlanCompiler {
    let storage: LightningStorage
    let now: Date
    let calendar: Calendar
    let homeDirectory: String
    let contentByteLimit: Int

    func compile(_ query: LightningQuery, caseSensitive: Bool) -> LightningPlanNode {
        switch query {
        case .everything:
            return LightningAllNode()
        case let .term(term):
            return compile(term, caseSensitive: caseSensitive, allowPath: true)
        case let .filter(filter):
            return compile(filter, caseSensitive: caseSensitive)
        case let .not(inner):
            let child = compile(inner, caseSensitive: caseSensitive)
            if child is LightningAllNode { return LightningNothingNode() }
            if child is LightningNothingNode { return LightningAllNode() }
            return LightningNotNode(child)
        case let .and(items):
            return all(items.map { compile($0, caseSensitive: caseSensitive) })
        case let .or(items):
            return any(items.map { compile($0, caseSensitive: caseSensitive) })
        case let .matchCase(sensitive, inner):
            return compile(inner, caseSensitive: sensitive)
        }
    }

    private func all(_ nodes: [LightningPlanNode]) -> LightningPlanNode {
        var children: [LightningPlanNode] = []
        for node in nodes {
            if node is LightningNothingNode { return node }
            if node is LightningAllNode { continue }
            if let nested = node as? LightningAndNode { children += nested.children } else { children.append(node) }
        }
        if children.isEmpty { return LightningAllNode() }
        return children.count == 1 ? children[0] : LightningAndNode(children)
    }

    private func any(_ nodes: [LightningPlanNode]) -> LightningPlanNode {
        var children: [LightningPlanNode] = []
        for node in nodes {
            if node is LightningAllNode { return node }
            if node is LightningNothingNode { continue }
            if let nested = node as? LightningOrNode { children += nested.children } else { children.append(node) }
        }
        if children.isEmpty { return LightningNothingNode() }
        return children.count == 1 ? children[0] : LightningOrNode(children)
    }

    private func compile(_ term: LightningTerm, caseSensitive: Bool, allowPath: Bool) -> LightningPlanNode {
        if allowPath, term.isPath {
            guard let pattern = LightningPathPattern(term: term.text, caseSensitive: caseSensitive) else { return LightningAllNode() }
            return LightningPathNode(pattern)
        }
        let mode: LightningNameMatcher.Mode = term.hasWildcards ? .glob : .substring
        return LightningNameNode(LightningNameMatcher(text: term.text, mode: mode, caseSensitive: caseSensitive))
    }

    private func compile(_ filter: LightningFilter, caseSensitive: Bool) -> LightningPlanNode {
        switch filter {
        case let .extension(names):
            return LightningExtensionNode(names: names, table: storage.extensions)
        case let .type(types):
            return any(types.map { type -> LightningPlanNode in
                switch type {
                case .file: LightningKindNode(folders: false)
                case .folder: LightningKindNode(folders: true)
                default: LightningExtensionNode(names: type.extensions, table: storage.extensions)
                }
            })
        case let .folder(term):
            return all([LightningKindNode(folders: true)] + (term.map { [compile($0, caseSensitive: caseSensitive, allowPath: true)] } ?? []))
        case let .file(term):
            return all([LightningKindNode(folders: false)] + (term.map { [compile($0, caseSensitive: caseSensitive, allowPath: true)] } ?? []))
        case let .name(term):
            return compile(term, caseSensitive: caseSensitive, allowPath: false)
        case let .size(conditions):
            let ranges = conditions.flatMap(sizeRanges)
            return ranges.isEmpty ? LightningNothingNode() : LightningSizeNode(ranges: ranges)
        case let .dateModified(conditions):
            return LightningDateNode(modified: true, ranges: conditions.flatMap(dateRanges))
        case let .dateCreated(conditions):
            return LightningDateNode(modified: false, ranges: conditions.flatMap(dateRanges))
        case let .inFolder(paths):
            let folders = resolve(paths)
            return folders.isEmpty ? LightningNothingNode() : LightningUnderNode(folders: folders)
        case let .noSubfolders(paths):
            let folders = resolve(paths)
            return folders.isEmpty ? LightningNothingNode() : LightningChildNode(folders: folders)
        case let .regex(pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
                return LightningNothingNode()
            }
            return LightningRegexNode(regex)
        case let .content(values):
            return LightningContentNode(values: values, caseSensitive: caseSensitive, byteLimit: contentByteLimit)
        case let .tag(values):
            return LightningTagNode(values: values, caseSensitive: caseSensitive)
        case let .tagExact(values):
            return LightningTagNode(values: values, caseSensitive: caseSensitive, exact: true)
        }
    }

    private func sizeRanges(_ condition: LightningSizeCondition) -> [(Int64, Int64)] {
        switch condition {
        case let .compare(comparison, value):
            let zero: Int64 = 0, maximum = Int64.max
            switch comparison {
            case .equal: return [(value, value)]
            case .notEqual: return [(zero, value - 1), (value + 1, maximum)].filter { $0.0 <= $0.1 }
            case .greater: return value < maximum ? [(value + 1, maximum)] : []
            case .greaterOrEqual: return [(value, maximum)]
            case .less: return value > 0 ? [(zero, value - 1)] : []
            case .lessOrEqual: return [(zero, value)]
            }
        case let .range(lower, upper):
            return [(lower ?? 0, upper ?? .max)]
        case let .named(named):
            return [(named.bounds.lower, named.bounds.upper ?? .max)]
        }
    }

    private func dateRanges(_ condition: LightningDateCondition) -> [(Double, Double)] {
        let infinity = Double.infinity
        func span(_ value: LightningDateValue) -> (Double, Double) {
            let interval = value.interval(now: now, calendar: calendar)
            return (interval.lowerBound.timeIntervalSince1970, interval.upperBound.timeIntervalSince1970)
        }
        switch condition {
        case let .compare(comparison, value):
            let (start, end) = span(value)
            switch comparison {
            case .equal: return [(start, end)]
            case .notEqual: return [(-infinity, start), (end, infinity)]
            case .greater: return [(end, infinity)]
            case .greaterOrEqual: return [(start, infinity)]
            case .less: return [(-infinity, start)]
            case .lessOrEqual: return [(-infinity, end)]
            }
        case let .range(lower, upper):
            return [(lower.map { span($0).0 } ?? -infinity, upper.map { span($0).1 } ?? infinity)]
        }
    }

    /// Resolves folder paths (`~` expanded) to index entries; unknown folders are dropped.
    private func resolve(_ paths: [String]) -> Set<Int32> {
        var result: Set<Int32> = []
        for path in paths {
            let expanded = path == "~" ? homeDirectory : path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
            let canonical = LightningIndex.canonicalPath(expanded)
            if let entry = storage.lookup(path: canonical) ?? storage.lookup(path: (expanded as NSString).standardizingPath) {
                result.insert(entry)
            }
        }
        return result
    }
}
