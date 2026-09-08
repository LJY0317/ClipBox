import Foundation

private struct CollectionBatchAccumulator {
    var item: CollectionItem
    var collections: [BuiltInCollection]
    var previouslySeenCollections: [BuiltInCollection]
    var alreadyDownloaded: Bool
}

private struct CollectionBatchScanData {
    let result: CollectionBatchScanResult
    let membershipItems: [CollectionItem]
}

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
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> CollectionScanResult {
        let items: [CollectionItem]
        switch collection.site {
        case "youtube":
            items = try await ytDlp.scanCollection(
                collection,
                cookiesFromBrowser: cookiesFromBrowser,
                limit: limit
            ).filter { mediaTypes.contains($0.mediaType) }
        case "twitter":
            items = try await galleryDl.scanCollection(
                collection,
                accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser,
                mediaTypes: mediaTypes,
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
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionSyncResult {
        let scanResult = try await scan(
            collection: collection,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            mediaTypes: mediaTypes,
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

    public func scan(
        collections: [BuiltInCollection],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> CollectionBatchScanResult {
        try await scanBatchData(
            collections: collections,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            mediaTypes: mediaTypes,
            limit: limit
        ).result
    }

    public func sync(
        collections: [BuiltInCollection],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        outputDirectory: URL? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionBatchSyncResult {
        let scanData = try await scanBatchData(
            collections: collections,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            mediaTypes: mediaTypes,
            limit: limit
        )
        let scanResult = scanData.result
        let candidates = scanResult.items.filter { !$0.alreadyDownloaded }
        let initiallyArchived = scanResult.items.count - candidates.count

        if dryRun {
            return CollectionBatchSyncResult(
                collections: scanResult.collections,
                scannedOccurrences: scanResult.scannedOccurrences,
                uniqueMedia: scanResult.uniqueMediaCount,
                duplicatesCollapsed: scanResult.duplicateOccurrencesCollapsed,
                unarchived: candidates.count,
                downloaded: 0,
                skippedAlreadyArchived: initiallyArchived,
                failed: 0,
                dryRun: true,
                failures: []
            )
        }

        // Preserve every collection membership even when the actual media file
        // is deduplicated across multiple selected collections.
        _ = try await archive.recordCollectionItems(scanData.membershipItems)

        var downloaded = 0
        var skipped = initiallyArchived
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

        return CollectionBatchSyncResult(
            collections: scanResult.collections,
            scannedOccurrences: scanResult.scannedOccurrences,
            uniqueMedia: scanResult.uniqueMediaCount,
            duplicatesCollapsed: scanResult.duplicateOccurrencesCollapsed,
            unarchived: candidates.count,
            downloaded: downloaded,
            skippedAlreadyArchived: skipped,
            failed: failures.count,
            dryRun: false,
            failures: failures
        )
    }

    private func scanBatchData(
        collections: [BuiltInCollection],
        accountName: String?,
        cookiesFromBrowser: BrowserCookieSource,
        mediaTypes: MediaTypeSelection,
        limit: Int?
    ) async throws -> CollectionBatchScanData {
        var selectedCollections: [BuiltInCollection] = []
        for collection in collections where !selectedCollections.contains(collection) {
            selectedCollections.append(collection)
        }
        guard !selectedCollections.isEmpty else {
            throw YtDlpError.inspectionFailed("Select at least one collection to scan.")
        }

        var membershipItems: [CollectionItem] = []
        var orderedIdentities: [ArchiveIdentity] = []
        var accumulators: [ArchiveIdentity: CollectionBatchAccumulator] = [:]

        for collection in selectedCollections {
            let result = try await scan(
                collection: collection,
                accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser,
                mediaTypes: mediaTypes,
                limit: limit
            )

            for scanItem in result.items {
                membershipItems.append(scanItem.item)
                let identity = scanItem.item.archiveIdentity

                if var accumulator = accumulators[identity] {
                    if !accumulator.collections.contains(collection) {
                        accumulator.collections.append(collection)
                    }
                    if scanItem.previouslySeen,
                       !accumulator.previouslySeenCollections.contains(collection) {
                        accumulator.previouslySeenCollections.append(collection)
                    }
                    accumulator.alreadyDownloaded = accumulator.alreadyDownloaded || scanItem.alreadyDownloaded
                    accumulator.item = preferredRepresentative(
                        current: accumulator.item,
                        candidate: scanItem.item
                    )
                    accumulators[identity] = accumulator
                } else {
                    orderedIdentities.append(identity)
                    accumulators[identity] = CollectionBatchAccumulator(
                        item: scanItem.item,
                        collections: [collection],
                        previouslySeenCollections: scanItem.previouslySeen ? [collection] : [],
                        alreadyDownloaded: scanItem.alreadyDownloaded
                    )
                }
            }
        }

        let items = orderedIdentities.compactMap { identity -> CollectionBatchScanItem? in
            guard let accumulator = accumulators[identity] else { return nil }
            return CollectionBatchScanItem(
                item: accumulator.item,
                collections: accumulator.collections,
                previouslySeenCollections: accumulator.previouslySeenCollections,
                alreadyDownloaded: accumulator.alreadyDownloaded
            )
        }

        return CollectionBatchScanData(
            result: CollectionBatchScanResult(
                collections: selectedCollections,
                items: items,
                scannedOccurrences: membershipItems.count
            ),
            membershipItems: membershipItems
        )
    }

    private func preferredRepresentative(
        current: CollectionItem,
        candidate: CollectionItem
    ) -> CollectionItem {
        let currentBitrate = current.bitrate ?? 0
        let candidateBitrate = candidate.bitrate ?? 0
        if candidateBitrate != currentBitrate {
            return candidateBitrate > currentBitrate ? candidate : current
        }

        let currentPixels = (current.width ?? 0) * (current.height ?? 0)
        let candidatePixels = (candidate.width ?? 0) * (candidate.height ?? 0)
        return candidatePixels > currentPixels ? candidate : current
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
