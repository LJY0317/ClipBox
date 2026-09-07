import Foundation

public enum DirectMediaDownloaderError: Error, LocalizedError, Sendable {
    case unavailable
    case missingDirectURL
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The macOS curl executable could not be found."
        case .missingDirectURL:
            "The collection item has no direct media URL."
        case .downloadFailed(let message):
            "Direct media download failed: \(message)"
        }
    }
}

public actor DirectMediaDownloader {
    private let executableURL: URL?

    public init(executableURL: URL? = ExecutableLocator.locate("curl")) {
        self.executableURL = executableURL
    }

    public func download(item: CollectionItem, outputDirectory: URL) throws -> String {
        guard let executableURL else {
            throw DirectMediaDownloaderError.unavailable
        }
        guard let directMediaURL = item.directMediaURL, !directMediaURL.isEmpty else {
            throw DirectMediaDownloaderError.missingDirectURL
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let finalURL = outputDirectory.appendingPathComponent(filename(for: item))
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return finalURL.path
        }

        let partialURL = outputDirectory.appendingPathComponent(
            ".clipbox-\(item.mediaID)-\(UUID().uuidString).part",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try ProcessRunner.run(
            executable: executableURL,
            arguments: [
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry", "2",
                "--retry-delay", "1",
                "--output", partialURL.path,
                directMediaURL,
            ]
        )
        guard result.exitCode == 0 else {
            let message = result.stderr
                .split(whereSeparator: \.isNewline)
                .suffix(8)
                .joined(separator: "\n")
            throw DirectMediaDownloaderError.downloadFailed(message)
        }

        do {
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        } catch {
            throw DirectMediaDownloaderError.downloadFailed(error.localizedDescription)
        }
        return finalURL.path
    }

    private func filename(for item: CollectionItem) -> String {
        var parts: [String] = []
        if let creator = item.creator, !creator.isEmpty {
            parts.append(creator.hasPrefix("@") ? creator : "@\(creator)")
        }
        if let publishedAt = item.publishedAt, publishedAt.count >= 10 {
            parts.append(String(publishedAt.prefix(10)))
        }
        if let sourceID = item.sourceID, !sourceID.isEmpty {
            parts.append("[\(sourceID)]")
        }
        parts.append("[\(item.mediaID)]")
        if let width = item.width, let height = item.height, width > 0, height > 0 {
            parts.append("[\(width)x\(height)]")
        }

        let base = FilenameSanitizer.sanitize(parts.joined(separator: " "))
        let ext = FilenameSanitizer.sanitize(item.extensionName ?? "mp4")
        return "\(base).\(ext)"
    }
}
