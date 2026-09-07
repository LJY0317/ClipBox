import ClipBoxCore
import Combine
import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var sourceURL = ""
    @Published var outputDirectory: URL
    @Published var browserCookieSource: BrowserCookieSource?
    @Published var media: MediaMetadata?
    @Published var dependencies: ClipBoxDependencyStatus?
    @Published var archiveCount = 0
    @Published var recentHistory: [ArchiveRecord] = []
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let service: ClipBoxService?
    private let initializationError: Error?

    init() {
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        outputDirectory = preferences.resolvedOutputDirectory
        browserCookieSource = nil

        do {
            service = try ClipBoxService()
            initializationError = nil
        } catch {
            service = nil
            initializationError = error
        }

        Task {
            await refreshStatus()
        }
    }

    var canAnalyze: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isWorking
            && dependencies?.ytDlp.isAvailable == true
    }

    var canDownload: Bool {
        canAnalyze
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

    func analyze() {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? "ClipBox service is unavailable."
            return
        }

        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserCookieSource = browserCookieSource
        isWorking = true
        errorMessage = nil
        statusMessage = "Analyzing media…"

        Task {
            do {
                media = try await service.inspect(
                    url: url,
                    cookiesFromBrowser: browserCookieSource
                )
                statusMessage = "Found \(media?.formats.count ?? 0) available formats."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func download() {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? "ClipBox service is unavailable."
            return
        }

        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserCookieSource = browserCookieSource
        isWorking = true
        errorMessage = nil
        statusMessage = "Downloading best available quality…"

        Task {
            do {
                let outcome = try await service.download(
                    url: url,
                    outputDirectory: outputDirectory,
                    cookiesFromBrowser: browserCookieSource
                )
                switch outcome {
                case .downloaded(let downloadedMedia, let outputPath):
                    media = downloadedMedia
                    statusMessage = "Downloaded to \(outputPath)"
                case .skippedAlreadyArchived(let archivedMedia, let previousPath):
                    media = archivedMedia
                    statusMessage = previousPath.map { "Already archived. Previous file: \($0)" }
                        ?? "Already archived. Download skipped."
                }
                await refreshHistory()
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func refreshStatus() async {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? "ClipBox service is unavailable."
            return
        }

        dependencies = await service.dependencyStatus()
        await refreshHistory()
    }

    func refreshHistory() async {
        guard let service else { return }
        do {
            async let count = service.historyCount()
            async let history = service.recentHistory(limit: 50)
            archiveCount = try await count
            recentHistory = try await history
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
