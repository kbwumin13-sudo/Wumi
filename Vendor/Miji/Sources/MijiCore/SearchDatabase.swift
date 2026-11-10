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
    private var metadataCandidates = 0
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
            sqlite3_create_function_v2(connection, "miji_raw_size", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                Unmanaged.passUnretained(self).toOpaque(), { context, _, args in
                    guard let context, let owner = sqlite3_user_data(context), let value = args?[0],
                          let pointer = sqlite3_value_blob(value) else { return }
                    let db = Unmanaged<SearchDatabase>.fromOpaque(owner).takeUnretainedValue()
                    db.metadataCandidates += 1
                    let header = Data(bytes: pointer, count: min(16, Int(sqlite3_value_bytes(value))))
                    sqlite3_result_int64(context, Int64(ContentCodec.declaredRawBytes(header) ?? ContentCodec.maximumRawBytes))
                }, nil, nil, nil)
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
                      m.file_id IS NOT NULL,m.created,m.is_directory,m.is_package,
                      f.content_id IS NOT NULL,f.size,f.modified,f.inode
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
                    let invalidatesContent = found && sqlite3_column_int(existing, 10) != 0
                        && (sqlite3_column_int64(existing, 11) != file.size
                            || sqlite3_column_double(existing, 12) != file.modified
                            || sqlite3_column_int64(existing, 13) != file.inode)
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
                    if invalidatesContent { statistics.contentInvalidations += 1 }
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
                                    onPartial:(([SearchHit])->Void)?=nil, traceCandidates: Bool = false,
                                    onMetrics: ((SearchMetrics) -> Void)? = nil) throws -> [SearchHit] {
        try searchImpl(query, options: options, includeNames: false, cancelled: cancelled,onPartial:onPartial,traceCandidates:traceCandidates,onMetrics:onMetrics)
    }

    private func searchImpl(_ query: String, options: SearchOptions, includeNames: Bool, cancelled: @escaping () -> Bool,
                            onPartial:(([SearchHit])->Void)?=nil, traceCandidates: Bool = false,
                            onMetrics: ((SearchMetrics) -> Void)? = nil) throws -> [SearchHit] {
        let started = DispatchTime.now().uptimeNanoseconds
        let bounded = options.sort == .relevance && options.scope != .name
        let deadline = started + 2_000_000_000
        var phaseDeadline = started + 1_600_000_000
        func expired() -> Bool { bounded && DispatchTime.now().uptimeNanoseconds >= phaseDeadline }
        var metrics = SearchMetrics()
        var decodedBodies = Set<Int64>()
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }
        defer { metrics.finalMS = elapsed(); onMetrics?(metrics) }
        if cancelled() { throw CancellationError() }
        return try synchronized {
            if cancelled() { throw CancellationError() }
            guard options.limit > 0 else { return [] }
            let context = Unmanaged.passRetained(SearchCancellationContext { cancelled() || expired() })
            sqlite3_progress_handler(connection, 1_000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<SearchCancellationContext>.fromOpaque(pointer).takeUnretainedValue().cancelled() ? 1 : 0
            }, context.toOpaque())
            defer { sqlite3_progress_handler(connection, 0, nil, nil); context.release() }
            try execute("BEGIN")
            defer {
                // Cleanup must run even after the caller or deadline interrupted SQL.
                sqlite3_progress_handler(connection, 0, nil, nil)
                try? execute("ROLLBACK")
            }
            let bodyReader = try prepare("SELECT packed FROM content_blobs WHERE id=?")
            defer { sqlite3_finalize(bodyReader) }
            let metadataStart = metadataCandidates
            defer { metrics.metadataCandidates = metadataCandidates - metadataStart }
            var cache: [Int64: ExtractedContent] = [:]
            var cacheBytes = 0
            typealias Summary = (content: ExtractedContent, terms: [String], labels: String, snippet: String)
            var summaries: [Int64: Summary] = [:]
            var summaryBytes = 0
            var decodingLimit = bounded ? 48 * 1024 * 1024 : Int.max
            func readContent(_ id: Int64) throws -> ExtractedContent? {
                if let cached = cache[id] { return cached }
                if expired() { throw ContentBudgetReached() }
                sqlite3_reset(bodyReader); sqlite3_clear_bindings(bodyReader)
                try bind([.integer(id)], to: bodyReader)
                guard try next(bodyReader) else { return nil }
                let packed = blob(bodyReader, 0)
                if bounded, let size = ContentCodec.declaredRawBytes(packed), metrics.decompressedBytes + size > decodingLimit {
                    throw ContentBudgetReached()
                }
                let raw = try ContentCodec.unpack(packed)
                do {
                    decodedBodies.insert(id)
                    metrics.distinctBodies = decodedBodies.count
                    metrics.decompressions += 1
                    metrics.decompressedBytes += raw.count
                }
                let content = try ContentCodec.content(raw, decoder: decoder)
                if raw.count + summaryBytes <= 16 * 1024 * 1024 {
                    if cacheBytes + raw.count + summaryBytes > 16 * 1024 * 1024 { cache.removeAll(keepingCapacity: true); cacheBytes = 0 }
                    cache[id] = content; cacheBytes += raw.count
                }
                return content
            }
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
            // Exact evidence ranks candidates. Useful decoded bodies retain a short excerpt;
            // remaining selected summaries use the reserved time/byte allowance.
            typealias Candidate=(SearchHit,Int,Int64?,String,tier:Int,strongName:Bool)
            var hits: [Candidate] = []
            var seen = Set<Int64>()
            func better(_ left:Candidate,_ right:Candidate) -> Bool {
                switch options.sort {
                case .relevance:
                    if left.strongName != right.strongName { return left.strongName }
                    if left.1 != right.1 { return left.1 > right.1 }
                    if left.2 != nil && right.2 != nil {
                        if left.tier != right.tier { return left.tier < right.tier }
                        if left.0.file.modified != right.0.file.modified { return left.0.file.modified > right.0.file.modified }
                    }
                case .modified: if left.0.file.modified != right.0.file.modified {return left.0.file.modified > right.0.file.modified}
                case .size: if left.0.file.size != right.0.file.size {return left.0.file.size > right.0.file.size}
                case .name: break
                }
                let a=left.3,b=right.3
                if a != b { return a < b }
                if options.sort == .relevance {
                    let l = left.0.root.id + "/" + left.0.file.relativePath, r = right.0.root.id + "/" + right.0.file.relativePath
                    return l < r
                }
                return left.0.id < right.0.id
            }
            var rootCache: [String: IndexedRoot] = [:]
            var contentCacheID: Int64 = -1
            var cachedTerms: [(body: Bool, labels: Bool)] = []
            var cachedRelevance = 0
            var lastPartial=Date.distantPast
            /// Generate cheap, stable candidates before bounded exact verification.
            /// Copies share a request-local body cache; final limit is independent.
            func collect(_ predicates: [String], _ values: [Value], readBody: Bool, focusedBody: Bool = false) throws {
                let columns = "\(Self.fileColumns),r.payload,f.name_search,f.pinyin_search,f.initials_search,f.content_id,\(Self.locationTier("f"))"
                let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
                /// One candidate row; false once the page is full.
                func consider(_ statement: OpaquePointer) throws -> Bool {
                    if cancelled() { throw CancellationError() }
                    let id = sqlite3_column_int64(statement, 0)
                    if seen.contains(id) { return true }
                    if bounded && readBody && (metrics.candidates >= 4_000 || expired()) { throw ContentBudgetReached() }
                    metrics.candidates += 1
                    if traceCandidates { metrics.candidateOrder.append(text(statement, 1) + "/" + text(statement, 2)) }
                    let name = text(statement, 13), pinyin = text(statement, 14), initials = text(statement, 15)
                    var found: [(body: Bool, labels: Bool)] = []
                    if readBody && !textTerms.isEmpty {
                        let contentID = sqlite3_column_int64(statement, 16)
                        if contentID != contentCacheID {
                            let content = try readContent(contentID)
                            let body = Self.bodyHits(content?.text ?? "", textTerms.map(\.value), hanTerms: hanTerms)
                            let labels = QueryParser.normalize(content?.labels.joined(separator: "\n") ?? "")
                            cachedTerms = textTerms.indices.map { (body[$0], labels.contains(textTerms[$0].value)) }
                            let indices = textTerms.indices.filter { !textTerms[$0].isExcluded }
                            cachedRelevance = ContentRelevanceScorer.strength(text: content?.text ?? "",
                                positive: indices.map { textTerms[$0].value }, bodyMatches: indices.map { body[$0] })
                            if cachedRelevance >= 2, summaries[contentID] == nil, let content {
                                let matched = indices.filter { body[$0] }.map { textTerms[$0].value }
                                let snippet = Self.snippet(content.text, matching: matched)
                                metrics.summariesBuilt += 1
                                // Only the short excerpt and labels survive, charged to the same 16 MiB cache allowance.
                                let cost = 2 * (snippet.utf8.count + labels.utf8.count + matched.reduce(0) { $0 + $1.utf8.count }) + 256
                                if summaryBytes + cost <= 8 * 1024 * 1024 {
                                    summaryBytes += cost
                                    if cacheBytes + summaryBytes > 16 * 1024 * 1024 { cache.removeAll(keepingCapacity: true); cacheBytes = 0 }
                                    summaries[contentID] = (ExtractedContent(labels: content.labels), matched, labels, snippet)
                                }
                            }
                            contentCacheID = contentID
                        }
                        found = cachedTerms
                    }
                    var score = 0
                    var matches = true, nameHit = false
                    for (index, term) in textTerms.enumerated() {
                        let inBody = !found.isEmpty && found[index].body, inLabels = !found.isEmpty && found[index].labels
                        let nameMatch = options.scope != .content && (name.contains(term.value) || pinyin.contains(term.value) || initials.contains(term.value))
                        if nameMatch && !term.isExcluded { nameHit = true }
                        let bodyMatch = options.scope != .name && (inBody || inLabels)
                        if term.isExcluded ? (nameMatch || bodyMatch) : !(nameMatch || bodyMatch) { matches = false; break }
                        if !term.isExcluded {
                            if name.contains(term.value) && options.scope != .content { score += 100 }
                            else if nameMatch { score += 70 }
                            if inLabels && options.scope != .name { score += 35 }
                            if inBody && options.scope != .name { score += 20 }
                        }
                    }
                    guard matches else { return true }
                    metrics.verified += 1
                    let file = fileRecord(statement)
                    let root: IndexedRoot
                    if let cached = rootCache[file.rootID] { root = cached }
                    else { root = try decode(IndexedRoot.self, text(statement, 12)); rootCache[file.rootID] = root }
                    let bodyID=readBody && sqlite3_column_type(statement,16) != SQLITE_NULL ? sqlite3_column_int64(statement,16) : nil
                    var hit = SearchHit(file:file,root:root,snippet:"",matchedIn:readBody ? "内容" : "文件名",labels:"")
                    hit.contentRelevance = readBody ? cachedRelevance : 0
                    if let bodyID, let summary = summaries[bodyID] {
                        hit.snippet = summary.snippet
                        hit.labels = summary.content.labels.joined(separator: "、")
                        hit.matchedIn = nameHit ? "文件名、正文" : "正文"
                    }
                    if readBody { score = cachedRelevance * 1_000 + (nameHit ? 100 : 0) }
                    let phrase = positive.map(\.value).joined(separator: " ")
                    let strongName = options.scope != .content && !positive.isEmpty &&
                        (name == phrase || QueryParser.normalize((file.name as NSString).deletingPathExtension) == phrase ||
                         (positive.count == 1 && (name.hasPrefix(phrase) || pinyin.hasPrefix(phrase) || initials.hasPrefix(phrase))))
                    hits.append((hit,score,bodyID,name,tier:Int(sqlite3_column_int(statement,17)),strongName:strongName))
                    // A broad body query can match hundreds of thousands of
                    // paths. Keep only a bounded top set, not every snippet.
                    if hits.count > max(256,options.limit*2) {
                        metrics.resultTruncated = true
                        hits.sort(by:better)
                        hits.removeLast(hits.count-options.limit)
                    }
                    if let onPartial,Date().timeIntervalSince(lastPartial)>=0.25 {
                        // Every emitted hit has passed all exact predicates.
                        // Continue ranking and add selected snippets at completion.
                        if metrics.firstResultMS == nil { metrics.firstResultMS = elapsed() }
                        onPartial(hits.sorted(by:better).prefix(options.limit).map(\.0))
                        lastPartial=Date()
                    }
                    return true
                }
                let focused = bounded && readBody && focusedBody
                if focused {
                    // Stream old/new metadata in rounds. Never wait for all headers before the first verification.
                    var pooled = Set<Int64>()
                    var more = [true, true]
                    let row = try prepare("SELECT \(columns) FROM files f JOIN roots r ON r.id=f.root_id WHERE f.id=?")
                    defer { metrics.sqlSteps += Int(sqlite3_stmt_status(row, SQLITE_STMTSTATUS_VM_STEP, 0)); sqlite3_finalize(row) }
                    exploration: for page in 0..<4 {
                        var pool: [(id: Int64, size: Int, path: String)] = []
                        for lane in 0..<2 where more[lane] {
                            let direction = lane == 0 ? "ASC" : "DESC"
                            var count = 0
                            let rows = try prepare("WITH lane AS MATERIALIZED (SELECT f.id,f.content_id,f.root_id || '/' || f.path_search AS path FROM files f JOIN roots r ON r.id=f.root_id\(filter) ORDER BY f.content_id \(direction),f.id LIMIT 512 OFFSET \(page * 512)) SELECT lane.id,miji_raw_size(substr(b.packed,1,16)),lane.path FROM lane JOIN content_blobs b ON b.id=lane.content_id")
                            defer { metrics.sqlSteps += Int(sqlite3_stmt_status(rows, SQLITE_STMTSTATUS_VM_STEP, 0)); sqlite3_finalize(rows) }
                            try bind(values, to: rows)
                            do {
                                while try next(rows) {
                                    count += 1
                                    let id = sqlite3_column_int64(rows, 0)
                                    if pooled.insert(id).inserted { pool.append((id, Int(sqlite3_column_int64(rows, 1)), text(rows, 2))) }
                                    if expired() { throw ContentBudgetReached() }
                                }
                            } catch is ContentBudgetReached { metrics.budgetExhausted = true; metrics.resultTruncated = true; break exploration }
                            catch is CancellationError {
                                if cancelled() { throw CancellationError() }
                                guard expired() else { throw CancellationError() }
                                metrics.budgetExhausted = true; metrics.resultTruncated = true; break exploration
                            }
                            more[lane] = count == 512
                        }
                        pool.sort { $0.size == $1.size ? $0.path < $1.path : $0.size < $1.size }
                        do {
                            for candidate in pool {
                                sqlite3_reset(row); sqlite3_clear_bindings(row)
                                try bind([.integer(candidate.id)], to: row)
                                if try next(row), !(try consider(row)) { break exploration }
                            }
                        } catch is ContentBudgetReached { metrics.budgetExhausted = true; metrics.resultTruncated = true; break exploration }
                        catch is CancellationError {
                            if cancelled() { throw CancellationError() }
                            guard expired() else { throw CancellationError() }
                            metrics.budgetExhausted = true; metrics.resultTruncated = true; break exploration
                        }
                        if !more.contains(true) { break }
                    }
                    if more.contains(true) { metrics.budgetExhausted = true; metrics.resultTruncated = true }
                } else {
                    let order = readBody ? "f.content_id,f.id" : "f.id"
                    let statement = try prepare("SELECT \(columns) FROM files f JOIN roots r ON r.id=f.root_id\(filter) ORDER BY " + order)
                    defer { metrics.sqlSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)); sqlite3_finalize(statement) }
                    try bind(values, to: statement)
                    do { while try next(statement), try consider(statement) {} }
                    catch is ContentBudgetReached { metrics.budgetExhausted = true; metrics.resultTruncated = true }
                    catch is CancellationError {
                        if cancelled() { throw CancellationError() }
                        guard expired() else { throw CancellationError() }
                        metrics.budgetExhausted = true; metrics.resultTruncated = true
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
                try collect(bodyFilters, bodyValues, readBody: true, focusedBody: true)
            }
            if cancelled() { throw CancellationError() }
            hits.sort(by:better)
            // The fixed total budget reserves time and bytes for selected summaries.
            phaseDeadline = deadline
            decodingLimit = bounded ? 64 * 1024 * 1024 : Int.max
            // Decorate in rank order. Strong bodies reuse their already-built short excerpts.
            metrics.resultTruncated = metrics.resultTruncated || hits.count > options.limit
            let selected=Array(hits.prefix(options.limit))
            var decorated=[SearchHit?](repeating:nil,count:selected.count)
            var previousBody:Int64?,content:ExtractedContent?,bodyTerms:[String]=[],labels="",snippet=""
            for index in selected.indices {
                if cancelled() {throw CancellationError()}
                let candidate=selected[index]
                if let id = candidate.2, let summary = summaries[id] {
                    var hit = Self.hit(file: candidate.0.file, root: candidate.0.root, content: summary.content,
                        terms: terms, scope: options.scope, bodyTerms: summary.terms,
                        normalizedLabels: summary.labels, cachedSnippet: summary.snippet)
                    hit.contentRelevance = candidate.0.contentRelevance
                    decorated[index] = hit
                    continue
                }
                if candidate.2 != previousBody {
                    content=nil;bodyTerms=[];labels="";snippet=""
                    if let id=candidate.2, !expired() {
                        let loaded: ExtractedContent?
                        do { loaded = try readContent(id) }
                        catch is ContentBudgetReached { loaded = nil; metrics.budgetExhausted = true; metrics.resultTruncated = true }
                        catch is CancellationError {
                            if cancelled() { throw CancellationError() }
                            guard expired() else { throw CancellationError() }
                            loaded = nil; metrics.budgetExhausted = true; metrics.resultTruncated = true
                        }
                        if let loaded {
                            content=loaded
                            // The candidate pass's check, not another scan of the body per term.
                            let found=textTerms.isEmpty ? [] : Self.bodyHits(content?.text ?? "",textTerms.map(\.value),hanTerms:hanTerms)
                            bodyTerms=textTerms.indices.filter {!textTerms[$0].isExcluded && found[$0]}.map {textTerms[$0].value}
                            labels=QueryParser.normalize(content?.labels.joined(separator:"\n") ?? "")
                            snippet=Self.snippet(content?.text ?? "",matching:bodyTerms)
                            metrics.summariesBuilt += 1
                        }
                    }
                    previousBody=candidate.2
                }
                var hit = content == nil ? candidate.0 : Self.hit(file:candidate.0.file,root:candidate.0.root,content:content,terms:terms,scope:options.scope,bodyTerms:bodyTerms,normalizedLabels:labels,cachedSnippet:snippet)
                hit.contentRelevance = candidate.0.contentRelevance
                decorated[index] = hit
            }
            if expired() { metrics.budgetExhausted = true; metrics.resultTruncated = true }
            if metrics.firstResultMS == nil && !selected.isEmpty { metrics.firstResultMS = elapsed() }
            return decorated.compactMap{$0}
        }
    }

    /// Whether each normalized term occurs in a body, as Foundation's `contains`
    /// on the body decides (the raw body when Han terms all occur in it
    /// literally, the normalized body otherwise): whole characters (grapheme
    /// clusters), without a character walk over every body. Pure ASCII text
    /// normalizes to its lowercase. A byte match counts when both of its ends
    /// are character boundaries; where that is not certain, Foundation decides.
    static func bodyHits(_ text: String, _ terms: [String], hanTerms: Bool) -> [Bool] {
        var raw = text
        return raw.withUTF8 { source -> [Bool] in
            var hits = [Bool](repeating: false, count: terms.count)
            if hanTerms {
                for (i, term) in terms.enumerated() {
                    switch characterMatch(term, in: source) {
                    case true?: hits[i] = true
                    case false?: hits[i] = false
                    case nil: hits[i] = text.contains(term)
                    }
                }
                if hits.allSatisfy({ $0 }) { return hits }
            }
            func check(_ normalized: UnsafeBufferPointer<UInt8>, _ string: () -> String) {
                for (i, term) in terms.enumerated() where !hits[i] {
                    hits[i] = characterMatch(term, in: normalized) ?? string().contains(term)
                }
            }
            if source.allSatisfy({ $0 < 128 }) {
                let lowered = source.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
                lowered.withUnsafeBufferPointer { bytes in check(bytes) { String(decoding: bytes, as: UTF8.self) } }
            } else {
                var normalized = QueryParser.normalize(text)
                let copy = normalized
                normalized.withUTF8 { bytes in check(bytes) { copy } }
            }
            return hits
        }
    }

    /// Some occurrence of `term` in `bytes` starts and ends on character
    /// boundaries (true), none does (false), or a boundary is not certain (nil).
    static func characterMatch(_ term: String, in bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
        var needle = term
        return needle.withUTF8 { key -> Bool? in
            guard !key.isEmpty else { return true }
            /// Foundation's NFC leaves a syllable followed by a trailing jamo
            /// uncomposed, while Swift compares it as the composed syllable, so
            /// no byte match is not a miss where a Hangul term meets that form.
            func missed() -> Bool? {
                func jamo(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
                    var i = 0
                    while i + 2 < b.count {
                        switch (b[i], b[i + 1]) {
                        case (0xE1, 0x84...0x87): return true                       // U+1100-11FF
                        case (0xEA, 0xA5) where b[i + 2] >= 0xA0: return true       // U+A960-A97F
                        case (0xED, 0x9E) where b[i + 2] >= 0xB0, (0xED, 0x9F): return true // U+D7B0-D7FF
                        default: i += 1
                        }
                    }
                    return false
                }
                let hangul = term.unicodeScalars.contains {
                    (0x1100...0x11FF).contains($0.value) || (0xA960...0xA97F).contains($0.value) || (0xAC00...0xD7FF).contains($0.value)
                }
                return hangul && (jamo(key) || jamo(bytes)) ? nil : false
            }
            guard key.count <= bytes.count, let base = bytes.baseAddress else { return missed() }
            var from = 0, uncertain = false
            while from <= bytes.count - key.count,
                  let found = memmem(base + from, bytes.count - from, key.baseAddress!, key.count) {
                let start = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                switch (characterBoundary(bytes, start), characterBoundary(bytes, start + key.count)) {
                case (true?, true?): return true
                case (false?, _), (_, false?): break
                default: uncertain = true
                }
                from = start + 1
            }
            return uncertain ? nil : missed()
        }
    }

    /// A grapheme cluster boundary at a scalar boundary of valid UTF-8 (UAX #29),
    /// decided only where the rules are unambiguous; nil otherwise.
    static func characterBoundary(_ bytes: UnsafeBufferPointer<UInt8>, _ position: Int) -> Bool? {
        if position == 0 || position == bytes.count { return true }
        func scalar(at index: Int) -> Unicode.Scalar? {
            var iterator = UnsafeBufferPointer(rebasing: bytes[index...]).makeIterator()
            var decoder = UTF8()
            if case .scalarValue(let value) = decoder.decode(&iterator) { return value }
            return nil
        }
        var lead = position - 1
        while lead > 0 && bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        guard let before = scalar(at: lead), let after = scalar(at: position) else { return nil }
        func regional(_ s: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(s.value) }
        func jamo(_ s: Unicode.Scalar) -> Bool {
            (0x1100...0x11FF).contains(s.value) || (0xA960...0xA97F).contains(s.value) || (0xD7B0...0xD7FF).contains(s.value)
        }
        func prepend(_ s: Unicode.Scalar) -> Bool {
            [0x0600...0x0605, 0x06DD...0x06DD, 0x070F...0x070F, 0x0890...0x0891, 0x08E2...0x08E2, 0x0D4E...0x0D4E,
             0x110BD...0x110BD, 0x110CD...0x110CD, 0x111C2...0x111C3, 0x1193F...0x1193F, 0x11941...0x11941,
             0x11A3A...0x11A3A, 0x11A84...0x11A89, 0x11D46...0x11D46, 0x11F02...0x11F02].contains { $0.contains(s.value) }
        }
        let syllable: (Unicode.Scalar) -> Bool = { (0xAC00...0xD7A3).contains($0.value) }
        if before.value == 0x0D && after.value == 0x0A { return false }                     // GB3
        if before.properties.generalCategory == .control || after.properties.generalCategory == .control { return true } // GB4, GB5
        let category = before.properties.generalCategory
        if category == .format || category == .lineSeparator || category == .paragraphSeparator,
           before.value != 0x200C, before.value != 0x200D {
            // Controls too, apart from extenders (tags) and prepended marks.
            return before.properties.isGraphemeExtend || prepend(before) ? nil : true       // GB4
        }
        if after.properties.isGraphemeExtend || after.properties.isEmojiModifier || after.value == 0x200D { return false } // GB9
        if after.properties.generalCategory == .spacingMark
            || after.value == 0x0E33 || after.value == 0x0EB3 { return nil }               // GB9a (Thai and Lao AM are Lo)
        if before.properties.isGraphemeExtend || before.properties.isEmojiModifier { return nil } // GB9c conjuncts
        if before.value == 0x200D || prepend(before) || (regional(before) && regional(after))
            || jamo(before) || jamo(after) || (syllable(before) && jamo(after)) { return nil } // GB9b, GB11, GB12-13, GB6-8
        return true                                                                         // GB999
    }

    private final class SearchCancellationContext {
        let cancelled: () -> Bool
        init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
    }

    private static func hit(file: FileRecord, root: IndexedRoot, content: ExtractedContent?, terms: [QueryTerm], scope: SearchScope,
                            bodyTerms:[String],normalizedLabels:String?=nil,cachedSnippet:String?=nil) -> SearchHit {
        let positive = terms.filter { $0.field == .text && !$0.isExcluded }.map(\.value)
        let name = QueryParser.normalize(file.name)
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
        let bodyTerms = scope == .name ? [] : bodyTerms
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

    static func pinyin(_ name: String) -> (String, String) {
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

    /// Where a file lives, for ranking: 1 under hidden folders, Library and
    /// caches, system trees and dependency folders; 0 elsewhere, which is
    /// where the user's own files are. `table` is the alias of `files`.
    static func locationTier(_ table: String) -> String {
        // Core columns only (the name engine reads no derived ones). LIKE
        // ignores ASCII case, so no lower() copy per row.
        let path = "('/'||\(table).relative_path)"
        let inside = ["/.", "/library/", "/caches/", "/node\\_modules/", "/site-packages/", "/deriveddata/", "/pods/"]
            .map { "\(path) LIKE '%\($0)%' ESCAPE '\\'" }
        let roots = ["system/", "usr/", "opt/", "private/", "bin/", "sbin/", "cores/"].map { "\(table).relative_path LIKE '\($0)%'" }
        return "(CASE WHEN " + (inside + roots).joined(separator: " OR ") + " THEN 1 ELSE 0 END)"
    }
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

private struct ContentBudgetReached: Error {}
