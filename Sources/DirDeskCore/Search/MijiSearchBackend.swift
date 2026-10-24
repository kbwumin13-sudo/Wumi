import Foundation
import MijiCore

/// One shared Miji name index. AST fallback uses only a short-lived 256-row adapter.
public final class MijiSearchBackend: @unchecked Sendable {
    public let databaseURL: URL
    public let names: NameSearchEngine
    public var onError: ((String) -> Void)?
    private let settingsLock=NSLock()
    private var offlineEnabled=true
    /// Hides offline results when disabled, while preserving their data for re-enabling.
    public var retainsOffline:Bool {
        get {settingsLock.lock();defer{settingsLock.unlock()};return offlineEnabled}
        set {settingsLock.lock();offlineEnabled=newValue;settingsLock.unlock()}
    }
    private let ignoredPaths: [String]
    private let allowsTemporaryScopes: Bool
    private let creationDateReader: (URL) -> Date?
    private let temporaryLock = NSLock()
    private var temporary: [String: (LightningSearchEngine, ContinuousClock.Instant)] = [:]

    public convenience init(databaseURL: URL, names: NameSearchEngine, ignoredPaths: [String] = [], allowsTemporaryScopes: Bool = true) {
        self.init(databaseURL:databaseURL,names:names,ignoredPaths:ignoredPaths,allowsTemporaryScopes:allowsTemporaryScopes,
                  creationDateReader:{ (try? $0.resourceValues(forKeys:[.creationDateKey]))?.creationDate })
    }

    // Internal seam for fixture assertions on actual metadata read counts.
    init(databaseURL: URL, names: NameSearchEngine, ignoredPaths: [String] = [], allowsTemporaryScopes: Bool = true,
         creationDateReader: @escaping (URL) -> Date?) {
        self.databaseURL=databaseURL; self.names=names
        self.ignoredPaths=ignoredPaths; self.allowsTemporaryScopes=allowsTemporaryScopes
        self.creationDateReader=creationDateReader
    }

    public func discardTemporaryIndexes() {
        temporaryLock.lock(); temporary.removeAll(); temporaryLock.unlock()
    }

    public func search(_ query: LightningQuery, scope: LightningScope = .computer, caseSensitive: Bool = false,
                       sort: LightningSortKey = .none, descending: Bool = false, limit: Int = 1_000,
                       isCancelled: () -> Bool = { false }) -> LightningSearchResult {
        run(query, scope:scope, caseSensitive:caseSensitive, sort:sort, descending:descending,
            limit:limit, namesOnly:false, isCancelled:isCancelled)
    }

    /// Only for an ordinary literal term. Other ASTs execute once with full semantics.
    public func searchNames(_ query: LightningQuery, scope: LightningScope = .computer, caseSensitive: Bool = false,
                            sort: LightningSortKey = .none, descending: Bool = false, limit: Int = 1_000,
                            isCancelled: () -> Bool = { false }) -> LightningSearchResult {
        guard Self.ordinaryTerms(query) != nil else {
            return search(query,scope:scope,caseSensitive:caseSensitive,sort:sort,descending:descending,limit:limit,isCancelled:isCancelled)
        }
        return run(query,scope:scope,caseSensitive:caseSensitive,sort:sort,descending:descending,limit:limit,namesOnly:true,isCancelled:isCancelled)
    }

    private static func ordinaryTerms(_ query: LightningQuery) -> [String]? {
        switch query {
        case let .term(term) where !term.hasWildcards && !term.isPath && !term.text.isEmpty: return [term.text]
        case let .and(items) where !items.isEmpty:
            let parts=items.map(ordinaryTerms)
            return parts.allSatisfy { $0 != nil } ? parts.compactMap { $0 }.flatMap { $0 } : nil
        default: return nil
        }
    }
    /// A necessary positive body branch is safe under AND; all OR branches must be bounded.
    private static func bodyCandidates(_ query:LightningQuery)->[String]? {
        switch query {
        case let .filter(.content(values)) where !values.isEmpty: return values
        case let .matchCase(_,inner): return bodyCandidates(inner)
        case let .and(items): return items.compactMap(bodyCandidates).first
        case let .or(items) where !items.isEmpty:
            let parts=items.map(bodyCandidates)
            return parts.allSatisfy { $0 != nil } ? parts.compactMap { $0 }.flatMap { $0 } : nil
        default: return nil
        }
    }

