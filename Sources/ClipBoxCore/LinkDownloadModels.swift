import Foundation

public struct LinkDownloadAsset: Sendable, Identifiable, Equatable {
    enum Transfer: Sendable, Equatable {
        case ytDlp(url: String)
        case direct(CollectionItem)
    }

    public var id: String { "\(media.site):\(media.mediaID)" }

    public let media: MediaMetadata
    public let mediaType: MediaAssetType
    public let thumbnailURL: String?
    public var alreadyDownloaded: Bool
    let transfer: Transfer

    init(
        media: MediaMetadata,
        mediaType: MediaAssetType,
        thumbnailURL: String?,
        alreadyDownloaded: Bool,
        transfer: Transfer
    ) {
        self.media = media
        self.mediaType = mediaType
        self.thumbnailURL = thumbnailURL
        self.alreadyDownloaded = alreadyDownloaded
        self.transfer = transfer
    }
}

public struct LinkInspection: Sendable, Equatable {
    public let sourceURL: String
    public let assets: [LinkDownloadAsset]

    public init(sourceURL: String, assets: [LinkDownloadAsset]) {
        self.sourceURL = sourceURL
        self.assets = assets
    }
}
