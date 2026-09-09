import Foundation

public enum GalleryDlError: Error, LocalizedError, Sendable {
    case unavailable
    case unsupportedSession(String)
    case rateLimited(TimeInterval?)
    case sessionExpired
    case securityChallenge
    case accessDenied
    case unsupportedCollection(String)
    case missingAccountName
    case authenticationRequired(BrowserCookieSource)
    case browserCookieAccessFailed(BrowserCookieSource, String)
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
        case .unsupportedSession(let message):
            message
        case .rateLimited(let retryAfter):
            retryAfter.map { "X rate limit reached. Retry after about \(Int($0.rounded(.up))) seconds. Successful downloads remain archived." }
                ?? "X rate limit reached. ClipBox will pause before another X request. Successful downloads remain archived."
        case .sessionExpired:
            "X rejected this session. Sign in again in the selected browser profile, then test the connection."
        case .securityChallenge:
            "X requested an additional security check. ClipBox stopped instead of retrying automatically. Complete the check in the selected browser, then test the connection once."
        case .accessDenied:
            "X denied this request. This does not by itself mean the account is suspended; the content may be unavailable, restricted, or the extractor may need an update."
        case .authenticationRequired(let browser):
            browser == .safari
                ? "The selected Safari profile/store is readable, but it does not contain a usable X login. Choose the Safari profile where you are signed in to X, then use Test connection. Refresh local sessions only refreshes local stores and does not sign you in."
                : "No usable X login session was received from \(browser.displayName). Sign in to X in the selected profile, then retry. Changing the account handle does not sign you in."
        case .browserCookieAccessFailed(let browser, let reason):
            switch reason {
            case "permissionDenied":
                "macOS denied this process access to \(browser.displayName)'s cookie store. If Terminal can read it but the installed ClipBox app cannot, review the installed app's privacy grant and code-signing identity, then reopen ClipBox."
            case "storeMissing":
                "The selected \(browser.displayName) cookie store was not found. Refresh the store list and choose an existing profile."
            case "unsupportedFormat":
                "The selected Safari store could not be parsed. Try another store or use Chrome / Firefox."
            default:
                "Could not decrypt \(browser.displayName)'s cookies. Check the selected profile and the macOS Keychain prompt."
            }
        case .scanFailed(let message):
            "Could not read the X collection: \(message)"
        case .malformedOutput(let message):
            "gallery-dl returned data ClipBox could not understand: \(message)"
        }
    }
}

public struct XCollectionPageResult: Sendable {
    public let items: [BuiltInCollection: [CollectionItem]]
    public let continuations: [BuiltInCollection: String]
    public let diagnostics: [CollectionDiagnostic]
}

