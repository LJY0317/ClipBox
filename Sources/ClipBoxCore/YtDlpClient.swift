import Foundation
import SQLite3

public enum YtDlpError: Error, LocalizedError, Sendable {
    case unavailable
    case inspectionFailed(String)
    case malformedMetadata(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "yt-dlp is not installed or could not be found. Install yt-dlp, then try again."
        case .inspectionFailed(let message):
            "Could not inspect media: \(message)"
        case .malformedMetadata(let message):
            "yt-dlp returned metadata ClipBox could not understand: \(message)"
        case .downloadFailed(let message):
            "Download failed: \(message)"
        }
    }
}

public actor YtDlpClient {
    private let executableURL: URL?

    public init(executableURL: URL? = ExecutableLocator.locate("yt-dlp")) {
        self.executableURL = executableURL
    }

    public func dependencyStatus() -> ClipBoxDependencyStatus {
        let ytDlp = toolStatus(name: "yt-dlp", executable: executableURL, versionArguments: ["--version"])
        let ffmpegURL = ExecutableLocator.locate("ffmpeg")
        let ffmpeg = toolStatus(name: "ffmpeg", executable: ffmpegURL, versionArguments: ["-version"])
        let sqliteVersion = sqlite3_libversion().map { String(cString: $0) } ?? "unknown"
        return ClipBoxDependencyStatus(ytDlp: ytDlp, ffmpeg: ffmpeg, sqliteVersion: sqliteVersion)
    }

    public func inspect(
        url: String,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) throws -> MediaMetadata {
        guard let executableURL else {
            throw YtDlpError.unavailable
        }

        var arguments = [
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
        ]
        arguments.append(contentsOf: authenticationArguments(cookiesFromBrowser))
        arguments.append(url)

        let result = try ProcessRunner.run(
            executable: executableURL,
            arguments: arguments
        )
        guard result.exitCode == 0 else {
            throw YtDlpError.inspectionFailed(cleanError(result.stderr))
        }

        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw YtDlpError.malformedMetadata("empty JSON output")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else {
                throw YtDlpError.malformedMetadata("top-level JSON value is not an object")
            }
            return try Self.parseMetadata(json: json, inputURL: url)
        } catch let error as YtDlpError {
            throw error
        } catch {
            throw YtDlpError.malformedMetadata(error.localizedDescription)
        }
    }

    public func download(
        url: String,
        outputDirectory: URL,
        cookiesFromBrowser: BrowserCookieSource? = nil
    ) throws -> String {
        guard let executableURL else {
            throw YtDlpError.unavailable
        }

        let outputTemplate = outputDirectory
            .appendingPathComponent("%(title).180B [%(id)s].%(ext)s", isDirectory: false)
            .path

        var arguments = [
            "--no-playlist",
            "--newline",
            "--no-warnings",
            "--format", "bestvideo*+bestaudio/best",
            "--merge-output-format", "mp4",
            "--output", outputTemplate,
            "--print", "after_move:filepath",
        ]
        arguments.append(contentsOf: authenticationArguments(cookiesFromBrowser))
        arguments.append(url)

        let result = try ProcessRunner.run(
            executable: executableURL,
            arguments: arguments
        )
        guard result.exitCode == 0 else {
            throw YtDlpError.downloadFailed(cleanError(result.stderr))
        }

        let paths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let finalPath = paths.last else {
            throw YtDlpError.downloadFailed("yt-dlp completed without reporting the output file path")
        }
        return finalPath
    }

    public func scanCollection(
        _ collection: BuiltInCollection,
        cookiesFromBrowser: BrowserCookieSource,
        limit: Int? = nil
    ) throws -> [CollectionItem] {
        guard let executableURL else {
            throw YtDlpError.unavailable
        }

        var arguments = [
            "--flat-playlist",
            "--dump-single-json",
            "--no-warnings",
            "--cookies-from-browser", cookiesFromBrowser.rawValue,
        ]
        if let limit, limit > 0 {
            arguments.append(contentsOf: ["--playlist-end", String(limit)])
        }
        arguments.append(collection.sourceToken)

        let result = try ProcessRunner.run(executable: executableURL, arguments: arguments)
        guard result.exitCode == 0 else {
            throw YtDlpError.inspectionFailed(cleanError(result.stderr))
        }

        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw YtDlpError.malformedMetadata("empty collection JSON output")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else {
                throw YtDlpError.malformedMetadata("collection JSON has no entries array")
            }

            return entries.compactMap { entry in
                guard let mediaID = Self.string(entry["id"]), !mediaID.isEmpty else {
                    return nil
                }
                let sourceURL = Self.collectionSourceURL(
                    entry: entry,
                    collection: collection,
                    mediaID: mediaID
                )
                return CollectionItem(
                    site: collection.site,
                    collectionName: collection.collectionName,
                    mediaID: mediaID,
                    sourceURL: sourceURL,
                    title: Self.string(entry["title"]),
                    creator: Self.string(entry["uploader"])
                        ?? Self.string(entry["channel"])
                        ?? Self.string(entry["creator"])
                )
            }
        } catch let error as YtDlpError {
            throw error
        } catch {
            throw YtDlpError.malformedMetadata(error.localizedDescription)
        }
    }

    private func toolStatus(name: String, executable: URL?, versionArguments: [String]) -> ExternalToolStatus {
        guard let executable else {
            return ExternalToolStatus(name: name, path: nil, version: nil)
        }

        let result = try? ProcessRunner.run(executable: executable, arguments: versionArguments)
        let firstLine = result?
            .stdout
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
        return ExternalToolStatus(name: name, path: executable.path, version: firstLine)
    }

    private func authenticationArguments(_ browser: BrowserCookieSource?) -> [String] {
        guard let browser else { return [] }
        return ["--cookies-from-browser", browser.rawValue]
    }

    private static func parseMetadata(json: [String: Any], inputURL: String) throws -> MediaMetadata {
        guard let mediaID = string(json["id"]), !mediaID.isEmpty else {
            throw YtDlpError.malformedMetadata("missing media id")
        }

        let site = string(json["extractor_key"])
            ?? string(json["extractor"])
            ?? "generic"

        let formats: [MediaFormat] = (json["formats"] as? [[String: Any]] ?? []).compactMap { format in
            guard let formatID = string(format["format_id"]), !formatID.isEmpty else {
                return nil
            }

            return MediaFormat(
                formatID: formatID,
                note: string(format["format_note"]),
                extensionName: string(format["ext"]),
                width: int(format["width"]),
                height: int(format["height"]),
                fps: double(format["fps"]),
                totalBitrateKbps: double(format["tbr"]),
                fileSize: int64(format["filesize"] ?? format["filesize_approx"]),
                videoCodec: string(format["vcodec"]),
                audioCodec: string(format["acodec"])
            )
        }

        return MediaMetadata(
            site: site.lowercased(),
            mediaID: mediaID,
            sourceID: string(json["display_id"]),
            inputURL: inputURL,
            webpageURL: string(json["webpage_url"]),
            title: string(json["title"]),
            creator: string(json["uploader"]) ?? string(json["channel"]) ?? string(json["creator"]),
            uploadDate: string(json["upload_date"]),
            durationSeconds: double(json["duration"]),
            width: int(json["width"]),
            height: int(json["height"]),
            fps: double(json["fps"]),
            videoCodec: string(json["vcodec"]),
            audioCodec: string(json["acodec"]),
            formatID: string(json["format_id"]),
            formats: formats.sorted { lhs, rhs in
                let lhsPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
                let rhsPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
                if lhsPixels == rhsPixels {
                    return (lhs.totalBitrateKbps ?? 0) > (rhs.totalBitrateKbps ?? 0)
                }
                return lhsPixels > rhsPixels
            }
        )
    }

    private static func collectionSourceURL(
        entry: [String: Any],
        collection: BuiltInCollection,
        mediaID: String
    ) -> String {
        if let webpageURL = string(entry["webpage_url"]), webpageURL.hasPrefix("http") {
            return webpageURL
        }
        if let url = string(entry["url"]), url.hasPrefix("http") {
            return url
        }

        switch collection.site {
        case "youtube":
            return "https://www.youtube.com/watch?v=\(mediaID)"
        default:
            return string(entry["url"]) ?? mediaID
        }
    }

    private func cleanError(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        return lines.suffix(8).joined(separator: "\n")
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value
        case let value as NSNumber:
            value.stringValue
        default:
            nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value)
        default:
            nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            value
        case let value as NSNumber:
            value.int64Value
        case let value as String:
            Int64(value)
        default:
            nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            value
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }
}
