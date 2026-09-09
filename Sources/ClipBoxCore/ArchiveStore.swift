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

    public func downloaded(site: String, sourceID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM media WHERE site = ?1 AND source_id = ?2 AND status = 'downloaded' LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(site, at: 1, in: statement)
        bind(sourceID, at: 2, in: statement)
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

    public func collectionContains(
        site: String,
        collectionName: String,
        mediaID: String,
        ownerID: String? = nil
    ) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM collection_memberships WHERE site = ?1 AND owner_namespace = ?2 AND collection_name = ?3 AND media_id = ?4 LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(site, at: 1, in: statement)
        bind(Self.ownerNamespace(ownerID), at: 2, in: statement)
        bind(collectionName, at: 3, in: statement)
        bind(mediaID, at: 4, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func collectionCount(site: String, collectionName: String, ownerID: String? = nil) throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM collection_memberships WHERE site = ?1 AND owner_namespace = ?2 AND collection_name = ?3"
        )
        defer { sqlite3_finalize(statement) }
        bind(site, at: 1, in: statement)
        bind(Self.ownerNamespace(ownerID), at: 2, in: statement)
        bind(collectionName, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func allCollectionMemberships() throws -> [CollectionMembershipRecord] {
        let statement = try prepare(
            """
            SELECT site, owner_namespace, collection_name, media_id, source_url, first_seen_at, last_seen_at
            FROM collection_memberships
            ORDER BY site, owner_namespace, collection_name, media_id
            """
        )
        defer { sqlite3_finalize(statement) }

        var memberships: [CollectionMembershipRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw currentError()
            }
            memberships.append(
                CollectionMembershipRecord(
                    site: text(statement, 0) ?? "unknown",
                    ownerID: Self.ownerID(from: text(statement, 1)),
                    collectionName: text(statement, 2) ?? "unknown",
                    mediaID: text(statement, 3) ?? "unknown",
                    sourceURL: text(statement, 4),
                    firstSeenAt: text(statement, 5) ?? "",
                    lastSeenAt: text(statement, 6) ?? ""
                )
            )
        }
        return memberships
    }

    @discardableResult
    public func recordCollectionItems(_ items: [CollectionItem], ownerID: String? = nil) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let statement = try prepare(
            """
            INSERT INTO collection_memberships (
                site, owner_namespace, collection_name, media_id, source_url, first_seen_at, last_seen_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(site, owner_namespace, collection_name, media_id) DO UPDATE SET
                source_url = COALESCE(excluded.source_url, collection_memberships.source_url),
                last_seen_at = excluded.last_seen_at
            """
        )
        defer { sqlite3_finalize(statement) }
        let now = ISO8601DateFormatter().string(from: Date())

        try Self.execute(database: connection.handle, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for item in items {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(item.site, at: 1, in: statement)
                bind(Self.ownerNamespace(ownerID), at: 2, in: statement)
                bind(item.collectionName, at: 3, in: statement)
                bind(item.mediaID, at: 4, in: statement)
                bind(item.sourceURL, at: 5, in: statement)
                bind(now, at: 6, in: statement)
                bind(now, at: 7, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw currentError()
                }
            }
            try Self.execute(database: connection.handle, sql: "COMMIT;")
            return items.count
        } catch {
            try? Self.execute(database: connection.handle, sql: "ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func importCollectionMemberships(_ records: [CollectionMembershipRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }
        let statement = try prepare(
            """
            INSERT INTO collection_memberships (
                site, owner_namespace, collection_name, media_id, source_url, first_seen_at, last_seen_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(site, owner_namespace, collection_name, media_id) DO UPDATE SET
                source_url = COALESCE(collection_memberships.source_url, excluded.source_url),
                first_seen_at = MIN(collection_memberships.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(collection_memberships.last_seen_at, excluded.last_seen_at)
            """
        )
        defer { sqlite3_finalize(statement) }

        try Self.execute(database: connection.handle, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(record.site, at: 1, in: statement)
                bind(Self.ownerNamespace(record.ownerID), at: 2, in: statement)
                bind(record.collectionName, at: 3, in: statement)
                bind(record.mediaID, at: 4, in: statement)
                bind(record.sourceURL, at: 5, in: statement)
                bind(record.firstSeenAt, at: 6, in: statement)
                bind(record.lastSeenAt, at: 7, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw currentError()
                }
            }
            try Self.execute(database: connection.handle, sql: "COMMIT;")
            return records.count
        } catch {
            try? Self.execute(database: connection.handle, sql: "ROLLBACK;")
            throw error
        }
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

    public func allRecords() throws -> [ArchiveRecord] {
        let sql = """
        SELECT site, media_id, source_id, collection_name, source_url, creator, title,
               published_at, first_seen_at, downloaded_at, width, height, fps,
               video_codec, audio_codec, format_id, output_path, status, last_error
        FROM media
        ORDER BY site, media_id
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

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

    public func quickIntegrityCheck() throws -> Bool {
        let statement = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError()
        }
        return text(statement, 0)?.lowercased() == "ok"
    }

    public func createSnapshot(at destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        var destinationDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(destinationURL.path, &destinationDatabase, flags, nil)
        guard openResult == SQLITE_OK, let destinationDatabase else {
            let message = destinationDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let destinationDatabase {
                sqlite3_close(destinationDatabase)
            }
            throw ArchiveStoreError.openFailed(message)
        }
        defer { sqlite3_close(destinationDatabase) }

        guard let backup = sqlite3_backup_init(
            destinationDatabase,
            "main",
            connection.handle,
            "main"
        ) else {
            throw ArchiveStoreError.executionFailed(String(cString: sqlite3_errmsg(destinationDatabase)))
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ArchiveStoreError.executionFailed(String(cString: sqlite3_errmsg(destinationDatabase)))
        }
    }

    public func createSnapshotAndRecords(at destinationURL: URL) throws -> [ArchiveRecord] {
        try createSnapshot(at: destinationURL)
        return try allRecords()
    }

    @discardableResult
    public func importRecords(_ records: [ArchiveRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }

        let sql = """
        INSERT INTO media (
            site, media_id, source_id, collection_name, source_url, creator, title,
            published_at, first_seen_at, downloaded_at, width, height, fps,
            video_codec, audio_codec, format_id, output_path, status, last_error
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19
        )
        ON CONFLICT(site, media_id) DO UPDATE SET
            source_id = COALESCE(excluded.source_id, media.source_id),
            collection_name = COALESCE(excluded.collection_name, media.collection_name),
            source_url = COALESCE(excluded.source_url, media.source_url),
            creator = COALESCE(excluded.creator, media.creator),
            title = COALESCE(excluded.title, media.title),
            published_at = COALESCE(excluded.published_at, media.published_at),
            first_seen_at = MIN(media.first_seen_at, excluded.first_seen_at),
            downloaded_at = CASE
                WHEN media.downloaded_at IS NULL THEN excluded.downloaded_at
                WHEN excluded.downloaded_at IS NULL THEN media.downloaded_at
                ELSE MIN(media.downloaded_at, excluded.downloaded_at)
            END,
            width = COALESCE(excluded.width, media.width),
            height = COALESCE(excluded.height, media.height),
            fps = COALESCE(excluded.fps, media.fps),
            video_codec = COALESCE(excluded.video_codec, media.video_codec),
            audio_codec = COALESCE(excluded.audio_codec, media.audio_codec),
            format_id = COALESCE(excluded.format_id, media.format_id),
            output_path = COALESCE(media.output_path, excluded.output_path),
            status = CASE
                WHEN media.status = 'downloaded' OR excluded.status = 'downloaded' THEN 'downloaded'
                WHEN excluded.status = 'failed' THEN 'failed'
                WHEN media.status = 'failed' THEN 'failed'
                WHEN excluded.status = 'downloading' OR media.status = 'downloading' THEN 'downloading'
                ELSE 'discovered'
            END,
            last_error = CASE
                WHEN media.status = 'downloaded' OR excluded.status = 'downloaded' THEN NULL
                ELSE COALESCE(excluded.last_error, media.last_error)
            END
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try Self.execute(database: connection.handle, sql: "BEGIN IMMEDIATE TRANSACTION;")

        do {
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                let values: [String?] = [
                    record.site,
                    record.mediaID,
                    record.sourceID,
                    record.collection,
                    record.sourceURL,
                    record.creator,
                    record.title,
                    record.publishedAt,
                    record.firstSeenAt,
                    record.downloadedAt,
                ]
                for (offset, value) in values.enumerated() {
                    bind(value, at: Int32(offset + 1), in: statement)
                }

                bind(record.width, at: 11, in: statement)
                bind(record.height, at: 12, in: statement)
                bind(record.fps, at: 13, in: statement)
                bind(record.videoCodec, at: 14, in: statement)
                bind(record.audioCodec, at: 15, in: statement)
                bind(record.formatID, at: 16, in: statement)
                bind(record.outputPath, at: 17, in: statement)
                bind(record.status.rawValue, at: 18, in: statement)
                bind(record.lastError, at: 19, in: statement)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw currentError()
                }
            }

            try Self.execute(database: connection.handle, sql: "COMMIT;")
            return records.count
        } catch {
            try? Self.execute(database: connection.handle, sql: "ROLLBACK;")
            throw error
        }
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

            CREATE TABLE IF NOT EXISTS collection_memberships (
                site TEXT NOT NULL,
                owner_namespace TEXT NOT NULL,
                collection_name TEXT NOT NULL,
                media_id TEXT NOT NULL,
                source_url TEXT,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                PRIMARY KEY(site, owner_namespace, collection_name, media_id)
            );
            """
        )

        if try !columnExists("owner_namespace", in: "collection_memberships", database: database) {
            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(database: database, sql: "ALTER TABLE collection_memberships RENAME TO collection_memberships_v2;")
                try execute(
                    database: database,
                    sql: """
                    CREATE TABLE collection_memberships (
                        site TEXT NOT NULL,
                        owner_namespace TEXT NOT NULL,
                        collection_name TEXT NOT NULL,
                        media_id TEXT NOT NULL,
                        source_url TEXT,
                        first_seen_at TEXT NOT NULL,
                        last_seen_at TEXT NOT NULL,
                        PRIMARY KEY(site, owner_namespace, collection_name, media_id)
                    );
                    INSERT INTO collection_memberships (
                        site, owner_namespace, collection_name, media_id, source_url, first_seen_at, last_seen_at
                    )
                    SELECT site, 'unknown', collection_name, media_id, source_url, first_seen_at, last_seen_at
                    FROM collection_memberships_v2;
                    DROP TABLE collection_memberships_v2;
                    """
                )
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
        }

        try execute(
            database: database,
            sql: """
            CREATE INDEX IF NOT EXISTS collection_memberships_seen_idx
            ON collection_memberships(site, owner_namespace, collection_name, last_seen_at DESC);

            INSERT INTO schema_metadata(key, value)
            VALUES ('schema_version', '3')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
    }

    private static func columnExists(_ column: String, in table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ArchiveStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    private static func ownerNamespace(_ ownerID: String?) -> String {
        guard let ownerID, !ownerID.isEmpty else { return "unknown" }
        return "verified:\(ownerID)"
    }

    private static func ownerID(from namespace: String?) -> String? {
        guard let namespace, namespace.hasPrefix("verified:") else { return nil }
        let ownerID = String(namespace.dropFirst("verified:".count))
        return ownerID.isEmpty ? nil : ownerID
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
