import Foundation

public struct ClipBoxBackupManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let application: String
    public let createdAt: String
    public let archiveSchemaVersion: Int
    public let recordCount: Int
    public let collectionMembershipCount: Int?
    public let includesPreferences: Bool

    public init(
        formatVersion: Int = 1,
        application: String = "ClipBox",
        createdAt: String,
        archiveSchemaVersion: Int = 2,
        recordCount: Int,
        collectionMembershipCount: Int? = nil,
        includesPreferences: Bool
    ) {
        self.formatVersion = formatVersion
        self.application = application
        self.createdAt = createdAt
        self.archiveSchemaVersion = archiveSchemaVersion
        self.recordCount = recordCount
        self.collectionMembershipCount = collectionMembershipCount
        self.includesPreferences = includesPreferences
    }
}

public struct BackupCreationResult: Codable, Equatable, Sendable {
    public let path: String
    public let recordCount: Int
    public let createdAt: String

    public init(path: String, recordCount: Int, createdAt: String) {
        self.path = path
        self.recordCount = recordCount
        self.createdAt = createdAt
    }
}

public struct BackupRestoreResult: Codable, Equatable, Sendable {
    public let backupRecordCount: Int
    public let recordsProcessed: Int
    public let recordsAdded: Int
    public let finalRecordCount: Int
    public let preferencesRestored: Bool

    public init(
        backupRecordCount: Int,
        recordsProcessed: Int,
        recordsAdded: Int,
        finalRecordCount: Int,
        preferencesRestored: Bool
    ) {
        self.backupRecordCount = backupRecordCount
        self.recordsProcessed = recordsProcessed
        self.recordsAdded = recordsAdded
        self.finalRecordCount = finalRecordCount
        self.preferencesRestored = preferencesRestored
    }
}

public enum BackupServiceError: Error, LocalizedError, Sendable {
    case systemArchiveToolUnavailable
    case archiveCommandFailed(String)
    case invalidBackup(String)
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .systemArchiveToolUnavailable:
            "The macOS `ditto` archive tool is unavailable."
        case .archiveCommandFailed(let message):
            "Could not create or extract the ClipBox backup: \(message)"
        case .invalidBackup(let message):
            "The selected file is not a valid ClipBox backup: \(message)"
        case .unsupportedFormatVersion(let version):
            "This ClipBox backup uses unsupported format version \(version)."
        }
    }
}

