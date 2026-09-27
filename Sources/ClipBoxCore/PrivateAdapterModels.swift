import Foundation

public struct PrivateAdapterCollectionDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct PrivateAdapterManifest: Codable, Equatable, Sendable, Identifiable {
    public let protocolVersion: Int
    public let id: String
    public let displayName: String
    public let executable: String
    public let collections: [PrivateAdapterCollectionDefinition]

    public init(
        protocolVersion: Int = 1,
        id: String,
        displayName: String,
        executable: String,
        collections: [PrivateAdapterCollectionDefinition]
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.collections = collections
    }
}

public enum PrivateAdapterDownloadStrategy: String, Codable, Sendable {
    case direct
    case ytDlp = "yt-dlp"
}

public struct PrivateAdapterDownload: Codable, Equatable, Sendable {
    public let strategy: PrivateAdapterDownloadStrategy
    public let url: String

    public init(strategy: PrivateAdapterDownloadStrategy, url: String) {
        self.strategy = strategy
        self.url = url
    }
}

public struct PrivateAdapterMediaItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String { mediaID }

    public let mediaID: String
    public let sourceID: String?
    public let sourceURL: String
    public let title: String?
    public let creator: String?
    public let publishedAt: String?
    public let extensionName: String?
    public let width: Int?
    public let height: Int?
    public let bitrate: Double?
    public let download: PrivateAdapterDownload

    public init(
        mediaID: String,
        sourceID: String? = nil,
        sourceURL: String,
        title: String? = nil,
        creator: String? = nil,
        publishedAt: String? = nil,
        extensionName: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Double? = nil,
        download: PrivateAdapterDownload
    ) {
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.title = title
        self.creator = creator
        self.publishedAt = publishedAt
        self.extensionName = extensionName
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.download = download
    }
}

public struct PrivateAdapterRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case doctor
        case scan
    }

    public let protocolVersion: Int
    public let command: Command
    public let collection: String?
    public let browser: String?
    public let limit: Int?

    public init(
        protocolVersion: Int = 1,
        command: Command,
        collection: String? = nil,
        browser: String? = nil,
        limit: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.collection = collection
        self.browser = browser
        self.limit = limit
    }
}

public struct PrivateAdapterDoctorResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let ok: Bool
    public let message: String?

    public init(protocolVersion: Int = 1, ok: Bool, message: String? = nil) {
        self.protocolVersion = protocolVersion
        self.ok = ok
        self.message = message
    }
}

public struct PrivateAdapterScanResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let items: [PrivateAdapterMediaItem]

    public init(protocolVersion: Int = 1, items: [PrivateAdapterMediaItem]) {
        self.protocolVersion = protocolVersion
        self.items = items
    }
}

public struct PrivateAdapterScanResult: Codable, Equatable, Sendable {
    public let adapterID: String
    public let collection: String
    public let items: [CollectionScanItem]

    public init(adapterID: String, collection: String, items: [CollectionScanItem]) {
        self.adapterID = adapterID
        self.collection = collection
        self.items = items
    }

    public var unarchivedCount: Int {
        items.lazy.filter { !$0.alreadyDownloaded }.count
    }
}

public struct PrivateAdapterSyncResult: Codable, Equatable, Sendable {
    public let adapterID: String
    public let collection: String
    public let scanned: Int
    public let unarchived: Int
    public let downloaded: Int
    public let skippedAlreadyArchived: Int
    public let failed: Int
    public let dryRun: Bool
    public let failures: [CollectionSyncFailure]

    public init(
        adapterID: String,
        collection: String,
        scanned: Int,
        unarchived: Int,
        downloaded: Int,
        skippedAlreadyArchived: Int,
        failed: Int,
        dryRun: Bool,
        failures: [CollectionSyncFailure]
    ) {
        self.adapterID = adapterID
        self.collection = collection
        self.scanned = scanned
        self.unarchived = unarchived
        self.downloaded = downloaded
        self.skippedAlreadyArchived = skippedAlreadyArchived
        self.failed = failed
        self.dryRun = dryRun
        self.failures = failures
    }
}
