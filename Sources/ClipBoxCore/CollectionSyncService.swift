import Foundation

public actor CollectionSyncService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient
    private let downloadService: ClipBoxService

    public init(
        archive: ArchiveStore? = nil,
        ytDlp: YtDlpClient? = nil
    ) throws {
        let resolvedArchive = try archive ?? ArchiveStore()
        let resolvedYtDlp = ytDlp ?? YtDlpClient()
        self.archive = resolvedArchive
        self.ytDlp = resolvedYtDlp
        self.downloadService = try ClipBoxService(
            archive: resolvedArchive,
            ytDlp: resolvedYtDlp
        )
    }

    public func scan(
        collection: BuiltInCollection,
        cookiesFromBrowser: BrowserCookieSource,
        limit: Int? = 100
    ) async throws -> CollectionScanResult {
        let items = try await ytDlp.scanCollection(
            collection,
            cookiesFromBrowser: cookiesFromBrowser,
            limit: limit
        )

        var scanItems: [CollectionScanItem] = []
        scanItems.reserveCapacity(items.count)
        for item in items {
            let previouslySeen = try await archive.collectionContains(
                site: item.site,
                collectionName: item.collectionName,
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

        return CollectionScanResult(collection: collection, items: scanItems)
    }

    public func sync(
        collection: BuiltInCollection,
        cookiesFromBrowser: BrowserCookieSource,
        outputDirectory: URL? = nil,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionSyncResult {
        let scanResult = try await scan(
            collection: collection,
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
}
