import Foundation

public enum DirectMediaDownloaderError: Error, LocalizedError, Sendable {
    case unavailable
    case missingDirectURL
    case httpStatus(Int)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The macOS curl executable could not be found."
        case .missingDirectURL:
            "The collection item has no direct media URL."
        case .httpStatus(let status):
            "Direct media download returned HTTP \(status). The media URL may have expired or access may have changed."
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

    public func download(item: CollectionItem, outputDirectory: URL) async throws -> String {
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

        var finalURL = outputDirectory.appendingPathComponent(filename(for: item))
        if FileManager.default.fileExists(atPath: finalURL.path) {
            // An existing file without an archive decision is not proof of a completed download.
            // Preserve it and avoid overwriting a user file or a previous interrupted run.
            let base = finalURL.deletingPathExtension().lastPathComponent
            let ext = finalURL.pathExtension
            finalURL = outputDirectory.appendingPathComponent("\(base)_\(UUID().uuidString).\(ext)")
        }

        let partialURL = outputDirectory.appendingPathComponent(
            ".clipbox-\(item.mediaID)-\(UUID().uuidString).part",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try await ProcessRunner.runAsync(
            executable: executableURL,
            arguments: [
                "--disable",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry", "2",
                "--retry-delay", "2",
                "--connect-timeout", "30",
                "--max-time", "600",
                "--write-out", "%{http_code}",
                "--output", partialURL.path,
                directMediaURL,
            ], timeout: 650
        )
        guard result.exitCode == 0 else {
            if let status = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), status >= 400 {
                throw DirectMediaDownloaderError.httpStatus(status)
            }
            throw DirectMediaDownloaderError.downloadFailed("The media server rejected the request or the connection failed. Retry sync to refresh media URLs; completed files are skipped.")
        }

        do {
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        } catch {
            throw DirectMediaDownloaderError.downloadFailed(error.localizedDescription)
        }
        return finalURL.path
    }

    private func filename(for item: CollectionItem) -> String {
        if item.site == "twitter" {
            return xFilename(for: item)
        }

        var parts: [String] = []
        if let creator = item.creator, !creator.isEmpty {
            parts.append(creator.hasPrefix("@") ? creator : "@\(creator)")
        }
        if let publishedAt = item.publishedAt, publishedAt.count >= 10 {
            parts.append(String(publishedAt.prefix(10)))
        }
        if let sourceID = item.sourceID, !sourceID.isEmpty {
            parts.append(sourceID)
        }
        parts.append(item.mediaID)
        if let width = item.width, let height = item.height, width > 0, height > 0 {
            parts.append("\(width)x\(height)")
        }

        let base = FilenameSanitizer.sanitize(parts.joined(separator: "_"))
        let ext = FilenameSanitizer.sanitize(item.extensionName ?? defaultExtension(for: item.mediaType))
        return "\(base).\(ext)"
    }

    private func xFilename(for item: CollectionItem) -> String {
        var parts = ["x"]

        if let creatorID = item.creatorID, !creatorID.isEmpty {
            parts.append(FilenameSanitizer.sanitize(creatorID))
        } else {
            parts.append("unknown-user")
        }

        if let publishedAt = item.publishedAt, publishedAt.count >= 10 {
            parts.append(String(publishedAt.prefix(10)))
        } else {
            parts.append("unknown-date")
        }

        if let creator = item.creator, !creator.isEmpty {
            let handle = creator.hasPrefix("@") ? creator : "@\(creator)"
            parts.append(FilenameSanitizer.sanitize(handle))
        } else {
            parts.append("@unknown")
        }

        parts.append(FilenameSanitizer.sanitize(item.mediaID))

        if let width = item.width, let height = item.height, width > 0, height > 0 {
            parts.append("\(width)x\(height)")
        } else {
            parts.append("unknown-resolution")
        }

        let ext = FilenameSanitizer.sanitize(item.extensionName ?? defaultExtension(for: item.mediaType))
        return "\(parts.joined(separator: "_")).\(ext)"
    }

    private func defaultExtension(for mediaType: MediaAssetType) -> String {
        switch mediaType {
        case .video, .animated: "mp4"
        case .photo: "jpg"
        }
    }
}
