import ClipBoxCore
import Combine
import Foundation

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
    @Published var selectedSource: CollectionSourceMode = .xCollections
    @Published var xLikesEnabled = true
    @Published var xBookmarksEnabled = true
    @Published var browser: BrowserCookieSource = .safari
    @Published var xAccountName = ""
    @Published var mediaTypes: MediaTypeSelection = .defaultSelection
    @Published var scanLimit = 100
    @Published var scanAll = false
    @Published var outputDirectory: URL
    @Published var scanResult: CollectionBatchScanResult?
    @Published var syncResult: CollectionBatchSyncResult?
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let service: CollectionSyncService?
    private let initializationError: Error?

    init() {
        outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
        do {
            service = try CollectionSyncService()
            initializationError = nil
        } catch {
            service = nil
            initializationError = error
        }
    }

    var effectiveLimit: Int? {
        scanAll ? nil : max(1, scanLimit)
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
        !requiresXAccountName || !normalizedXAccountName.isEmpty
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
            errorMessage = initializationError?.localizedDescription ?? "Collection service is unavailable."
            return
        }
        guard canRun else {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        errorMessage = nil
        syncResult = nil
        statusMessage = "Reading \(selectedSource.displayName)…"

        let collections = selectedCollections
        let browser = browser
        let accountName = normalizedXAccountName
        let mediaTypes = mediaTypes
        let limit = effectiveLimit
        Task {
            do {
                let result = try await service.scan(
                    collections: collections,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    mediaTypes: mediaTypes,
                    limit: limit
                )
                scanResult = result
                statusMessage = scanSummary(result)
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func sync() {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? "Collection service is unavailable."
            return
        }
        guard canRun else {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = "Synchronizing \(selectedSource.displayName)…"

        let collections = selectedCollections
        let browser = browser
        let accountName = normalizedXAccountName
        let mediaTypes = mediaTypes
        let limit = effectiveLimit
        let outputDirectory = outputDirectory
        Task {
            do {
                let result = try await service.sync(
                    collections: collections,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    outputDirectory: outputDirectory,
                    mediaTypes: mediaTypes,
                    limit: limit
                )
                syncResult = result
                scanResult = try await service.scan(
                    collections: collections,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    mediaTypes: mediaTypes,
                    limit: limit
                )
                statusMessage = "Downloaded \(result.downloaded), skipped \(result.skippedAlreadyArchived), failed \(result.failed). \(result.duplicatesCollapsed) overlapping collection entries were merged."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    private var validationMessage: String {
        if !hasSelectedCollections {
            return "Select at least one X collection."
        }
        if !hasSelectedMediaTypes {
            return "Select at least one media type."
        }
        if !hasRequiredXAccountName {
            return "Enter the X username for Likes, or turn Likes off to sync Bookmarks only."
        }
        return "Collection sync is unavailable while another operation is running."
    }

    private func scanSummary(_ result: CollectionBatchScanResult) -> String {
        let overlap = result.duplicateOccurrencesCollapsed
        if overlap > 0 {
            return "Found \(result.uniqueMediaCount) unique media across \(result.scannedOccurrences) collection entries; \(overlap) overlapping entries were merged. \(result.unarchivedCount) are not in the downloaded archive."
        }
        return "Found \(result.uniqueMediaCount) unique media; \(result.unarchivedCount) are not in the downloaded archive."
    }

    private func clearResults() {
        scanResult = nil
        syncResult = nil
        statusMessage = ""
        errorMessage = nil
    }
}
