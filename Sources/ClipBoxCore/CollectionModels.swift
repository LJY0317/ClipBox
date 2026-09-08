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

public enum MediaAssetType: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case video
    case photo
    case animated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .video: "Videos"
        case .photo: "Photos"
        case .animated: "Animated media"
        }
    }

    public var systemImage: String {
        switch self {
        case .video: "video.fill"
        case .photo: "photo"
        case .animated: "sparkles.rectangle.stack"
        }
    }
}

public struct MediaTypeSelection: Codable, Equatable, Sendable {
    public var types: Set<MediaAssetType>

    public static let all = MediaTypeSelection(types: Set(MediaAssetType.allCases))
    public static let defaultSelection = all

    public init(types: Set<MediaAssetType> = Set(MediaAssetType.allCases)) {
        self.types = types
    }

    public func contains(_ type: MediaAssetType) -> Bool {
        types.contains(type)
    }

    public mutating func set(_ type: MediaAssetType, enabled: Bool) {
        if enabled {
            types.insert(type)
        } else {
            types.remove(type)
        }
    }

    public var isEmpty: Bool { types.isEmpty }

    public var sortedTypes: [MediaAssetType] {
        MediaAssetType.allCases.filter(types.contains)
    }
}

public enum BuiltInCollection: String, CaseIterable, Codable, Sendable, Identifiable {
    case youtubeLiked = "youtube-liked"
    case youtubeWatchLater = "youtube-watch-later"
    case xLikes = "x-likes"
    case xBookmarks = "x-bookmarks"

    public var id: String { rawValue }

    public var site: String {
        switch self {
        case .youtubeLiked, .youtubeWatchLater: "youtube"
        case .xLikes, .xBookmarks: "twitter"
        }
    }

    public var collectionName: String {
        switch self {
        case .youtubeLiked: "liked"
        case .youtubeWatchLater: "watch-later"
        case .xLikes: "likes"
        case .xBookmarks: "bookmarks"
        }
    }

    public var displayName: String {
        switch self {
        case .youtubeLiked: "YouTube Liked Videos"
        case .youtubeWatchLater: "YouTube Watch Later"
        case .xLikes: "X Likes"
        case .xBookmarks: "X Bookmarks"
        }
    }

    public var youtubeSourceToken: String? {
        switch self {
        case .youtubeLiked: ":ytfav"
        case .youtubeWatchLater: ":ytwatchlater"
        case .xLikes, .xBookmarks: nil
        }
    }

    public var requiresAccountName: Bool {
        self == .xLikes
    }

    public func collectionURL(accountName: String?) -> String? {
        switch self {
        case .xLikes:
            guard let accountName = Self.normalizedAccountName(accountName), !accountName.isEmpty else {
                return nil
            }
            return "https://x.com/\(accountName)/likes"
        case .xBookmarks:
            return "https://x.com/i/bookmarks"
        case .youtubeLiked, .youtubeWatchLater:
            return nil
        }
    }

    public static func resolve(site: String, collection: String) -> BuiltInCollection? {
        let normalizedSite = site.lowercased()
        let normalizedCollection = collection.lowercased()
        switch normalizedSite {
        case "youtube", "yt":
            switch normalizedCollection {
            case "liked", "likes", "favorite", "favorites", "favourites":
                return .youtubeLiked
            case "watch-later", "watchlater", "later":
                return .youtubeWatchLater
            default:
                return nil
            }
        case "x", "twitter":
            switch normalizedCollection {
            case "liked", "likes":
                return .xLikes
            case "bookmark", "bookmarks", "saved":
                return .xBookmarks
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func normalizedAccountName(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }
}

public struct CollectionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(site):\(mediaID)" }

    public let site: String
    public let collectionName: String
    public let mediaID: String
    public let sourceID: String?
    public let sourceURL: String
    public let title: String?
    public let creator: String?
    public let creatorID: String?
    public let publishedAt: String?
    public let mediaType: MediaAssetType
    public let directMediaURL: String?
    public let extensionName: String?
    public let width: Int?
    public let height: Int?
    public let bitrate: Double?

    public init(
        site: String,
        collectionName: String,
        mediaID: String,
        sourceID: String? = nil,
        sourceURL: String,
        title: String? = nil,
        creator: String? = nil,
        creatorID: String? = nil,
        publishedAt: String? = nil,
        mediaType: MediaAssetType = .video,
        directMediaURL: String? = nil,
        extensionName: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Double? = nil
    ) {
        self.site = site
        self.collectionName = collectionName
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.title = title
        self.creator = creator
        self.creatorID = creatorID
        self.publishedAt = publishedAt
        self.mediaType = mediaType
        self.directMediaURL = directMediaURL
        self.extensionName = extensionName
        self.width = width
        self.height = height
        self.bitrate = bitrate
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
