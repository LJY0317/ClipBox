import AppKit
import ClipBoxCore
import Combine
import Foundation
import OSLog

enum CollectionSourceMode: String, CaseIterable, Identifiable {
    case xCollections
    case youtubeLiked
    case youtubeWatchLater

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xCollections: "X Collections"
        case .youtubeLiked: "YouTube Liked Videos"
        case .youtubeWatchLater: "YouTube Watch Later"
        }
    }
}

@MainActor
final class CollectionViewModel: ObservableObject {
    private static let browserLogger = Logger(subsystem: "io.github.LJY0317.ClipBox", category: "BrowserSessions")
    @Published var selectedSource: CollectionSourceMode = .xCollections { didSet { persistScanSettings() } }
    @Published var xLikesEnabled = true { didSet { persistScanSettings() } }
    @Published var xBookmarksEnabled = true { didSet { persistScanSettings() } }
    @Published var browser: BrowserCookieSource = .chrome
    @Published var browserProfile = ""
    @Published var browserContainer = ""
    @Published var availableSessions: [BrowserSession] = []
    @Published private var profileLabels: [String: String] = [:]
    @Published var discoveryIssues: [BrowserSessionDiscoveryIssue] = []
    @Published var sessionChecks: [BrowserSessionCheck] = []
    @Published var rememberAccount = true
    private var workTask: Task<Void, Never>?
    private let sessionClient = GalleryDlClient()
    @Published var xAccountName = ""
    @Published var mediaTypes: MediaTypeSelection = .defaultSelection { didSet { persistScanSettings() } }
    @Published var scanLimit = 100 { didSet { persistScanSettings() } }
    @Published var scanAll = false { didSet { persistScanSettings() } }
    @Published var outputDirectory: URL
    @Published var scanResult: CollectionBatchScanResult?
    @Published var comparison: CollectionComparison?
    @Published var previewCollection: BuiltInCollection = .xLikes
    @Published var previewRowLimit = 50
    @Published var isPagedXPreview = false
    @Published var pagedPreviewHasMoreCollections: Set<BuiltInCollection> = []
    @Published var snapshotWarning: String?
    @Published var comparisonPostURL = ""
    var postComparisonMessage: String? {
        guard !comparisonPostURL.isEmpty, let snapshot = comparison?.current else { return nil }
        guard let url = URL(string: comparisonPostURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
              let status = url.pathComponents.firstIndex(of: "status"),
              url.pathComponents.indices.contains(status + 1),
              url.pathComponents[status + 1].allSatisfy(\.isNumber) else {
            return text("/status/와 게시물 번호가 포함된 X 게시물 주소를 붙여넣어 주세요.", "Paste an X post URL containing /status/ and its numeric ID.")
        }
        let matches = snapshot.entries.filter { $0.postID == url.pathComponents[status + 1] }
        if matches.isEmpty {
            return text(
                "이번 확인에서는 이 게시물을 찾지 못했습니다. 조회 범위 밖이거나, 미디어가 없거나, X가 이번 응답에 포함하지 않았을 수 있습니다.",
                "This post was not found in this scan. It may be outside the scan range, filtered, unavailable, or missing from the site's response."
            )
        }
        return matches.map {
            "\(collectionName($0.collection)) #\($0.position) · \(mediaTypeName($0.type)) · \($0.downloaded ? text("저장됨", "Archived") : text("새 항목", "Unarchived"))"
        }.joined(separator: "\n")
    }

    var observedRows: [CollectionObservation] {
        comparison?.current.entries.filter { $0.collection == previewCollection } ?? []
    }
    @Published var syncResult: CollectionBatchSyncResult?
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let service: CollectionSyncService?
    private let initializationError: Error?

    init() {
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        selectedSource = preferences.collectionSource.flatMap(CollectionSourceMode.init(rawValue:)) ?? .xCollections
        if let enabled = preferences.enabledXCollections {
            xLikesEnabled = enabled.contains(.xLikes)
            xBookmarksEnabled = enabled.contains(.xBookmarks)
        }
        mediaTypes = preferences.collectionMediaTypes ?? .defaultSelection
        scanAll = preferences.collectionScanAll ?? false
        scanLimit = min(1_000_000, max(1, preferences.collectionScanLimit ?? 100))
        outputDirectory = preferences.resolvedOutputDirectory
        xAccountName = preferences.xAccountHandle ?? ""
        let discovery = BrowserSessionDiscovery.report()
        let discovered = discovery.sessions
        availableSessions = discovered
        profileLabels = discovery.labels
        discoveryIssues = discovery.issues
        let safariIssueKinds = discovery.issues.filter { $0.browser == .safari }.map(\.kind.rawValue).joined(separator: ",")
        Self.browserLogger.info("Local Safari discovery stores=\(discovery.discoveredSafariStoreCount, privacy: .public) issues=\(safariIssueKinds, privacy: .public)")
        let initialSession = preferences.xBrowserSession ?? discovered.first ?? BrowserSession(browser: .chrome)
        browser = initialSession.browser
        browserProfile = initialSession.profile ?? ""
        browserContainer = initialSession.container ?? ""
        do {
            service = try CollectionSyncService()
            initializationError = nil
        } catch {
            service = nil
            initializationError = error
        }
    }

    private func persistScanSettings() {
        do {
            var preferences = try ClipBoxPreferencesStore.load()
            preferences.collectionScanAll = scanAll
            preferences.collectionScanLimit = scanLimit
            preferences.collectionSource = selectedSource.rawValue
            preferences.enabledXCollections = [.xLikes, .xBookmarks].filter { $0 == .xLikes ? xLikesEnabled : xBookmarksEnabled }
            preferences.collectionMediaTypes = mediaTypes
            try ClipBoxPreferencesStore.save(preferences)
        } catch { errorMessage = text("이 Mac에 조회 설정을 저장하지 못했습니다.", "Could not save scan settings on this Mac.") }
    }

    var effectiveLimit: Int? {
        if scanAll { return nil }
        if isXMode { return 50 }
        return max(1, scanLimit)
    }

    var currentPreviewHasMore: Bool {
        pagedPreviewHasMoreCollections.contains(previewCollection)
    }

    var currentPreviewPageResponses: Int {
        let key: String
        switch previewCollection {
        case .xLikes: key = "Likes"
        case .xBookmarks: key = "Bookmarks"
        default: return 0
        }
        return scanResult?.diagnostics?.first { $0.collection == key }?.pages ?? 0
    }

    var selectedCollections: [BuiltInCollection] {
        switch selectedSource {
        case .xCollections:
            var collections: [BuiltInCollection] = []
            if xLikesEnabled { collections.append(.xLikes) }
            if xBookmarksEnabled { collections.append(.xBookmarks) }
            return collections
        case .youtubeLiked:
            return [.youtubeLiked]
        case .youtubeWatchLater:
            return [.youtubeWatchLater]
        }
    }

    var isXMode: Bool {
        selectedSource == .xCollections
    }

    var requiresXAccountName: Bool {
        selectedCollections.contains(.xLikes)
    }

    var hasRequiredXAccountName: Bool {
        !requiresXAccountName || BuiltInCollection.normalizedAccountName(xAccountName) != nil
    }

    var hasSelectedCollections: Bool {
        !selectedCollections.isEmpty
    }

    var hasSelectedMediaTypes: Bool {
        !mediaTypes.isEmpty
    }

    var canRun: Bool {
        hasSelectedCollections && hasSelectedMediaTypes && hasRequiredXAccountName && !isWorking
    }

    var normalizedXAccountName: String {
        xAccountName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    func setSource(_ source: CollectionSourceMode) {
        selectedSource = source
        clearResults()
    }

    func isXCollectionEnabled(_ collection: BuiltInCollection) -> Bool {
        switch collection {
        case .xLikes: xLikesEnabled
        case .xBookmarks: xBookmarksEnabled
        case .youtubeLiked, .youtubeWatchLater: false
        }
    }

    func setXCollection(_ collection: BuiltInCollection, enabled: Bool) {
        switch collection {
        case .xLikes:
            xLikesEnabled = enabled
        case .xBookmarks:
            xBookmarksEnabled = enabled
        case .youtubeLiked, .youtubeWatchLater:
            return
        }
        clearResults()
    }

    func setXAccountName(_ value: String) {
        xAccountName = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        sessionChecks = []
        clearResults()
    }

    func isMediaTypeEnabled(_ type: MediaAssetType) -> Bool {
        mediaTypes.contains(type)
    }

    func setMediaType(_ type: MediaAssetType, enabled: Bool) {
        mediaTypes.set(type, enabled: enabled)
        clearResults()
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        var preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        preferences.outputDirectoryPath = url.path
        do {
            try ClipBoxPreferencesStore.save(preferences)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func preview() {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? text("모음 기능을 사용할 수 없습니다.", "Collection service is unavailable.")
            return
        }
        guard canRun else {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        errorMessage = nil
        syncResult = nil
        statusMessage = text("\(sourceName(selectedSource))을 확인하는 중…", "Reading \(selectedSource.displayName)…")
            + (scanAll ? text(" X의 요청 제한이 풀릴 때까지 잠시 기다릴 수 있으며 언제든 중지할 수 있습니다.", " Full scans may pause until X rate limits reset; you can stop at any time.") : "")

        let collections = selectedCollections
        let browser = browser
        let accountName = normalizedXAccountName
        let mediaTypes = mediaTypes
        let limit = effectiveLimit
        let session = selectedSession
        workTask = Task {
            do {
                let result: CollectionBatchScanResult
                if isXMode && !scanAll {
                    let page = try await service.beginPagedXPreview(
                        collections: collections,
                        accountName: accountName,
                        cookiesFromBrowser: browser,
                        browserProfile: session.profile,
                        browserContainer: session.container,
                        mediaTypes: mediaTypes,
                        pageSize: 50
                    )
                    result = page.result
                    isPagedXPreview = true
                    pagedPreviewHasMoreCollections = page.hasMoreCollections
                } else {
                    result = try await service.scan(
                        collections: collections,
                        accountName: accountName,
                        cookiesFromBrowser: browser,
                        browserProfile: isXMode ? session.profile : nil,
                        browserContainer: isXMode ? session.container : nil,
                        mediaTypes: mediaTypes,
                        limit: limit
                    )
                    isPagedXPreview = false
                    pagedPreviewHasMoreCollections = []
                }
                scanResult = result
                snapshotWarning = nil
                let snapshot = CollectionSnapshot(result: result, limit: limit, mediaTypes: mediaTypes)
                if isPagedXPreview {
                    comparison = CollectionComparison(current: snapshot, previousDate: nil,
                        added: snapshot.entries.count, notReturned: [])
                } else {
                    do {
                        comparison = try await CollectionSnapshotStore.shared.record(snapshot, session: session, handle: accountName)
                    } catch {
                        comparison = CollectionComparison(current: snapshot, previousDate: nil, added: snapshot.entries.count, notReturned: [])
                        snapshotWarning = text("미리보기는 완료했지만 이전 조회와 비교할 기록을 이 Mac에 저장하지 못했습니다.", "Scan succeeded, but local comparison history could not be saved.")
                    }
                }
                previewCollection = collections.first ?? .xLikes
                previewRowLimit = 50
                saveConnection(session)
                let executionNote = await service.lastExecutionNote
                statusMessage = scanSummary(result) + englishExecutionNote(executionNote)
            } catch is CancellationError {
                statusMessage = text("중지했습니다. 이미 완료된 다운로드 기록은 유지됩니다.", "Stopped. Completed downloads remain archived.")
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func loadNextXPreviewPage() {
        guard let service, isPagedXPreview, currentPreviewHasMore, !isWorking else { return }
        let collection = previewCollection
        let browser = browser
        let accountName = normalizedXAccountName
        let mediaTypes = mediaTypes
        let session = selectedSession
        isWorking = true
        errorMessage = nil
        statusMessage = text("\(collectionName(collection))의 다음 항목을 불러오는 중…", "Loading one more X page for \(collection.displayName)…")
        workTask = Task {
            do {
                let page = try await service.loadNextXPreviewPage(
                    collection: collection,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    browserProfile: session.profile,
                    browserContainer: session.container,
                    mediaTypes: mediaTypes,
                    pageSize: 50
                )
                scanResult = page.result
                pagedPreviewHasMoreCollections = page.hasMoreCollections
                let snapshot = CollectionSnapshot(result: page.result, limit: effectiveLimit, mediaTypes: mediaTypes)
                comparison = CollectionComparison(current: snapshot, previousDate: nil,
                    added: snapshot.entries.count, notReturned: [])
                let executionNote = await service.lastExecutionNote
                statusMessage = scanSummary(page.result) + englishExecutionNote(executionNote)
            } catch is CancellationError {
                statusMessage = text("중지했습니다.", "Stopped.")
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func thumbnailURL(for observation: CollectionObservation) -> URL? {
        guard let item = scanResult?.collectionItems?.first(where: {
            $0.collectionName == observation.collection.collectionName &&
            ($0.sourceID ?? $0.mediaID) == observation.postID &&
            $0.thumbnailURL != nil
        }), let value = item.thumbnailURL else { return nil }
        return URL(string: value)
    }

    func creatorHandle(for observation: CollectionObservation) -> String? {
        scanResult?.collectionItems?.first(where: {
            $0.collectionName == observation.collection.collectionName &&
            ($0.sourceID ?? $0.mediaID) == observation.postID
        })?.creator
    }

    func sync() {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? text("모음 기능을 사용할 수 없습니다.", "Collection service is unavailable.")
            return
        }
        guard canRun else {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = text("\(sourceName(selectedSource))에서 새 항목을 다운로드하는 중…", "Synchronizing \(selectedSource.displayName)…")
            + (scanAll ? text(" X의 요청 제한이 풀릴 때까지 잠시 기다릴 수 있으며 언제든 중지할 수 있습니다.", " Full scans may pause until X rate limits reset; you can stop at any time.") : "")

        let collections = selectedCollections
        let browser = browser
        let accountName = normalizedXAccountName
        let mediaTypes = mediaTypes
        let limit = effectiveLimit
        let outputDirectory = outputDirectory
        let session = selectedSession
        workTask = Task {
            do {
                let result: CollectionBatchSyncResult
                if isXMode && !scanAll,
                   let loaded = try await service.syncLoadedXPreview(
                    collections: collections,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    browserProfile: session.profile,
                    browserContainer: session.container,
                    outputDirectory: outputDirectory,
                    mediaTypes: mediaTypes
                   ) {
                    result = loaded
                } else {
                    result = try await service.sync(
                        collections: collections,
                        accountName: accountName,
                        cookiesFromBrowser: browser,
                        browserProfile: isXMode ? session.profile : nil,
                        browserContainer: isXMode ? session.container : nil,
                        outputDirectory: outputDirectory,
                        mediaTypes: mediaTypes,
                        limit: limit
                    )
                }
                syncResult = result
                scanResult = nil
                isPagedXPreview = false
                pagedPreviewHasMoreCollections = []
                saveConnection(session)
                let executionNote = await service.lastExecutionNote
                statusMessage = text(
                    "다운로드 \(result.downloaded)개 · 건너뜀 \(result.skippedAlreadyArchived)개 · 실패 \(result.failed)개 · 중복 \(result.duplicatesCollapsed)개 정리",
                    "Downloaded \(result.downloaded), skipped \(result.skippedAlreadyArchived), failed \(result.failed). \(result.duplicatesCollapsed) overlapping collection entries were merged."
                ) + englishExecutionNote(executionNote)
            } catch is CancellationError {
                statusMessage = text("중지했습니다. 이미 완료된 다운로드 기록은 유지됩니다.", "Stopped. Completed downloads remain archived.")
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    var selectedSession: BrowserSession {
        BrowserSession(browser: browser, profile: browserProfile, container: browserContainer)
    }

    func profileLabel(_ session: BrowserSession) -> String {
        profileLabels[session.id] ?? session.displayName
    }

    var profilesForBrowser: [BrowserSession] { availableSessions.filter { $0.browser == browser } }

    func setBrowser(_ value: BrowserCookieSource) {
        browser = value
        browserProfile = availableSessions.first { $0.browser == value }?.profile ?? ""
        browserContainer = ""
        sessionChecks = []
        clearResults()
    }

    func setBrowserProfile(_ value: String) {
        guard browserProfile != value else { return }
        browserProfile = value
        if browser != .firefox { browserContainer = "" }
        sessionChecks = []
        clearResults()
    }

    func setBrowserContainer(_ value: String) {
        guard browserContainer != value else { return }
        browserContainer = value
        sessionChecks = []
        clearResults()
    }

    func useSession(_ session: BrowserSession) {
        browser = session.browser
        browserProfile = session.profile ?? ""
        browserContainer = session.container ?? ""
        sessionChecks = []
        clearResults()
    }

    func openXLogin() {
        let identifiers: [BrowserCookieSource: String] = [
            .chrome: "com.google.Chrome", .firefox: "org.mozilla.firefox", .brave: "com.brave.Browser",
            .safari: "com.apple.Safari", .edge: "com.microsoft.edgemac", .chromium: "org.chromium.Chromium"
        ]
        guard let identifier = identifiers[browser],
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            errorMessage = text("선택한 브라우저가 설치되어 있지 않습니다. 다른 브라우저를 선택해 주세요.", "The selected browser is not installed. Choose another browser.")
            return
        }
        NSWorkspace.shared.open([URL(string: "https://x.com/i/bookmarks")!], withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration())
        statusMessage = text(
            "브라우저에서 X에 로그인한 뒤 ClipBox로 돌아와 ‘연결 확인’을 눌러 주세요.",
            "Sign in to X in the browser, return to ClipBox, then test the connection."
        )
    }

    func refreshSessions() {
        guard !isWorking else { return }
        let discovery = BrowserSessionDiscovery.report()
        availableSessions = discovery.sessions
        profileLabels = discovery.labels
        discoveryIssues = discovery.issues
        let safariIssueKinds = discovery.issues.filter { $0.browser == .safari }.map(\.kind.rawValue).joined(separator: ",")
        Self.browserLogger.info("Local Safari discovery refresh stores=\(discovery.discoveredSafariStoreCount, privacy: .public) issues=\(safariIssueKinds, privacy: .public)")
        if !availableSessions.contains(selectedSession), let replacement = availableSessions.first(where: { $0.browser == browser }) {
            browserProfile = replacement.profile ?? ""
            browserContainer = replacement.container ?? ""
        }
        sessionChecks = []
        statusMessage = text("브라우저 프로필을 새로고침했습니다.", "Browser profiles refreshed. No network request was sent to X.")
    }

    func testSessions(all: Bool = false) {
        guard !isWorking else { return }
        if all {
            refreshSessions()
            return
        }
        let sessions = [selectedSession]
        isWorking = true
        errorMessage = nil
        sessionChecks = []
        workTask = Task {
            do {
                for session in sessions {
                    try Task.checkCancellation()
                    statusMessage = text("연결을 확인하는 중…", "Testing \(session.displayName)…")
                    let result = try await sessionClient.checkSession(session,
                        accountName: BuiltInCollection.normalizedAccountName(xAccountName))
                    sessionChecks.append(result)
                    if result.connected { saveConnection(session) }
                }
                statusMessage = text(
                    "연결 확인이 끝났습니다. 브라우저에서 계정을 바꿨다면 다시 확인해 주세요.",
                    "Connection check complete. If you switch accounts in the browser, check again."
                )
            } catch is CancellationError { statusMessage = text("연결 확인을 중지했습니다.", "Connection check stopped.") }
            catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func cancel() {
        workTask?.cancel()
        statusMessage = text("중지하는 중… 이미 완료된 다운로드 기록은 유지됩니다.", "Stopping… Completed downloads remain archived.")
    }

    func forgetConnection() {
        var preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        preferences.xAccountHandle = nil
        preferences.xBrowserSession = nil
        do {
            try ClipBoxPreferencesStore.save(preferences)
            xAccountName = ""
            sessionChecks = []
            clearResults()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveConnection(_ session: BrowserSession) {
        guard isXMode else { return }
        var preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        preferences.xBrowserSession = session
        preferences.xAccountHandle = rememberAccount ? BuiltInCollection.normalizedAccountName(xAccountName) : nil
        do { try ClipBoxPreferencesStore.save(preferences) }
        catch { errorMessage = text("작업은 완료했지만 연결 설정을 이 Mac에 저장하지 못했습니다.", "The operation succeeded, but ClipBox could not save your connection preferences.") }
    }

    private var validationMessage: String {
        if !hasSelectedCollections {
            return text("좋아요나 북마크를 하나 이상 선택해 주세요.", "Select at least one X collection.")
        }
        if !hasSelectedMediaTypes {
            return text("미디어 종류를 하나 이상 선택해 주세요.", "Select at least one media type.")
        }
        if !hasRequiredXAccountName {
            return text("좋아요를 가져오려면 X 사용자 이름을 입력해 주세요.", "Enter your X handle (1–15 letters, digits or underscores), or turn Likes off.")
        }
        return text("다른 작업이 끝난 뒤 다시 시도해 주세요.", "Collection sync is unavailable while another operation is running.")
    }

    private func scanSummary(_ result: CollectionBatchScanResult) -> String {
        let overlap = result.duplicateOccurrencesCollapsed
        if overlap > 0 {
            return text(
                "미디어 \(result.uniqueMediaCount)개를 찾았습니다. 새 항목 \(result.unarchivedCount)개 · 중복 \(overlap)개 정리.",
                "Found \(result.uniqueMediaCount) unique media across \(result.scannedOccurrences) collection entries; \(overlap) overlapping entries were merged. \(result.unarchivedCount) are not in the downloaded archive."
            )
        }
        return text(
            "미디어 \(result.uniqueMediaCount)개를 찾았습니다. 새 항목 \(result.unarchivedCount)개.",
            "Found \(result.uniqueMediaCount) unique media; \(result.unarchivedCount) are not in the downloaded archive."
        )
    }

    private func text(_ korean: String, _ english: String) -> String {
        AppLanguageStore.shared.text(korean, english)
    }

    private func englishExecutionNote(_ note: String) -> String {
        AppLanguageStore.shared.language == .english && !note.isEmpty ? " \(note)" : ""
    }

    private func sourceName(_ source: CollectionSourceMode) -> String {
        switch source {
        case .xCollections: text("X 좋아요 · 북마크", "X Collections")
        case .youtubeLiked: text("YouTube 좋아요 표시한 동영상", "YouTube Liked Videos")
        case .youtubeWatchLater: text("YouTube 나중에 볼 동영상", "YouTube Watch Later")
        }
    }

    private func collectionName(_ collection: BuiltInCollection) -> String {
        switch collection {
        case .xLikes: text("X 좋아요", "X Likes")
        case .xBookmarks: text("X 북마크", "X Bookmarks")
        case .youtubeLiked: text("YouTube 좋아요", "YouTube Likes")
        case .youtubeWatchLater: text("YouTube 나중에 볼 동영상", "YouTube Watch Later")
        }
    }

    private func mediaTypeName(_ type: MediaAssetType) -> String {
        switch type {
        case .video: text("동영상", "Video")
        case .photo: text("사진", "Photo")
        case .animated: text("움직이는 미디어", "Animated media")
        }
    }

    private func clearResults() {
        scanResult = nil
        comparison = nil
        isPagedXPreview = false
        pagedPreviewHasMoreCollections = []
        snapshotWarning = nil
        syncResult = nil
        statusMessage = ""
        errorMessage = nil
    }
}
