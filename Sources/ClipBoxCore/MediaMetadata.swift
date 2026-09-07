import Foundation

public struct MediaFormat: Codable, Equatable, Sendable, Identifiable {
    public var id: String { formatID }

    public let formatID: String
    public let note: String?
    public let extensionName: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let totalBitrateKbps: Double?
    public let fileSize: Int64?
    public let videoCodec: String?
    public let audioCodec: String?

    public init(
        formatID: String,
        note: String? = nil,
        extensionName: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        totalBitrateKbps: Double? = nil,
        fileSize: Int64? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil
    ) {
        self.formatID = formatID
        self.note = note
        self.extensionName = extensionName
        self.width = width
        self.height = height
        self.fps = fps
        self.totalBitrateKbps = totalBitrateKbps
        self.fileSize = fileSize
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }

    public var resolutionDescription: String {
        switch (width, height) {
        case let (width?, height?):
            "\(width)x\(height)"
        case (_, let height?):
            "\(height)p"
        default:
            "audio/unknown"
        }
    }
}

public struct MediaMetadata: Codable, Equatable, Sendable {
    public let site: String
    public let mediaID: String
    public let sourceID: String?
    public let inputURL: String
    public let webpageURL: String?
    public let title: String?
    public let creator: String?
    public let uploadDate: String?
    public let durationSeconds: Double?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let formatID: String?
    public let formats: [MediaFormat]

    public init(
        site: String,
        mediaID: String,
        sourceID: String? = nil,
        inputURL: String,
        webpageURL: String? = nil,
        title: String? = nil,
        creator: String? = nil,
        uploadDate: String? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        formatID: String? = nil,
        formats: [MediaFormat] = []
    ) {
        self.site = site
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.inputURL = inputURL
        self.webpageURL = webpageURL
        self.title = title
        self.creator = creator
        self.uploadDate = uploadDate
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.formatID = formatID
        self.formats = formats
    }

    public var archiveIdentity: ArchiveIdentity {
        ArchiveIdentity(site: site, mediaID: mediaID)
    }
}
