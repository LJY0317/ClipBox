import ClipBoxCore
import Combine
import Foundation

@MainActor
final class CollectionViewModel: ObservableObject {
    @Published var selectedCollection: BuiltInCollection = .youtubeLiked
    @Published var browser: BrowserCookieSource = .safari
    @Published var xAccountName = ""
    @Published var scanLimit = 100
    @Published var scanAll = false
    @Published var outputDirectory: URL
    @Published var scanResult: CollectionScanResult?
    @Published var syncResult: CollectionSyncResult?
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
        isWorking = true
        errorMessage = nil
        syncResult = nil
        statusMessage = "Reading \(selectedCollection.displayName)…"

        let collection = selectedCollection
        let browser = browser
        let accountName = xAccountName
        let limit = effectiveLimit
        Task {
            do {
                let result = try await service.scan(
                    collection: collection,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    limit: limit
                )
                scanResult = result
                statusMessage = "Found \(result.items.count) items; \(result.unarchivedCount) are not in the downloaded archive."
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
        isWorking = true
        errorMessage = nil
        statusMessage = "Synchronizing \(selectedCollection.displayName)…"

        let collection = selectedCollection
        let browser = browser
        let accountName = xAccountName
        let limit = effectiveLimit
        let outputDirectory = outputDirectory
        Task {
            do {
                let result = try await service.sync(
                    collection: collection,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    outputDirectory: outputDirectory,
                    limit: limit
                )
                syncResult = result
                scanResult = try await service.scan(
                    collection: collection,
                    accountName: accountName,
                    cookiesFromBrowser: browser,
                    limit: limit
                )
                statusMessage = "Downloaded \(result.downloaded), skipped \(result.skippedAlreadyArchived), failed \(result.failed)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }
}
