import Foundation
import CSQLite
import OilFindCore

/// Name-only SQLite reader. It neither initializes schema nor accesses bodies.
final class NameMetadataReader {
    let connection: OpaquePointer
    private let cancellation: Cancellation
    private final class Cancellation {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }
    init(url: URL, immutable: Bool = false, cancelled: @escaping () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        var handle: OpaquePointer?
        let filename = immutable ? url.standardizedFileURL.absoluteString + "?immutable=1" : url.path
        let flags = (immutable ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX | (immutable ? SQLITE_OPEN_URI : 0)
        let code = sqlite3_open_v2(filename, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开名称元数据"
            sqlite3_close(handle)
            throw SearchDatabaseError(message: message)
        }
        connection = handle
        cancellation = Cancellation(cancelled)
        sqlite3_busy_timeout(handle, 1_000)
        guard sqlite3_exec(handle,"PRAGMA query_only=ON",nil,nil,nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw SearchDatabaseError(message:"无法启用名称只读连接")
        }
        sqlite3_progress_handler(handle, 1_000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<Cancellation>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
    }
    deinit {
        sqlite3_progress_handler(connection, 0, nil, nil)
        sqlite3_close(connection)
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        _ = try next(statement)
    }
    func next(_ statement: OpaquePointer) throws -> Bool {
        if cancellation.check() { throw CancellationError() }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error()
        }
    }
    func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (i, value) in values.enumerated() {
            let code = value.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(statement, Int32(i + 1), $0.baseAddress, Int32($0.count - 1), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if code != SQLITE_OK { throw error() }
        }
    }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func error() -> Error {
        if cancellation.check() || sqlite3_errcode(connection) == SQLITE_INTERRUPT { return CancellationError() }
        return SearchDatabaseError(message: String(cString: sqlite3_errmsg(connection)))
    }
}

/// Structure-of-arrays metadata, plus a small map only for rows changed since load.
/// No FileRecord objects, bodies, root JSON or per-file Swift path strings.
final class NameSnapshot {
    static let columns = "id,root_id,name,extension,kind,size,modified"
    var core = DeduplicatedNameIndex()
    // Columns restored from a v3 cache stay in its file mapping; rows added
    // afterwards (and every row of a snapshot built from SQLite) live in memory.
    var ids = SegmentedArray<Int64>(), sizes = SegmentedArray<Int64>(), modified = SegmentedArray<Double>()
    var roots = SegmentedArray<UInt32>(), extensions = SegmentedArray<UInt32>(), kinds = SegmentedArray<UInt32>()
    var live = SegmentedArray<UInt8>()
    var rootKeys: [String: UInt32] = [:], extensionKeys: [String: UInt32] = [:], kindKeys: [String: UInt32] = [:]
    var baseCount = 0
    var changedIDs: [Int64: UInt32] = [:]
    var liveCount = 0
    var changeRevision: Int64?
    var deadCount: Int { ids.count - liveCount }
    /// The v3 cache file this snapshot's mapped columns point into, if any.
    var mapping: MappedFile?
    /// Rows held in ordinary memory rather than in the cache mapping.
    var unmappedRows: Int { ids.tail.count }

    private func intern(_ key: String, _ map: inout [String: UInt32]) -> UInt32 {
        if let code = map[key] { return code }
        let code = UInt32(map.count)
        map[key] = code
        return code
    }
    func index(_ id: Int64) -> UInt32? {
        if let updated = changedIDs[id] { return updated }
        var low = 0, high = baseCount
        while low < high {
            let mid = low + (high - low) / 2
            if ids[mid] < id { low = mid + 1 } else { high = mid }
        }
        return low < baseCount && ids[low] == id ? UInt32(low) : nil
    }
    func remove(_ i: UInt32) {
        guard live[Int(i)] != 0 else { return }
        live[Int(i)] = 0
        core.remove(i)
        liveCount -= 1
    }
    func upsert(_ row: OpaquePointer, reader: NameMetadataReader, incremental: Bool) throws {
        let id = sqlite3_column_int64(row, 0)
        let root = intern(reader.text(row, 1), &rootKeys)
        let name = QueryParser.normalize(reader.text(row, 2))
        let ext = intern(QueryParser.normalize(reader.text(row, 3)), &extensionKeys)
        let kind = intern(reader.text(row, 4), &kindKeys)
        let size = sqlite3_column_int64(row, 5), date = sqlite3_column_double(row, 6)
        if incremental, let old = index(id), live[Int(old)] != 0 {
            if core.nameEquals(old, name) {
                let i = Int(old)
                roots[i] = root; extensions[i] = ext; kinds[i] = kind; sizes[i] = size; modified[i] = date
                return
            }
            remove(old)
        }
        try core.append(name)
        let i = UInt32(ids.count)
        ids.append(id); roots.append(root); extensions.append(ext); kinds.append(kind)
        sizes.append(size); modified.append(date); live.append(1); liveCount += 1
        if incremental { changedIDs[id] = i }
    }
}