    private static func nameLiterals(_ query:LightningQuery,caseSensitive:Bool)->Set<String> {
        switch query {
        case let .term(term) where !caseSensitive && !term.hasWildcards && !term.isPath:
            return [term.text]
        case let .filter(.name(term)) where !caseSensitive && !term.hasWildcards:
            return [term.text]
        case let .not(inner): return nameLiterals(inner,caseSensitive:caseSensitive)
        case let .matchCase(sensitive,inner): return nameLiterals(inner,caseSensitive:sensitive)
        case let .and(items),let .or(items):
            return items.reduce(into:Set<String>()) {$0.formUnion(nameLiterals($1,caseSensitive:caseSensitive))}
        default: return []
        }
    }

    private func run(_ query: LightningQuery, scope: LightningScope, caseSensitive: Bool, sort: LightningSortKey,
                     descending: Bool, limit: Int, namesOnly: Bool, isCancelled: () -> Bool) -> LightningSearchResult {
        let includeOffline=retainsOffline
        let start=ContinuousClock.now
        var heap=MijiRowHeap(limit:max(0,limit),sort:sort,descending:descending)
        var total=0, cancelled=false, incomplete=false
        do {
            try withoutActuallyEscaping(isCancelled) { check in
                if check() {throw CancellationError()}
                let database=try SearchDatabase(url:databaseURL,readOnly:true)
                let contentDatabase=try SearchDatabase(url:databaseURL,readOnly:true)
                let roots=try database.roots()
                let paths: [String]?
                switch scope {
                case .computer: paths=nil
                case let .folder(url): paths=[LightningIndex.canonicalPath(url.path)]
                case let .folders(urls): paths=LightningIndex.outermost(urls.map {LightningIndex.canonicalPath($0.path)})
                }
                var indexedPaths:[String]=[], unindexedPaths:[String]=[]
                for path in paths ?? [] {
                    let covered=roots.contains { LightningIndex.isPath(path,inside:$0.path) || path == $0.path }
                        && !ignoredPaths.contains {LightningIndex.isPath(path,inside:$0) || path == $0}
                        && !path.split(separator:"/").contains(where:{["node_modules",".git"].contains(String($0))})
                        && !((try? URL(fileURLWithPath:path).resourceValues(forKeys:[.isPackageKey]).isPackage) ?? false)
                    if covered {indexedPaths.append(path)} else {unindexedPaths.append(path)}
                }
                func inScope(_ row: LightningRow) -> Bool {
                    guard paths != nil else {return true}
                    return indexedPaths.contains {row.path != $0 && LightningIndex.isPath(row.path,inside:$0)}
                }
                var nameMatches:[String:Set<Int64>]=[:]
                let ordinary=Self.ordinaryTerms(query)
                // Advanced name leaves, and mixed name/body ANDs, use the same
                // alias union as the ordinary hot path. Retain query-local IDs
                // only; never materialize a second path/name catalog or SQL LIKE.
                if ordinary == nil || (!namesOnly && (ordinary?.count ?? 0)>1) {
                    for literal in Self.nameLiterals(query,caseSensitive:caseSensitive) {
                        var ids=Set<Int64>()
                        try names.forEachNameMatch(literal:literal,cancelled:check) {ids.insert($0)}
                        nameMatches[literal]=ids
                    }
                }
                var matchedIDs=Set<Int64>()
                func consume(_ records:[CatalogRecord], confirmedTerms: [String] = []) throws {
                    if check() {throw CancellationError()}
                    let batch=MijiBatch(records:records)
                    let compiler=MijiASTCompiler(storage:batch.storage,database:contentDatabase,namesOnly:namesOnly,
                        nameMatches:nameMatches,creationDateReader:creationDateReader,isCancelled:check)
                    let plan=compiler.compile(query,caseSensitive:caseSensitive)
                    try batch.storage.withView { view in
                        let context=LightningEvalContext(view:view)
                        for (offset,record) in records.enumerated() {
                            if check() {throw CancellationError()}
                            var row=Self.row(record)
                            guard (includeOffline || row.isOnline), inScope(row) else {continue}
                            let state=MijiEvaluationState(confirmedTerms:confirmedTerms)
                            if try plan(Int(batch.indices[offset]),context,record,state) == .yes {
                                if Self.ordinaryTerms(query) != nil, !matchedIDs.insert(record.file.id).inserted {continue}
                                // Sorting needs dates for all verified matches, never all candidates.
                                // A date predicate and sorting share this row's single lazy read.
                                if sort == .created {
                                    row.created=try state.creationDate(record,reader:creationDateReader,isCancelled:check)
                                } else if state.createdLoaded {
                                    row.created=state.created
                                }
                                row.matchedIn=state.labels.sorted().joined(separator:"、")
                                row.snippet=state.snippet
                                total += 1; heap.insert(row)
                            }
                        }
                    }
                }
                if paths == nil || !indexedPaths.isEmpty {
                    if let literals=Self.ordinaryTerms(query) {
                        var ids:[Int64]=[]
                        func flush() throws {
                            guard !ids.isEmpty else {return}
                            try consume(database.catalogBatch(ids:ids,limit:512,cancelled:check),confirmedTerms:caseSensitive ? [] : literals)
                            ids.removeAll(keepingCapacity:true)
                        }
                        let fastNames = scope == .computer && !caseSensitive && sort == .none && includeOffline
                        if fastNames {
                            // Core has already proved the complete literal AND. Count every hit,
                            // hydrate only rows that can be displayed; no full path/record replica.
                            try names.forEachNameMatch(literals:literals,cancelled:check) { id in
                                total += 1
                                if !namesOnly {matchedIDs.insert(id)}
                                if total <= max(0,limit) {ids.append(id)}
                                if ids.count==256 {
                                    for record in try database.catalogBatch(ids:ids,limit:512,cancelled:check) {
                                        var row=Self.row(record);row.matchedIn="文件名";heap.insert(row)
                                    }
                                    ids.removeAll(keepingCapacity:true)
                                }
                            }
                            if !ids.isEmpty {
                                for record in try database.catalogBatch(ids:ids,limit:512,cancelled:check) {
                                    var row=Self.row(record);row.matchedIn="文件名";heap.insert(row)
                                }
                                ids.removeAll()
                            }
                        } else {
                            try names.forEachNameMatch(literals:literals,cancelled:check) { id in
                                ids.append(id)
                                if ids.count==256 {try flush()}
                            }
                            try flush()
                        }
                        if !namesOnly {
                            var after:Int64=0
                            while true {
                                let records=try database.catalogBatch(afterID:after,contentLiterals:literals,cancelled:check)
                                guard let last=records.last else {break}
                                after=last.file.id
                                // Only verified name hits are omitted; raw-case misses still test their body.
                                try consume(records.filter {!matchedIDs.contains($0.file.id)})
                            }
                        }
                    } else {
                        var after:Int64=0
                        while true {
                            let records=try database.catalogBatch(afterID:after,contentLiterals:Self.bodyCandidates(query),cancelled:check)
                            guard let last=records.last else {break}
                            after=last.file.id;try consume(records)
                        }
                    }
                }
                for path in unindexedPaths {
                    if check() {throw CancellationError()}
                    guard allowsTemporaryScopes else {incomplete=true;continue}
                    guard let local=temporaryEngine(path:path,isCancelled:check) else {incomplete=true;continue}
                    let result=local.search(query,scope:.folder(URL(fileURLWithPath:path)),caseSensitive:caseSensitive,
                                            sort:sort,descending:descending,limit:limit,isCancelled:check)
                    for row in result.rows {heap.insert(row)}
                    total += result.totalCount;cancelled = cancelled || result.cancelled
                    if case .limited = local.index.status.stage {incomplete=true}
                }
            }
        } catch is CancellationError {cancelled=true}
        catch {incomplete=true;onError?(error.localizedDescription)}
        let rows=heap.sorted()
        let elapsed=ContinuousClock.now-start
        return LightningSearchResult(rows:rows,totalCount:total,
            elapsedMilliseconds:Int(elapsed.components.seconds*1000+elapsed.components.attoseconds/1_000_000_000_000_000),
            truncated:incomplete || cancelled || total>rows.count,cancelled:cancelled)
    }

