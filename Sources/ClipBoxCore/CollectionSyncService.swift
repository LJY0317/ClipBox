import Foundation

private struct CollectionBatchAccumulator {
    var item: CollectionItem
    var collections: [BuiltInCollection]
    var previouslySeenCollections: [BuiltInCollection]
    var alreadyDownloaded: Bool
}

struct CollectionBatchScanData {
    let result: CollectionBatchScanResult
    let membershipItems: [CollectionItem]
}

struct CollectionExecutionContext: Equatable {
    let collections: [BuiltInCollection]
    let accountName: String?
    let session: BrowserSession
    let mediaTypes: MediaTypeSelection
    let limit: Int?
    let ownerID: String?
}

struct CollectionExecutionPlan {
    let context: CollectionExecutionContext
    let createdAt: Date
    let data: CollectionBatchScanData
}

struct CollectionExecutionPlanCache {
    var plan: CollectionExecutionPlan?
    let lifetime: TimeInterval

    init(lifetime: TimeInterval = 10 * 60) {
        self.lifetime = lifetime
    }

    mutating func store(context: CollectionExecutionContext, data: CollectionBatchScanData, now: Date = Date()) {
        plan = CollectionExecutionPlan(context: context, createdAt: now, data: data)
    }

    func reusableData(context: CollectionExecutionContext, now: Date = Date()) -> CollectionBatchScanData? {
        guard let plan, plan.context == context, now.timeIntervalSince(plan.createdAt) <= lifetime else { return nil }
        return plan.data
    }
}

public struct CollectionPagedPreview: Sendable {
    public let result: CollectionBatchScanResult
    public let hasMoreCollections: Set<BuiltInCollection>

    public func hasMore(_ collection: BuiltInCollection) -> Bool {
        hasMoreCollections.contains(collection)
    }
}

private struct XPreviewPagingState {
    let collections: [BuiltInCollection]
    let accountName: String?
    let session: BrowserSession
    let mediaTypes: MediaTypeSelection
    let ownerID: String?
    var rawItems: [BuiltInCollection: [CollectionItem]]
    var continuations: [BuiltInCollection: String]
    var diagnostics: [CollectionDiagnostic]
}

