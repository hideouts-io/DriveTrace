import Foundation
import CSQLite

public enum SQLValue: Sendable { case text(String), integer(Int64), null }

/// Serializes SQLite access. Cursor advancement and the evidence it represents share one transaction.
public actor Database {
    private var handle: OpaquePointer?
    public init(path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw MonitorError.database("Cannot open local database at \(path). Check folder permissions.")
        }
        handle = connection
        sqlite3_busy_timeout(connection, 5000)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK else {
            sqlite3_close(connection); throw MonitorError.database("Cannot read database schema version.")
        }
        let versionResult = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionResult == SQLITE_ROW, version <= 2 else {
            sqlite3_close(connection); throw MonitorError.database("Unsupported database schema version \(version). Use a compatible newer app.")
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY,payload TEXT NOT NULL,first_seen TEXT NOT NULL,stream TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,file_id TEXT NOT NULL,time TEXT NOT NULL,detected TEXT NOT NULL,payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_time ON events(time DESC);
        CREATE INDEX IF NOT EXISTS events_file ON events(file_id,time DESC);
        CREATE TABLE IF NOT EXISTS snapshots(file_id TEXT NOT NULL,detected TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(file_id,detected));
        CREATE TABLE IF NOT EXISTS cursors(stream TEXT PRIMARY KEY,token TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS membership(file_id TEXT NOT NULL,stream TEXT NOT NULL,PRIMARY KEY(file_id,stream));
        INSERT OR IGNORE INTO membership SELECT id,stream FROM files WHERE id NOT IN (SELECT file_id FROM membership);
        CREATE TABLE IF NOT EXISTS staged(id TEXT NOT NULL,stream TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(id,stream));
        PRAGMA user_version=2;
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection)); sqlite3_close(connection)
            throw MonitorError.database("Database migration failed: \(message)")
        }
    }
    public func close() throws {
        guard sqlite3_close(handle) == SQLITE_OK else { throw MonitorError.database("Database is busy; cannot close.") }; handle = nil
    }
    private func execute(_ sql: String, _ values: [SQLValue]) throws -> [[String]] {
        guard let handle else { throw MonitorError.database("Database connection is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(sql) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(sql) }
        }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure(sql) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
    private func failure(_ operation: String) -> MonitorError {
        .database("SQLite operation failed: \(operation). \(String(cString: sqlite3_errmsg(handle)))")
    }
    private func transaction(_ body: () throws -> Void) throws {
        _ = try execute("BEGIN IMMEDIATE", [])
        do { try body(); _ = try execute("COMMIT", []) }
        catch {
            let original = error
            do { _ = try execute("ROLLBACK", []) } catch { throw MonitorError.database("Transaction failed: \(original.localizedDescription); rollback also failed: \(error.localizedDescription)") }
            throw original
        }
    }
    public func setting(_ key: String) throws -> String? { try execute("SELECT value FROM settings WHERE key=?", [.text(key)]).first?.first }
    public func setSetting(_ key: String, value: String) throws { _ = try execute("INSERT OR REPLACE INTO settings VALUES(?,?)", [.text(key), .text(value)]) }
    public func cursor(_ stream: String) throws -> String? { try execute("SELECT token FROM cursors WHERE stream=?", [.text(stream)]).first?.first }
    public func files() throws -> [DriveFile] { try execute("SELECT payload FROM files", []).map { try JSONDecoder().decode(DriveFile.self, from: Data($0[0].utf8)) } }
    public func file(_ id: String) throws -> DriveFile? {
        guard let row = try execute("SELECT payload FROM files WHERE id=?", [.text(id)]).first else { return nil }
        return try JSONDecoder().decode(DriveFile.self, from: Data(row[0].utf8))
    }
    public func events(fileID: String?, limit: Int) throws -> [DriveEvent] {
        let rows = try fileID.map { try execute("SELECT payload FROM events WHERE file_id=? ORDER BY time DESC,id LIMIT ?", [.text($0), .integer(Int64(limit))]) }
            ?? execute("SELECT payload FROM events ORDER BY time DESC,id LIMIT ?", [.integer(Int64(limit))])
        return try rows.map { try JSONDecoder().decode(DriveEvent.self, from: Data($0[0].utf8)) }
    }
    public func facts() throws -> FileFacts {
        let seen = try execute("SELECT id,first_seen FROM files", [])
        let activity = try execute("SELECT file_id,MAX(time),COUNT(*) FROM events GROUP BY file_id", [])
        return FileFacts(firstSeen: Dictionary(uniqueKeysWithValues: seen.map { ($0[0], $0[1]) }), lastActivity: Dictionary(uniqueKeysWithValues: activity.map { ($0[0], $0[1]) }), activityCounts: Dictionary(uniqueKeysWithValues: activity.map { ($0[0], Int($0[2]) ?? 0) }))
    }
    public func stage(_ files: [DriveFile], stream: String) throws {
        try transaction { for file in files { _ = try execute("INSERT OR REPLACE INTO staged VALUES(?,?,?)", [.text(file.id), .text(stream), .text(try encoded(file))]) } }
    }
    public func beginBaseline(stream: String) throws { _ = try execute("DELETE FROM staged WHERE stream=?", [.text(stream)]) }
    public func promote(stream: String, cursor: String, detected: String) throws {
        try transaction {
            let files = try execute("SELECT payload FROM staged WHERE stream=?", [.text(stream)]).map { try JSONDecoder().decode(DriveFile.self, from: Data($0[0].utf8)) }
            _ = try execute("DELETE FROM membership WHERE stream=?", [.text(stream)])
            for file in files { try upsert(file, stream: stream, detected: detected) }
            _ = try execute("DELETE FROM files WHERE id NOT IN (SELECT file_id FROM membership)", [])
            _ = try execute("INSERT OR REPLACE INTO cursors VALUES(?,?)", [.text(stream), .text(cursor)])
            _ = try execute("DELETE FROM staged WHERE stream=?", [.text(stream)])
            try setSetting("coverage.\(stream)", value: detected)
        }
    }
    private func upsert(_ file: DriveFile, stream: String, detected: String) throws {
        let payload = try encoded(file)
        _ = try execute("INSERT OR IGNORE INTO membership VALUES(?,?)", [.text(file.id), .text(stream)])
        _ = try execute("INSERT INTO files VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,stream=excluded.stream", [.text(file.id), .text(payload), .text(detected), .text(stream)])
        _ = try execute("INSERT OR REPLACE INTO snapshots VALUES(?,?,?)", [.text(file.id), .text(detected), .text(payload)])
    }
    private func insertEvent(_ event: DriveEvent) throws { _ = try execute("INSERT OR IGNORE INTO events VALUES(?,?,?,?,?)", [.text(event.id), .text(event.fileID), .text(event.time), .text(event.detected), .text(try encoded(event))]) }
    public func apply(_ page: ChangePage, stream: String, detected: String) throws {
        guard let next = page.nextPageToken ?? page.newStartPageToken else { throw MonitorError.invalid("Changes response omitted its continuation cursor; no data committed.") }
        try transaction {
            for change in page.changes ?? [] {
                guard change.changeType == "file" else { continue }
                guard let id = change.fileId else { throw MonitorError.invalid("File change lacks fileId; page was not committed.") }
                let previous = try file(id)
                for event in try transitions(previous: previous, change: change, detected: detected) { try insertEvent(event) }
                if change.removed == true {
                    _ = try execute("DELETE FROM membership WHERE file_id=? AND stream=?", [.text(id), .text(stream)])
                    _ = try execute("DELETE FROM files WHERE id=? AND id NOT IN (SELECT file_id FROM membership)", [.text(id)])
                }
                else if let file = change.file { try upsert(file, stream: stream, detected: detected) }
            }
            _ = try execute("INSERT OR REPLACE INTO cursors VALUES(?,?)", [.text(stream), .text(next)])
        }
    }
    public func recordActivity(_ events: [DriveEvent], watermark: String?) throws {
        try transaction { for event in events { try insertEvent(event) }; if let watermark { try setSetting("activity.watermark", value: watermark) } }
    }
    public func history(_ id: String) throws -> [(String, DriveFile)] {
        try execute("SELECT detected,payload FROM snapshots WHERE file_id=? ORDER BY detected DESC", [.text(id)]).map { ($0[0], try JSONDecoder().decode(DriveFile.self, from: Data($0[1].utf8))) }
    }
    /// Returns each item's latest observation by the cutoff, including retained inaccessible items.
    /// Observation time is not proof of continued existence, access, or state at Google's action time.
    public func observedFiles(at cutoff: String) throws -> [ObservedFile] {
        guard parseDate(cutoff) != nil else { throw MonitorError.invalid("History cutoff must be a complete RFC3339 timestamp, for example 2026-09-01T12:00:00Z.") }
        let rows = try execute("""
        SELECT detected,payload FROM (
            SELECT file_id,detected,payload,ROW_NUMBER() OVER (
                PARTITION BY file_id ORDER BY julianday(detected) DESC,detected DESC
            ) AS position FROM snapshots WHERE julianday(detected)<=julianday(?)
        ) WHERE position=1 ORDER BY detected,file_id
        """, [.text(cutoff)])
        return try rows.map { row in
            try Task.checkCancellation()
            return ObservedFile(observedAt: row[0], file: try JSONDecoder().decode(DriveFile.self, from: Data(row[1].utf8)))
        }
    }
    /// Reconstructs only from snapshots observed by the cutoff, never from newer current metadata.
    public func observedPath(_ id: String, at cutoff: String) throws -> String {
        guard parseDate(cutoff) != nil else { throw MonitorError.invalid("Historical path cutoff must be an RFC3339 timestamp.") }
        var components: [String] = []; var visited: Set<String> = []; var current = id
        let root = try setting("rootID")
        while true {
            guard visited.insert(current).inserted else { components.append("[cycle: " + current + "]"); break }
            if current == root { components.append("My Drive"); break }
            guard let row = try execute("SELECT payload FROM snapshots WHERE file_id=? AND julianday(detected)<=julianday(?) ORDER BY julianday(detected) DESC,detected DESC LIMIT 1", [.text(current), .text(cutoff)]).first else {
                components.append("[not observed by cutoff: " + current + "]"); break
            }
            let file = try JSONDecoder().decode(DriveFile.self, from: Data(row[0].utf8))
            components.append(file.name)
            guard let parents = file.parents else { components.append("[parent unavailable]"); break }
            guard let parent = parents.first else { break }
            current = parent
        }
        return components.reversed().joined(separator: "/")
    }
    public func snapshotRecords(_ id: String) throws -> [SnapshotRecord] {
        try history(id).map { time, file in
            SnapshotRecord(observedAt: time, file: file, reconstructedPath: try observedPath(id, at: time), provenance: "Latest available ancestor snapshots at or before local observation time. Not proof of location at Google's action time, continuous coverage, or historical accessibility. Multiple parents use the first recorded parent.")
        }
    }
    public func retireScope(_ stream: String) throws {
        try transaction {
            _ = try execute("DELETE FROM membership WHERE stream=?", [.text(stream)])
            _ = try execute("DELETE FROM files WHERE id NOT IN (SELECT file_id FROM membership)", [])
            _ = try execute("DELETE FROM cursors WHERE stream=?", [.text(stream)])
            _ = try execute("DELETE FROM staged WHERE stream=?", [.text(stream)])
            _ = try execute("DELETE FROM settings WHERE key=? OR key=?", [.text("coverage." + stream), .text("activity.watermark." + stream)])
        }
    }
    public func clearCache() throws {
        try transaction { for table in ["files", "events", "snapshots", "cursors", "staged", "membership"] { _ = try execute("DELETE FROM \(table)", []) }; _ = try execute("DELETE FROM settings WHERE key LIKE 'coverage.%' OR key LIKE 'activity.watermark%' OR key='lastSync' OR key LIKE 'pendingNotifications.%' OR key LIKE 'notified.%'", []) }
    }
    public func clearHistory() throws { try transaction { _ = try execute("DELETE FROM events", []); _ = try execute("DELETE FROM snapshots", []) } }
}
