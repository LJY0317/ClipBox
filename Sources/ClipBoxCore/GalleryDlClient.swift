import Foundation

public enum GalleryDlError: Error, LocalizedError, Sendable {
    case unavailable
    case unsupportedCollection(String)
    case missingAccountName
    case scanFailed(String)
    case malformedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "gallery-dl is not installed or could not be found. Install gallery-dl, then try again."
        case .unsupportedCollection(let name):
            "gallery-dl collection support is not configured for \(name)."
        case .missingAccountName:
            "X Likes requires an X account name so ClipBox can open that account's Likes URL."
        case .scanFailed(let message):
            "Could not read the X collection: \(message)"
        case .malformedOutput(let message):
            "gallery-dl returned data ClipBox could not understand: \(message)"
        }
    }
}

public actor GalleryDlClient {
    private let executableURL: URL?

    public init(executableURL: URL? = ExecutableLocator.locate("gallery-dl")) {
        self.executableURL = executableURL
    }

    public func scanCollection(
        _ collection: BuiltInCollection,
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) throws -> [CollectionItem] {
        guard let executableURL else {
            throw GalleryDlError.unavailable
        }
        guard collection.site == "twitter" else {
            throw GalleryDlError.unsupportedCollection(collection.displayName)
        }
        guard let collectionURL = collection.collectionURL(accountName: accountName) else {
            throw GalleryDlError.missingAccountName
        }

        var arguments = [
            "--dump-json",
            "--cookies-from-browser", cookiesFromBrowser.rawValue,
        ]
        if let limit, limit > 0 {
            arguments.append(contentsOf: ["--post-range", "1-\(limit)"])
        }
        arguments.append(collectionURL)

        let result = try ProcessRunner.run(executable: executableURL, arguments: arguments)
        guard result.exitCode == 0 else {
            throw GalleryDlError.scanFailed(cleanError(result.stderr))
        }
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw GalleryDlError.malformedOutput("empty JSON output")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let messages = object as? [Any] else {
                throw GalleryDlError.malformedOutput("top-level JSON value is not an array")
            }
            return try parseMessages(
                messages,
                collection: collection,
                mediaTypes: mediaTypes
            )
        } catch let error as GalleryDlError {
            throw error
        } catch {
            throw GalleryDlError.malformedOutput(error.localizedDescription)
        }
    }

    private func parseMessages(
        _ messages: [Any],
        collection: BuiltInCollection,
        mediaTypes: MediaTypeSelection
    ) throws -> [CollectionItem] {
        var items: [CollectionItem] = []
        var seenMediaIDs = Set<String>()

        for rawMessage in messages {
            guard let message = rawMessage as? [Any],
                  let messageCode = Self.int(message.first) else {
                continue
            }

            if messageCode == -1 {
                let metadata = message.count > 1 ? message[1] as? [String: Any] : nil
                let errorName = Self.string(metadata?["error"]) ?? "ExtractionError"
                let detail = Self.string(metadata?["message"]) ?? "unknown gallery-dl error"
                throw GalleryDlError.scanFailed("\(errorName): \(detail)")
            }

            guard messageCode == 3,
                  message.count >= 3,
                  let directURL = message[1] as? String,
                  let metadata = message[2] as? [String: Any],
                  let tweetID = Self.string(metadata["tweet_id"]),
                  !tweetID.isEmpty else {
                continue
            }

            guard let mediaType = Self.mediaType(metadata: metadata, directURL: directURL),
                  mediaTypes.contains(mediaType) else {
                continue
            }

            let sequenceNumber = Self.int(metadata["num"]) ?? 1
            let mediaID = Self.mediaID(
                fromDirectURL: directURL,
                metadata: metadata,
                mediaType: mediaType
            ) ?? "\(tweetID)-\(mediaType.rawValue)-\(sequenceNumber)"
            guard seenMediaIDs.insert(mediaID).inserted else {
                continue
            }

            let author = metadata["author"] as? [String: Any]
            let creator = Self.string(author?["name"])
            let postURL: String
            if let creator, !creator.isEmpty {
                postURL = "https://x.com/\(creator)/status/\(tweetID)"
            } else {
                postURL = "https://x.com/i/web/status/\(tweetID)"
            }

            items.append(
                CollectionItem(
                    site: collection.site,
                    collectionName: collection.collectionName,
                    mediaID: mediaID,
                    sourceID: tweetID,
                    sourceURL: postURL,
                    title: Self.string(metadata["content"]),
                    creator: creator,
                    publishedAt: Self.string(metadata["date"]),
                    mediaType: mediaType,
                    directMediaURL: directURL,
                    extensionName: Self.extensionName(metadata: metadata, directURL: directURL, mediaType: mediaType),
                    width: Self.int(metadata["width"]),
                    height: Self.int(metadata["height"]),
                    bitrate: Self.double(metadata["bitrate"])
                )
            )
        }

        return items
    }

    private static func mediaID(
        fromDirectURL value: String,
        metadata: [String: Any],
        mediaType: MediaAssetType
    ) -> String? {
        if let metadataID = string(metadata["media_id"]), !metadataID.isEmpty {
            return metadataID
        }

        guard let components = URLComponents(string: value) else { return nil }
        let pathComponents = components.path.split(separator: "/").map(String.init)
        for marker in ["ext_tw_video", "amplify_video"] {
            guard let index = pathComponents.firstIndex(of: marker) else { continue }
            let nextIndex = pathComponents.index(after: index)
            guard nextIndex < pathComponents.endIndex else { continue }
            let candidate = pathComponents[nextIndex]
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) {
                return candidate
            }
        }

        if let marker = pathComponents.firstIndex(of: "media") {
            let nextIndex = pathComponents.index(after: marker)
            if nextIndex < pathComponents.endIndex {
                let token = pathComponents[nextIndex].split(separator: ".", maxSplits: 1).first.map(String.init)
                if let token, !token.isEmpty {
                    return token
                }
            }
        }

        if let marker = pathComponents.firstIndex(of: "tweet_video") {
            let nextIndex = pathComponents.index(after: marker)
            if nextIndex < pathComponents.endIndex {
                let token = pathComponents[nextIndex].split(separator: ".", maxSplits: 1).first.map(String.init)
                if let token, !token.isEmpty {
                    return token
                }
            }
        }

        if mediaType != .video,
           let filename = string(metadata["filename"]),
           !filename.isEmpty {
            return filename
        }
        return nil
    }

    private static func mediaType(
        metadata: [String: Any],
        directURL: String
    ) -> MediaAssetType? {
        let rawType = string(metadata["type"])?.lowercased() ?? ""
        if rawType == "animated_gif" || rawType.contains("animated") {
            return .animated
        }
        if rawType == "photo" || rawType.hasSuffix(":image") || rawType.hasSuffix(":cover") {
            return .photo
        }
        if rawType == "video" || rawType.hasSuffix(":video") {
            return .video
        }
        if rawType == "preview" {
            return nil
        }

        guard let ext = detectedExtension(metadata: metadata, directURL: directURL) else {
            return nil
        }
        if ["jpg", "jpeg", "png", "webp", "heic", "avif"].contains(ext.lowercased()) {
            return .photo
        }
        if ["mp4", "mov", "m4v", "webm"].contains(ext.lowercased()) {
            return .video
        }
        return nil
    }

    private static func extensionName(
        metadata: [String: Any],
        directURL: String,
        mediaType: MediaAssetType
    ) -> String {
        if let ext = detectedExtension(metadata: metadata, directURL: directURL) {
            return ext
        }
        return switch mediaType {
        case .video, .animated: "mp4"
        case .photo: "jpg"
        }
    }

    private static func detectedExtension(
        metadata: [String: Any],
        directURL: String
    ) -> String? {
        if let ext = string(metadata["extension"]), !ext.isEmpty {
            return ext.lowercased()
        }
        if let components = URLComponents(string: directURL),
           let format = components.queryItems?.first(where: { $0.name == "format" })?.value,
           !format.isEmpty {
            return format.lowercased()
        }
        if let components = URLComponents(string: directURL) {
            let ext = URL(fileURLWithPath: components.path).pathExtension
            if !ext.isEmpty {
                return ext.lowercased()
            }
        }
        return nil
    }

    private func cleanError(_ stderr: String) -> String {
        stderr
            .split(whereSeparator: \.isNewline)
            .suffix(8)
            .joined(separator: "\n")
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