public actor CollectionSyncService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient
    private let galleryDl: GalleryDlClient
    private let directDownloader: DirectMediaDownloader
    private let downloadService: ClipBoxService
    private var planCache = CollectionExecutionPlanCache()
    private var xPreviewPaging: XPreviewPagingState?
    public private(set) var lastExecutionNote: String = ""

    static func shouldRefreshDirectMedia(status: Int, refreshAttempts: Int) -> Bool {
        refreshAttempts == 0 && [401, 403, 404].contains(status)
    }

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
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> CollectionScanResult {
        if collection.site == "twitter" {
            let batch = try await scan(collections: [collection], accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit)
            let items = batch.items.filter { $0.collections.contains(collection) }.map {
                CollectionScanItem(item: $0.item,
                    previouslySeen: $0.previouslySeenCollections.contains(collection),
                    alreadyDownloaded: $0.alreadyDownloaded)
            }
            return CollectionScanResult(collection: collection, items: items)
        }
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
            browserProfile: browserProfile,
            browserContainer: browserContainer,
                mediaTypes: mediaTypes,
                limit: limit
            )
        default:
            throw YtDlpError.inspectionFailed("No built-in collection scanner is configured for \(collection.site)")
        }

        return try await annotate(items, collection: collection)
    }

    private func annotate(
        _ items: [CollectionItem],
        collection: BuiltInCollection,
        ownerID: String? = nil
    ) async throws -> CollectionScanResult {
        var scanItems: [CollectionScanItem] = []
        scanItems.reserveCapacity(items.count)
        for item in items {
            let previouslySeen = try await archive.collectionContains(
                site: item.site,
                collectionName: item.collectionName,
                mediaID: item.mediaID,
                ownerID: ownerID
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
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        outputDirectory: URL? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionSyncResult {
        if collection.site == "twitter" {
            let batch = try await sync(collections: [collection], accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, outputDirectory: outputDirectory,
                mediaTypes: mediaTypes, limit: limit, dryRun: dryRun)
            return CollectionSyncResult(collection: collection, scanned: batch.uniqueMedia,
                unarchived: batch.unarchived, downloaded: batch.downloaded,
                skippedAlreadyArchived: batch.skippedAlreadyArchived, failed: batch.failed,
                dryRun: batch.dryRun, failures: batch.failures)
        }
        let scanResult = try await scan(
            collection: collection,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            browserProfile: browserProfile,
            browserContainer: browserContainer,
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
            try Task.checkCancellation()
            do {
                if candidate.item.directMediaURL != nil {
                    try await downloadDirectCollectionItem(
                        candidate.item,
                        outputDirectory: outputDirectory,
                        session: BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer),
                        mediaTypes: mediaTypes
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
            } catch is CancellationError {
                throw CancellationError()
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
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> CollectionBatchScanResult {
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let xSelected = collections.contains { $0.site == "twitter" }
        let lease = try xSelected ? XWorkCoordinator.acquire(scope: XWorkScope(session: session)) : nil
        _ = lease
        var ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
            let ownerLease = try ownerID.map { try XWorkCoordinator.acquire(scope: XWorkScope(ownerID: $0, session: session)) }
            _ = ownerLease
            let data = try await scanBatchData(collections: collections, accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
            if xSelected {
                let context = executionContext(collections: collections, accountName: accountName, session: session,
                    mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
                planCache.store(context: context, data: data)
                lastExecutionNote = "Fresh collection lookup completed. Sync can reuse this in-memory result for 10 minutes if the session and settings stay unchanged."
            }
            return data.result
        } catch let error as GalleryDlError {
            try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
            throw error
        }
    }

    public func sync(
        collections: [BuiltInCollection],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        outputDirectory: URL? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100,
        dryRun: Bool = false
    ) async throws -> CollectionBatchSyncResult {
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let xSelected = collections.contains { $0.site == "twitter" }
        let lease = try xSelected ? XWorkCoordinator.acquire(scope: XWorkScope(session: session)) : nil
        _ = lease
        let ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
        } catch let error as GalleryDlError {
            try persistCooldownIfNeeded(error, session: session, ownerID: nil)
            throw error
        }
        let ownerLease = try ownerID.map { try XWorkCoordinator.acquire(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease
        if xSelected, !dryRun, ownerID == nil {
            throw GalleryDlError.scanFailed(
                "X account identity could not be server-verified, so ClipBox made no membership or download changes. Test the selected browser session and try again."
            )
        }
        let context = executionContext(collections: collections, accountName: accountName, session: session,
            mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
        let scanData: CollectionBatchScanData
        if xSelected, let reusable = planCache.reusableData(context: context) {
            scanData = reusable
            lastExecutionNote = "Reused the recent Preview execution plan; X Likes/Bookmarks were not listed again."
        } else {
            do {
                scanData = try await scanBatchData(collections: collections, accountName: accountName,
                    cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                    browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
            } catch let error as GalleryDlError {
                try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                throw error
            }
            if xSelected {
                planCache.store(context: context, data: scanData)
                lastExecutionNote = "Collection list was queried because there was no matching, unexpired Preview plan."
            }
        }
        return try await syncBatchData(scanData, ownerID: xSelected ? ownerID : nil,
            session: session, cookiesFromBrowser: cookiesFromBrowser,
            outputDirectory: outputDirectory, mediaTypes: mediaTypes, dryRun: dryRun)
    }

    public func beginPagedXPreview(
        collections: [BuiltInCollection],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        pageSize: Int = 50
    ) async throws -> CollectionPagedPreview {
        var selected: [BuiltInCollection] = []
        for collection in collections where !selected.contains(collection) {
            guard collection.site == "twitter" else {
                throw YtDlpError.inspectionFailed("Incremental Preview is available only for X collections.")
            }
            selected.append(collection)
        }
        guard !selected.isEmpty else {
            throw YtDlpError.inspectionFailed("Select at least one X collection to preview.")
        }

        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let sessionLease = try XWorkCoordinator.acquire(scope: XWorkScope(session: session))
        _ = sessionLease
        var ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: selected, accountName: accountName, session: session)
            let ownerLease = try ownerID.map { try XWorkCoordinator.acquire(scope: XWorkScope(ownerID: $0, session: session)) }
            _ = ownerLease
            let page = try await galleryDl.scanCollectionPage(
                selected,
                accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser,
                browserProfile: browserProfile,
                browserContainer: browserContainer,
                mediaTypes: mediaTypes,
                pageSize: pageSize,
                expectedOwnerID: ownerID
            )
            let data = try await pagedBatchData(
                collections: selected,
                rawItems: page.items,
                ownerID: ownerID,
                diagnostics: page.diagnostics
            )
            xPreviewPaging = XPreviewPagingState(
                collections: selected,
                accountName: BuiltInCollection.normalizedAccountName(accountName),
                session: session,
                mediaTypes: mediaTypes,
                ownerID: ownerID,
                rawItems: page.items,
                continuations: page.continuations,
                diagnostics: page.diagnostics
            )
            lastExecutionNote = "Loaded one X page per selected collection. Additional pages are fetched only when requested."
            return CollectionPagedPreview(result: data.result, hasMoreCollections: Set(page.continuations.keys))
        } catch let error as GalleryDlError {
            try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
            throw error
        }
    }

    public func loadNextXPreviewPage(
        collection: BuiltInCollection,
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        pageSize: Int = 50
    ) async throws -> CollectionPagedPreview {
        guard collection.site == "twitter" else {
            throw YtDlpError.inspectionFailed("Incremental Preview is available only for X collections.")
        }
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let normalizedAccount = BuiltInCollection.normalizedAccountName(accountName)
        guard var state = xPreviewPaging,
              state.collections.contains(collection),
              state.accountName == normalizedAccount,
              state.session == session,
              state.mediaTypes == mediaTypes else {
            throw YtDlpError.inspectionFailed("The paged Preview context changed. Start a new Preview before loading another page.")
        }
        guard let cursor = state.continuations[collection] else {
            let data = try await pagedBatchData(collections: state.collections, rawItems: state.rawItems,
                ownerID: state.ownerID, diagnostics: state.diagnostics)
            return CollectionPagedPreview(result: data.result, hasMoreCollections: Set(state.continuations.keys))
        }

        let sessionLease = try XWorkCoordinator.acquire(scope: XWorkScope(session: session))
        _ = sessionLease
        let ownerLease = try state.ownerID.map { try XWorkCoordinator.acquire(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease
        do {
            let page = try await galleryDl.scanCollectionPage(
                [collection],
                accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser,
                browserProfile: browserProfile,
                browserContainer: browserContainer,
                mediaTypes: mediaTypes,
                continuations: [collection: cursor],
                pageSize: pageSize,
                expectedOwnerID: state.ownerID
            )
            var existing = state.rawItems[collection] ?? []
            var seen = Set(existing.map(\.archiveIdentity))
            for item in page.items[collection] ?? [] where seen.insert(item.archiveIdentity).inserted {
                existing.append(item)
            }
            state.rawItems[collection] = existing
            if let next = page.continuations[collection] {
                state.continuations[collection] = next
            } else {
                state.continuations.removeValue(forKey: collection)
            }
            state.diagnostics = Self.mergingDiagnostics(state.diagnostics, page.diagnostics)
            xPreviewPaging = state
            let data = try await pagedBatchData(collections: state.collections, rawItems: state.rawItems,
                ownerID: state.ownerID, diagnostics: state.diagnostics)
            lastExecutionNote = "Loaded one additional X page for \(collection.displayName) without restarting from the first page."
            return CollectionPagedPreview(result: data.result, hasMoreCollections: Set(state.continuations.keys))
        } catch let error as GalleryDlError {
            try persistCooldownIfNeeded(error, session: session, ownerID: state.ownerID)
            throw error
        }
    }

    public func syncLoadedXPreview(
        collections: [BuiltInCollection],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        outputDirectory: URL? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection
    ) async throws -> CollectionBatchSyncResult? {
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let normalizedAccount = BuiltInCollection.normalizedAccountName(accountName)
        guard let state = xPreviewPaging,
              state.collections == collections,
              state.accountName == normalizedAccount,
              state.session == session,
              state.mediaTypes == mediaTypes else { return nil }

        let sessionLease = try XWorkCoordinator.acquire(scope: XWorkScope(session: session))
        _ = sessionLease
        let verifiedOwner = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
        guard verifiedOwner == state.ownerID, verifiedOwner != nil else {
            throw GalleryDlError.scanFailed("The X account changed since Preview. Start a new Preview before syncing.")
        }
        let ownerLease = try verifiedOwner.map { try XWorkCoordinator.acquire(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease
        let freshData = try await pagedBatchData(collections: state.collections, rawItems: state.rawItems,
            ownerID: verifiedOwner, diagnostics: state.diagnostics)
        lastExecutionNote = "Reused the X pages already loaded in Preview; no Likes/Bookmarks list was queried again."
        return try await syncBatchData(freshData, ownerID: verifiedOwner, session: session,
            cookiesFromBrowser: cookiesFromBrowser, outputDirectory: outputDirectory,
            mediaTypes: mediaTypes, dryRun: false)
    }

    private func pagedBatchData(
        collections: [BuiltInCollection],
        rawItems: [BuiltInCollection: [CollectionItem]],
        ownerID: String?,
        diagnostics: [CollectionDiagnostic]
    ) async throws -> CollectionBatchScanData {
        var membershipItems: [CollectionItem] = []
        var orderedIdentities: [ArchiveIdentity] = []
        var accumulators: [ArchiveIdentity: CollectionBatchAccumulator] = [:]

        for collection in collections {
            let annotated = try await annotate(rawItems[collection] ?? [], collection: collection, ownerID: ownerID)
            for scanItem in annotated.items {
                membershipItems.append(scanItem.item)
                let identity = scanItem.item.archiveIdentity
                if var accumulator = accumulators[identity] {
                    if !accumulator.collections.contains(collection) { accumulator.collections.append(collection) }
                    if scanItem.previouslySeen, !accumulator.previouslySeenCollections.contains(collection) {
                        accumulator.previouslySeenCollections.append(collection)
                    }
                    accumulator.alreadyDownloaded = accumulator.alreadyDownloaded || scanItem.alreadyDownloaded
                    accumulator.item = preferredRepresentative(current: accumulator.item, candidate: scanItem.item)
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
            return CollectionBatchScanItem(item: accumulator.item,
                collections: accumulator.collections,
                previouslySeenCollections: accumulator.previouslySeenCollections,
                alreadyDownloaded: accumulator.alreadyDownloaded)
        }
        var result = CollectionBatchScanResult(collections: collections, items: items,
            scannedOccurrences: membershipItems.count)
        result.collectionItems = membershipItems
        result.diagnostics = diagnostics
        return CollectionBatchScanData(result: result, membershipItems: membershipItems)
    }

    private static func mergingDiagnostics(
        _ existing: [CollectionDiagnostic], _ added: [CollectionDiagnostic]
    ) -> [CollectionDiagnostic] {
        var order: [String] = []
        var values: [String: CollectionDiagnostic] = [:]
        for diagnostic in existing + added {
            if values[diagnostic.collection] == nil { order.append(diagnostic.collection) }
            if let previous = values[diagnostic.collection] {
                values[diagnostic.collection] = CollectionDiagnostic(
                    collection: diagnostic.collection,
                    pages: previous.pages + diagnostic.pages,
                    entries: previous.entries + diagnostic.entries,
                    lastPageEntries: diagnostic.lastPageEntries,
                    stop: diagnostic.stop
                )
            } else {
                values[diagnostic.collection] = diagnostic
            }
        }
        return order.compactMap { values[$0] }
    }

    private func syncBatchData(
        _ scanData: CollectionBatchScanData,
        ownerID: String?,
        session: BrowserSession,
        cookiesFromBrowser: BrowserCookieSource,
        outputDirectory: URL?,
        mediaTypes: MediaTypeSelection,
        dryRun: Bool
    ) async throws -> CollectionBatchSyncResult {
        let scanResult = scanData.result
        let candidates = scanResult.items.filter { !$0.alreadyDownloaded }
        let initiallyArchived = scanResult.items.count - candidates.count
        if dryRun {
            return CollectionBatchSyncResult(collections: scanResult.collections,
                scannedOccurrences: scanResult.scannedOccurrences,
                uniqueMedia: scanResult.uniqueMediaCount,
                duplicatesCollapsed: scanResult.duplicateOccurrencesCollapsed,
                unarchived: candidates.count, downloaded: 0,
                skippedAlreadyArchived: initiallyArchived, failed: 0,
                dryRun: true, failures: [])
        }

        _ = try await archive.recordCollectionItems(scanData.membershipItems, ownerID: ownerID)
        var downloaded = 0
        var skipped = initiallyArchived
        var failures: [CollectionSyncFailure] = []
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                if candidate.item.directMediaURL != nil {
                    try await downloadDirectCollectionItem(candidate.item, outputDirectory: outputDirectory,
                        session: session, mediaTypes: mediaTypes)
                    downloaded += 1
                } else {
                    let outcome = try await downloadService.download(url: candidate.item.sourceURL,
                        outputDirectory: outputDirectory, cookiesFromBrowser: cookiesFromBrowser)
                    switch outcome {
                    case .downloaded: downloaded += 1
                    case .skippedAlreadyArchived: skipped += 1
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(CollectionSyncFailure(site: candidate.item.site,
                    mediaID: candidate.item.mediaID, title: candidate.item.title,
                    error: error.localizedDescription))
            }
        }
        return CollectionBatchSyncResult(collections: scanResult.collections,
            scannedOccurrences: scanResult.scannedOccurrences,
            uniqueMedia: scanResult.uniqueMediaCount,
            duplicatesCollapsed: scanResult.duplicateOccurrencesCollapsed,
            unarchived: candidates.count, downloaded: downloaded,
            skippedAlreadyArchived: skipped, failed: failures.count,
            dryRun: false, failures: failures)
    }

    private func executionContext(
        collections: [BuiltInCollection], accountName: String?, session: BrowserSession,
        mediaTypes: MediaTypeSelection, limit: Int?, ownerID: String?
    ) -> CollectionExecutionContext {
        var unique: [BuiltInCollection] = []
        for collection in collections where !unique.contains(collection) { unique.append(collection) }
        return CollectionExecutionContext(collections: unique, accountName: BuiltInCollection.normalizedAccountName(accountName),
            session: session, mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
    }

    private func verifiedOwnerIDIfNeeded(
        collections: [BuiltInCollection], accountName: String?, session: BrowserSession
    ) async throws -> String? {
        guard collections.contains(where: { $0.site == "twitter" }) else { return nil }
        let check = try await galleryDl.checkSession(session, accountName: accountName)
        guard check.connected else {
            if check.failureKind == .noAuthentication {
                throw GalleryDlError.authenticationRequired(session.browser)
            }
            throw GalleryDlError.scanFailed(check.message)
        }
        guard let identity = check.identity, identity.evidence == .serverVerified else { return nil }
        return identity.userID
    }

    private func persistCooldownIfNeeded(
        _ error: GalleryDlError,
        session: BrowserSession,
        ownerID: String? = nil
    ) throws {
        let ownerScopes = ownerID.map { [XWorkScope(ownerID: $0, session: session)] } ?? []
        let scopes = [XWorkScope(session: session)] + ownerScopes
        switch error {
        case .rateLimited(let retryAfter):
            let seconds = min(max(retryAfter ?? 15 * 60, 60), 6 * 60 * 60)
            let until = Date().addingTimeInterval(seconds)
            for scope in scopes {
                try XWorkCoordinator.setCooldown(scope: scope, until: until, reason: "an X rate limit")
            }
        case .securityChallenge:
            let until = Date().addingTimeInterval(30 * 60)
            for scope in scopes {
                try XWorkCoordinator.setCooldown(scope: scope, until: until, reason: "an X security check")
            }
        default:
            break
        }
    }

    private func scanBatchData(
        collections: [BuiltInCollection],
        accountName: String?,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection,
        limit: Int?,
        ownerID: String? = nil
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

        // A single invocation reuses gallery-dl's in-memory cookie cache across Likes and Bookmarks.
        // This avoids duplicate Keychain prompts and decrypting the same profile twice.
        let xCollections = selectedCollections.filter { $0.site == "twitter" }
        let xItems = xCollections.isEmpty ? [:] : try await galleryDl.scanCollections(
            xCollections, accountName: accountName, cookiesFromBrowser: cookiesFromBrowser,
            browserProfile: browserProfile, browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit)
        for collection in selectedCollections {
            let result: CollectionScanResult
            if let items = xItems[collection] {
                result = try await annotate(items, collection: collection, ownerID: ownerID)
            } else {
                result = try await scan(collection: collection, accountName: accountName,
                    cookiesFromBrowser: cookiesFromBrowser, mediaTypes: mediaTypes, limit: limit)
            }

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

        var result = CollectionBatchScanResult(collections: selectedCollections, items: items,
            scannedOccurrences: membershipItems.count)
        result.collectionItems = membershipItems
        result.diagnostics = await galleryDl.lastDiagnostics
        return CollectionBatchScanData(result: result, membershipItems: membershipItems)
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
        outputDirectory: URL?,
        session: BrowserSession,
        mediaTypes: MediaTypeSelection
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
            let outputPath: String
            do {
                outputPath = try await directDownloader.download(item: item, outputDirectory: destination)
            } catch DirectMediaDownloaderError.httpStatus(let status) where Self.shouldRefreshDirectMedia(status: status, refreshAttempts: 0) {
                // Direct media URLs are short-lived. Refresh only this source post once;
                // never re-list the entire Likes/Bookmarks collection for one expired URL.
                guard let refreshed = try await galleryDl.refreshItem(item, session: session, mediaTypes: mediaTypes) else {
                    throw DirectMediaDownloaderError.httpStatus(status)
                }
                outputPath = try await directDownloader.download(item: refreshed, outputDirectory: destination)
            }
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
