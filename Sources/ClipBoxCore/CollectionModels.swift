import Foundation

public enum BrowserCookieSource: String, CaseIterable, Codable, Sendable {
    case safari
    case chrome
    case chromium
    case firefox
    case brave
    case edge

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .edge: "Edge"
        }
    }
}

public enum BuiltInCollection: String, CaseIterable, Codable, Sendable, Identifiable {
    case youtubeLiked = "youtube-liked"
    case youtubeWatchLater = "youtube-watch-later"

    public var id: String { rawValue }

    public var site: String { "youtube" }

    public var collectionName: String {
        switch self {
        case .youtubeLiked: "liked"
        case .youtubeWatchLater: "watch-later"
        }
    }

    public var displayName: String {
        switch self {
        case .youtubeLiked: "YouTube Liked Videos"
        case .youtubeWatchLater: "YouTube Watch Later"
        }
    }

    public var sourceToken: String {
        switch self {
        case .youtubeLiked: ":ytfav"
        case .youtubeWatchLater: ":ytwatchlater"
        }
    }

    public static func resolve(site: String, collection: String) -> BuiltInCollection? {
        let normalizedSite = site.lowercased()
        let normalizedCollection = collection.lowercased()
        guard normalizedSite == "youtube" else { return nil }

        switch normalizedCollection {
        case "liked", "likes", "favorite", "favorites", "favourites":
            return .youtubeLiked
        case "watch-later", "watchlater", "later":
            return .youtubeWatchLater
        default:
            return nil
        }
    }
}

public struct CollectionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(site):\(mediaID)" }

    public let site: String
    public let collectionName: String
    public let mediaID: String
    public let sourceURL: String
    public let title: String?
    public let creator: String?

    public init(
        site: String,
        collectionName: String,
        mediaID: String,
        sourceURL: String,
        title: String? = nil,
        creator: String? = nil
    ) {
        self.site = site
        self.collectionName = collectionName
        self.mediaID = mediaID
        self.sourceURL = sourceURL
        self.title = title
        self.creator = creator
    }

    public var archiveIdentity: ArchiveIdentity {
        ArchiveIdentity(site: site, mediaID: mediaID)
    }
}

public struct CollectionMembershipRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(site):\(collectionName):\(mediaID)" }

    public let site: String
    public let collectionName: String
    public let mediaID: String
    public let sourceURL: String?
    public let firstSeenAt: String
    public let lastSeenAt: String

    public init(
        site: String,
        collectionName: String,
        mediaID: String,
        sourceURL: String?,
        firstSeenAt: String,
        lastSeenAt: String
    ) {
        self.site = site
        self.collectionName = collectionName
        self.mediaID = mediaID
        self.sourceURL = sourceURL
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct CollectionScanItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String { item.id }
    public let item: CollectionItem
    public let previouslySeen: Bool
    public let alreadyDownloaded: Bool

    public init(item: CollectionItem, previouslySeen: Bool, alreadyDownloaded: Bool) {
        self.item = item
        self.previouslySeen = previouslySeen
        self.alreadyDownloaded = alreadyDownloaded
    }
}

public struct CollectionScanResult: Codable, Equatable, Sendable {
    public let collection: BuiltInCollection
    public let items: [CollectionScanItem]

    public init(collection: BuiltInCollection, items: [CollectionScanItem]) {
        self.collection = collection
        self.items = items
    }

    public var unarchivedCount: Int {
        items.lazy.filter { !$0.alreadyDownloaded }.count
    }
}

public struct CollectionSyncFailure: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(site):\(mediaID)" }
    public let site: String
    public let mediaID: String
    public let title: String?
    public let error: String

    public init(site: String, mediaID: String, title: String?, error: String) {
        self.site = site
        self.mediaID = mediaID
        self.title = title
        self.error = error
    }
}

public struct CollectionSyncResult: Codable, Equatable, Sendable {
    public let collection: BuiltInCollection
    public let scanned: Int
    public let unarchived: Int
    public let downloaded: Int
    public let skippedAlreadyArchived: Int
    public let failed: Int
    public let dryRun: Bool
    public let failures: [CollectionSyncFailure]

    public init(
        collection: BuiltInCollection,
        scanned: Int,
        unarchived: Int,
        downloaded: Int,
        skippedAlreadyArchived: Int,
        failed: Int,
        dryRun: Bool,
        failures: [CollectionSyncFailure]
    ) {
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
