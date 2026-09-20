import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Every write reports failure by throwing, so an index
/// pass can roll back instead of leaving token totals and file offsets out of step.
///
/// Not thread-safe: `UsageIndex` owns one connection and uses it from one task.
final class Database {
    private var db: OpaquePointer?

    /// Bump when the schema changes. The cache is disposable, so an older schema
    /// is dropped and rebuilt from the logs.
    ///
    /// The version is also part of the file name (`cache-v3.sqlite`). An older
    /// build still running therefore keeps writing its own file and can't corrupt
    /// this one. That happened once: a v1 build running alongside a v2 build
    /// double-counted tokens.
    static let schemaVersion: Int32 = 3

    struct DBError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// `~/Library/Application Support/AIUsageMeter/cache-v<N>.sqlite`. Deleting it
    /// is always safe while the app isn't running: the next pass rebuilds it.
    static var defaultURL: URL {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageMeter", isDirectory: true)
        // Owner-only: the cache records log file paths, which include project
        // folder names.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("cache-v\(schemaVersion).sqlite")
    }

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw DBError(message: "Could not open cache: \(msg)")
        }
        // The app and `AIUsageMeter --scan` may use the cache at the same time.
        // A first full index pass can hold the write lock for ~10 s, so wait
        // long enough for it rather than failing.
        sqlite3_busy_timeout(db, 30_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    /// Creates or upgrades the schema in one exclusive transaction, so a second
    /// process can never see a half-dropped or half-created schema.
    private func migrate() throws {
        // Already current: no lock needed. Checking first keeps a normal open from
        // waiting behind a long index pass in another process.
        if try userVersion() == Self.schemaVersion { return }

        try exec("BEGIN EXCLUSIVE;")
        do {
            // Re-check under the lock: another process may have just upgraded.
            let version = try userVersion()
            if version == Self.schemaVersion { try exec("COMMIT;"); return }
            if version != Self.schemaVersion {
                if version > Self.schemaVersion {
                    throw DBError(message: "The cache was created by a newer version of AI Usage "
                                  + "Meter. Quit other copies of the app, or delete the cache.")
                }
                try exec("DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS buckets; "
                         + "DROP TABLE IF EXISTS snapshots; DROP TABLE IF EXISTS readings;")
            }
            // How far each log has been read. inode + offset detect replacement
            // and truncation.
            try exec("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                inode INTEGER NOT NULL,
                offset INTEGER NOT NULL,
                mtime REAL NOT NULL
            );
            """)
            // Token sums per 5-minute bucket: fine enough for a 5-hour window, and
            // about 2k rows per provider per week.
            try exec("""
            CREATE TABLE IF NOT EXISTS buckets (
                provider TEXT NOT NULL,
                bucket INTEGER NOT NULL,
                input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                messages INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (provider, bucket)
            );
            """)
            // Allowance readings exactly as reported. One row per limit
            // (`limit_key` = the window's limit id, or "" when it has none), so a
            // newer reading for one limit never replaces another limit.
            try exec("""
            CREATE TABLE IF NOT EXISTS readings (
                provider TEXT NOT NULL,
                source TEXT NOT NULL,
                limit_key TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                plan_type TEXT,
                windows_json TEXT NOT NULL,
                PRIMARY KEY (provider, source, limit_key, recorded_at)
            );
            """)
            try exec("PRAGMA user_version = \(Self.schemaVersion);")
            try exec("COMMIT;")
        } catch {
            rollback()
            throw error
        }
    }

    /// Guards every pass: refuses to write if another build changed the schema
    /// after this connection opened it.
    func assertSchemaCurrent() throws {
        let version = try userVersion()
        guard version == Self.schemaVersion else {
            throw DBError(message: "The cache format changed (v\(version), expected "
                          + "v\(Self.schemaVersion)). Another version of AI Usage Meter may be running.")
        }
    }

    private func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    // MARK: - Primitives

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError(message: msg)
        }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw DBError(message: lastError)
        }
        return stmt
    }

    /// Runs a write statement to completion, throwing on anything but DONE.
    private func run(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(message: lastError) }
    }

    /// Starts a pass: takes the write lock, then checks the schema under it.
    func begin() throws {
        try exec("BEGIN IMMEDIATE;")
        do { try assertSchemaCurrent() } catch { rollback(); throw error }
    }
    func commit() throws { try exec("COMMIT;") }
    /// Safe to call when no transaction is open.
    func rollback() { try? exec("ROLLBACK;") }

    /// Nested checkpoint inside the pass transaction, so one file's partial
    /// writes can be undone without abandoning the whole pass.
    func savepoint(_ name: String) throws { try exec("SAVEPOINT \(name);") }
    func release(_ name: String) throws { try exec("RELEASE \(name);") }
    func rollback(to name: String) {
        try? exec("ROLLBACK TO \(name);")
        try? exec("RELEASE \(name);")
    }

    // MARK: - Files

    struct FileState: Equatable { var inode: UInt64; var offset: UInt64 }

    func fileStates(provider: String) throws -> [String: FileState] {
        let stmt = try prepare("SELECT path, inode, offset FROM files WHERE provider=?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        var out: [String: FileState] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            out[path] = FileState(inode: UInt64(sqlite3_column_int64(stmt, 1)),
                                  offset: UInt64(sqlite3_column_int64(stmt, 2)))
        }
        return out
    }

    func setFileState(provider: String, path: String, inode: UInt64, offset: UInt64,
                      mtime: Date) throws {
        let stmt = try prepare("""
        INSERT INTO files(path,provider,inode,offset,mtime) VALUES(?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET provider=excluded.provider, inode=excluded.inode,
          offset=excluded.offset, mtime=excluded.mtime;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: inode))
        sqlite3_bind_int64(stmt, 4, Int64(offset))
        sqlite3_bind_double(stmt, 5, mtime.timeIntervalSince1970)
        try run(stmt)
    }

    /// Drops one provider's token totals and file offsets so its logs are
    /// re-read. Used when a log was replaced or truncated: its earlier
    /// contribution is folded into aggregates and cannot be subtracted.
    func resetTokens(provider: String) throws {
        for sql in ["DELETE FROM buckets WHERE provider=?;", "DELETE FROM files WHERE provider=?;"] {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
            try run(stmt)
        }
    }

    // MARK: - Token buckets

    func addUsage(provider: String, bucket: Int64, _ t: TokenTotals) throws {
        let stmt = try prepare("""
        INSERT INTO buckets(provider,bucket,input,output,cache_read,cache_write,messages)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(provider,bucket) DO UPDATE SET
          input=input+excluded.input, output=output+excluded.output,
          cache_read=cache_read+excluded.cache_read,
          cache_write=cache_write+excluded.cache_write,
          messages=messages+excluded.messages;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, bucket)
        sqlite3_bind_int64(stmt, 3, Int64(t.input))
        sqlite3_bind_int64(stmt, 4, Int64(t.output))
        sqlite3_bind_int64(stmt, 5, Int64(t.cacheRead))
        sqlite3_bind_int64(stmt, 6, Int64(t.cacheWrite))
        sqlite3_bind_int64(stmt, 7, Int64(t.messages))
        try run(stmt)
    }

    func totals(provider: String, since: Date) throws -> TokenTotals {
        let stmt = try prepare("""
        SELECT COALESCE(SUM(input),0), COALESCE(SUM(output),0), COALESCE(SUM(cache_read),0),
               COALESCE(SUM(cache_write),0), COALESCE(SUM(messages),0)
        FROM buckets WHERE provider=? AND bucket >= ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        // Buckets are keyed by their start; include the bucket that contains `since`.
        sqlite3_bind_int64(stmt, 2, (Int64(since.timeIntervalSince1970) / 300) * 300)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw DBError(message: lastError) }
        return TokenTotals(input: Int(sqlite3_column_int64(stmt, 0)),
                           output: Int(sqlite3_column_int64(stmt, 1)),
                           cacheRead: Int(sqlite3_column_int64(stmt, 2)),
                           cacheWrite: Int(sqlite3_column_int64(stmt, 3)),
                           messages: Int(sqlite3_column_int64(stmt, 4)))
    }

    func newestBucket(provider: String) throws -> Date? {
        let stmt = try prepare("SELECT MAX(bucket) FROM buckets WHERE provider=?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0)))
    }

    func pruneBuckets(before: Date) throws {
        let stmt = try prepare("DELETE FROM buckets WHERE bucket < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(before.timeIntervalSince1970))
        try run(stmt)
    }

    // MARK: - Allowance readings

    /// Stores a reading split by limit: one row per distinct `limitId`.
    func addReading(provider: String, _ r: AllowanceReading) throws {
        let byLimit = Dictionary(grouping: r.windows) { $0.limitId ?? "" }
        for (limitKey, windows) in byLimit {
            let json = try JSONEncoder().encode(windows)
            let stmt = try prepare("""
            INSERT OR IGNORE INTO readings(provider,source,limit_key,recorded_at,plan_type,windows_json)
            VALUES(?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.source.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, limitKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, r.recordedAt.timeIntervalSince1970)
            if let p = r.planType { sqlite3_bind_text(stmt, 5, p, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_text(stmt, 6, String(decoding: json, as: UTF8.self), -1, SQLITE_TRANSIENT)
            try run(stmt)
        }
    }

    /// The newest reading for each (source, limit) of a provider.
    func latestReadings(provider: String) throws -> [AllowanceReading] {
        let stmt = try prepare("""
        SELECT source, recorded_at, plan_type, windows_json FROM readings r
        WHERE provider=? AND recorded_at = (
            SELECT MAX(recorded_at) FROM readings
            WHERE provider=r.provider AND source=r.source AND limit_key=r.limit_key);
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        var out: [AllowanceReading] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let source = ReadingSource(rawValue: String(cString: sqlite3_column_text(stmt, 0))),
                  let windows = try? JSONDecoder().decode(
                    [AllowanceWindow].self,
                    from: Data(String(cString: sqlite3_column_text(stmt, 3)).utf8))
            else { continue }
            out.append(AllowanceReading(
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                source: source,
                planType: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 2)),
                windows: windows))
        }
        return out
    }

    /// Keeps the readings table from growing without bound: Codex writes a
    /// reading on most turns.
    func pruneReadings(before: Date) throws {
        let stmt = try prepare("DELETE FROM readings WHERE recorded_at < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, before.timeIntervalSince1970)
        try run(stmt)
    }
}
