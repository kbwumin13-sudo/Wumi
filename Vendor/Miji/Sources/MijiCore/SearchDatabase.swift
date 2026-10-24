import Foundation
import CSQLite
import CContentIndex

public struct SearchDatabaseError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One serialized connection; transactions protect batches and FTS triggers.
/// WAL allows other SearchDatabase instances to read while this one writes.
public final class SearchDatabase: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    var connection: OpaquePointer?
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Open the writer first to initialize/migrate the schema. UI queries should
    /// use a separate read-only instance; it never creates directories or runs DDL.
    public init(url: URL, readOnly: Bool = false, immutable: Bool = false) throws {
        self.url = url
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // Apple SQLite may need to create WAL sidecars even for a SELECT on a
        // closed database. query_only enforces SQL read-only access without
        // CREATE, while allowing that bookkeeping in an existing writable DB.
        let access = immutable ? SQLITE_OPEN_READONLY : (readOnly ? SQLITE_OPEN_READWRITE : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
        let path = immutable ? url.absoluteString + "?immutable=1" : url.path
        let code = sqlite3_open_v2(path, &connection, access | SQLITE_OPEN_FULLMUTEX | (immutable ? SQLITE_OPEN_URI : 0), nil)
        guard code == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(connection)
            connection = nil
            throw SearchDatabaseError(message: message)
        }
        do {
            sqlite3_busy_timeout(connection, 5_000)
            if readOnly { try execute("PRAGMA query_only=ON") }
            guard miji_register_tokenizer(connection) == SQLITE_OK else { throw error() }
            sqlite3_create_function_v2(connection, "miji_content", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, args in
                guard let context, let value = args?[0], let pointer = sqlite3_value_blob(value) else { sqlite3_result_null(context); return }
                do {
                    let data = Data(bytes: pointer, count: Int(sqlite3_value_bytes(value)))
                    let text = try ContentCodec.searchableText(data)
                    text.withCString { sqlite3_result_text(context, $0, Int32(text.utf8.count), SearchDatabase.transient) }
                } catch { sqlite3_result_error(context, error.localizedDescription, -1) }
            }, nil, nil, nil)
            try execute("PRAGMA foreign_keys=ON;")
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
                let version = try prepare("PRAGMA user_version")
                _ = try next(version)
                let oldVersion = sqlite3_column_int(version, 0)
                sqlite3_finalize(version)
                guard oldVersion != 1 else { throw SearchDatabaseError(message: "旧版索引需要无损迁移，请使用 miji-cli migrate 后再打开。") }
                try transaction { try execute(Self.schema); try execute(Self.wumiSchema) }
            }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    public func roots() throws -> [IndexedRoot] {
        try synchronized {
            let statement = try prepare("SELECT payload FROM roots ORDER BY id")
            defer { sqlite3_finalize(statement) }
            var result: [IndexedRoot] = []
            while try next(statement) { result.append(try decode(IndexedRoot.self, text(statement, 0))) }
            return result
        }
    }

    public func saveRoot(_ root: IndexedRoot) throws {
        try synchronized {
            // Stable key order makes repeated saves comparable, without changing
            // the encoder used for content digests or the v2 payload format.
            let rootEncoder = JSONEncoder()
            rootEncoder.outputFormatting = .sortedKeys
            let payload = String(decoding: try rootEncoder.encode(root), as: UTF8.self)
            try run("""
                INSERT INTO roots(id,payload,online,enabled) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,online=excluded.online,enabled=excluded.enabled
                WHERE roots.payload IS NOT excluded.payload OR roots.online<>excluded.online OR roots.enabled<>excluded.enabled
                """, [.string(root.id), .string(payload), .integer(root.isOnline ? 1 : 0), .integer(root.enabled ? 1 : 0)])
        }
    }

    /// Cascading deletion only touches this database, never the source folder.
    public func removeRoot(id: String) throws {
        try synchronized { try transaction { try run("DELETE FROM roots WHERE id=?", [.string(id)]) } }
    }

    public func upsertFiles(_ files: [FileRecord], generation: Int64) throws {
        try synchronized {
            try transaction {
                let statement = try prepare(Self.upsert)
                defer { sqlite3_finalize(statement) }
                // Compare with SQLite's equality rules and the same state/error
                // semantics as upsert. A generation touch must not rewrite name,
                // content or secondary indexes, or consume an AUTOINCREMENT ID.
                let existing = try prepare("""
                    SELECT id,generation,
                      name=? AND extension=? AND kind=? AND size=? AND modified=? AND inode=?
                      AND (content_state IN ('done','error') OR (content_state=? AND content_error IS ?)),
                      name,pinyin_search,initials_search
                    FROM files WHERE root_id=? AND relative_path=?
                    """)
                defer { sqlite3_finalize(existing) }
                let touch = try prepare("UPDATE files SET generation=? WHERE id=?")
                defer { sqlite3_finalize(touch) }
                for file in files {
                    try Self.validateRelativePath(file.relativePath)
                    let state = ["deferred", "skipped"].contains(file.contentState) ? file.contentState : "pending"
                    let contentError: Value = state == "pending" ? .null : (file.contentError.map(Value.string) ?? .null)
                    let fileExtension = QueryParser.normalize(file.fileExtension).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    sqlite3_reset(existing)
                    sqlite3_clear_bindings(existing)
                    try bind([.string(file.name), .string(fileExtension), .string(file.kind.rawValue),
                              .integer(file.size), .real(file.modified), .integer(file.inode), .string(state), contentError,
                              .string(file.rootID), .string(file.relativePath)], to: existing)
                    let romanized: (String, String)
                    let found = try next(existing)
                    if found, sqlite3_column_int(existing, 2) == 1 {
                        if sqlite3_column_int64(existing, 1) != generation {
                            let id = sqlite3_column_int64(existing, 0)
                            sqlite3_reset(existing)
                            sqlite3_reset(touch)
                            sqlite3_clear_bindings(touch)
                            try bind([.integer(generation), .integer(id)], to: touch)
                            try done(touch)
                        }
                        try saveWumiMetadata(file)
                        continue
                    }
                    if found, text(existing, 3) == file.name {
                        romanized = (text(existing, 4), text(existing, 5))
                    } else { romanized = Self.pinyin(file.name) }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([
                        .string(file.rootID), .string(file.relativePath), .string(file.name),
                        .string(fileExtension),
                        .string(file.kind.rawValue), .integer(file.size), .real(file.modified), .integer(file.inode),
                        .string(state), contentError, .integer(generation),
                        .string(QueryParser.normalize(file.name)), .string(romanized.0), .string(romanized.1),
                        .string(QueryParser.normalize(file.relativePath))
                    ], to: statement)
                    try done(statement)
                    try saveWumiMetadata(file)
                }
            }
        }
    }

    /// Scanner variant of `upsertFiles`: inserts new rows and rewrites changed ones,
    /// but leaves unchanged rows (and their Wumi metadata) untouched. Every row ID
    /// the batch covers goes into `seen`; prune with the `seen` variants of
    /// `finishScan`/`finishIncrementalScan` instead of comparing generations.
    @discardableResult
    public func upsertScannedFiles(_ files: [FileRecord], generation: Int64, seen: FileIDSet) throws -> ScanWriteStatistics {
        try synchronized {
            try transaction {
                var statistics = ScanWriteStatistics()
                let statement = try prepare(Self.upsert)
                defer { sqlite3_finalize(statement) }
                let existing = try prepare("""
                    SELECT f.id,f.generation,
                      f.name=? AND f.extension=? AND f.kind=? AND f.size=? AND f.modified=? AND f.inode=?
                      AND (f.content_state IN ('done','error') OR (f.content_state=? AND f.content_error IS ?)),
                      f.name,f.pinyin_search,f.initials_search,
                      m.file_id IS NOT NULL,m.created,m.is_directory,m.is_package
                    FROM files f LEFT JOIN wumi_file_metadata m ON m.file_id=f.id
                    WHERE f.root_id=? AND f.relative_path=?
                    """)
                defer { sqlite3_finalize(existing) }
                let metadata = try prepare("""
                    INSERT INTO wumi_file_metadata(file_id,created,is_directory,is_package) VALUES(?,?,?,?)
                    ON CONFLICT(file_id) DO UPDATE SET
                      created=coalesce(excluded.created,created),
                      is_directory=coalesce(excluded.is_directory,is_directory),
                      is_package=coalesce(excluded.is_package,is_package)
                    WHERE created IS NOT coalesce(excluded.created,created)
                       OR is_directory IS NOT coalesce(excluded.is_directory,is_directory)
                       OR is_package IS NOT coalesce(excluded.is_package,is_package)
                    """)
                defer { sqlite3_finalize(metadata) }
                func storedMetadataDiffers(_ file: FileRecord) -> Bool {
                    guard file.created != nil || file.isDirectory != nil || file.isPackage != nil else { return false }
                    guard sqlite3_column_int(existing, 6) == 1 else { return true }
                    func double(_ column: Int32) -> Double? {
                        sqlite3_column_type(existing, column) == SQLITE_NULL ? nil : sqlite3_column_double(existing, column)
                    }
                    func flag(_ column: Int32) -> Bool? {
                        sqlite3_column_type(existing, column) == SQLITE_NULL ? nil : sqlite3_column_int(existing, column) != 0
                    }
                    return (file.created != nil && file.created != double(7))
                        || (file.isDirectory != nil && file.isDirectory != flag(8))
                        || (file.isPackage != nil && file.isPackage != flag(9))
                }
                func saveMetadata(_ file: FileRecord, id: Int64) throws {
                    sqlite3_reset(metadata)
                    sqlite3_clear_bindings(metadata)
                    try bind([.integer(id), file.created.map(Value.real) ?? .null,
                              file.isDirectory.map { .integer($0 ? 1 : 0) } ?? .null,
                              file.isPackage.map { .integer($0 ? 1 : 0) } ?? .null], to: metadata)
                    try done(metadata)
                    statistics.metadataWrites += 1
                }
                for file in files {
                    try Self.validateRelativePath(file.relativePath)
                    let state = ["deferred", "skipped"].contains(file.contentState) ? file.contentState : "pending"
                    let contentError: Value = state == "pending" ? .null : (file.contentError.map(Value.string) ?? .null)
                    let fileExtension = QueryParser.normalize(file.fileExtension).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    sqlite3_reset(existing)
                    sqlite3_clear_bindings(existing)
                    try bind([.string(file.name), .string(fileExtension), .string(file.kind.rawValue),
                              .integer(file.size), .real(file.modified), .integer(file.inode), .string(state), contentError,
                              .string(file.rootID), .string(file.relativePath)], to: existing)
                    let found = try next(existing)
                    let existingID = found ? sqlite3_column_int64(existing, 0) : 0
                    let metadataChanged = found ? storedMetadataDiffers(file)
                        : file.created != nil || file.isDirectory != nil || file.isPackage != nil
                    if found, sqlite3_column_int(existing, 2) == 1 {
                        sqlite3_reset(existing)
                        seen.insert(existingID)
                        statistics.unchanged += 1
                        if metadataChanged { try saveMetadata(file, id: existingID) }
                        continue
                    }
                    let romanized = found && text(existing, 3) == file.name ? (text(existing, 4), text(existing, 5)) : Self.pinyin(file.name)
                    sqlite3_reset(existing)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([
                        .string(file.rootID), .string(file.relativePath), .string(file.name),
                        .string(fileExtension),
                        .string(file.kind.rawValue), .integer(file.size), .real(file.modified), .integer(file.inode),
                        .string(state), contentError, .integer(generation),
                        .string(QueryParser.normalize(file.name)), .string(romanized.0), .string(romanized.1),
                        .string(QueryParser.normalize(file.relativePath))
                    ], to: statement)
                    try done(statement)
                    // Triggers restore last_insert_rowid when they finish, so it names this row.
                    let id = found ? existingID : sqlite3_last_insert_rowid(connection)
                    seen.insert(id)
                    if found { statistics.updated += 1 } else { statistics.inserted += 1 }
                    if metadataChanged { try saveMetadata(file, id: id) }
                }
                return statistics
            }
        }
    }

    /// The largest file row ID, to size a scan's `FileIDSet`.
    public func largestFileID() throws -> Int64 {
        try synchronized {
            let statement = try prepare("SELECT coalesce(max(id),0) FROM files")
            defer { sqlite3_finalize(statement) }
            return try next(statement) ? sqlite3_column_int64(statement, 0) : 0
        }
    }

    /// Removes rows of `rootID` (or of one subtree, `scope`) that a complete scan did
    /// not report through `seen`. Same protection as the generation variants:
    /// offline and disabled roots keep their rows, and preserved paths keep theirs.
    /// Returns the number of removed rows.
    @discardableResult
    public func finishScan(rootID: String, seen: FileIDSet, preservingPaths: [String] = []) throws -> Int {
        try pruneUnseen(rootID: rootID, scope: nil, seen: seen, preservingPaths: preservingPaths)
    }

    @discardableResult
    public func finishIncrementalScan(rootID: String, relativePath: String, seen: FileIDSet, preservingPaths: [String] = []) throws -> Int {
        try pruneUnseen(rootID: rootID, scope: relativePath.isEmpty ? nil : relativePath, seen: seen, preservingPaths: preservingPaths)
    }

    private func pruneUnseen(rootID: String, scope: String?, seen: FileIDSet, preservingPaths: [String]) throws -> Int {
        guard !preservingPaths.contains("") else { return 0 }
        if let scope { try Self.validateRelativePath(scope) }
        for path in preservingPaths { try Self.validateRelativePath(path) }
        return try synchronized {
            try transaction {
                let rootRow = try prepare("SELECT payload FROM roots WHERE id=?")
                defer { sqlite3_finalize(rootRow) }
                try bind([.string(rootID)], to: rootRow)
                guard try next(rootRow) else { return 0 }
                var root = try decode(IndexedRoot.self, text(rootRow, 0))
                sqlite3_reset(rootRow)
                guard root.isOnline && root.enabled else { return 0 }
                // Only read IDs here; unseen rows are normally few (deletions and
                // protected subtrees), so their paths are fetched one by one. A scope is
                // read as its own row plus its descendants' range: SQLite cannot use the
                // path index for an OR of the two, and would read every row of the root.
                var queries: [(String, [Value])] = []
                if let scope {
                    queries.append(("SELECT id FROM files WHERE root_id=? AND relative_path=?", [.string(rootID), .string(scope)]))
                    queries.append(("SELECT id FROM files WHERE root_id=? AND relative_path>=? AND relative_path<?",
                                    [.string(rootID), .string(scope + "/"), .string(scope + "0")]))
                } else {
                    queries.append(("SELECT id FROM files WHERE root_id=?", [.string(rootID)]))
                }
                var unseen: [Int64] = []
                for (sql, values) in queries {
                    let rows = try prepare(sql)
                    defer { sqlite3_finalize(rows) }
                    try bind(values, to: rows)
                    while try next(rows) {
                        let id = sqlite3_column_int64(rows, 0)
                        if !seen.contains(id) { unseen.append(id) }
                    }
                }
                let path = try prepare("SELECT relative_path FROM files WHERE id=?")
                defer { sqlite3_finalize(path) }
                let delete = try prepare("DELETE FROM files WHERE id=?")
                defer { sqlite3_finalize(delete) }
                var removed = 0
                for id in unseen {
                    if !preservingPaths.isEmpty {
                        sqlite3_reset(path)
                        try bind([.integer(id)], to: path)
                        guard try next(path) else { continue }
                        let relative = text(path, 0)
                        sqlite3_reset(path)
                        if preservingPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
                    }
                    sqlite3_reset(delete)
                    try bind([.integer(id)], to: delete)
                    try done(delete)
                    removed += Int(sqlite3_changes(connection))
                }
                if scope == nil && preservingPaths.isEmpty {
                    root.lastScan = Date()
                    root.lastError = nil
                    try run("UPDATE roots SET payload=? WHERE id=?", [.string(try encode(root)), .string(rootID)])
                }
                return removed
            }
        }
    }

    /// Prune only after enumeration reaches its end. Failed relative paths and
    /// their descendants can be protected; an empty path protects the full root.
    /// Cancelled, offline and disabled roots must retain their old records.
    public func finishScan(rootID: String, generation: Int64, prune: Bool = true, preservingPaths: [String] = []) throws {
        try synchronized {
            guard prune, !preservingPaths.contains("") else { return }
            for path in preservingPaths { try Self.validateRelativePath(path) }
            try transaction {
                let statement = try prepare("SELECT payload FROM roots WHERE id=?")
                defer { sqlite3_finalize(statement) }
                try bind([.string(rootID)], to: statement)
                guard try next(statement) else { return }
                var root = try decode(IndexedRoot.self, text(statement, 0))
                guard root.isOnline && root.enabled else { return }
                if preservingPaths.isEmpty {
                    try run("DELETE FROM files WHERE root_id=? AND generation<>?", [.string(rootID), .integer(generation)])
                    root.lastScan = Date()
                    root.lastError = nil
                } else {
                    // A temporary relation avoids SQL variable/expression limits
                    // when many protected directories occur in a whole-disk scan.
                    try run("CREATE TEMP TABLE IF NOT EXISTS scan_preserving_paths(path TEXT PRIMARY KEY)")
                    try run("DELETE FROM scan_preserving_paths")
                    defer { try? run("DELETE FROM scan_preserving_paths") }
                    for path in preservingPaths {
                        try run("INSERT OR IGNORE INTO scan_preserving_paths(path) VALUES(?)", [.string(path)])
                    }
                    try run("""
                        DELETE FROM files WHERE root_id=? AND generation<>?
                        AND NOT EXISTS (SELECT 1 FROM scan_preserving_paths p
                            WHERE files.relative_path=p.path OR instr(files.relative_path,p.path || '/')=1)
                        """, [.string(rootID), .integer(generation)])
                }
                try run("UPDATE roots SET payload=? WHERE id=?", [.string(try encode(root)), .string(rootID)])
            }
        }
    }

    public func pendingFiles(rootID: String, limit: Int = 100, kind: FileKind? = nil) throws -> [FileRecord] {
        try synchronized {
            var sql = "SELECT \(Self.fileColumns) FROM files f WHERE f.root_id=? AND f.content_state='pending'"
            var values: [Value] = [.string(rootID)]
            if let kind { sql += " AND f.kind=?"; values.append(.string(kind.rawValue)) }
            sql += " ORDER BY f.id LIMIT ?"
            values.append(.integer(Int64(max(0, limit))))
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement)
            var result: [FileRecord] = []
            while try next(statement) { result.append(fileRecord(statement)) }
            return result
        }
    }

    /// Complete a local rescan without touching siblings or unavailable roots.
    public func finishIncrementalScan(rootID: String, relativePath: String, generation: Int64, prune: Bool = true, preservingPaths: [String] = []) throws {
        guard !relativePath.isEmpty else {
            try finishScan(rootID: rootID, generation: generation, prune: prune, preservingPaths: preservingPaths)
            return
        }
        try Self.validateRelativePath(relativePath)
        guard prune, !preservingPaths.contains("") else { return }
        for path in preservingPaths { try Self.validateRelativePath(path) }
        try synchronized {
            try transaction {
                try run("CREATE TEMP TABLE IF NOT EXISTS scan_preserving_paths(path TEXT PRIMARY KEY)")
                try run("DELETE FROM scan_preserving_paths")
                defer { try? run("DELETE FROM scan_preserving_paths") }
                for path in preservingPaths { try run("INSERT OR IGNORE INTO scan_preserving_paths VALUES(?)", [.string(path)]) }
                // The scope's own row and its descendants' range as separate statements,
                // so each uses the path index (an OR of both reads the whole root).
                for (predicate, values) in [("relative_path=?", [Value.string(relativePath)]),
                                            ("relative_path>=? AND relative_path<?", [Value.string(relativePath+"/"), .string(relativePath+"0")])] {
                    try run("""
                        DELETE FROM files WHERE root_id=? AND \(predicate) AND generation<>?
                        AND EXISTS(SELECT 1 FROM roots WHERE id=files.root_id AND online=1 AND enabled=1)
                        AND NOT EXISTS(SELECT 1 FROM scan_preserving_paths p
                          WHERE files.relative_path=p.path OR instr(files.relative_path,p.path || '/')=1)
                        """, [.string(rootID)] + values + [.integer(generation)])
                }
            }
        }
    }

    @discardableResult
    public func completeContent(file: FileRecord, content: ExtractedContent) throws -> Bool {
        let raw = try encoder.encode(content)
        return try synchronized {
            try transaction {
                let check = try prepare("SELECT id FROM files WHERE \(Self.signaturePredicate)")
                defer { sqlite3_finalize(check) }
                try bind(signature(file), to: check)
                guard try next(check) else { return false }
                let bodyID = try insertBody(raw)
                try run("UPDATE files SET content_id=?,content_state='done',content_error=NULL WHERE \(Self.signaturePredicate)", [.integer(bodyID)] + signature(file))
                return sqlite3_changes(connection) > 0
            }
        }
    }

    func insertBody(_ raw: Data) throws -> Int64 {
        let digest = ContentCodec.digest(raw)
        let existing = try prepare("SELECT id FROM content_blobs WHERE digest=?")
        defer { sqlite3_finalize(existing) }
        try bind([.blob(digest)], to: existing)
        if try next(existing) { return sqlite3_column_int64(existing, 0) }
        try run("INSERT INTO content_blobs(digest,packed) VALUES(?,?)", [.blob(digest), .blob(try ContentCodec.pack(raw))])
        return sqlite3_last_insert_rowid(connection)
    }

    public func failContent(file: FileRecord, message: String) throws {
        try synchronized {
            try run("UPDATE files SET content_state='error',content_error=? WHERE \(Self.signaturePredicate)", [.string(message)] + signature(file))
        }
    }

    public func resetContent(rootID: String, kind: FileKind? = nil) throws {
        try synchronized {
            try transaction {
                var sql = "UPDATE files SET content_id=NULL,content_state='pending',content_error=NULL WHERE root_id=? AND content_state NOT IN ('deferred','skipped')"
                var values: [Value] = [.string(rootID)]
                if let kind { sql += " AND kind=?"; values.append(.string(kind.rawValue)) }
                try run(sql, values)
            }
        }
    }

    public func storedContent(fileID: Int64) throws -> ExtractedContent? {
        try synchronized {
            let statement = try prepare("SELECT b.packed FROM files f JOIN content_blobs b ON b.id=f.content_id WHERE f.id=?")
            defer { sqlite3_finalize(statement) }
            try bind([.integer(fileID)], to: statement)
            guard try next(statement) else { return nil }
            return try decoder.decode(ExtractedContent.self, from: ContentCodec.unpack(blob(statement, 0)))
        }
    }

    /// Metadata-only hydration preserves core ranking and never reads a body.
    public func nameHits(ids: [Int64], query: String, verifyContentExclusions: Bool = false, cancelled: () -> Bool = { false }) throws -> [SearchHit] {
        try synchronized {
            let parsed = QueryParser.parse(query)
            let exclusions = parsed.terms.filter { $0.field == .text && $0.isExcluded }
            let statement = try prepare("SELECT \(Self.fileColumns),r.payload FROM files f JOIN roots r ON r.id=f.root_id WHERE f.id=?")
            defer { sqlite3_finalize(statement) }
            var result: [SearchHit] = []
            var roots: [String: IndexedRoot] = [:]
            for id in ids {
                if cancelled() { throw CancellationError() }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind([.integer(id)], to: statement)
                guard try next(statement) else { continue }
                let file = fileRecord(statement)
                let root: IndexedRoot
                if let cached = roots[file.rootID] { root = cached }
                else { root = try decode(IndexedRoot.self, text(statement, 12)); roots[file.rootID] = root }
                if verifyContentExclusions && !exclusions.isEmpty,
                   let content = try contentUnlocked(fileID: id) {
                    let body = QueryParser.normalize(content.text)
                    let labels = QueryParser.normalize(content.labels.joined(separator:"\n"))
                    if exclusions.contains(where: { body.contains($0.value) || labels.contains($0.value) }) { continue }
                }
                let pathOnly = !parsed.terms.contains { $0.field == .text && !$0.isExcluded }
                    && parsed.terms.contains { $0.field == .path && !$0.isExcluded }
                result.append(SearchHit(file:file,root:root,snippet:"",matchedIn:pathOnly ? "路径" : "文件名",labels:""))
            }
            return result
        }
    }

    private func contentUnlocked(fileID: Int64) throws -> ExtractedContent? {
        let statement = try prepare("SELECT b.packed FROM content_blobs b JOIN files f ON f.content_id=b.id WHERE f.id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(fileID)], to: statement)
        return try next(statement) ? decoder.decode(ExtractedContent.self, from: ContentCodec.unpack(blob(statement, 0))) : nil
    }

    public func statistics() throws -> IndexStatistics {
        try synchronized {
            let statement = try prepare(Self.statisticsSQL)
            defer { sqlite3_finalize(statement) }
            _ = try next(statement)
            return IndexStatistics(files: Int(sqlite3_column_int64(statement, 0)), documents: Int(sqlite3_column_int64(statement, 1)), images: Int(sqlite3_column_int64(statement, 2)), pending: Int(sqlite3_column_int64(statement, 3)), errors: Int(sqlite3_column_int64(statement, 4)), indexedContent: Int(sqlite3_column_int64(statement, 5)))
        }
    }

    /// Cancellation throws CancellationError and never returns partial results.
    /// The predicate runs synchronously on the querying thread, including inside
    /// SQLite: keep it cheap/thread-safe and do not reenter this instance from it.
    public func search(_ query: String, options: SearchOptions = SearchOptions(), cancelled: @escaping () -> Bool = { false }) throws -> [SearchHit] {
        try searchImpl(query, options: options, includeNames: true, cancelled: cancelled)
    }

    /// Runs independently after the filename first screen. Includes mixed
    /// filename/body terms; every candidate is verified against exact strings.
    public func searchSupplementary(_ query: String, options: SearchOptions, cancelled: @escaping () -> Bool = { false },
                                    onPartial:(([SearchHit])->Void)?=nil) throws -> [SearchHit] {
        try searchImpl(query, options: options, includeNames: false, cancelled: cancelled,onPartial:onPartial)
    }

    private func searchImpl(_ query: String, options: SearchOptions, includeNames: Bool, cancelled: @escaping () -> Bool,
                            onPartial:(([SearchHit])->Void)?=nil) throws -> [SearchHit] {
        if cancelled() { throw CancellationError() }
        return try synchronized {
            if cancelled() { throw CancellationError() }
            guard options.limit > 0 else { return [] }
            let context = Unmanaged.passRetained(SearchCancellationContext(cancelled))
            sqlite3_progress_handler(connection, 1_000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<SearchCancellationContext>.fromOpaque(pointer).takeUnretainedValue().cancelled() ? 1 : 0
            }, context.toOpaque())
            defer { sqlite3_progress_handler(connection, 0, nil, nil); context.release() }
            let terms = QueryParser.parse(query).terms
            var filters: [String] = []
            var filterValues: [Value] = []
            if let rootID = options.rootID { filters.append("f.root_id=?"); filterValues.append(.string(rootID)) }
            if let kind = options.kind { filters.append("f.kind=?"); filterValues.append(.string(kind.rawValue)) }
            if options.onlineOnly { filters.append("r.online=1") }
            for term in terms where term.field != .text {
                let predicate: String
                switch term.field {
                case .ext: predicate = "f.extension=?"; filterValues.append(.string(term.value))
                case .kind: predicate = "f.kind=?"; filterValues.append(.string(QueryParser.kindValue(term.value)))
                default: predicate = "instr(f.path_search,?)>0"; filterValues.append(.string(term.value))
                }
                filters.append(term.isExcluded ? "NOT (\(predicate))" : predicate)
            }
            let positive = terms.filter { $0.field == .text && !$0.isExcluded }
            let textTerms = terms.filter { $0.field == .text }
            // Unified Han characters have no case mapping or NFC composition
            // with adjacent characters. A literal hit is already an exact
            // normalized hit; misses still take the general Unicode path.
            let hanTerms = !textTerms.isEmpty && textTerms.allSatisfy {
                !$0.value.isEmpty && $0.value.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) }
            }
            func queryBody(_ raw:String)->String {
                if textTerms.isEmpty {return ""}
                if hanTerms && textTerms.allSatisfy({raw.contains($0.value)}) {return raw}
                return QueryParser.normalize(raw)
            }
            // Rank metadata first. Building snippets for every match can dwarf
            // the index lookup when only the best 500 will ever be displayed.
            typealias Candidate=(SearchHit,Int,Int64?,String)
            var hits: [Candidate] = []
            var seen = Set<Int64>()
            func better(_ left:Candidate,_ right:Candidate) -> Bool {
                switch options.sort {
                case .relevance: if left.1 != right.1 {return left.1 > right.1}
                case .modified: if left.0.file.modified != right.0.file.modified {return left.0.file.modified > right.0.file.modified}
                case .size: if left.0.file.size != right.0.file.size {return left.0.file.size > right.0.file.size}
                case .name: break
                }
                let a=left.3,b=right.3
                return a == b ? left.0.id < right.0.id : a < b
            }
            var rootCache: [String: IndexedRoot] = [:]
            var contentCacheID: Int64 = -1
            var cachedContent: ExtractedContent?
            var cachedBody = "", cachedLabels = ""
            var lastPartial=Date.distantPast
            func collect(_ predicates: [String], _ values: [Value], readBody: Bool) throws {
                var sql = "SELECT \(Self.fileColumns),r.payload,f.name_search,f.pinyin_search,f.initials_search,f.content_id FROM files f JOIN roots r ON r.id=f.root_id"
                if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
                // Group identical bodies so one decompression can serve copies.
                sql += readBody ? " ORDER BY f.content_id,f.id" : " ORDER BY f.id"
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bind(values, to: statement)
                while try next(statement) {
                    if cancelled() { throw CancellationError() }
                    let id = sqlite3_column_int64(statement, 0)
                    if seen.contains(id) { continue }
                    let name = text(statement, 13), pinyin = text(statement, 14), initials = text(statement, 15)
                    var body = "", labels = ""
                    if readBody && !textTerms.isEmpty {
                        let contentID = sqlite3_column_int64(statement, 16)
                        if contentID != contentCacheID {
                            cachedContent = try contentUnlocked(fileID: id)
                            cachedBody = queryBody(cachedContent?.text ?? "")
                            cachedLabels = QueryParser.normalize(cachedContent?.labels.joined(separator: "\n") ?? "")
                            contentCacheID = contentID
                        }
                        body = cachedBody; labels = cachedLabels
                    }
                    var score = 0
                    var matches = true
                    for term in textTerms {
                        let nameMatch = options.scope != .content && (name.contains(term.value) || pinyin.contains(term.value) || initials.contains(term.value))
                        let bodyMatch = options.scope != .name && (body.contains(term.value) || labels.contains(term.value))
                        if term.isExcluded ? (nameMatch || bodyMatch) : !(nameMatch || bodyMatch) { matches = false; break }
                        if !term.isExcluded {
                            if name.contains(term.value) && options.scope != .content { score += 100 }
                            else if nameMatch { score += 70 }
                            if labels.contains(term.value) && options.scope != .name { score += 35 }
                            if body.contains(term.value) && options.scope != .name { score += 20 }
                        }
                    }
                    guard matches else { continue }
                    let file = fileRecord(statement)
                    let root: IndexedRoot
                    if let cached = rootCache[file.rootID] { root = cached }
                    else { root = try decode(IndexedRoot.self, text(statement, 12)); rootCache[file.rootID] = root }
                    let bodyID=readBody && sqlite3_column_type(statement,16) != SQLITE_NULL ? sqlite3_column_int64(statement,16) : nil
                    hits.append((SearchHit(file:file,root:root,snippet:"",matchedIn:readBody ? "内容" : "文件名",labels:""),score,bodyID,name))
                    // A broad body query can match hundreds of thousands of
                    // paths. Keep only a bounded top set, not every snippet.
                    if hits.count > max(256,options.limit*2) {
                        hits.sort(by:better)
                        hits.removeLast(hits.count-options.limit)
                    }
                    if let onPartial,Date().timeIntervalSince(lastPartial)>=0.25 {
                        // Every emitted hit has passed all exact predicates.
                        // Continue ranking and add selected snippets at completion.
                        onPartial(hits.sorted(by:better).prefix(options.limit).map(\.0))
                        lastPartial=Date()
                    }
                }
            }
            if includeNames && options.scope != .content {
                var nameFilters = filters, nameValues = filterValues
                for term in positive {
                    nameFilters.append("(instr(f.name_search,?)>0 OR instr(f.pinyin_search,?)>0 OR instr(f.initials_search,?)>0)")
                    nameValues += Array(repeating: .string(term.value), count: 3)
                }
                // In all scope, negative terms may occur only in the body.
                try collect(nameFilters, nameValues, readBody: options.scope == .all && textTerms.contains(where: \.isExcluded))
                hits.sort(by:better)
                if hits.count>options.limit {hits.removeLast(hits.count-options.limit)}
                seen=Set(hits.map {$0.0.id})
            }
            if options.scope != .name && (!positive.isEmpty || !includeNames || options.scope == .content) {
                var bodyFilters = filters, bodyValues = filterValues
                let expressions = positive.compactMap { ContentCodec.matchExpression($0.value) }
                if !expressions.isEmpty {
                    let joiner = options.scope == .content ? " AND " : " OR "
                    bodyFilters.append("f.content_id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)")
                    bodyValues.append(.string(expressions.map { "(" + $0 + ")" }.joined(separator: joiner)))
                } else { bodyFilters.append("f.content_id IS NOT NULL") }
                try collect(bodyFilters, bodyValues, readBody: true)
            }
            if cancelled() { throw CancellationError() }
            hits.sort(by:better)
            // Read each selected shared body once, then restore result rank.
            let selected=Array(hits.prefix(options.limit))
            var decorated=[SearchHit?](repeating:nil,count:selected.count)
            let selectedBodies=try prepare("SELECT packed FROM content_blobs WHERE id=?")
            defer {sqlite3_finalize(selectedBodies)}
            var previousBody:Int64?,content:ExtractedContent?,body="",labels="",snippet=""
            for index in selected.indices.sorted(by:{(selected[$0].2 ?? -1)<(selected[$1].2 ?? -1)}) {
                if cancelled() {throw CancellationError()}
                let candidate=selected[index]
                if candidate.2 != previousBody {
                    content=nil;body="";labels="";snippet=""
                    if let id=candidate.2 {
                        sqlite3_reset(selectedBodies);sqlite3_clear_bindings(selectedBodies)
                        try bind([.integer(id)],to:selectedBodies)
                        if try next(selectedBodies) {
                            content=try decoder.decode(ExtractedContent.self,from:ContentCodec.unpack(blob(selectedBodies,0)))
                            body=queryBody(content?.text ?? "")
                            labels=QueryParser.normalize(content?.labels.joined(separator:"\n") ?? "")
                            snippet=Self.snippet(content?.text ?? "",matching:positive.map(\.value).filter{body.contains($0)})
                        }
                    }
                    previousBody=candidate.2
                }
                decorated[index]=Self.hit(file:candidate.0.file,root:candidate.0.root,content:content,terms:terms,scope:options.scope,normalizedBody:body,normalizedLabels:labels,cachedSnippet:snippet)
            }
            return decorated.compactMap{$0}
        }
    }

    private final class SearchCancellationContext {
        let cancelled: () -> Bool
        init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
    }

    private static func hit(file: FileRecord, root: IndexedRoot, content: ExtractedContent?, terms: [QueryTerm], scope: SearchScope,
                            normalizedBody:String?=nil,normalizedLabels:String?=nil,cachedSnippet:String?=nil) -> SearchHit {
        let positive = terms.filter { $0.field == .text && !$0.isExcluded }.map(\.value)
        let name = QueryParser.normalize(file.name)
        let body = normalizedBody ?? QueryParser.normalize(content?.text ?? "")
        let labels = content?.labels.joined(separator: "、") ?? ""
        let labelSearch = normalizedLabels ?? QueryParser.normalize(content?.labels.joined(separator: "\n") ?? "")
        var locations: [String] = []
        if scope != .content && !positive.isEmpty {
            var matchesName = positive.contains(where: { name.contains($0) })
            if !matchesName {
                let romanized = Self.pinyin(file.name)
                matchesName = positive.contains(where: { romanized.0.contains($0) || romanized.1.contains($0) })
            }
            if matchesName { locations.append("文件名") }
        }
        let bodyTerms = scope == .name ? [] : positive.filter { body.contains($0) }
        if !bodyTerms.isEmpty { locations.append("正文") }
        if scope != .name && positive.contains(where: { labelSearch.contains($0) }) { locations.append("图片标签") }
        if locations.isEmpty { locations.append(terms.contains(where: { $0.field == .path && !$0.isExcluded }) ? "路径" : "文件名") }
        let snippet = cachedSnippet ?? Self.snippet(content?.text ?? "", matching: bodyTerms)
        return SearchHit(file: file, root: root, snippet: snippet.isEmpty ? labels : snippet, matchedIn: locations.joined(separator: "、"), labels: labels)
    }

    private static func snippet(_ body: String, matching terms: [String]) -> String {
        guard !body.isEmpty else { return "" }
        // Search the original text so a lowercasing expansion cannot corrupt indices.
        // NSString uses the optimized UTF-16 finder; convert its range against
        // the original text so Unicode case expansion cannot shift offsets.
        let original=body as NSString
        let range = terms.compactMap { term -> Range<String.Index>? in
            let found=original.range(of:term,options:[.caseInsensitive,.diacriticInsensitive])
            return found.location==NSNotFound ? nil : Range(found,in:body)
        }.min { $0.lowerBound < $1.lowerBound }
        let anchor = range?.lowerBound ?? body.startIndex
        let start = body.index(anchor, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(start, offsetBy: 200, limitedBy: body.endIndex) ?? body.endIndex
        let piece = String(body[start..<end]).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (start == body.startIndex ? "" : "…") + piece + (end == body.endIndex ? "" : "…")
    }

    private static func pinyin(_ name: String) -> (String, String) {
        let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? name
        let words = QueryParser.normalize(latin).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (words.joined(), String(words.compactMap(\.first)))
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw SearchDatabaseError(message: "文件路径必须是根目录下的规范相对路径")
        }
    }

    private func signature(_ file: FileRecord) -> [Value] {
        [.integer(file.id), .string(file.rootID), .string(file.relativePath), .integer(file.size), .real(file.modified), .integer(file.inode)]
    }

    // files_pending covers kind/state for the full aggregate. The partial index
    // counts non-NULL content exactly, including retained content on error rows,
    // without loading the potentially large JSON/text columns of the files table.
    static let statisticsSQL = """
        SELECT count(*),coalesce(sum(kind='document'),0),coalesce(sum(kind='image'),0),
               coalesce(sum(content_state='pending'),0),coalesce(sum(content_state='error'),0),
               (SELECT count(*) FROM files INDEXED BY files_with_content WHERE content_id IS NOT NULL)
        FROM files INDEXED BY files_pending
        """

    private static let signaturePredicate = "id=? AND root_id=? AND relative_path=? AND size=? AND modified=? AND inode=?"
    static let fileColumns = "f.id,f.root_id,f.relative_path,f.name,f.extension,f.kind,f.size,f.modified,f.inode,f.content_state,f.content_error,f.generation"

    func fileRecord(_ statement: OpaquePointer) -> FileRecord {
        FileRecord(id: sqlite3_column_int64(statement, 0), rootID: text(statement, 1), relativePath: text(statement, 2), name: text(statement, 3), fileExtension: text(statement, 4), kind: FileKind(rawValue: text(statement, 5)) ?? .other, size: sqlite3_column_int64(statement, 6), modified: sqlite3_column_double(statement, 7), inode: sqlite3_column_int64(statement, 8), contentState: text(statement, 9), contentError: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : text(statement, 10))
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    enum Value { case string(String), integer(Int64), real(Double), blob(Data), null }

    private func error() -> Error {
        if sqlite3_errcode(connection) == SQLITE_INTERRUPT { return CancellationError() }
        return SearchDatabaseError(message: String(cString: sqlite3_errmsg(connection)))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .string(let string): code = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), Self.transient) }
            case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .integer(let integer): code = sqlite3_bind_int64(statement, index, integer)
            case .real(let double): code = sqlite3_bind_double(statement, index, double)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw error() }
        }
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error()
        }
    }

    func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        try done(statement)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T { try decoder.decode(type, from: Data(string.utf8)) }

    private static let changed = "(files.size<>excluded.size OR files.modified<>excluded.modified OR files.inode<>excluded.inode)"
    private static let upsert = """
        INSERT INTO files(root_id,relative_path,name,extension,kind,size,modified,inode,content_state,content_error,generation,name_search,pinyin_search,initials_search,path_search)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(root_id,relative_path) DO UPDATE SET
          name=excluded.name,extension=excluded.extension,kind=excluded.kind,
          size=excluded.size,modified=excluded.modified,inode=excluded.inode,generation=excluded.generation,
          name_search=excluded.name_search,pinyin_search=excluded.pinyin_search,initials_search=excluded.initials_search,path_search=excluded.path_search,
          content_id=CASE WHEN \(changed) THEN NULL ELSE files.content_id END,
          content_state=CASE WHEN \(changed) THEN excluded.content_state
                            WHEN files.content_state IN ('done','error') THEN files.content_state
                            ELSE excluded.content_state END,
          content_error=CASE WHEN \(changed) THEN excluded.content_error
                            WHEN files.content_state IN ('done','error') THEN files.content_error
                            ELSE excluded.content_error END
        """

    static let schema = """
        CREATE TABLE IF NOT EXISTS roots (
          id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL,
          online INTEGER NOT NULL, enabled INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS content_blobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          digest BLOB NOT NULL UNIQUE, packed BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          relative_path TEXT NOT NULL, name TEXT NOT NULL, extension TEXT NOT NULL,
          kind TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL, inode INTEGER NOT NULL,
          content_state TEXT NOT NULL, content_error TEXT, generation INTEGER NOT NULL,
          content_id INTEGER REFERENCES content_blobs(id),
          name_search TEXT NOT NULL, pinyin_search TEXT NOT NULL, initials_search TEXT NOT NULL, path_search TEXT NOT NULL,
          UNIQUE(root_id,relative_path)
        );
        CREATE INDEX IF NOT EXISTS files_pending ON files(root_id,content_state,kind,id);
        CREATE INDEX IF NOT EXISTS files_generation ON files(root_id,generation);
        CREATE INDEX IF NOT EXISTS files_kind ON files(kind);
        CREATE INDEX IF NOT EXISTS files_extension ON files(extension);
        CREATE INDEX IF NOT EXISTS files_with_content ON files(content_id,id) WHERE content_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS catalog_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
        INSERT OR IGNORE INTO catalog_state VALUES(1,0);
        CREATE TABLE IF NOT EXISTS name_changes(file_id INTEGER PRIMARY KEY,revision INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS name_changes_revision ON name_changes(revision);
        DROP TRIGGER IF EXISTS names_insert;
        DROP TRIGGER IF EXISTS names_delete;
        DROP TRIGGER IF EXISTS names_update;
        CREATE TRIGGER IF NOT EXISTS names_insert AFTER INSERT ON files BEGIN
          UPDATE catalog_state SET revision=revision+1 WHERE id=1;
          DELETE FROM name_changes WHERE file_id=new.id;
          INSERT INTO name_changes VALUES(new.id,(SELECT revision FROM catalog_state WHERE id=1));
          DELETE FROM name_changes WHERE revision<=(SELECT revision-100000 FROM catalog_state WHERE id=1);
        END;
        CREATE TRIGGER IF NOT EXISTS names_delete AFTER DELETE ON files BEGIN
          UPDATE catalog_state SET revision=revision+1 WHERE id=1;
          DELETE FROM name_changes WHERE file_id=old.id;
          INSERT INTO name_changes VALUES(old.id,(SELECT revision FROM catalog_state WHERE id=1));
          DELETE FROM name_changes WHERE revision<=(SELECT revision-100000 FROM catalog_state WHERE id=1);
        END;
        CREATE TRIGGER IF NOT EXISTS names_update AFTER UPDATE OF name,extension,kind,size,modified,root_id,relative_path ON files
        WHEN old.name<>new.name OR old.extension<>new.extension OR old.kind<>new.kind OR old.size<>new.size OR old.modified<>new.modified OR old.root_id<>new.root_id OR old.relative_path<>new.relative_path BEGIN
          UPDATE catalog_state SET revision=revision+1 WHERE id=1;
          DELETE FROM name_changes WHERE file_id=new.id;
          INSERT INTO name_changes VALUES(new.id,(SELECT revision FROM catalog_state WHERE id=1));
          DELETE FROM name_changes WHERE revision<=(SELECT revision-100000 FROM catalog_state WHERE id=1);
        END;
        CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(terms,content='',detail=none,columnsize=0,tokenize='miji_grams');
        CREATE TRIGGER IF NOT EXISTS content_insert AFTER INSERT ON content_blobs BEGIN
          INSERT INTO content_fts(rowid,terms) VALUES(new.id,miji_content(new.packed));
        END;
        CREATE TRIGGER IF NOT EXISTS content_delete AFTER DELETE ON content_blobs BEGIN
          INSERT INTO content_fts(content_fts,rowid,terms) VALUES('delete',old.id,miji_content(old.packed));
        END;
        CREATE TRIGGER IF NOT EXISTS files_delete AFTER DELETE ON files WHEN old.content_id IS NOT NULL BEGIN
          DELETE FROM content_blobs WHERE id=old.content_id AND NOT EXISTS(SELECT 1 FROM files WHERE content_id=old.content_id);
        END;
        CREATE TRIGGER IF NOT EXISTS files_content_update AFTER UPDATE OF content_id ON files
        WHEN old.content_id IS NOT NULL AND old.content_id IS NOT new.content_id BEGIN
          DELETE FROM content_blobs WHERE id=old.content_id AND NOT EXISTS(SELECT 1 FROM files WHERE content_id=old.content_id);
        END;
        PRAGMA user_version=2;
        """
}
