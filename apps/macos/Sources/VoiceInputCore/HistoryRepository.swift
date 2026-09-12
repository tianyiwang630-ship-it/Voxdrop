import CSQLite
import Foundation

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error { case open(String), execute(String) }

public actor HistoryRepository {
    private var db: OpaquePointer?

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError.open("cannot open history database")
        }
        db = handle
        try Self.execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;", on: handle)
        try Self.migrate(on: handle)
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: db)
    }

    private static func execute(_ sql: String, on db: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error); throw DatabaseError.execute(message)
        }
    }

    private static func migrate(on db: OpaquePointer?) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS transcriptions(
          id TEXT PRIMARY KEY, created_at REAL NOT NULL, text TEXT NOT NULL,
          audio_duration_ms INTEGER NOT NULL, inference_ms INTEGER, end_to_end_ms INTEGER,
          model_id TEXT NOT NULL, hotwords_enabled INTEGER NOT NULL, hotword_count INTEGER NOT NULL,
          clipboard_status TEXT NOT NULL, paste_status TEXT NOT NULL, skip_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS transcriptions_time ON transcriptions(created_at DESC, id DESC);
        CREATE TABLE IF NOT EXISTS hotwords(
          id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE COLLATE BINARY,
          enabled INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        PRAGMA user_version=1;
        """, on: db)
    }

    public func insert(_ row: TranscriptionRecord) throws {
        let sql = "INSERT OR IGNORE INTO transcriptions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.execute("prepare failed") }
        defer { sqlite3_finalize(statement) }
        bind(row.id, 1, statement); sqlite3_bind_double(statement, 2, row.createdAt.timeIntervalSince1970)
        bind(row.text, 3, statement); sqlite3_bind_int64(statement, 4, Int64(row.audioDurationMS))
        optionalInt(row.inferenceMS, 5, statement); optionalInt(row.endToEndMS, 6, statement)
        bind(row.modelID, 7, statement); sqlite3_bind_int(statement, 8, row.hotwordsEnabled ? 1 : 0)
        sqlite3_bind_int64(statement, 9, Int64(row.hotwordCount)); bind(row.clipboardStatus.rawValue, 10, statement)
        bind(row.pasteStatus.rawValue, 11, statement); optionalText(row.skipReason, 12, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute("insert failed") }
    }

    public func page(search: String = "", before: Date? = nil, beforeID: String? = nil, limit: Int = 50) throws -> [TranscriptionRecord] {
        let sql = """
        SELECT id,created_at,text,audio_duration_ms,inference_ms,end_to_end_ms,model_id,
               hotwords_enabled,hotword_count,clipboard_status,paste_status,skip_reason
        FROM transcriptions WHERE (?1='' OR instr(text,?1)>0)
          AND (?2 IS NULL OR created_at<?2 OR (created_at=?2 AND id<?3))
        ORDER BY created_at DESC,id DESC LIMIT ?4
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.execute("prepare failed") }
        defer { sqlite3_finalize(statement) }
        bind(search, 1, statement)
        if let before { sqlite3_bind_double(statement, 2, before.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 2) }
        optionalText(beforeID, 3, statement)
        sqlite3_bind_int(statement, 4, Int32(min(max(limit, 1), 200)))
        var rows: [TranscriptionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(TranscriptionRecord(
                id: text(0, statement), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                text: text(2, statement), audioDurationMS: Int(sqlite3_column_int64(statement, 3)),
                inferenceMS: nullableInt(4, statement), endToEndMS: nullableInt(5, statement), modelID: text(6, statement),
                hotwordsEnabled: sqlite3_column_int(statement, 7) != 0, hotwordCount: Int(sqlite3_column_int64(statement, 8)),
                clipboardStatus: ClipboardStatus(rawValue: text(9, statement)) ?? .failed,
                pasteStatus: PasteStatus(rawValue: text(10, statement)) ?? .skipped,
                skipReason: nullableText(11, statement)))
        }
        return rows
    }

    public func delete(id: String) throws { try prepared("DELETE FROM transcriptions WHERE id=?", text: id) }
    public func deleteAll() throws { try execute("DELETE FROM transcriptions") }

    public func updateOutput(id: String, clipboard: ClipboardStatus, paste: PasteStatus, skipReason: String?) throws {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE transcriptions SET clipboard_status=?,paste_status=?,skip_reason=? WHERE id=?", -1, &statement, nil)
        bind(clipboard.rawValue, 1, statement); bind(paste.rawValue, 2, statement)
        optionalText(skipReason, 3, statement); bind(id, 4, statement); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute("status update failed") }
    }

    public func hotwords() throws -> [Hotword] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,text,enabled FROM hotwords ORDER BY created_at,id", -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.execute("prepare failed") }
        defer { sqlite3_finalize(statement) }
        var values: [Hotword] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(Hotword(id: sqlite3_column_int64(statement, 0), text: text(1, statement), enabled: sqlite3_column_int(statement, 2) != 0))
        }
        return values
    }

    public func addHotwords(_ values: [String]) throws {
        let now = Date().timeIntervalSince1970
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO hotwords(text,enabled,created_at,updated_at) VALUES(?,1,?,?)", -1, &statement, nil)
            bind(value, 1, statement); sqlite3_bind_double(statement, 2, now); sqlite3_bind_double(statement, 3, now)
            sqlite3_step(statement); sqlite3_finalize(statement)
        }
    }

    public func setHotword(id: Int64, enabled: Bool) throws {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE hotwords SET enabled=?,updated_at=? WHERE id=?", -1, &statement, nil)
        sqlite3_bind_int(statement, 1, enabled ? 1 : 0); sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute("update failed") }
    }

    public func updateHotword(id: Int64, text value: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw DatabaseError.execute("hotword cannot be empty") }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE hotwords SET text=?,updated_at=? WHERE id=?", -1, &statement, nil)
        bind(cleaned, 1, statement); sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute("duplicate hotword") }
    }

    public func deleteHotword(id: Int64) throws {
        var statement: OpaquePointer?; sqlite3_prepare_v2(db, "DELETE FROM hotwords WHERE id=?", -1, &statement, nil)
        sqlite3_bind_int64(statement, 1, id); defer { sqlite3_finalize(statement) }; sqlite3_step(statement)
    }

    private func prepared(_ sql: String, text value: String) throws {
        var statement: OpaquePointer?; sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        bind(value, 1, statement); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute("statement failed") }
    }
}

private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) { sqlite3_bind_text(statement, index, value, -1, transient) }
private func optionalText(_ value: String?, _ index: Int32, _ statement: OpaquePointer?) { if let value { bind(value, index, statement) } else { sqlite3_bind_null(statement, index) } }
private func optionalInt(_ value: Int?, _ index: Int32, _ statement: OpaquePointer?) { if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) } }
private func text(_ index: Int32, _ statement: OpaquePointer?) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
private func nullableText(_ index: Int32, _ statement: OpaquePointer?) -> String? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index, statement) }
private func nullableInt(_ index: Int32, _ statement: OpaquePointer?) -> Int? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index)) }
