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
            "--filter", "extension == 'mp4'",
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
            return try parseMessages(messages, collection: collection)
        } catch let error as GalleryDlError {
            throw error
        } catch {
            throw GalleryDlError.malformedOutput(error.localizedDescription)
        }
    }

    private func parseMessages(
        _ messages: [Any],
        collection: BuiltInCollection
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
                  (Self.string(metadata["extension"])?.lowercased() == "mp4"
                    || Self.string(metadata["type"])?.lowercased().contains("video") == true),
                  let tweetID = Self.string(metadata["tweet_id"]),
                  !tweetID.isEmpty else {
                continue
            }

            let sequenceNumber = Self.int(metadata["num"]) ?? 1
            let mediaID = Self.mediaID(fromDirectURL: directURL)
                ?? "\(tweetID)-media-\(sequenceNumber)"
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
                    directMediaURL: directURL,
                    extensionName: Self.string(metadata["extension"]) ?? "mp4",
                    width: Self.int(metadata["width"]),
                    height: Self.int(metadata["height"]),
                    bitrate: Self.double(metadata["bitrate"])
                )
            )
        }

        return items
    }

    private static func mediaID(fromDirectURL value: String) -> String? {
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
