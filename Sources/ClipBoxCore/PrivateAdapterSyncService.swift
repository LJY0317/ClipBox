import Foundation

public actor PrivateAdapterSyncService {
    private let manager: PrivateAdapterManager
    private let archive: ArchiveStore
    private let directDownloader: DirectMediaDownloader
    private let ytDlp: YtDlpClient

    public init(
        manager: PrivateAdapterManager? = nil,
        archive: ArchiveStore? = nil,
        directDownloader: DirectMediaDownloader? = nil,
        ytDlp: YtDlpClient? = nil
    ) throws {
        self.manager = manager ?? PrivateAdapterManager()
        self.archive = try archive ?? ArchiveStore()
        self.directDownloader = directDownloader ?? DirectMediaDownloader()
        self.ytDlp = ytDlp ?? YtDlpClient()
    }

    public func scan(
        adapterID: String,
        collection: String,
        browser: BrowserCookieSource,
        limit: Int? = 100
    ) async throws -> PrivateAdapterScanResult {
        let response = try await manager.scan(
            id: adapterID,
            collection: collection,
            browser: browser,
            limit: limit
        )
        let site = siteKey(adapterID)
        var scanItems: [CollectionScanItem] = []
        scanItems.reserveCapacity(response.items.count)

        for adapterItem in response.items {
            let item = normalizedItem(
                adapterItem,
                site: site,
                collection: collection
            )
            let previouslySeen = try await archive.collectionContains(
                site: site,
                collectionName: collection,
                mediaID: item.mediaID
            )
            let alreadyDownloaded = try await archive.downloaded(identity: item.archiveIdentity)
            scanItems.append(
                CollectionScanItem(
                    item: item,
                    previouslySeen: previouslySeen,
                    alreadyDownloaded: alreadyDownloaded
                )
            )
        }

        return PrivateAdapterScanResult(
            adapterID: adapterID,
            collection: collection,
            items: scanItems
        )
    }

    public func sync(
        adapterID: String,
        collection: String,
        browser: BrowserCookieSource,
        outputDirectory: URL? = nil,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> PrivateAdapterSyncResult {
        let adapterResponse = try await manager.scan(
            id: adapterID,
            collection: collection,
            browser: browser,
            limit: limit
        )
        let site = siteKey(adapterID)
        var normalized: [(PrivateAdapterMediaItem, CollectionScanItem)] = []
        for adapterItem in adapterResponse.items {
            let item = normalizedItem(adapterItem, site: site, collection: collection)
            let previouslySeen = try await archive.collectionContains(
                site: site,
                collectionName: collection,
                mediaID: item.mediaID
            )
            let alreadyDownloaded = try await archive.downloaded(identity: item.archiveIdentity)
            normalized.append((
                adapterItem,
                CollectionScanItem(
                    item: item,
                    previouslySeen: previouslySeen,
                    alreadyDownloaded: alreadyDownloaded
                )
            ))
        }

        let candidates = normalized.filter { !$0.1.alreadyDownloaded }
        if dryRun {
            return PrivateAdapterSyncResult(
                adapterID: adapterID,
                collection: collection,
                scanned: normalized.count,
                unarchived: candidates.count,
                downloaded: 0,
                skippedAlreadyArchived: normalized.count - candidates.count,
                failed: 0,
                dryRun: true,
                failures: []
            )
        }

        _ = try await archive.recordCollectionItems(normalized.map { $0.1.item })
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let destination = try ClipBoxPaths.ensureDownloadDirectory(
            outputDirectory ?? preferences.resolvedOutputDirectory
        )

        var downloaded = 0
        var failures: [CollectionSyncFailure] = []
        for (adapterItem, scanItem) in candidates {
            let metadata = mediaMetadata(
                adapterItem,
                site: site,
                collectionItem: scanItem.item
            )
            try await archive.record(
                media: metadata,
                collection: collection,
                status: .downloading
            )

            do {
                let outputPath: String
                switch adapterItem.download.strategy {
                case .direct:
                    outputPath = try await directDownloader.download(
                        item: scanItem.item,
                        outputDirectory: destination
                    )
                case .ytDlp:
                    outputPath = try await ytDlp.download(
                        url: adapterItem.download.url,
                        outputDirectory: destination,
                        cookiesFromBrowser: browser
                    )
                }
                try await archive.record(
                    media: metadata,
                    collection: collection,
                    status: .downloaded,
                    outputPath: outputPath,
                    formatID: metadata.formatID
                )
                downloaded += 1
            } catch {
                try? await archive.record(
                    media: metadata,
                    collection: collection,
                    status: .failed,
                    error: error.localizedDescription
                )
                failures.append(
                    CollectionSyncFailure(
                        site: site,
                        mediaID: adapterItem.mediaID,
                        title: adapterItem.title,
                        error: error.localizedDescription
                    )
                )
            }
        }

        return PrivateAdapterSyncResult(
            adapterID: adapterID,
            collection: collection,
            scanned: normalized.count,
            unarchived: candidates.count,
            downloaded: downloaded,
            skippedAlreadyArchived: normalized.count - candidates.count,
            failed: failures.count,
            dryRun: false,
            failures: failures
        )
    }

    private func siteKey(_ adapterID: String) -> String {
        "custom:\(adapterID)"
    }

    private func normalizedItem(
        _ item: PrivateAdapterMediaItem,
        site: String,
        collection: String
    ) -> CollectionItem {
        CollectionItem(
            site: site,
            collectionName: collection,
            mediaID: item.mediaID,
            sourceID: item.sourceID,
            sourceURL: item.sourceURL,
            title: item.title,
            creator: item.creator,
            publishedAt: item.publishedAt,
            directMediaURL: item.download.strategy == .direct ? item.download.url : nil,
            extensionName: item.extensionName,
            width: item.width,
            height: item.height,
            bitrate: item.bitrate
        )
    }

    private func mediaMetadata(
        _ adapterItem: PrivateAdapterMediaItem,
        site: String,
        collectionItem: CollectionItem
    ) -> MediaMetadata {
        let uploadDate = adapterItem.publishedAt.map {
            String($0.filter(\.isNumber).prefix(8))
        }
        return MediaMetadata(
            site: site,
            mediaID: adapterItem.mediaID,
            sourceID: adapterItem.sourceID,
            inputURL: adapterItem.sourceURL,
            webpageURL: adapterItem.sourceURL,
            title: adapterItem.title,
            creator: adapterItem.creator,
            uploadDate: uploadDate,
            width: adapterItem.width,
            height: adapterItem.height,
            formatID: "private-adapter:\(adapterItem.download.strategy.rawValue)"
        )
    }
}