    private func temporaryEngine(path:String,isCancelled:()->Bool) -> LightningSearchEngine? {
        temporaryLock.lock()
        temporary = temporary.filter { ContinuousClock.now - $0.value.1 < .seconds(30) }
        if let existing=temporary[path],ContinuousClock.now-existing.1 < .seconds(30) {
            temporaryLock.unlock();return existing.0
        }
        temporaryLock.unlock()
        let config=LightningIndexConfiguration(roots:[URL(fileURLWithPath:path)],
            excludedPaths:ignoredPaths.filter {!LightningIndex.isPath(path,inside:$0) && path != $0},
            maximumEntries:500_000,maximumElapsedTime:.seconds(15),maximumMemoryBytes:128<<20,autosaveInterval:nil)
        let index=LightningIndex(configuration:config)
        index.rebuild(isCancelled:isCancelled)
        guard index.status.stage.isSearchable,!isCancelled() else {return nil}
        let engine=LightningSearchEngine(index:index)
        temporaryLock.lock()
        if temporary.count >= 2, let oldest = temporary.min(by: { $0.value.1 < $1.value.1 })?.key { temporary.removeValue(forKey: oldest) }
        temporary[path]=(engine,.now)
        temporaryLock.unlock()
        return engine
    }

    static func row(_ record:CatalogRecord) -> LightningRow {
        let f=record.file
        let package=f.isPackage ?? (f.kind == .application || ["pages","numbers","key","keynote","rtfd"].contains(f.fileExtension))
        let directory=f.isDirectory ?? (f.kind == .folder || f.kind == .application || package)
        return LightningRow(path:URL(fileURLWithPath:record.root.path).appendingPathComponent(f.relativePath).path,
            name:f.name,isDirectory:directory,isPackage:package,size:directory ? nil : f.size,
            modified:Date(timeIntervalSince1970:f.modified),created:f.created.map(Date.init(timeIntervalSince1970:)),isOnline:record.root.isOnline)
    }
}

