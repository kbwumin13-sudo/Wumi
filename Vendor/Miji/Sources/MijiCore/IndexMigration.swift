import Foundation
import CSQLite

public struct IndexMigrationProgress: Codable, Sendable {
    public var phase: String
    public var files: Int64
    public var contents: Int64
    public var rawBytes: Int64
    public var databaseBytes: Int64
}

extension SearchDatabase {
    /// Creates a new compact database; never edits, scans or extracts source files.
    /// Restarting the same destination resumes at the last committed file ID.
    public static func migrateLegacy(from sourceURL: URL, to destinationURL: URL,
                                     progress: (IndexMigrationProgress) -> Void = { _ in }) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw SearchDatabaseError(message: "迁移目标必须是另一个文件")
        }
        let walPath = sourceURL.path + "-wal"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: walPath),
           let size = attributes[.size] as? NSNumber, size.int64Value > 0 {
            throw SearchDatabaseError(message: "请先退出旧版应用并 checkpoint WAL，迁移不能忽略尚未落盘的内容")
        }
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        // Caller has stopped the old writer and checkpointed its WAL. Immutable
        // also lets SQLite read a closed WAL-mode database without sidecars.
        let source = try SearchDatabase(url: sourceURL, readOnly: true, immutable: true)
        let version = try source.prepare("PRAGMA user_version")
        _ = try source.next(version)
        let legacyVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard legacyVersion == 1 else { throw SearchDatabaseError(message: "迁移仅接受版本1索引") }
        try source.execute("BEGIN")
        defer { try? source.execute("ROLLBACK") }
        let destination = try SearchDatabase(url: destinationURL)
        try destination.execute("PRAGMA cache_size=-32768; PRAGMA wal_autocheckpoint=1000; PRAGMA temp_store=MEMORY;")
        try destination.execute("CREATE TABLE IF NOT EXISTS migration_state(source TEXT NOT NULL,last_id INTEGER NOT NULL,files INTEGER NOT NULL,contents INTEGER NOT NULL,raw_bytes INTEGER NOT NULL,verified INTEGER NOT NULL DEFAULT 0)")
        let state = try destination.prepare("SELECT source,last_id,files,contents,raw_bytes FROM migration_state")
        var lastID: Int64 = 0, count: Int64 = 0, contents: Int64 = 0, rawBytes: Int64 = 0
        if try destination.next(state) {
            guard destination.text(state, 0) == sourceURL.standardizedFileURL.path else {
                sqlite3_finalize(state)
                throw SearchDatabaseError(message: "目标中存在另一个迁移任务")
            }
            lastID = sqlite3_column_int64(state, 1); count = sqlite3_column_int64(state, 2)
            contents = sqlite3_column_int64(state, 3); rawBytes = sqlite3_column_int64(state, 4)
        } else {
            let existing = try destination.prepare("SELECT count(*) FROM files")
            _ = try destination.next(existing)
            let existingCount = sqlite3_column_int64(existing, 0)
            sqlite3_finalize(existing)
            guard existingCount == 0 else { sqlite3_finalize(state); throw SearchDatabaseError(message: "迁移目标不是空库") }
            try destination.run("INSERT INTO migration_state(source,last_id,files,contents,raw_bytes) VALUES(?,0,0,0,0)", [.string(sourceURL.standardizedFileURL.path)])
        }
        sqlite3_finalize(state)
        // Bulk import must not interleave FTS writes with every FK-protected
        // file INSERT: SQLite otherwise flushes its FTS hash on each savepoint.
        let tableInfo = try destination.prepare("PRAGMA table_info(migration_state)")
        var hasFTSCursor = false
        while try destination.next(tableInfo) { if destination.text(tableInfo,1) == "fts_last_id" { hasFTSCursor = true } }
        sqlite3_finalize(tableInfo)
        if !hasFTSCursor {
            try destination.execute("ALTER TABLE migration_state ADD COLUMN fts_last_id INTEGER NOT NULL DEFAULT 0")
            // Older in-progress migrations indexed each committed body already.
            try destination.execute("UPDATE migration_state SET fts_last_id=(SELECT coalesce(max(id),0) FROM content_blobs)")
        }
        try destination.execute("DROP TRIGGER IF EXISTS content_insert; DROP TRIGGER IF EXISTS names_insert;")
        let roots = try source.prepare("SELECT id,payload,online,enabled FROM roots")
        while try source.next(roots) {
            try destination.run("INSERT INTO roots(id,payload,online,enabled) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,online=excluded.online,enabled=excluded.enabled",
                                [.string(source.text(roots,0)),.string(source.text(roots,1)),.integer(sqlite3_column_int64(roots,2)),.integer(sqlite3_column_int64(roots,3))])
        }
        sqlite3_finalize(roots)
        let columns = "id,root_id,relative_path,name,extension,kind,size,modified,inode,content_state,content_error,generation,name_search,pinyin_search,initials_search,path_search"
        let reader = try source.prepare("SELECT \(columns),content FROM files WHERE id>? ORDER BY id")
        defer { sqlite3_finalize(reader) }
        try source.bind([.integer(lastID)], to: reader)
        let insert = try destination.prepare("INSERT INTO files(\(columns),content_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        var batch = 0
        func report(_ phase: String) {
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            progress(IndexMigrationProgress(phase: phase, files: count, contents: contents, rawBytes: rawBytes, databaseBytes: bytes))
        }
        try destination.execute("BEGIN IMMEDIATE")
        do {
            while try source.next(reader) {
                try autoreleasepool {
                    var values = source.migrationValues(reader)
                    if sqlite3_column_type(reader, 16) != SQLITE_NULL {
                        let raw = source.blob(reader, 16)
                        let bodyID = try destination.insertBody(raw)
                        values.append(.integer(bodyID)); contents += 1; rawBytes += Int64(raw.count)
                    } else { values.append(.null) }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    try destination.bind(values, to: insert); try destination.done(insert)
                    lastID = sqlite3_column_int64(reader, 0); count += 1; batch += 1
                }
                if batch >= 1000 {
                    try destination.run("UPDATE migration_state SET last_id=?,files=?,contents=?,raw_bytes=?,verified=0", [.integer(lastID),.integer(count),.integer(contents),.integer(rawBytes)])
                    try destination.execute("COMMIT")
                    batch = 0; report("copy")
                    let space = try FileManager.default.attributesOfFileSystem(forPath: destinationURL.deletingLastPathComponent().path)
                    if let free = space[.systemFreeSize] as? NSNumber, free.int64Value < 1_073_741_824 {
                        throw SearchDatabaseError(message: "剩余空间不足1GiB，迁移已安全保存进度；原索引未修改")
                    }
                    try destination.execute("BEGIN IMMEDIATE")
                }
            }
            try destination.run("UPDATE migration_state SET last_id=?,files=?,contents=?,raw_bytes=?,verified=0", [.integer(lastID),.integer(count),.integer(contents),.integer(rawBytes)])
            try destination.execute("COMMIT")
        } catch { try? destination.execute("ROLLBACK"); throw error }
        let ftsCursor = try destination.prepare("SELECT fts_last_id FROM migration_state")
        _ = try destination.next(ftsCursor)
        var indexedID = sqlite3_column_int64(ftsCursor,0)
        sqlite3_finalize(ftsCursor)
        while true {
            let end = try destination.prepare("SELECT max(id) FROM (SELECT id FROM content_blobs WHERE id>? ORDER BY id LIMIT 500)")
            try destination.bind([.integer(indexedID)],to:end)
            _ = try destination.next(end)
            let last = sqlite3_column_type(end,0) == SQLITE_NULL ? indexedID : sqlite3_column_int64(end,0)
            sqlite3_finalize(end)
            if last == indexedID { break }
            try destination.transaction {
                try destination.run("INSERT INTO content_fts(rowid,terms) SELECT id,miji_content(packed) FROM content_blobs WHERE id>? AND id<=? ORDER BY id",[.integer(indexedID),.integer(last)])
                try destination.run("UPDATE migration_state SET fts_last_id=?",[.integer(last)])
            }
            indexedID = last
            report("index:\(indexedID)")
            let space = try FileManager.default.attributesOfFileSystem(forPath: destinationURL.deletingLastPathComponent().path)
            if let free = space[.systemFreeSize] as? NSNumber,free.int64Value < 1_073_741_824 { throw SearchDatabaseError(message:"剩余空间不足1GiB，全文索引已安全保存进度") }
        }
        try destination.execute(Self.schema)
        report("verify")
        try destination.verifyLegacy(source: source, columns: columns)
        // Verify every unique compressed payload, including large/OCR bodies.
        let bodies = try destination.prepare("SELECT digest,packed FROM content_blobs")
        defer { sqlite3_finalize(bodies) }
        while try destination.next(bodies) {
            try autoreleasepool {
                let raw = try ContentCodec.unpack(destination.blob(bodies,1))
                guard ContentCodec.digest(raw) == destination.blob(bodies,0) else { throw SearchDatabaseError(message: "迁移正文校验失败") }
                _ = try JSONDecoder().decode(ExtractedContent.self, from: raw)
            }
        }
        let check = try destination.prepare("PRAGMA quick_check")
        let checkOK = try destination.next(check) && destination.text(check,0) == "ok"
        sqlite3_finalize(check)
        guard checkOK else { throw SearchDatabaseError(message: "迁移数据库检查失败") }
        let foreign = try destination.prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreign) }
        guard try !destination.next(foreign) else { throw SearchDatabaseError(message: "迁移引用校验失败") }
        try destination.run("INSERT INTO content_fts(content_fts) VALUES('integrity-check')")
        let after = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard sourceAttributes[.modificationDate] as? Date == after[.modificationDate] as? Date,
              sourceAttributes[.size] as? NSNumber == after[.size] as? NSNumber else {
            throw SearchDatabaseError(message: "迁移过程中旧库发生变化，未标记为可切换")
        }
        try destination.run("UPDATE migration_state SET verified=1")
        try destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        report("complete")
    }

    private func migrationValues(_ row: OpaquePointer) -> [Value] {
        (0..<16).map { column in
            let index = Int32(column)
            if sqlite3_column_type(row,index) == SQLITE_NULL { return .null }
            if [0,6,8,11].contains(column) { return .integer(sqlite3_column_int64(row,index)) }
            if column == 7 { return .real(sqlite3_column_double(row,index)) }
            return .string(text(row,index))
        }
    }

    private func verifyLegacy(source: SearchDatabase, columns: String) throws {
        let old = try source.prepare("SELECT \(columns),content FROM files ORDER BY id")
        let new = try prepare("SELECT \(columns.split(separator: ",").map { "f."+$0 }.joined(separator: ",")),b.digest FROM files f LEFT JOIN content_blobs b ON b.id=f.content_id ORDER BY f.id")
        defer { sqlite3_finalize(old); sqlite3_finalize(new) }
        while try source.next(old) {
            guard try next(new) else { throw SearchDatabaseError(message: "迁移缺少文件记录") }
            for index: Int32 in 0..<16 {
                guard sqlite3_column_type(old,index) == sqlite3_column_type(new,index),
                      source.blob(old,index) == blob(new,index) else { throw SearchDatabaseError(message: "迁移元数据不同，文件ID \(sqlite3_column_int64(old,0))，列 \(index)") }
            }
            if sqlite3_column_type(old,16) == SQLITE_NULL {
                guard sqlite3_column_type(new,16) == SQLITE_NULL else { throw SearchDatabaseError(message: "迁移正文状态不一致") }
            } else {
                let digest = ContentCodec.digest(source.blob(old,16))
                guard digest == blob(new,16) else { throw SearchDatabaseError(message: "迁移正文不同，文件ID \(sqlite3_column_int64(old,0))") }
            }
        }
        guard try !next(new) else { throw SearchDatabaseError(message: "迁移多出文件记录") }
    }
}
