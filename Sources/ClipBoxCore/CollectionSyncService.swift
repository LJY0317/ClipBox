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

    mutating func clear() {
        plan = nil
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
    let createdAt: Date
    let collections: [BuiltInCollection]
    let accountName: String?
    let session: BrowserSession
    let mediaTypes: MediaTypeSelection
    let ownerID: String?
    var rawItems: [BuiltInCollection: [CollectionItem]]
    var continuations: [BuiltInCollection: String]
    var diagnostics: [CollectionDiagnostic]
}

public enum CollectionPreviewError: LocalizedError, Sendable {
    case expired

    public var errorDescription: String? {
        switch self {
        case .expired:
            "The X Preview expired. Start a new Preview so ClipBox can download the same set of items you review."
        }
    }
}

public actor CollectionSyncService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient
    private let galleryDl: GalleryDlClient
    private let directDownloader: DirectMediaDownloader
    private let downloadService: ClipBoxService
    private var planCache = CollectionExecutionPlanCache()
    private var xPreviewPaging: XPreviewPagingState?
    private let xPreviewLifetime: TimeInterval
    private let coordinationDirectory: URL?
    public private(set) var lastExecutionNote: String = ""

    static func shouldRefreshDirectMedia(status: Int, refreshAttempts: Int) -> Bool {
        refreshAttempts == 0 && [401, 403, 404].contains(status)
    }

    public init(
        archive: ArchiveStore? = nil,
        ytDlp: YtDlpClient? = nil,
        galleryDl: GalleryDlClient? = nil,
        directDownloader: DirectMediaDownloader? = nil,
        xPreviewLifetime: TimeInterval = 10 * 60,
        xWorkDirectory: URL? = nil
    ) throws {
        let resolvedArchive = try archive ?? ArchiveStore()
        let resolvedYtDlp = ytDlp ?? YtDlpClient()
        self.archive = resolvedArchive
        self.ytDlp = resolvedYtDlp
        self.galleryDl = galleryDl ?? GalleryDlClient()
        self.directDownloader = directDownloader ?? DirectMediaDownloader()
        self.xPreviewLifetime = xPreviewLifetime
        self.coordinationDirectory = xWorkDirectory
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
        if ["twitter", "instagram"].contains(collection.site) {
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
        return try await scanStandaloneCollection(
            collection,
            accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser,
            browserProfile: browserProfile,
            browserContainer: browserContainer,
            mediaTypes: mediaTypes,
            limit: limit
        )
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
        dryRun: Bool = false,
        progress: CollectionSyncProgressHandler? = nil
    ) async throws -> CollectionSyncResult {
        if ["twitter", "instagram"].contains(collection.site) {
            let batch = try await sync(collections: [collection], accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, outputDirectory: outputDirectory,
                mediaTypes: mediaTypes, limit: limit, dryRun: dryRun, progress: progress)
            return CollectionSyncResult(collection: collection, scanned: batch.uniqueMedia,
                unarchived: batch.unarchived, downloaded: batch.downloaded,
                skippedAlreadyArchived: batch.skippedAlreadyArchived, failed: batch.failed,
                attempted: batch.attempted, remaining: batch.remaining,
                stoppedReason: batch.stoppedReason,
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
        let instagramSelected = collections.contains { $0.site == "instagram" }
        let xLease = try xSelected ? acquireXWork(scope: XWorkScope(session: session)) : nil
        let instagramLease = try instagramSelected
            ? acquireCollectionWork(scope: CollectionWorkScope(site: "instagram", session: session))
            : nil
        _ = (xLease, instagramLease)
        var ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
            let ownerLease = try ownerID.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
            _ = ownerLease
            let data = try await scanBatchData(collections: collections, accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
            if isReusableGallerySelection(collections) {
                let context = executionContext(collections: collections, accountName: accountName, session: session,
                    mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
                planCache.store(context: context, data: data)
                lastExecutionNote = "Fresh collection lookup completed. Sync can reuse this in-memory result for 10 minutes if the browser session and settings stay unchanged."
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
        dryRun: Bool = false,
        progress: CollectionSyncProgressHandler? = nil
    ) async throws -> CollectionBatchSyncResult {
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let xSelected = collections.contains { $0.site == "twitter" }
        let instagramSelected = collections.contains { $0.site == "instagram" }
        let xLease = try xSelected ? acquireXWork(scope: XWorkScope(session: session)) : nil
        let instagramLease = try instagramSelected
            ? acquireCollectionWork(scope: CollectionWorkScope(site: "instagram", session: session))
            : nil
        _ = (xLease, instagramLease)
        let ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
        } catch let error as GalleryDlError {
            try persistCooldownIfNeeded(error, session: session, ownerID: nil)
            throw error
        }
        let ownerLease = try ownerID.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease
        if xSelected, !dryRun, ownerID == nil {
            throw GalleryDlError.scanFailed(
                "X account identity could not be server-verified, so ClipBox made no membership or download changes. Test the selected browser session and try again."
            )
        }
        if !collections.isEmpty, collections.allSatisfy({ $0.site == "twitter" }), limit == nil, !dryRun {
            return try await syncAllXPages(
                collections: collections, accountName: accountName,
                cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                browserContainer: browserContainer, outputDirectory: outputDirectory,
                mediaTypes: mediaTypes, ownerID: ownerID, session: session,
                progress: progress
            )
        }
        let context = executionContext(collections: collections, accountName: accountName, session: session,
            mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
        let scanData: CollectionBatchScanData
        let reusableGallerySelection = isReusableGallerySelection(collections)
        if reusableGallerySelection, let reusable = planCache.reusableData(context: context) {
            scanData = reusable
            lastExecutionNote = "Reused the recent Preview execution plan; the authenticated collection was not listed again."
        } else {
            do {
                scanData = try await scanBatchData(collections: collections, accountName: accountName,
                    cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
                    browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit, ownerID: ownerID)
            } catch let error as GalleryDlError {
                try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                throw error
            }
            if reusableGallerySelection {
                planCache.store(context: context, data: scanData)
                lastExecutionNote = "Collection list was queried because there was no matching, unexpired Preview plan."
            }
        }
        let result = try await syncBatchData(scanData, ownerID: xSelected ? ownerID : nil,
            session: session, cookiesFromBrowser: cookiesFromBrowser,
            outputDirectory: outputDirectory, mediaTypes: mediaTypes, dryRun: dryRun,
            progress: progress)
        if reusableGallerySelection, !dryRun {
            // A successful/partial Sync consumes the list plan. A later Sync must query
            // the source again so newly saved items are visible; only an explicit
            // Preview→Sync handoff reuses the already-loaded list.
            planCache.clear()
        }
        return result
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
        let sessionLease = try acquireXWork(scope: XWorkScope(session: session))
        _ = sessionLease
        var ownerID: String?
        do {
            ownerID = try await verifiedOwnerIDIfNeeded(collections: selected, accountName: accountName, session: session)
            let ownerLease = try ownerID.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
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
                createdAt: Date(),
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
              Date().timeIntervalSince(state.createdAt) <= xPreviewLifetime,
              state.collections.contains(collection),
              state.accountName == normalizedAccount,
              state.session == session,
              state.mediaTypes == mediaTypes else {
            xPreviewPaging = nil
            throw YtDlpError.inspectionFailed("The paged Preview expired or its settings changed. Start a new Preview before loading another page.")
        }
        guard let cursor = state.continuations[collection] else {
            let data = try await pagedBatchData(collections: state.collections, rawItems: state.rawItems,
                ownerID: state.ownerID, diagnostics: state.diagnostics)
            return CollectionPagedPreview(result: data.result, hasMoreCollections: Set(state.continuations.keys))
        }

        let sessionLease = try acquireXWork(scope: XWorkScope(session: session))
        _ = sessionLease
        let ownerLease = try state.ownerID.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
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
        mediaTypes: MediaTypeSelection = .defaultSelection,
        progress: CollectionSyncProgressHandler? = nil
    ) async throws -> CollectionBatchSyncResult? {
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let normalizedAccount = BuiltInCollection.normalizedAccountName(accountName)
        guard let state = xPreviewPaging else { return nil }
        guard Date().timeIntervalSince(state.createdAt) <= xPreviewLifetime else {
            xPreviewPaging = nil
            throw CollectionPreviewError.expired
        }
        guard state.collections == collections,
              state.accountName == normalizedAccount,
              state.session == session,
              state.mediaTypes == mediaTypes else {
            xPreviewPaging = nil
            return nil
        }

        let sessionLease = try acquireXWork(scope: XWorkScope(session: session))
        _ = sessionLease
        let verifiedOwner = try await verifiedOwnerIDIfNeeded(collections: collections, accountName: accountName, session: session)
        guard verifiedOwner == state.ownerID, verifiedOwner != nil else {
            throw GalleryDlError.scanFailed("The X account changed since Preview. Start a new Preview before syncing.")
        }
        let ownerLease = try verifiedOwner.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease
        let freshData = try await pagedBatchData(collections: state.collections, rawItems: state.rawItems,
            ownerID: verifiedOwner, diagnostics: state.diagnostics)
        // A loaded Preview is a one-shot execution plan. Consuming it prevents a later
        // Sync with the same settings from silently reusing an old X list after new saves arrive.
        xPreviewPaging = nil
        lastExecutionNote = "Reused the X pages already loaded in Preview; no Likes/Bookmarks list was queried again."
        return try await syncBatchData(freshData, ownerID: verifiedOwner, session: session,
            cookiesFromBrowser: cookiesFromBrowser, outputDirectory: outputDirectory,
            mediaTypes: mediaTypes, dryRun: false, progress: progress)
    }

    public func invalidateLoadedXPreview() {
        xPreviewPaging = nil
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
        dryRun: Bool,
        progress: CollectionSyncProgressHandler? = nil
    ) async throws -> CollectionBatchSyncResult {
        let scanResult = scanData.result
        var candidates: [CollectionBatchScanItem] = []
        for item in scanResult.items {
            if try await currentlyDownloaded(item.item) { continue }
            candidates.append(item)
        }
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
        // Save only stable post metadata before beginning a page. If the app quits,
        // the next full X sync can refresh these posts and finish them without first
        // walking back through the rest of the history. Direct media URLs are never
        // written to the archive.
        for candidate in candidates where candidate.item.site == "twitter" && candidate.item.directMediaURL != nil {
            try await archive.record(
                media: mediaMetadata(from: candidate.item),
                collection: candidate.item.collectionName,
                status: .discovered
            )
        }
        var downloaded = 0
        var skipped = initiallyArchived
        var attempted = 0
        var remaining = 0
        var stoppedReason: String?
        var failures: [CollectionSyncFailure] = []
        await progress?(CollectionSyncProgress(stage: .downloading, totalItems: candidates.count,
            skippedAlreadyArchived: skipped))
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                remaining = candidates.count - index
                stoppedReason = "Cancelled"
                break
            }
            if try await currentlyDownloaded(candidate.item) {
                skipped += 1
                await progress?(CollectionSyncProgress(stage: .downloading,
                    completedItems: index + 1, totalItems: candidates.count,
                    downloaded: downloaded, skippedAlreadyArchived: skipped, failed: failures.count))
                continue
            }
            attempted += 1
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
                remaining = candidates.count - index
                stoppedReason = "Cancelled"
                break
            } catch let error as GalleryDlError where Self.shouldStopXRequests(after: error) {
                try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                failures.append(syncFailure(for: candidate.item, error: error))
                remaining = candidates.count - index - 1
                stoppedReason = error.localizedDescription
                break
            } catch {
                failures.append(syncFailure(for: candidate.item, error: error))
            }
            await progress?(CollectionSyncProgress(stage: .downloading,
                completedItems: index + 1, totalItems: candidates.count,
                downloaded: downloaded, skippedAlreadyArchived: skipped, failed: failures.count))
        }
        let result = CollectionBatchSyncResult(collections: scanResult.collections,
            scannedOccurrences: scanResult.scannedOccurrences,
            uniqueMedia: scanResult.uniqueMediaCount,
            duplicatesCollapsed: scanResult.duplicateOccurrencesCollapsed,
            unarchived: candidates.count, downloaded: downloaded,
            skippedAlreadyArchived: skipped, failed: failures.count,
            attempted: attempted, remaining: remaining, stoppedReason: stoppedReason,
            dryRun: false, failures: failures)
        await progress?(CollectionSyncProgress(stage: stoppedReason == nil ? .completed : .stopped,
            completedItems: candidates.count - remaining, totalItems: candidates.count,
            downloaded: downloaded, skippedAlreadyArchived: skipped, failed: failures.count,
            message: stoppedReason))
        return result
    }

    private func currentlyDownloaded(_ item: CollectionItem) async throws -> Bool {
        if try await archive.downloaded(identity: item.archiveIdentity) { return true }
        guard item.directMediaURL == nil, let sourceID = item.sourceID, !sourceID.isEmpty else { return false }
        return try await archive.downloaded(site: item.site, sourceID: sourceID)
    }

    private func syncFailure(for item: CollectionItem, error: Error) -> CollectionSyncFailure {
        CollectionSyncFailure(site: item.site, mediaID: item.mediaID, title: item.title,
            sourceURL: item.sourceURL, collectionName: item.collectionName, mediaType: item.mediaType,
            error: error.localizedDescription)
    }

    private static func shouldStopXRequests(after error: GalleryDlError) -> Bool {
        switch error {
        case .rateLimited, .securityChallenge: true
        default: false
        }
    }

    private func syncAllXPages(
        collections: [BuiltInCollection],
        accountName: String?,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String?,
        browserContainer: String?,
        outputDirectory: URL?,
        mediaTypes: MediaTypeSelection,
        ownerID: String?,
        session: BrowserSession,
        progress: CollectionSyncProgressHandler?
    ) async throws -> CollectionBatchSyncResult {
        var selected: [BuiltInCollection] = []
        for collection in collections where collection.site == "twitter" && !selected.contains(collection) {
            selected.append(collection)
        }
        var active = selected
        var continuations: [BuiltInCollection: String] = [:]
        var scannedOccurrences = 0
        var seen = Set<ArchiveIdentity>()
        var downloaded = 0
        var skipped = 0
        var unarchived = 0
        var attempted = 0
        var remaining = 0
        var failures: [CollectionSyncFailure] = []
        var stoppedReason: String?
        var pageNumber = 0

        let resumed = try await resumePendingXMedia(
            collections: selected, ownerID: ownerID, session: session,
            outputDirectory: outputDirectory, mediaTypes: mediaTypes, progress: progress
        )
        downloaded += resumed.downloaded
        skipped += resumed.skippedAlreadyArchived
        unarchived += resumed.unarchived
        attempted += resumed.attempted
        remaining += resumed.remaining
        failures.append(contentsOf: resumed.failures)
        if let reason = resumed.stoppedReason {
            lastExecutionNote = "Pending X items were resumed before listing new pages, then the resume stopped: \(reason)"
            return CollectionBatchSyncResult(collections: selected,
                scannedOccurrences: resumed.scannedOccurrences, uniqueMedia: resumed.uniqueMedia,
                duplicatesCollapsed: 0, unarchived: unarchived, downloaded: downloaded,
                skippedAlreadyArchived: skipped, failed: failures.count,
                attempted: attempted, remaining: remaining, stoppedReason: reason,
                dryRun: false, failures: failures)
        }

        while !active.isEmpty {
            if Task.isCancelled {
                stoppedReason = "Cancelled"
                break
            }
            pageNumber += 1
            await progress?(CollectionSyncProgress(stage: .listing, completedItems: scannedOccurrences,
                downloaded: downloaded, skippedAlreadyArchived: skipped, failed: failures.count,
                message: "Loading X page \(pageNumber)"))

            let page: XCollectionPageResult
            do {
                page = try await galleryDl.scanCollectionPage(
                    active, accountName: accountName, cookiesFromBrowser: cookiesFromBrowser,
                    browserProfile: browserProfile, browserContainer: browserContainer,
                    mediaTypes: mediaTypes, continuations: continuations, pageSize: 50,
                    expectedOwnerID: ownerID
                )
            } catch is CancellationError {
                stoppedReason = "Cancelled"
                break
            } catch let error as GalleryDlError {
                if Self.shouldStopXRequests(after: error) {
                    try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                } else if scannedOccurrences == 0 {
                    throw error
                }
                stoppedReason = error.localizedDescription
                break
            }

            let data = try await pagedBatchData(collections: active, rawItems: page.items,
                ownerID: ownerID, diagnostics: page.diagnostics)
            scannedOccurrences += data.result.scannedOccurrences
            for item in data.result.items { seen.insert(item.item.archiveIdentity) }

            let batch = try await syncBatchData(data, ownerID: ownerID, session: session,
                cookiesFromBrowser: cookiesFromBrowser, outputDirectory: outputDirectory,
                mediaTypes: mediaTypes, dryRun: false, progress: progress)
            downloaded += batch.downloaded
            skipped += batch.skippedAlreadyArchived
            unarchived += batch.unarchived
            attempted += batch.attempted
            remaining += batch.remaining
            failures.append(contentsOf: batch.failures)
            if let reason = batch.stoppedReason {
                stoppedReason = reason
                break
            }

            continuations = page.continuations
            active = selected.filter { continuations[$0] != nil }
        }

        let result = CollectionBatchSyncResult(collections: selected,
            scannedOccurrences: scannedOccurrences, uniqueMedia: seen.count,
            duplicatesCollapsed: max(0, scannedOccurrences - seen.count),
            unarchived: unarchived, downloaded: downloaded,
            skippedAlreadyArchived: skipped, failed: failures.count,
            attempted: attempted, remaining: remaining, stoppedReason: stoppedReason,
            dryRun: false, failures: failures)
        lastExecutionNote = stoppedReason == nil
            ? "X history was processed page by page; downloads were archived before the next page was requested."
            : "X history stopped after completed pages were archived. A later run starts from the newest page and safely skips completed media while walking back to older items."
        await progress?(CollectionSyncProgress(stage: stoppedReason == nil ? .completed : .stopped,
            completedItems: attempted + skipped, downloaded: downloaded,
            skippedAlreadyArchived: skipped, failed: failures.count, message: stoppedReason))
        return result
    }

    private func resumePendingXMedia(
        collections: [BuiltInCollection],
        ownerID: String?,
        session: BrowserSession,
        outputDirectory: URL?,
        mediaTypes: MediaTypeSelection,
        progress: CollectionSyncProgressHandler?
    ) async throws -> CollectionBatchSyncResult {
        guard let ownerID else {
            return CollectionBatchSyncResult(collections: collections, scannedOccurrences: 0, uniqueMedia: 0,
                duplicatesCollapsed: 0, unarchived: 0, downloaded: 0, skippedAlreadyArchived: 0,
                failed: 0, dryRun: false, failures: [])
        }
        let records = try await archive.pendingCollectionMedia(
            site: "twitter", ownerID: ownerID, collectionNames: collections.map(\.collectionName)
        )
        guard !records.isEmpty else {
            return CollectionBatchSyncResult(collections: collections, scannedOccurrences: 0, uniqueMedia: 0,
                duplicatesCollapsed: 0, unarchived: 0, downloaded: 0, skippedAlreadyArchived: 0,
                failed: 0, dryRun: false, failures: [])
        }

        var downloaded = 0
        var skipped = 0
        var attempted = 0
        var remaining = 0
        var failures: [CollectionSyncFailure] = []
        var stoppedReason: String?
        await progress?(CollectionSyncProgress(stage: .downloading, totalItems: records.count,
            message: "Resuming \(records.count) pending X item(s)"))

        for (index, record) in records.enumerated() {
            if Task.isCancelled {
                remaining = records.count - index
                stoppedReason = "Cancelled"
                break
            }
            guard let sourceURL = record.sourceURL, let collection = record.collection else {
                continue
            }
            let item = CollectionItem(site: record.site, collectionName: collection, mediaID: record.mediaID,
                sourceID: record.sourceID, sourceURL: sourceURL, title: record.title, creator: record.creator,
                mediaType: .video)
            if try await currentlyDownloaded(item) {
                skipped += 1
                continue
            }
            attempted += 1
            do {
                guard let refreshed = try await galleryDl.refreshItem(item, session: session, mediaTypes: .all) else {
                    throw GalleryDlError.scanFailed("The original X post no longer returned this media item.")
                }
                try await downloadDirectCollectionItem(refreshed, outputDirectory: outputDirectory,
                    session: session, mediaTypes: mediaTypes)
                downloaded += 1
            } catch is CancellationError {
                remaining = records.count - index
                stoppedReason = "Cancelled"
                break
            } catch let error as GalleryDlError where Self.shouldStopXRequests(after: error) {
                try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                remaining = records.count - index - 1
                stoppedReason = error.localizedDescription
                failures.append(syncFailure(for: item, error: error))
                break
            } catch {
                failures.append(syncFailure(for: item, error: error))
            }
            await progress?(CollectionSyncProgress(stage: .downloading, completedItems: index + 1,
                totalItems: records.count, downloaded: downloaded, skippedAlreadyArchived: skipped,
                failed: failures.count))
        }
        return CollectionBatchSyncResult(collections: collections, scannedOccurrences: records.count,
            uniqueMedia: records.count, duplicatesCollapsed: 0, unarchived: records.count,
            downloaded: downloaded, skippedAlreadyArchived: skipped, failed: failures.count,
            attempted: attempted, remaining: remaining, stoppedReason: stoppedReason,
            dryRun: false, failures: failures)
    }

    public func retryFailures(
        _ inputFailures: [CollectionSyncFailure],
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        outputDirectory: URL? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        progress: CollectionSyncProgressHandler? = nil
    ) async throws -> CollectionBatchSyncResult {
        var failuresToRetry: [CollectionSyncFailure] = []
        var seenFailures = Set<String>()
        for failure in inputFailures where seenFailures.insert(failure.id).inserted {
            failuresToRetry.append(failure)
        }
        let session = BrowserSession(browser: cookiesFromBrowser, profile: browserProfile, container: browserContainer)
        let xFailures = failuresToRetry.filter { $0.site == "twitter" }
        let xCollections = xFailures.compactMap { failure in
            failure.collectionName.flatMap { BuiltInCollection.resolve(site: "twitter", collection: $0) }
        }
        let sessionLease = try xFailures.isEmpty ? nil : acquireXWork(scope: XWorkScope(session: session))
        _ = sessionLease
        let ownerID = try xFailures.isEmpty ? nil : await verifiedOwnerIDIfNeeded(
            collections: xCollections.isEmpty ? [.xBookmarks] : xCollections,
            accountName: accountName, session: session
        )
        if !xFailures.isEmpty, ownerID == nil {
            throw GalleryDlError.scanFailed("X account identity could not be server-verified, so failed X items were not retried.")
        }
        let ownerLease = try ownerID.map { try acquireXWork(scope: XWorkScope(ownerID: $0, session: session)) }
        _ = ownerLease

        var downloaded = 0
        var skipped = 0
        var attempted = 0
        var remaining = 0
        var retryFailures: [CollectionSyncFailure] = []
        var stoppedReason: String?
        var unarchived = 0

        for failure in failuresToRetry {
            guard let sourceURL = failure.sourceURL, !sourceURL.isEmpty else { continue }
            let item = CollectionItem(site: failure.site,
                collectionName: failure.collectionName ?? "retry",
                mediaID: failure.mediaID, sourceURL: sourceURL,
                title: failure.title, mediaType: failure.mediaType ?? .video)
            if try await currentlyDownloaded(item) { skipped += 1 } else { unarchived += 1 }
        }

        await progress?(CollectionSyncProgress(stage: .downloading, totalItems: failuresToRetry.count,
            skippedAlreadyArchived: skipped))
        for (index, failure) in failuresToRetry.enumerated() {
            if Task.isCancelled {
                remaining = failuresToRetry.count - index
                stoppedReason = "Cancelled"
                retryFailures.append(contentsOf: failuresToRetry[index...])
                break
            }
            guard let sourceURL = failure.sourceURL, !sourceURL.isEmpty else {
                retryFailures.append(CollectionSyncFailure(site: failure.site, mediaID: failure.mediaID,
                    title: failure.title, sourceURL: failure.sourceURL, collectionName: failure.collectionName,
                    mediaType: failure.mediaType, error: "Original source URL is unavailable for retry."))
                continue
            }
            let stub = CollectionItem(site: failure.site,
                collectionName: failure.collectionName ?? "retry", mediaID: failure.mediaID,
                sourceURL: sourceURL, title: failure.title, mediaType: failure.mediaType ?? .video)
            if try await currentlyDownloaded(stub) {
                await progress?(CollectionSyncProgress(stage: .downloading,
                    completedItems: index + 1, totalItems: failuresToRetry.count,
                    downloaded: downloaded, skippedAlreadyArchived: skipped, failed: retryFailures.count))
                continue
            }
            attempted += 1
            do {
                if failure.site == "twitter" || failure.site == "instagram" {
                    guard let refreshed = try await galleryDl.refreshItem(stub, session: session, mediaTypes: mediaTypes) else {
                        let serviceName = failure.site == "instagram" ? "Instagram" : "X"
                        throw GalleryDlError.scanFailed("The original \(serviceName) post no longer returned this media item.")
                    }
                    try await downloadDirectCollectionItem(refreshed, outputDirectory: outputDirectory,
                        session: session, mediaTypes: mediaTypes)
                    downloaded += 1
                } else {
                    let outcome = try await downloadService.download(url: sourceURL,
                        outputDirectory: outputDirectory, cookiesFromBrowser: cookiesFromBrowser)
                    switch outcome {
                    case .downloaded: downloaded += 1
                    case .skippedAlreadyArchived: skipped += 1
                    }
                }
            } catch is CancellationError {
                remaining = failuresToRetry.count - index
                stoppedReason = "Cancelled"
                retryFailures.append(contentsOf: failuresToRetry[index...])
                break
            } catch let error as GalleryDlError where Self.shouldStopXRequests(after: error) {
                try persistCooldownIfNeeded(error, session: session, ownerID: ownerID)
                retryFailures.append(syncFailure(for: stub, error: error))
                remaining = failuresToRetry.count - index - 1
                stoppedReason = error.localizedDescription
                if index + 1 < failuresToRetry.count {
                    retryFailures.append(contentsOf: failuresToRetry[(index + 1)...])
                }
                break
            } catch {
                retryFailures.append(syncFailure(for: stub, error: error))
            }
            await progress?(CollectionSyncProgress(stage: .downloading,
                completedItems: index + 1, totalItems: failuresToRetry.count,
                downloaded: downloaded, skippedAlreadyArchived: skipped, failed: retryFailures.count))
        }

        let collections = Array(Set(failuresToRetry.compactMap { failure in
            failure.collectionName.flatMap { BuiltInCollection.resolve(site: failure.site, collection: $0) }
        })).sorted { $0.rawValue < $1.rawValue }
        let result = CollectionBatchSyncResult(collections: collections,
            scannedOccurrences: failuresToRetry.count, uniqueMedia: failuresToRetry.count,
            duplicatesCollapsed: 0, unarchived: unarchived, downloaded: downloaded,
            skippedAlreadyArchived: skipped, failed: retryFailures.count,
            attempted: attempted, remaining: remaining, stoppedReason: stoppedReason,
            dryRun: false, failures: retryFailures)
        await progress?(CollectionSyncProgress(stage: stoppedReason == nil ? .completed : .stopped,
            completedItems: failuresToRetry.count - remaining, totalItems: failuresToRetry.count,
            downloaded: downloaded, skippedAlreadyArchived: skipped, failed: retryFailures.count,
            message: stoppedReason))
        return result
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

    private func isReusableGallerySelection(_ collections: [BuiltInCollection]) -> Bool {
        !collections.isEmpty && collections.allSatisfy { collection in
            collection.site == "twitter" || collection.site == "instagram"
        }
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
                try setXCooldown(scope: scope, until: until, reason: "an X rate limit")
            }
        case .securityChallenge:
            let until = Date().addingTimeInterval(30 * 60)
            for scope in scopes {
                try setXCooldown(scope: scope, until: until, reason: "an X security check")
            }
        default:
            break
        }
    }

    private func acquireXWork(scope: XWorkScope) throws -> XWorkLease {
        if let coordinationDirectory {
            return try XWorkCoordinator.acquire(scope: scope, directory: coordinationDirectory)
        }
        return try XWorkCoordinator.acquire(scope: scope)
    }

    private func acquireCollectionWork(scope: CollectionWorkScope) throws -> CollectionWorkLease {
        if let coordinationDirectory {
            return try CollectionWorkCoordinator.acquire(scope: scope, directory: coordinationDirectory)
        }
        return try CollectionWorkCoordinator.acquire(scope: scope)
    }

    private func setXCooldown(scope: XWorkScope, until: Date, reason: String) throws {
        if let coordinationDirectory {
            try XWorkCoordinator.setCooldown(scope: scope, until: until, reason: reason, directory: coordinationDirectory)
        } else {
            try XWorkCoordinator.setCooldown(scope: scope, until: until, reason: reason)
        }
    }

    private func scanStandaloneCollection(
        _ collection: BuiltInCollection,
        accountName: String?,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String?,
        browserContainer: String?,
        mediaTypes: MediaTypeSelection,
        limit: Int?
    ) async throws -> CollectionScanResult {
        let items: [CollectionItem]
        switch collection.site {
        case "youtube":
            items = try await ytDlp.scanCollection(
                collection,
                cookiesFromBrowser: cookiesFromBrowser,
                limit: limit
            ).filter { mediaTypes.contains($0.mediaType) }
        case "instagram":
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
            throw YtDlpError.inspectionFailed("No standalone collection scanner is configured for \(collection.site)")
        }
        return try await annotate(items, collection: collection)
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
                result = try await scanStandaloneCollection(
                    collection,
                    accountName: accountName,
                    cookiesFromBrowser: cookiesFromBrowser,
                    browserProfile: browserProfile,
                    browserContainer: browserContainer,
                    mediaTypes: mediaTypes,
                    limit: limit
                )
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
        } catch is CancellationError {
            // A cancelled transfer has no usable output. Keep it eligible for the
            // failure-retry flow instead of marking a durable failure in the archive.
            try? await archive.record(
                media: metadata,
                collection: item.collectionName,
                status: .discovered
            )
            throw CancellationError()
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