/// A bounded max-heap: all matches are counted before the display limit is applied.
private struct MijiRowHeap {
    var rows:[LightningRow]=[]
    let limit:Int,sort:LightningSortKey,descending:Bool
    func precedes(_ a:LightningRow,_ b:LightningRow)->Bool {
        if sort == .none {return a.path < b.path}
        if LightningSearchEngine.rowPrecedes(a,b,sort:sort,descending:descending) {return true}
        if LightningSearchEngine.rowPrecedes(b,a,sort:sort,descending:descending) {return false}
        return a.path < b.path
    }
    mutating func insert(_ row:LightningRow) {
        guard limit>0 else {return}
        if sort == .none {if rows.count<limit {rows.append(row)};return}
        if rows.count<limit {
            rows.append(row);var child=rows.count-1
            while child>0 {
                let parent=(child-1)/2
                guard precedes(rows[parent],rows[child]) else {break}
                rows.swapAt(parent,child);child=parent
            }
        } else if precedes(row,rows[0]) {
            rows[0]=row;var parent=0
            while true {
                let left=parent*2+1,right=left+1
                var latest=parent
                if left<rows.count,precedes(rows[latest],rows[left]) {latest=left}
                if right<rows.count,precedes(rows[latest],rows[right]) {latest=right}
                if latest==parent {break}
                rows.swapAt(parent,latest);parent=latest
            }
        }
    }
    func sorted()->[LightningRow] {sort == .none ? rows : rows.sorted(by:precedes)}
}

