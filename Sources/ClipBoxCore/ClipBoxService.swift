import Foundation

public enum DownloadOutcome: Codable, Equatable, Sendable {
    case downloaded(media: MediaMetadata, outputPath: String)
    case skippedAlreadyArchived(media: MediaMetadata, previousPath: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case media
        case outputPath
        case previousPath
    }

    private enum Kind: String, Codable {
        case downloaded
        case skippedAlreadyArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let media = try container.decode(MediaMetadata.self, forKey: .media)
        switch kind {
        case .downloaded:
            self = .downloaded(
                media: media,
                outputPath: try container.decode(String.self, forKey: .outputPath)
            )
        case .skippedAlreadyArchived:
            self = .skippedAlreadyArchived(
                media: media,
                previousPath: try container.decodeIfPresent(String.self, forKey: .previousPath)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .downloaded(let media, let outputPath):
            try container.encode(Kind.downloaded, forKey: .kind)
            try container.encode(media, forKey: .media)
            try container.encode(outputPath, forKey: .outputPath)
        case .skippedAlreadyArchived(let media, let previousPath):
            try container.encode(Kind.skippedAlreadyArchived, forKey: .kind)
            try container.encode(media, forKey: .media)
            try container.encodeIfPresent(previousPath, forKey: .previousPath)
        }
    }
}

public actor ClipBoxService {
    private let archive: ArchiveStore
    private let ytDlp: YtDlpClient

    public init(
        archive: ArchiveStore? = nil,
        ytDlp: YtDlpClient? = nil
    ) throws {
        self.archive = try archive ?? ArchiveStore()
        self.ytDlp = ytDlp ?? YtDlpClient()
    }

    public func dependencyStatus() async -> ClipBoxDependencyStatus {
        await ytDlp.dependencyStatus()
    }

    public func inspect(
        url: String,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> MediaMetadata {
        try await ytDlp.inspect(url: url, cookiesFromBrowser: cookiesFromBrowser)
    }

    public func historyCount() async throws -> Int {
        try await archive.count()
    }

    public func recentHistory(limit: Int = 50) async throws -> [ArchiveRecord] {
        try await archive.recent(limit: limit)
    }

    public func download(
        url: String,
        outputDirectory: URL? = nil,
        force: Bool = false,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) async throws -> DownloadOutcome {
        let media = try await ytDlp.inspect(
            url: url,
            cookiesFromBrowser: cookiesFromBrowser
        )

        if !force, try await archive.downloaded(identity: media.archiveIdentity) {
            let previous = try await archive.record(identity: media.archiveIdentity)?.outputPath
            return .skippedAlreadyArchived(media: media, previousPath: previous)
        }

        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        let destination = try ClipBoxPaths.ensureDownloadDirectory(
            outputDirectory ?? preferences.resolvedOutputDirectory
        )

        try await archive.record(media: media, status: .downloading)
        do {
            let outputPath = try await ytDlp.download(
                url: url,
                outputDirectory: destination,
                cookiesFromBrowser: cookiesFromBrowser
            )
            try await archive.record(
                media: media,
                status: .downloaded,
                outputPath: outputPath
            )
            return .downloaded(media: media, outputPath: outputPath)
        } catch {
            try? await archive.record(
                media: media,
                status: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }
}
