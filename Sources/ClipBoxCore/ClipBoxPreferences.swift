import Foundation

public struct ClipBoxPreferences: Codable, Equatable, Sendable {
    public var outputDirectoryPath: String?

    public init(outputDirectoryPath: String? = nil) {
        self.outputDirectoryPath = outputDirectoryPath
    }

    public var resolvedOutputDirectory: URL {
        guard let outputDirectoryPath, !outputDirectoryPath.isEmpty else {
            return ClipBoxPaths.defaultDownloadDirectory
        }

        return URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
    }
}

public enum ClipBoxPreferencesStore {
    public static func load() throws -> ClipBoxPreferences {
        let url = ClipBoxPaths.preferencesFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClipBoxPreferences()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClipBoxPreferences.self, from: data)
    }

    public static func save(_ preferences: ClipBoxPreferences) throws {
        try ClipBoxPaths.ensureApplicationSupportDirectories()
        let data = try JSONEncoder.clipBoxPretty.encode(preferences)
        try data.write(to: ClipBoxPaths.preferencesFileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var clipBoxPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