/// At most one batch and its path ancestors, discarded after evaluation.
private struct MijiBatch {
    var storage=LightningStorage()
    var indices:[Int32]=[]
    init(records:[CatalogRecord]) {
        var ancestors:[String:Int32]=[:]
        func parent(_ path:String)->Int32 {
            if let index=ancestors[path] {return index}
            let up=(path as NSString).deletingLastPathComponent
            let p=path == "/" ? -1 : parent(up.isEmpty ? "/" : up)
            let i=storage.append(name:path == "/" ? "" : (path as NSString).lastPathComponent,parent:p,
                                 flags:LightningEntryFlag.directory | LightningEntryFlag.ancestor)
            ancestors[path]=i;return i
        }
        for record in records {
            let row=MijiSearchBackend.row(record)
            let p=parent((row.path as NSString).deletingLastPathComponent)
            let flags:UInt8=(row.isDirectory ? LightningEntryFlag.directory : 0) | (row.isPackage ? LightningEntryFlag.package : 0)
            indices.append(storage.append(name:row.name,parent:p,flags:flags,size:row.size ?? 0,
                modified:row.modified?.timeIntervalSince1970 ?? .nan,created:row.created?.timeIntervalSince1970 ?? .nan))
        }
    }
}

private enum MijiTruth {case yes,no,unknown
    var negated:Self {self == .yes ? .no : self == .no ? .yes : .unknown}
}
private final class MijiEvaluationState {
    var loaded=false,content:ExtractedContent?
    private(set) var createdLoaded=false,created:Date?
    var labels=Set<String>()
    var snippet:String?
    let confirmedTerms:[String]
    init(confirmedTerms:[String]) {self.confirmedTerms=confirmedTerms}

    func creationDate(_ record:CatalogRecord,reader:(URL)->Date?,isCancelled:()->Bool)throws->Date? {
        if isCancelled() {throw CancellationError()}
        if !createdLoaded {
            createdLoaded=true
            if let stored=record.file.created {created=Date(timeIntervalSince1970:stored)}
            else if record.root.isOnline {created=reader(MijiSearchBackend.row(record).url)}
        }
        if isCancelled() {throw CancellationError()}
        return created
    }
}
private typealias MijiPredicate=(Int,LightningEvalContext,CatalogRecord,MijiEvaluationState)throws->MijiTruth

private struct MijiASTCompiler {
    let storage:LightningStorage
    let database:SearchDatabase
    let namesOnly:Bool
    let nameMatches:[String:Set<Int64>]
    let creationDateReader:(URL)->Date?
    let isCancelled:()->Bool
    var legacy:LightningPlanCompiler {LightningPlanCompiler(storage:storage,now:Date(),calendar:.current,homeDirectory:NSHomeDirectory(),contentByteLimit:16<<20)}

