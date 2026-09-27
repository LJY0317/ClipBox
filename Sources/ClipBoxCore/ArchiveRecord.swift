import Foundation

public enum ArchiveStatus: String, Codable, Sendable {
    case discovered
    case downloading
    case downloaded
    case failed
}

public struct ArchiveRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(site):\(mediaID)" }

    public let site: String
    public let mediaID: String
    public let sourceID: String?
    public let collection: String?
    public let sourceURL: String?
    public let creator: String?
    public let title: String?
    public let publishedAt: String?
    public let firstSeenAt: String
    public let downloadedAt: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let formatID: String?
    public let outputPath: String?
    public let status: ArchiveStatus
    public let lastError: String?

    public init(
        site: String,
        mediaID: String,
        sourceID: String? = nil,
        collection: String? = nil,
        sourceURL: String? = nil,
        creator: String? = nil,
        title: String? = nil,
        publishedAt: String? = nil,
        firstSeenAt: String,
        downloadedAt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        formatID: String? = nil,
        outputPath: String? = nil,
        status: ArchiveStatus,
        lastError: String? = nil
    ) {
        self.site = site
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.collection = collection
        self.sourceURL = sourceURL
        self.creator = creator
        self.title = title
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
        self.downloadedAt = downloadedAt
        self.width = width
        self.height = height
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.formatID = formatID
        self.outputPath = outputPath
        self.status = status
        self.lastError = lastError
    }
}