public actor GalleryDlClient {
    private let executableURL: URL?
    public private(set) var lastDiagnostics: [CollectionDiagnostic] = []

    public init(executableURL: URL? = ExecutableLocator.locate("gallery-dl")) {
        self.executableURL = executableURL
    }

    public func scanCollection(
        _ collection: BuiltInCollection,
        accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        browserProfile: String? = nil,
        browserContainer: String? = nil,
        mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> [CollectionItem] {
        try await scanCollections([collection], accountName: accountName,
            cookiesFromBrowser: cookiesFromBrowser, browserProfile: browserProfile,
            browserContainer: browserContainer, mediaTypes: mediaTypes, limit: limit)[collection] ?? []
    }

    public func scanCollections(
        _ collections: [BuiltInCollection], accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource, browserProfile: String? = nil,
        browserContainer: String? = nil, mediaTypes: MediaTypeSelection = .defaultSelection,
        limit: Int? = 100
    ) async throws -> [BuiltInCollection: [CollectionItem]] {
        guard let executableURL else {
            throw GalleryDlError.unavailable
        }
        guard !collections.isEmpty else { return [:] }
        let urls = try collections.map { collection in
            guard collection.site == "twitter" else { throw GalleryDlError.unsupportedCollection(collection.displayName) }
            guard let url = collection.collectionURL(accountName: accountName) else { throw GalleryDlError.missingAccountName }
            return url
        }

        lastDiagnostics = []
        let interpreter = GalleryBridge.interpreter(for: executableURL)
        let safariStore = cookiesFromBrowser == .safari ? browserProfile : nil
        if safariStore != nil, interpreter == nil {
            throw GalleryDlError.unsupportedSession("Selecting a Safari store requires a Python-based gallery-dl installation (such as Homebrew).")
        }
        let session = BrowserSession(browser: cookiesFromBrowser,
            profile: cookiesFromBrowser == .safari ? nil : browserProfile, container: browserContainer)
        var arguments = [
            "--config-ignore", "--no-input", "--no-colors", "--no-postprocessors",
            "--dump-json", "-o", try session.galleryCookieOption(),
            "-o", "extractor.cookies-update=false", "-o", "cache.file=null",
            "-o", limit == nil ? "extractor.twitter.ratelimit=wait" : "extractor.twitter.ratelimit=abort",
            "-o", "extractor.twitter.retries-api=2",
            "--retries", "2", "--http-timeout", "30", "--sleep-request", "1.0-2.0",
        ]
        if let limit, limit > 0 {
            arguments.append(contentsOf: ["--post-range", "1-\(limit)"])
        }
        arguments.append(contentsOf: urls)

        let result = try await ProcessRunner.runAsync(
            executable: interpreter ?? executableURL,
            arguments: interpreter == nil ? arguments : ["-c", GalleryBridge.script, safariStore ?? ""] + arguments,
            timeout: limit == nil ? 21600 : 300
        )
        lastDiagnostics = GalleryBridge.diagnostics(result.stderr)
        // gallery-dl can swallow cookie reader errors and report AuthRequired in JSON.
        // Classify stderr even when its process exit status is zero.
        if let failure = Self.classifyError(result.stderr, browser: cookiesFromBrowser),
           case .browserCookieAccessFailed = failure { throw failure }
        guard result.exitCode == 0 else {
            if let failure = Self.classifyError(result.stderr, browser: cookiesFromBrowser) { throw failure }
            throw GalleryDlError.scanFailed("The extraction tool failed. Check its version, network connection and browser session, then retry.")
        }
        let frames = try Self.jsonFrames(result.stdout)
        guard frames.count == collections.count else {
            throw GalleryDlError.malformedOutput("response count does not match requested collections")
        }
        var items: [BuiltInCollection: [CollectionItem]] = [:]
        for (collection, frame) in zip(collections, frames) {
            do {
                guard let messages = try JSONSerialization.jsonObject(with: frame) as? [Any] else {
                    throw GalleryDlError.malformedOutput("top-level response is not an array")
                }
                items[collection] = try parseMessages(messages, collection: collection,
                    cookiesFromBrowser: cookiesFromBrowser, mediaTypes: mediaTypes)
            } catch let error as GalleryDlError { throw error }
            catch { throw GalleryDlError.malformedOutput("invalid JSON response; raw output omitted for privacy") }
        }
        return items
    }

    /// Fetch exactly one real X timeline page per requested collection. Opaque
    /// cursors live only in process memory and are never written to diagnostics,
    /// preferences, snapshots, or argv.
    public func scanCollectionPage(
        _ collections: [BuiltInCollection], accountName: String? = nil,
        cookiesFromBrowser: BrowserCookieSource, browserProfile: String? = nil,
        browserContainer: String? = nil, mediaTypes: MediaTypeSelection = .defaultSelection,
        continuations: [BuiltInCollection: String] = [:], pageSize: Int = 50,
        expectedOwnerID: String? = nil
    ) async throws -> XCollectionPageResult {
        guard let executableURL else { throw GalleryDlError.unavailable }
        guard !collections.isEmpty else { return XCollectionPageResult(items: [:], continuations: [:], diagnostics: []) }
        guard let interpreter = GalleryBridge.interpreter(for: executableURL) else {
            throw GalleryDlError.unsupportedSession("Incremental X pagination requires a Python-based gallery-dl installation (such as Homebrew).")
        }
        let urls = try collections.map { collection in
            guard collection.site == "twitter" else { throw GalleryDlError.unsupportedCollection(collection.displayName) }
            guard let url = collection.collectionURL(accountName: accountName) else { throw GalleryDlError.missingAccountName }
            return url
        }
        let safariStore = cookiesFromBrowser == .safari ? browserProfile : nil
        let session = BrowserSession(browser: cookiesFromBrowser,
            profile: cookiesFromBrowser == .safari ? nil : browserProfile, container: browserContainer)
        let boundedPageSize = min(50, max(10, pageSize))
        var arguments = [
            "--config-ignore", "--no-input", "--no-colors", "--no-postprocessors",
            "--dump-json", "-o", try session.galleryCookieOption(),
            "-o", "extractor.cookies-update=false", "-o", "cache.file=null",
            "-o", "extractor.twitter.ratelimit=abort", "-o", "extractor.twitter.retries-api=1",
            "-o", "extractor.twitter.limit=\(boundedPageSize)",
            "--retries", "1", "--http-timeout", "30", "--sleep-request", "1.0-2.0",
        ]
        arguments.append(contentsOf: urls)

        var cursorPayload: [String: String] = [:]
        for (collection, cursor) in continuations {
            switch collection {
            case .xLikes: cursorPayload["Likes"] = cursor
            case .xBookmarks: cursorPayload["Bookmarks"] = cursor
            case .youtubeLiked, .youtubeWatchLater: break
            }
        }
        var bridgeInput: [String: Any] = ["pageMode": true, "cursors": cursorPayload]
        if let expectedOwnerID { bridgeInput["expectedOwnerID"] = expectedOwnerID }
        let input = try JSONSerialization.data(withJSONObject: bridgeInput, options: [])
        let result = try await ProcessRunner.runAsync(
            executable: interpreter,
            arguments: ["-c", GalleryBridge.script, safariStore ?? ""] + arguments,
            standardInput: input,
            timeout: 120
        )
        let diagnostics = GalleryBridge.diagnostics(result.stderr)
        lastDiagnostics = diagnostics
        let pageStates = GalleryBridge.pageStates(result.stderr)
        let safeStderr = GalleryBridge.stderrWithoutPrivatePageState(result.stderr)
        if safeStderr.contains("CLIPBOX_ACCOUNT_CHANGED") {
            throw GalleryDlError.scanFailed("The X account in the selected browser profile changed. Start a new Preview before loading more pages.")
        }
        if let failure = Self.classifyError(safeStderr, browser: cookiesFromBrowser),
           case .browserCookieAccessFailed = failure { throw failure }
        guard result.exitCode == 0 else {
            if let failure = Self.classifyError(safeStderr, browser: cookiesFromBrowser) { throw failure }
            throw GalleryDlError.scanFailed("The extraction tool failed while loading the next X page.")
        }
        let frames = try Self.jsonFrames(result.stdout)
        guard frames.count == collections.count else {
            throw GalleryDlError.malformedOutput("paged response count does not match requested collections")
        }
        var items: [BuiltInCollection: [CollectionItem]] = [:]
        for (collection, frame) in zip(collections, frames) {
            guard let messages = try JSONSerialization.jsonObject(with: frame) as? [Any] else {
                throw GalleryDlError.malformedOutput("paged top-level response is not an array")
            }
            items[collection] = try parseMessages(messages, collection: collection,
                cookiesFromBrowser: cookiesFromBrowser, mediaTypes: mediaTypes)
        }
        var next: [BuiltInCollection: String] = [:]
        for state in pageStates {
            guard let cursor = state.nextCursor else { continue }
            switch state.collection {
            case "Likes": next[.xLikes] = cursor
            case "Bookmarks": next[.xBookmarks] = cursor
            default: break
            }
        }
        return XCollectionPageResult(items: items, continuations: next, diagnostics: diagnostics)
    }

    /// gallery-dl writes one JSON array per input URL. Frame arrays without splitting quoted content.
    static func jsonFrames(_ output: String) throws -> [Data] {
        let bytes = Array(output.utf8)
        var start: Int?, depth = 0, quoted = false, escaped = false
        var frames: [Data] = []
        for (index, byte) in bytes.enumerated() {
            if start == nil {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard byte == 91 else { throw GalleryDlError.malformedOutput("unexpected non-JSON output") }
                start = index
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 { depth += 1 }
            else if byte == 93 {
                depth -= 1
                if depth == 0, let first = start {
                    frames.append(Data(bytes[first...index]))
                    start = nil
                }
            }
        }
        guard start == nil, !frames.isEmpty else { throw GalleryDlError.malformedOutput("incomplete JSON response") }
        return frames
    }

    private func parseMessages(
        _ messages: [Any],
        collection: BuiltInCollection,
        cookiesFromBrowser: BrowserCookieSource,
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
                if errorName == "AuthRequired" {
                    throw GalleryDlError.authenticationRequired(cookiesFromBrowser)
                }
                if let failure = Self.classifyError(errorName + " " + detail, browser: cookiesFromBrowser) { throw failure }
                throw GalleryDlError.scanFailed("X returned an extraction error. Check for a gallery-dl update and retry. Raw server responses are omitted for privacy.")
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
            let creatorID = Self.string(author?["id"])
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
                    creatorID: creatorID,
                    publishedAt: Self.string(metadata["date"]),
                    thumbnailURL: Self.string(metadata["clipbox_thumbnail"]),
                    mediaType: mediaType,
                    directMediaURL: directURL,
                    extensionName: Self.extensionName(metadata: metadata, directURL: directURL, mediaType: mediaType),
                    width: Self.int(metadata["width"]),
                    height: Self.int(metadata["height"]),
                    bitrate: Self.double(metadata["bitrate"])
                )
            )
            items[items.count - 1].bookmarkedAt = Self.string(metadata["date_bookmarked"])
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

    public func refreshItem(
        _ item: CollectionItem,
        session: BrowserSession,
        mediaTypes: MediaTypeSelection = .defaultSelection
    ) async throws -> CollectionItem? {
        guard item.site == "twitter", let executableURL else { return nil }
        let interpreter = GalleryBridge.interpreter(for: executableURL)
        let safariStore = session.browser == .safari ? session.profile : nil
        if safariStore != nil, interpreter == nil {
            throw GalleryDlError.unsupportedSession("Refreshing a selected Safari store requires a Python-based gallery-dl installation.")
        }
        let cookieSession = BrowserSession(browser: session.browser,
            profile: session.browser == .safari ? nil : session.profile, container: session.container)
        let collection = BuiltInCollection.resolve(site: "x", collection: item.collectionName) ?? .xBookmarks
        let arguments = [
            "--config-ignore", "--no-input", "--no-colors", "--no-postprocessors", "--dump-json",
            "-o", try cookieSession.galleryCookieOption(), "-o", "extractor.cookies-update=false",
            "-o", "cache.file=null", "-o", "extractor.twitter.ratelimit=abort",
            "-o", "extractor.twitter.retries-api=1", "--retries", "1", "--http-timeout", "30",
            item.sourceURL,
        ]
        let result = try await ProcessRunner.runAsync(executable: interpreter ?? executableURL,
            arguments: interpreter == nil ? arguments : ["-c", GalleryBridge.script, safariStore ?? ""] + arguments,
            timeout: 90)
        guard result.exitCode == 0 else {
            if let failure = Self.classifyError(result.stderr, browser: session.browser) { throw failure }
            return nil
        }
        let frames = try Self.jsonFrames(result.stdout)
        guard let frame = frames.first,
              let messages = try JSONSerialization.jsonObject(with: frame) as? [Any] else { return nil }
        let refreshed = try parseMessages(messages, collection: collection,
            cookiesFromBrowser: session.browser, mediaTypes: mediaTypes)
        return refreshed.first { $0.mediaID == item.mediaID }
    }

    public func checkSession(_ session: BrowserSession, accountName: String? = nil) async throws -> BrowserSessionCheck {
        guard let executableURL else { throw GalleryDlError.unavailable }
        let interpreter = GalleryBridge.interpreter(for: executableURL)
        guard let interpreter else {
            return BrowserSessionCheck(session: session, connected: false,
                message: "This gallery-dl installation cannot perform a private, in-memory X identity check. The collection scanner may still work, but account identity is unverified.")
        }
        let safariStore = session.browser == .safari ? session.profile : nil
        let cookieSession = BrowserSession(browser: session.browser,
            profile: session.browser == .safari ? nil : session.profile, container: session.container)
        let option = try cookieSession.galleryCookieOption()
        let prefix = "extractor.twitter.cookies="
        let specification = option.hasPrefix(prefix) ? String(option.dropFirst(prefix.count)) : "[]"

        do {
            let result = try await ProcessRunner.runAsync(executable: interpreter,
                arguments: ["-c", GalleryBridge.identityScript, safariStore ?? "", specification], timeout: 60)
            guard result.exitCode == 0 else {
                if let failure = Self.classifyError(result.stderr, browser: session.browser) { throw failure }
                throw GalleryDlError.scanFailed("The X identity check failed without exposing authentication details.")
            }
            guard let data = result.stdout.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GalleryDlError.malformedOutput("identity response was not valid JSON")
            }
            let connected = (json["connected"] as? Bool) == true
            let cookieID = Self.string(json["cookieUserID"])
            let serverID = Self.string(json["serverUserID"])
            let handle = Self.string(json["handle"])
            let verified = (json["serverVerified"] as? Bool) == true && serverID != nil
            let identity: XSessionIdentity?
            if verified, let serverID {
                identity = XSessionIdentity(userID: serverID, handle: handle, evidence: .serverVerified)
            } else if let cookieID {
                identity = XSessionIdentity(userID: cookieID, handle: nil, evidence: .cookieClaim)
            } else {
                identity = nil
            }
            let expected = BuiltInCollection.normalizedAccountName(accountName)
            if let expected, verified, let handle, expected.caseInsensitiveCompare(handle) != .orderedSame {
                return BrowserSessionCheck(session: session, connected: false,
                    message: "Connected X session belongs to @\(handle), not the expected @\(expected). Switch accounts in the browser and check again before syncing.",
                    identity: identity,
                    failureKind: .accountMismatch)
            }
            let message: String
            if verified, let handle {
                message = "Connected · server-verified X account @\(handle)"
            } else if connected, identity != nil {
                message = "Connected · X cookie identity found, but server identity could not be verified"
            } else if connected {
                message = "Connected · X authentication cookie found, account identity unverified"
            } else {
                message = session.browser == .safari
                    ? "This Safari profile/store is readable, but it does not contain a usable X login. Choose the Safari profile where you are signed in to X."
                    : "No usable X authentication session was found in this browser profile"
            }
            return BrowserSessionCheck(
                session: session,
                connected: connected,
                message: message,
                identity: identity,
                failureKind: connected ? nil : .noAuthentication
            )
        } catch is CancellationError { throw CancellationError() }
        catch {
            return BrowserSessionCheck(
                session: session,
                connected: false,
                message: error.localizedDescription,
                failureKind: .runtimeError
            )
        }
    }

    static func classifyError(_ text: String, browser: BrowserCookieSource) -> GalleryDlError? {
        let message = text.lowercased()
        if message.contains("permission denied") || message.contains("operation not permitted") {
            return .browserCookieAccessFailed(browser, "permissionDenied")
        }
        if message.contains("filenotfounderror") || message.contains("no such file or directory") || message.contains("unable to find") && message.contains("cookies") {
            return .browserCookieAccessFailed(browser, "storeMissing")
        }
        if browser == .safari, message.contains("cookies:") && (message.contains("struct.error") || message.contains("invalid")) {
            return .browserCookieAccessFailed(browser, "unsupportedFormat")
        }
        if message.contains("could not be decrypted") || message.contains("unable to find") && message.contains("cookies") ||
            message.contains("failed to decrypt") || message.contains("keychain") && message.contains("failed") {
            return .browserCookieAccessFailed(browser, "Cookie access failed")
        }
        if message.contains("captcha") || message.contains("security challenge") || message.contains("additional verification") ||
            message.contains("challenge_required") || message.contains("temporarily locked") {
            return .securityChallenge
        }
        if message.contains("ratelimit") || message.contains("rate limit") || message.contains("429") {
            return .rateLimited(retryAfter(from: message))
        }
        if message.contains("could not authenticate") || message.contains("authorizationerror") || message.contains("401") {
            return .sessionExpired
        }
        if message.contains("authrequired") || message.contains("authenticated cookies needed") { return .authenticationRequired(browser) }
        if message.contains("403") || message.contains("forbidden") { return .accessDenied }
        return nil
    }

    private static func retryAfter(from text: String) -> TimeInterval? {
        for pattern in ["retry-after[:= ]+(\\d+)", "retry after[:= ]+(\\d+)"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let seconds = TimeInterval(text[range]), seconds > 0 else { continue }
            return min(seconds, 6 * 60 * 60)
        }
        return nil
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