    func compile(_ query:LightningQuery,caseSensitive:Bool)->MijiPredicate {
        switch query {
        case .everything: return {_,_,_,_ in .yes}
        case let .matchCase(sensitive,inner):return compile(inner,caseSensitive:sensitive)
        case let .not(inner):let child=compile(inner,caseSensitive:caseSensitive);return {try child($0,$1,$2,$3).negated}
        case let .and(items):
            // Stable partition of this conjunction only. Do not move predicates
            // across OR/NOT; their short-circuit and unknown-body semantics stay intact.
            let ordered=items.filter(isMemoryOnly) + items.filter {!isMemoryOnly($0)}
            let children=ordered.map {compile($0,caseSensitive:caseSensitive)}
            return {i,c,r,s in
                var unknown=false
                for child in children {let value=try child(i,c,r,s);if value == .no {return .no};unknown = unknown || value == .unknown}
                return unknown ? .unknown : .yes
            }
        case let .or(items):
            let children=items.map {compile($0,caseSensitive:caseSensitive)}
            return {i,c,r,s in
                var unknown=false
                for child in children {let value=try child(i,c,r,s);if value == .yes {return .yes};unknown = unknown || value == .unknown}
                return unknown ? .unknown : .no
            }
        case let .term(term):
            let name=name(term,caseSensitive:caseSensitive,allowPath:true)
            guard !term.hasWildcards,!term.isPath,!namesOnly else {return name}
            let body=content([term.text],caseSensitive:caseSensitive)
            return {i,c,r,s in let match=try name(i,c,r,s);return match == .yes ? .yes : try body(i,c,r,s)}
        case let .filter(.name(term)):return name(term,caseSensitive:caseSensitive,allowPath:false)
        case let .filter(.content(values)):return content(values,caseSensitive:caseSensitive)
        case .filter(.dateCreated):
            // Reuse the original date-condition compiler's half-open ranges.
            let ranges=(legacy.compile(query,caseSensitive:caseSensitive) as? LightningDateNode)?.ranges ?? []
            return {_,_,record,state in
                guard let date=try state.creationDate(record,reader:creationDateReader,isCancelled:isCancelled) else {return .no}
                let value=date.timeIntervalSince1970
                return ranges.contains {$0.0 <= value && value < $0.1} ? .yes : .no
            }
        case .filter(.tag),.filter(.tagExact):
            let plan=legacy.compile(query,caseSensitive:caseSensitive)
            return {i,c,r,s in
                guard r.root.isOnline else {return .unknown}
                return plan.matches(i,c) ? .yes : .no
            }
        default:
            let plan=legacy.compile(query,caseSensitive:caseSensitive)
            return {i,c,_,_ in plan.matches(i,c) ? .yes : .no}
        }
    }
    private func isMemoryOnly(_ query:LightningQuery)->Bool {
        switch query {
        case let .term(term): return namesOnly || term.hasWildcards || term.isPath
        case .filter(.dateCreated),.filter(.content),.filter(.tag),.filter(.tagExact): return false
        case let .not(inner),let .matchCase(_,inner): return isMemoryOnly(inner)
        case let .and(items),let .or(items): return items.allSatisfy(isMemoryOnly)
        default: return true
        }
    }
    private func name(_ term:LightningTerm,caseSensitive:Bool,allowPath:Bool)->MijiPredicate {
        let plan=legacy.compile(allowPath ? .term(term) : .filter(.name(term)),caseSensitive:caseSensitive)
        return {i,c,r,s in
            var matches=plan.matches(i,c)
            if !matches,!caseSensitive,!term.hasWildcards,!(allowPath && term.isPath) {
                let needle=String(decoding: LightningText.fold(string: term.text), as: UTF8.self)
                matches=s.confirmedTerms.contains(term.text) || nameMatches[term.text]?.contains(r.file.id) == true
                    || r.pinyin.contains(needle) || r.initials.contains(needle)
            }
            if matches {s.labels.insert("文件名")}
            return matches ? .yes : .no
        }
    }
    private func content(_ values:[String],caseSensitive:Bool)->MijiPredicate {
        {_,_,record,state in
            if !state.loaded {state.content=try database.storedContent(fileID:record.file.id);state.loaded=true}
            guard let content=state.content else {
                return record.file.contentState == "skipped" ? .no : .unknown
            }
            let options:String.CompareOptions=caseSensitive ? [] : [.caseInsensitive]
            for value in values where !value.isEmpty {
                let normalize: (String)->String = { value in
                    let n=value.precomposedStringWithCanonicalMapping
                    return caseSensitive ? n : n.lowercased().precomposedStringWithCanonicalMapping
                }
                if normalize(content.text).contains(normalize(value)) {
                    state.labels.insert("正文/OCR")
                    let anchor=content.text.range(of:value,options:options)?.lowerBound ?? content.text.startIndex
                    let start=content.text.index(anchor,offsetBy:-45,limitedBy:content.text.startIndex) ?? content.text.startIndex
                    state.snippet=String(content.text[start...].prefix(200));return .yes
                }
                if content.labels.contains(where:{normalize($0).contains(normalize(value))}) {
                    state.labels.insert("图片标签");state.snippet=content.labels.joined(separator:"、");return .yes
                }
            }
            return .no
        }
    }
}