public actor BackupService {
    private let archive: ArchiveStore
    private let dittoURL: URL?

    public init(
        archive: ArchiveStore? = nil,
        dittoURL: URL? = URL(fileURLWithPath: "/usr/bin/ditto")
    ) throws {
        self.archive = try archive ?? ArchiveStore()
        if let dittoURL, FileManager.default.isExecutableFile(atPath: dittoURL.path) {
            self.dittoURL = dittoURL
        } else {
            self.dittoURL = nil
        }
    }

    public func createBackup(at requestedURL: URL? = nil) async throws -> BackupCreationResult {
        guard let dittoURL else {
            throw BackupServiceError.systemArchiveToolUnavailable
        }

        let destination = try resolvedBackupDestination(requestedURL)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBoxBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let snapshotURL = stagingRoot.appendingPathComponent("history.sqlite3")
        let records = try await archive.createSnapshotAndRecords(at: snapshotURL)
        let memberships = try await archive.allCollectionMemberships()

        let createdAt = ISO8601DateFormatter().string(from: Date())
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let preferencesData = try Self.encoder.encode(preferences)
        try preferencesData.write(
            to: stagingRoot.appendingPathComponent("preferences.json"),
            options: .atomic
        )

        let manifest = ClipBoxBackupManifest(
            createdAt: createdAt,
            recordCount: records.count,
            collectionMembershipCount: memberships.count,
            includesPreferences: true
        )
        try Self.encoder.encode(manifest).write(
            to: stagingRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Self.writeJSONL(
            records,
            to: stagingRoot.appendingPathComponent("history.jsonl")
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let result = try ProcessRunner.run(
            executable: dittoURL,
            arguments: ["-c", "-k", "--norsrc", stagingRoot.path, destination.path]
        )
        guard result.exitCode == 0 else {
            throw BackupServiceError.archiveCommandFailed(Self.cleanCommandError(result))
        }

        return BackupCreationResult(
            path: destination.path,
            recordCount: records.count,
            createdAt: createdAt
        )
    }

    public func restoreBackup(
        from backupURL: URL,
        restorePreferences: Bool = false
    ) async throws -> BackupRestoreResult {
        guard let dittoURL else {
            throw BackupServiceError.systemArchiveToolUnavailable
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw BackupServiceError.invalidBackup("file does not exist")
        }

        let extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBoxRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionRoot) }

        let result = try ProcessRunner.run(
            executable: dittoURL,
            arguments: ["-x", "-k", backupURL.path, extractionRoot.path]
        )
        guard result.exitCode == 0 else {
            throw BackupServiceError.archiveCommandFailed(Self.cleanCommandError(result))
        }

        let payloadRoot = try Self.findPayloadRoot(in: extractionRoot)
        let manifestURL = payloadRoot.appendingPathComponent("manifest.json")
        let databaseURL = payloadRoot.appendingPathComponent("history.sqlite3")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BackupServiceError.invalidBackup("manifest.json or history.sqlite3 is missing")
        }

        let manifest = try Self.decoder.decode(
            ClipBoxBackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.application == "ClipBox" else {
            throw BackupServiceError.invalidBackup("manifest application does not match ClipBox")
        }
        guard manifest.formatVersion == 1 else {
            throw BackupServiceError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let backupStore = try ArchiveStore(databaseURL: databaseURL)
        guard try await backupStore.quickIntegrityCheck() else {
            throw BackupServiceError.invalidBackup("SQLite integrity check failed")
        }
        let records = try await backupStore.allRecords()
        guard records.count == manifest.recordCount else {
            throw BackupServiceError.invalidBackup(
                "manifest reports \(manifest.recordCount) records but archive contains \(records.count)"
            )
        }

        let memberships = try await backupStore.allCollectionMemberships()
        if let expectedMembershipCount = manifest.collectionMembershipCount,
           memberships.count != expectedMembershipCount {
            throw BackupServiceError.invalidBackup(
                "manifest reports \(expectedMembershipCount) collection memberships but archive contains \(memberships.count)"
            )
        }

        let beforeCount = try await archive.count()
        let processed = try await archive.importRecords(records)
        _ = try await archive.importCollectionMemberships(memberships)
        let afterCount = try await archive.count()

        var preferencesRestored = false
        if restorePreferences, manifest.includesPreferences {
            let preferencesURL = payloadRoot.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                let preferences = try Self.decoder.decode(
                    ClipBoxPreferences.self,
                    from: Data(contentsOf: preferencesURL)
                )
                try ClipBoxPreferencesStore.save(preferences)
                preferencesRestored = true
            }
        }

        return BackupRestoreResult(
            backupRecordCount: records.count,
            recordsProcessed: processed,
            recordsAdded: max(0, afterCount - beforeCount),
            finalRecordCount: afterCount,
            preferencesRestored: preferencesRestored
        )
    }

    private func resolvedBackupDestination(_ requestedURL: URL?) throws -> URL {
        if let requestedURL {
            let expanded = URL(
                fileURLWithPath: NSString(string: requestedURL.path).expandingTildeInPath,
                isDirectory: false
            )
            let destination = expanded.pathExtension.lowercased() == "clipboxbackup"
                ? expanded
                : expanded.appendingPathExtension("clipboxbackup")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return destination
        }

        let downloads = try ClipBoxPaths.ensureDownloadDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return downloads.appendingPathComponent(
            "ClipBox Backup \(formatter.string(from: Date())).clipboxbackup",
            isDirectory: false
        )
    }

    private static func findPayloadRoot(in extractionRoot: URL) throws -> URL {
        if FileManager.default.fileExists(
            atPath: extractionRoot.appendingPathComponent("manifest.json").path
        ) {
            return extractionRoot
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            if FileManager.default.fileExists(
                atPath: child.appendingPathComponent("manifest.json").path
            ) {
                return child
            }
        }
        throw BackupServiceError.invalidBackup("could not locate backup payload")
    }

    private static func writeJSONL(_ records: [ArchiveRecord], to url: URL) throws {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func cleanCommandError(_ result: ProcessResult) -> String {
        let message = result.stderr.isEmpty ? result.stdout : result.stderr
        return message
            .split(whereSeparator: \.isNewline)
            .suffix(8)
            .joined(separator: "\n")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
