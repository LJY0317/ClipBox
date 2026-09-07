import Foundation

public actor CollectionSyncService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient
    private let galleryDl: GalleryDlClient
    private let directDownloader: DirectMediaDownloader
    private let downloadService: ClipBoxService

    public init(
        archive: ArchiveStore? = nil,
        ytDlp: YtDlpClient? = nil,
        galleryDl: GalleryDlClient? = nil,
        directDownloader: DirectMediaDownloader? = nil
    ) throws {
        let resolvedArchive = try archive ?? ArchiveStore()
        let resolvedYtDlp = ytDlp ?? YtDlpClient()
        self.archive = resolvedArchive
        self.ytDlp = resolvedYtDlp
        self.galleryDl = galleryDl ?? GalleryDlClient()
        self.directDownloader = directDownloader ?? DirectMediaDownloader()
        self.downloadService = try ClipBoxService(
            archive: resolvedArchive,
            ytDlp: resolvedYtDlp
        )
    }

    public func scan(
        collection: BuiltInCollection,
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        limit: Int? = 100
    ) async throws -> CollectionScanResult {
        let items: [CollectionItem]
        switch collection.site {
        case "youtube":
            items = try await ytDlp.scanCollection(
                collection,
                cookiesFromBrowser: cookiesFromBrowser,
                limit: limit
            )
        case "twitter":
            items = try await galleryDl.scanCollection(
                collection,
                accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser,
                limit: limit
            )
        default:
            throw YtDlpError.inspectionFailed("No built-in collection scanner is configured for \(collection.site)")
        }

        var scanItems: [CollectionScanItem] = []
        scanItems.reserveCapacity(items.count)
        for item in items {
            let previouslySeen = try await archive.collectionContains(
                site: item.site,
                collectionName: item.collectionName,
                mediaID: item.mediaID
            )
            let downloadedByMediaID = try await archive.downloaded(identity: item.archiveIdentity)
            let downloadedBySourceID: Bool
            if item.directMediaURL == nil,
               let sourceID = item.sourceID,
               !sourceID.isEmpty {
                downloadedBySourceID = try await archive.downloaded(
                    site: item.site,
                    sourceID: sourceID
                )
            } else {
                downloadedBySourceID = false
            }
            let alreadyDownloaded = downloadedByMediaID || downloadedBySourceID
            scanItems.append(
                CollectionScanItem(
                    item: item,
                    previouslySeen: previouslySeen,
                    alreadyDownloaded: alreadyDownloaded
                )
            )
        }

        return CollectionScanResult(collection: collection, items: scanItems)
    }

    public func sync(
        collection: BuiltInCollection,
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        outputDirectory: URL? = nil,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionSyncResult {
        let scanResult = try await scan(
            collection: collection,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            limit: limit
        )
        let candidates = scanResult.items.filter { !$0.alreadyDownloaded }

        if dryRun {
            return CollectionSyncResult(
                collection: collection,
                scanned: scanResult.items.count,
                unarchived: candidates.count,
                downloaded: 0,
                skippedAlreadyArchived: scanResult.items.count - candidates.count,
                failed: 0,
                dryRun: true,
                failures: []
            )
        }

        _ = try await archive.recordCollectionItems(scanResult.items.map(\.item))

        var downloaded = 0
        var skipped = scanResult.items.count - candidates.count
        var failures: [CollectionSyncFailure] = []

        for candidate in candidates {
            do {
                if candidate.item.directMediaURL != nil {
                    try await downloadDirectCollectionItem(
                        candidate.item,
                        outputDirectory: outputDirectory
                    )
                    downloaded += 1
                } else {
                    let outcome = try await downloadService.download(
                        url: candidate.item.sourceURL,
                        outputDirectory: outputDirectory,
                        cookiesFromBrowser: cookiesFromBrowser
                    )
                    switch outcome {
                    case .downloaded:
                        downloaded += 1
                    case .skippedAlreadyArchived:
                        skipped += 1
                    }
                }
            } catch {
                failures.append(
                    CollectionSyncFailure(
                        site: candidate.item.site,
                        mediaID: candidate.item.mediaID,
                        title: candidate.item.title,
                        error: error.localizedDescription
                    )
                )
            }
        }

        return CollectionSyncResult(
            collection: collection,
            scanned: scanResult.items.count,
            unarchived: candidates.count,
            downloaded: downloaded,
            skippedAlreadyArchived: skipped,
            failed: failures.count,
            dryRun: false,
            failures: failures
        )
    }

    private func downloadDirectCollectionItem(
        _ item: CollectionItem,
        outputDirectory: URL?
    ) async throws {
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let destination = try ClipBoxPaths.ensureDownloadDirectory(
            outputDirectory ?? preferences.resolvedOutputDirectory
        )
        let metadata = mediaMetadata(from: item)
        try await archive.record(
            media: metadata,
            collection: item.collectionName,
            status: .downloading
        )

        do {
            let outputPath = try await directDownloader.download(
                item: item,
                outputDirectory: destination
            )
            try await archive.record(
                media: metadata,
                collection: item.collectionName,
                status: .downloaded,
                outputPath: outputPath,
                formatID: metadata.formatID
            )
        } catch {
            try? await archive.record(
                media: metadata,
                collection: item.collectionName,
                status: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func mediaMetadata(from item: CollectionItem) -> MediaMetadata {
        let uploadDate = item.publishedAt.map {
            $0.filter(\.isNumber).prefix(8)
        }.map(String.init)
        let bitrateDescription = item.bitrate.map { value in
            String(format: "gallery-dl-direct-%.0f", value)
        } ?? "gallery-dl-direct"

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
            formatID: bitrateDescription
        )
    }
}
