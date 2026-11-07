import Foundation
import CSQLite
import Darwin

/// Bounded query transfer, never a second resident whole-disk name index.
public struct CatalogRecord: Sendable {
    public var file: FileRecord
    public var root: IndexedRoot
    public var pinyin: String
    public var initials: String
}

extension SearchDatabase {
    static let wumiSchema = """
        CREATE TABLE IF NOT EXISTS wumi_file_metadata (
          file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
          created REAL, is_directory INTEGER, is_package INTEGER
        );
        """

    func saveWumiMetadata(_ file: FileRecord) throws {
        guard file.created != nil || file.isDirectory != nil || file.isPackage != nil else { return }
        try run("""
            INSERT INTO wumi_file_metadata(file_id,created,is_directory,is_package)
            SELECT id,?,?,? FROM files WHERE root_id=? AND relative_path=?
            ON CONFLICT(file_id) DO UPDATE SET
              created=coalesce(excluded.created,created),
              is_directory=coalesce(excluded.is_directory,is_directory),
              is_package=coalesce(excluded.is_package,is_package)
            WHERE created IS NOT coalesce(excluded.created,created)
               OR is_directory IS NOT coalesce(excluded.is_directory,is_directory)
               OR is_package IS NOT coalesce(excluded.is_package,is_package)
            """, [file.created.map(Value.real) ?? .null,
                  file.isDirectory.map { .integer($0 ? 1 : 0) } ?? .null,
                  file.isPackage.map { .integer($0 ? 1 : 0) } ?? .null,
                  .string(file.rootID),.string(file.relativePath)])
    }

    /// ID keyset paging. `ids` is bounded by the caller, never an unbounded SQL IN.
    /// A literal body candidate uses FTS only as a superset; callers verify the AST.
    public func catalogBatch(afterID: Int64 = 0, ids: [Int64]? = nil, contentLiteral: String? = nil, contentLiterals: [String]? = nil,
                             limit: Int = 256, cancelled: () -> Bool = { false }) throws -> [CatalogRecord] {
        try synchronized {
            if cancelled() { throw CancellationError() }
            if ids?.isEmpty == true { return [] }
            let exists = try prepare("SELECT 1 FROM sqlite_master WHERE name='wumi_file_metadata'")
            let metadata = try next(exists)
            sqlite3_finalize(exists)
            let columns = metadata ? "m.created,m.is_directory,m.is_package" : "NULL,NULL,NULL"
            var sql = "SELECT \(Self.fileColumns),r.payload,f.pinyin_search,f.initials_search,\(columns) FROM files f JOIN roots r ON r.id=f.root_id"
            if metadata { sql += " LEFT JOIN wumi_file_metadata m ON m.file_id=f.id" }
            sql += " WHERE f.id>?"
            var values: [Value] = [.integer(afterID)]
            if let ids {
                guard ids.count <= 512 else { throw SearchDatabaseError(message: "catalog ids batch exceeds 512") }
                sql += " AND f.id IN (" + Array(repeating:"?",count:ids.count).joined(separator:",") + ")"
                values += ids.map(Value.integer)
            }
            if let literals = contentLiterals ?? contentLiteral.map({ [$0] }) {
                sql += " AND f.content_id IS NOT NULL"
                let expressions = literals.map { ContentCodec.matchExpression(QueryParser.normalize($0)) }
                if !expressions.isEmpty, expressions.allSatisfy({ $0 != nil }) {
                    sql += " AND f.content_id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)"
                    values.append(.string(expressions.compactMap { $0 }.map { "(" + $0 + ")" }.joined(separator: " OR ")))
                }
            }
            sql += " ORDER BY f.id LIMIT ?"
            values.append(.integer(Int64(max(1,min(limit,512)))))
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(values,to:statement)
            var result:[CatalogRecord]=[]
            while try next(statement) {
                if cancelled() { throw CancellationError() }
                var file=fileRecord(statement)
                if sqlite3_column_type(statement,15) != SQLITE_NULL { file.created=sqlite3_column_double(statement,15) }
                if sqlite3_column_type(statement,16) != SQLITE_NULL { file.isDirectory=sqlite3_column_int(statement,16) != 0 }
                if sqlite3_column_type(statement,17) != SQLITE_NULL { file.isPackage=sqlite3_column_int(statement,17) != 0 }
                result.append(CatalogRecord(file:file,root:try decoder.decode(IndexedRoot.self,from:Data(text(statement,12).utf8)),
                                            pinyin:text(statement,13),initials:text(statement,14)))
            }
            return result
        }
    }

    /// SQLite online backup includes committed WAL frames, unlike copying the main file.
    /// Publish a closed, self-contained database atomically; readers never see a partial backup.
    /// Explicit paths only; destination must be new. The caller holds its DatabaseLease.
    public static func backup(from source: URL, to destination: URL, cancelled: () -> Bool = { false }) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath:destination.path) else {
            throw SearchDatabaseError(message:"备份目标必须是新文件")
        }
        if cancelled() { throw CancellationError() }
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString).tmp")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SearchDatabaseError(message:"无法创建备份暂存文件：\(errno)") }
        close(descriptor)
        defer {
            // Only this invocation's staging files belong to us, including when publication loses a race.
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: staging.path + suffix)
            }
        }
        var src:OpaquePointer?, dst:OpaquePointer?
        guard sqlite3_open_v2(source.path,&src,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            sqlite3_close(src);throw SearchDatabaseError(message:"无法只读打开备份源")
        }
        defer {sqlite3_close(src)}
        guard sqlite3_open_v2(staging.path,&dst,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            sqlite3_close(dst);throw SearchDatabaseError(message:"无法创建备份目标")
        }
        defer { if let dst { sqlite3_close(dst) } }
        guard let handle=sqlite3_backup_init(dst,"main",src,"main") else {throw SearchDatabaseError(message:"无法开始 SQLite backup")}
        var backupActive = true
        defer { if backupActive { sqlite3_backup_finish(handle) } }
        var code:Int32=SQLITE_OK
        var busy=0
        repeat {
            if cancelled() {throw CancellationError()}
            code=sqlite3_backup_step(handle,256)
            if code==SQLITE_BUSY || code==SQLITE_LOCKED {
                busy += 1
                if busy>500 {break}
                sqlite3_sleep(10)
            } else {busy=0}
        } while code==SQLITE_OK || code==SQLITE_BUSY || code==SQLITE_LOCKED
        let finish=sqlite3_backup_finish(handle)
        backupActive = false
        guard code==SQLITE_DONE,finish==SQLITE_OK else {throw SearchDatabaseError(message:"SQLite backup 未完成：\(code)/\(finish)")}
        if cancelled() { throw CancellationError() }
        let checkpoint = sqlite3_wal_checkpoint_v2(dst, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard checkpoint == SQLITE_OK,
              sqlite3_exec(dst, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw SearchDatabaseError(message:"无法完成备份 checkpoint：\(checkpoint)")
        }
        guard sqlite3_close(dst) == SQLITE_OK else { throw SearchDatabaseError(message:"无法关闭备份暂存数据库") }
        dst = nil
        if cancelled() { throw CancellationError() }
        // RENAME_EXCL is a single no-clobber rename on macOS, including dangling destination symlinks.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw SearchDatabaseError(message:"无法发布备份，目标可能已存在：\(errno)")
        }
    }
}
