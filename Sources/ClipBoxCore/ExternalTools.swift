import Foundation

public struct ExternalToolStatus: Codable, Equatable, Sendable {
    public let name: String
    public let path: String?
    public let version: String?

    public init(name: String, path: String?, version: String?) {
        self.name = name
        self.path = path
        self.version = version
    }

    public var isAvailable: Bool { path != nil }
}

public struct ClipBoxDependencyStatus: Codable, Equatable, Sendable {
    public let ytDlp: ExternalToolStatus
    public let ffmpeg: ExternalToolStatus
    public let galleryDl: ExternalToolStatus
    public let sqliteVersion: String

    public init(
        ytDlp: ExternalToolStatus,
        ffmpeg: ExternalToolStatus,
        galleryDl: ExternalToolStatus,
        sqliteVersion: String
    ) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.galleryDl = galleryDl
        self.sqliteVersion = sqliteVersion
    }
}

public enum ExecutableLocator {
    public static func locate(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let overrideKey: String?
        switch name {
        case "yt-dlp": overrideKey = "CLIPBOX_YTDLP_PATH"
        case "ffmpeg": overrideKey = "CLIPBOX_FFMPEG_PATH"
        case "gallery-dl": overrideKey = "CLIPBOX_GALLERYDL_PATH"
        case "curl": overrideKey = "CLIPBOX_CURL_PATH"
        default: overrideKey = nil
        }

        if let overrideKey,
           let overridePath = environment[overrideKey],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let candidate = URL(
                fileURLWithPath: NSString(string: overridePath).expandingTildeInPath,
                isDirectory: false
            )
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])

        var seen = Set<String>()
        for directory in candidates where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
