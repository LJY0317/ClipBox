import Foundation

public enum DownloadOutcome: Codable, Equatable, Sendable {
    case downloaded(media: MediaMetadata, outputPath: String)
    case skippedAlreadyArchived(media: MediaMetadata, previousPath: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case media
        case outputPath
        case previousPath
    }

    private enum Kind: String, Codable {
        case downloaded
        case skippedAlreadyArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let media = try container.decode(MediaMetadata.self, forKey: .media)
        switch kind {
        case .downloaded:
            self = .downloaded(
                media: media,
                outputPath: try container.decode(String.self, forKey: .outputPath)
            )
        case .skippedAlreadyArchived:
            self = .skippedAlreadyArchived(
                media: media,
                previousPath: try container.decodeIfPresent(String.self, forKey: .previousPath)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .downloaded(let media, let outputPath):
            try container.encode(Kind.downloaded, forKey: .kind)
            try container.encode(media, forKey: .media)
            try container.encode(outputPath, forKey: .outputPath)
        case .skippedAlreadyArchived(let media, let previousPath):
            try container.encode(Kind.skippedAlreadyArchived, forKey: .kind)
            try container.encode(media, forKey: .media)
            try container.encodeIfPresent(previousPath, forKey: .previousPath)
        }
    }
}

public actor ClipBoxService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient
    private let galleryDl: GalleryDlClient
    private let directDownloader: DirectMediaDownloader

    public init(
        archive: ArchiveStore? = nil,
        ytDlp: YtDlpClient? = nil,
        galleryDl: GalleryDlClient? = nil,
        directDownloader: DirectMediaDownloader? = nil
    ) throws {
        self.archive = try archive ?? ArchiveStore()
        self.ytDlp = ytDlp ?? YtDlpClient()
        self.galleryDl = galleryDl ?? GalleryDlClient()
        self.directDownloader = directDownloader ?? DirectMediaDownloader()
    }

    public func dependencyStatus() async -> ClipBoxDependencyStatus {
        await ytDlp.dependencyStatus()
    }

    public func inspect(
        url: String,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> MediaMetadata {
        try await ytDlp.inspect(url: url, cookiesFromBrowser: cookiesFromBrowser)
    }

    public func inspectLink(
        url: String,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> LinkInspection {
        if GalleryDlClient.supportsPostURL(url) {
            let items = try await galleryDl.inspectPost(
                url: url,
                cookiesFromBrowser: cookiesFromBrowser
            )
            var assets: [LinkDownloadAsset] = []
            assets.reserveCapacity(items.count)
            for item in items {
                let media = Self.mediaMetadata(from: item)
                assets.append(LinkDownloadAsset(
                    media: media,
                    mediaType: item.mediaType,
                    thumbnailURL: item.thumbnailURL,
                    alreadyDownloaded: try await archive.downloaded(identity: media.archiveIdentity),
                    transfer: .direct(item)
                ))
            }
            return LinkInspection(sourceURL: url, assets: assets)
        }

        let media = try await ytDlp.inspect(url: url, cookiesFromBrowser: cookiesFromBrowser)
        let asset = LinkDownloadAsset(
            media: media,
            mediaType: .video,
            thumbnailURL: nil,
            alreadyDownloaded: try await archive.downloaded(identity: media.archiveIdentity),
            transfer: .ytDlp(url: url)
        )
        return LinkInspection(sourceURL: url, assets: [asset])
    }

    public func historyCount() async throws -> Int {
        try await archive.count()
    }

    public func recentHistory(limit: Int = 50) async throws -> [ArchiveRecord] {
        try await archive.recent(limit: limit)
    }

    public func download(
        url: String,
        outputDirectory: URL? = nil,
        force: Bool = false,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> DownloadOutcome {
        let media = try await ytDlp.inspect(
            url: url,
            cookiesFromBrowser: cookiesFromBrowser
        )

        if !force, try await archive.downloaded(identity: media.archiveIdentity) {
            let previous = try await archive.record(identity: media.archiveIdentity)?.outputPath
            return .skippedAlreadyArchived(media: media, previousPath: previous)
        }

        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let destination = try ClipBoxPaths.ensureDownloadDirectory(
            outputDirectory ?? preferences.resolvedOutputDirectory
        )

        try await archive.record(media: media, status: .downloading)
        do {
            let outputPath = try await ytDlp.download(
                url: url,
                outputDirectory: destination,
                cookiesFromBrowser: cookiesFromBrowser
            )
            try await archive.record(
                media: media,
                status: .downloaded,
                outputPath: outputPath
            )
            return .downloaded(media: media, outputPath: outputPath)
        } catch is CancellationError {
            // yt-dlp keeps its .part file so a later run can resume. Cancellation is
            // not a failed download. Keep the interrupted record as downloading so a
            // later run can resume it instead of treating cancellation as completion.
            throw CancellationError()
        } catch {
            try? await archive.record(
                media: media,
                status: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }

    public func download(
        asset: LinkDownloadAsset,
        outputDirectory: URL? = nil,
        force: Bool = false,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> DownloadOutcome {
        let media = asset.media
        if !force, try await archive.downloaded(identity: media.archiveIdentity) {
            let previous = try await archive.record(identity: media.archiveIdentity)?.outputPath
            return .skippedAlreadyArchived(media: media, previousPath: previous)
        }

        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let destination = try ClipBoxPaths.ensureDownloadDirectory(
            outputDirectory ?? preferences.resolvedOutputDirectory
        )
        try await archive.record(media: media, status: .downloading)

        do {
            let outputPath: String
            switch asset.transfer {
            case .ytDlp(let url):
                outputPath = try await ytDlp.download(
                    url: url,
                    outputDirectory: destination,
                    cookiesFromBrowser: cookiesFromBrowser
                )
            case .direct(let item):
                do {
                    outputPath = try await directDownloader.download(item: item, outputDirectory: destination)
                } catch DirectMediaDownloaderError.httpStatus(let status) where [401, 403, 404, 410].contains(status) {
                    let refreshed = try await galleryDl.inspectPost(
                        url: item.sourceURL,
                        cookiesFromBrowser: cookiesFromBrowser
                    )
                    guard let refreshedItem = refreshed.first(where: { $0.mediaID == item.mediaID }) else {
                        throw DirectMediaDownloaderError.httpStatus(status)
                    }
                    outputPath = try await directDownloader.download(item: refreshedItem, outputDirectory: destination)
                }
            }
            try await archive.record(media: media, status: .downloaded, outputPath: outputPath)
            return .downloaded(media: media, outputPath: outputPath)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await archive.record(media: media, status: .failed, error: error.localizedDescription)
            throw error
        }
    }

    private static func mediaMetadata(from item: CollectionItem) -> MediaMetadata {
        let uploadDate = item.publishedAt.map { value in
            String(value.filter(\.isNumber).prefix(8))
        }
        return MediaMetadata(
            site: item.site,
            mediaID: item.mediaID,
            sourceID: item.sourceID,
            inputURL: item.sourceURL,
            webpageURL: item.sourceURL,
            title: item.title,
            creator: item.creator,
            uploadDate: uploadDate,
            width: item.width,
            height: item.height,
            formatID: item.bitrate.map { String(format: "direct-%.0f", $0) } ?? "direct"
        )
    }
}
