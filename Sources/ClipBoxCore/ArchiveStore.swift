import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

public enum ArchiveStoreError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Could not open the ClipBox archive database: \(message)"
        case .statementFailed(let message):
            "Could not prepare an archive database statement: \(message)"
        case .executionFailed(let message):
            "Archive database operation failed: \(message)"
        }
    }
}

public actor ArchiveStore {
    public nonisolated let databaseURL: URL
    private let connection: SQLiteConnection

    public init(databaseURL: URL = ClipBoxPaths.archiveDatabaseURL) throws {
        self.databaseURL = databaseURL

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let db {
                sqlite3_close(db)
            }
            throw ArchiveStoreError.openFailed(message)
        }

        connection = SQLiteConnection(handle: db)
        try Self.configure(database: db)
        try Self.migrate(database: db)
    }

    public func downloaded(identity: ArchiveIdentity) throws -> Bool {
        let sql = "SELECT 1 FROM media WHERE site = ?1 AND media_id = ?2 AND status = 'downloaded' LIMIT 1"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(identity.site, at: 1, in: statement)
        bind(identity.mediaID, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func record(identity: ArchiveIdentity) throws -> ArchiveRecord? {
        let sql = """
        SELECT site, media_id, source_id, collection_name, source_url, creator, title,
               published_at, first_seen_at, downloaded_at, width, height, fps,
               video_codec, audio_codec, format_id, output_path, status, last_error
        FROM media
        WHERE site = ?1 AND media_id = ?2
        LIMIT 1
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(identity.site, at: 1, in: statement)
        bind(identity.mediaID, at: 2, in: statement)

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            return nil
        }
        guard step == SQLITE_ROW else {
            throw currentError()
        }
        return decodeRecord(statement)
    }

    public func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM media")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func recent(limit: Int = 50) throws -> [ArchiveRecord] {
        let safeLimit = max(1, min(limit, 500))
        let sql = """
        SELECT site, media_id, source_id, collection_name, source_url, creator, title,
               published_at, first_seen_at, downloaded_at, width, height, fps,
               video_codec, audio_codec, format_id, output_path, status, last_error
        FROM media
        ORDER BY COALESCE(downloaded_at, first_seen_at) DESC
        LIMIT ?1
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var records: [ArchiveRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw currentError()
            }

            records.append(decodeRecord(statement))
        }

        return records
    }

    public func record(
        media: MediaMetadata,
        collection: String? = nil,
        status: ArchiveStatus,
        outputPath: String? = nil,
        formatID: String? = nil,
        error: String? = nil
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let downloadedAt = status == .downloaded ? now : nil

        let sql = """
        INSERT INTO media (
            site, media_id, source_id, collection_name, source_url, creator, title,
            published_at, first_seen_at, downloaded_at, width, height, fps,
            video_codec, audio_codec, format_id, output_path, status, last_error
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19
        )
        ON CONFLICT(site, media_id) DO UPDATE SET
            source_id = excluded.source_id,
            collection_name = COALESCE(excluded.collection_name, media.collection_name),
            source_url = excluded.source_url,
            creator = excluded.creator,
            title = excluded.title,
            published_at = excluded.published_at,
            downloaded_at = COALESCE(excluded.downloaded_at, media.downloaded_at),
            width = excluded.width,
            height = excluded.height,
            fps = excluded.fps,
            video_codec = excluded.video_codec,
            audio_codec = excluded.audio_codec,
            format_id = COALESCE(excluded.format_id, media.format_id),
            output_path = COALESCE(excluded.output_path, media.output_path),
            status = excluded.status,
            last_error = excluded.last_error
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let values: [String?] = [
            media.site,
            media.mediaID,
            media.sourceID,
            collection,
            media.webpageURL ?? media.inputURL,
            media.creator,
            media.title,
            media.uploadDate,
            now,
            downloadedAt,
        ]
        for (offset, value) in values.enumerated() {
            bind(value, at: Int32(offset + 1), in: statement)
        }

        bind(media.width, at: 11, in: statement)
        bind(media.height, at: 12, in: statement)
        bind(media.fps, at: 13, in: statement)
        bind(media.videoCodec, at: 14, in: statement)
        bind(media.audioCodec, at: 15, in: statement)
        bind(formatID ?? media.formatID, at: 16, in: statement)
        bind(outputPath, at: 17, in: statement)
        bind(status.rawValue, at: 18, in: statement)
        bind(error, at: 19, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError()
        }
    }

    private static func configure(database: OpaquePointer) throws {
        try execute(database: database, sql: "PRAGMA journal_mode=WAL;")
        try execute(database: database, sql: "PRAGMA foreign_keys=ON;")
        try execute(database: database, sql: "PRAGMA busy_timeout=5000;")
    }

    private static func migrate(database: OpaquePointer) throws {
        try execute(
            database: database,
            sql: """
            CREATE TABLE IF NOT EXISTS schema_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS media (
                site TEXT NOT NULL,
                media_id TEXT NOT NULL,
                source_id TEXT,
                collection_name TEXT,
                source_url TEXT,
                creator TEXT,
                title TEXT,
                published_at TEXT,
                first_seen_at TEXT NOT NULL,
                downloaded_at TEXT,
                width INTEGER,
                height INTEGER,
                fps REAL,
                video_codec TEXT,
                audio_codec TEXT,
                format_id TEXT,
                output_path TEXT,
                status TEXT NOT NULL,
                last_error TEXT,
                PRIMARY KEY(site, media_id)
            );

            CREATE INDEX IF NOT EXISTS media_status_idx ON media(status);
            CREATE INDEX IF NOT EXISTS media_downloaded_at_idx ON media(downloaded_at DESC);

            INSERT INTO schema_metadata(key, value)
            VALUES ('schema_version', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ArchiveStoreError.executionFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = connection.handle

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ArchiveStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func currentError() -> ArchiveStoreError {
        let database = connection.handle
        return .executionFailed(String(cString: sqlite3_errmsg(database)))
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, column)
    }

    private func decodeRecord(_ statement: OpaquePointer) -> ArchiveRecord {
        ArchiveRecord(
            site: text(statement, 0) ?? "unknown",
            mediaID: text(statement, 1) ?? "unknown",
            sourceID: text(statement, 2),
            collection: text(statement, 3),
            sourceURL: text(statement, 4),
            creator: text(statement, 5),
            title: text(statement, 6),
            publishedAt: text(statement, 7),
            firstSeenAt: text(statement, 8) ?? "",
            downloadedAt: text(statement, 9),
            width: optionalInt(statement, 10),
            height: optionalInt(statement, 11),
            fps: optionalDouble(statement, 12),
            videoCodec: text(statement, 13),
            audioCodec: text(statement, 14),
            formatID: text(statement, 15),
            outputPath: text(statement, 16),
            status: ArchiveStatus(rawValue: text(statement, 17) ?? "") ?? .discovered,
            lastError: text(statement, 18)
        )
    }
}
