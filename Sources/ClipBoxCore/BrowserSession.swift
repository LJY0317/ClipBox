import Foundation
import SQLite3

/// Non-secret preferences. Cookie contents are owned by the extraction tool.
public struct BrowserSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let browser: BrowserCookieSource
    public let profile: String?
    public let container: String?
    public var id: String { "\(browser.rawValue):\(profile ?? ""): \(container ?? "")" }
    public var displayName: String {
        [browser.displayName, profile.map {
            let url = URL(fileURLWithPath: $0)
            if browser == .safari {
                let store = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                return store == "Library" ? "Default profile" : "Unidentified Safari store"
            }
            return url.lastPathComponent
        }, container]
            .compactMap { $0 }.joined(separator: " · ")
    }
    public init(browser: BrowserCookieSource, profile: String? = nil, container: String? = nil) {
        self.browser = browser
        self.profile = profile?.isEmpty == false ? profile : nil
        self.container = container?.isEmpty == false ? container : nil
    }

    func galleryCookieOption() throws -> String {
        if browser == .safari, profile != nil || container != nil {
            throw GalleryDlError.unsupportedSession("gallery-dl cannot select Safari profiles. Use Chrome, Firefox or Brave for a specific profile.")
        }
        if container != nil, browser != .firefox {
            throw GalleryDlError.unsupportedSession("Container selection is available only for Firefox.")
        }
        let specification: [Any] = [browser.rawValue, profile as Any? ?? NSNull(), NSNull(), container as Any? ?? NSNull(), ".x.com"]
        let data = try JSONSerialization.data(withJSONObject: specification, options: [.withoutEscapingSlashes])
        return "extractor.twitter.cookies=" + String(decoding: data, as: UTF8.self)
    }
}

public enum BrowserSessionDiscoveryIssueKind: String, Codable, Equatable, Sendable {
    case enumerationPermissionDenied
    case fileReadPermissionDenied
    case unsupportedFormat
    case metadataPermissionDenied
    case metadataUnreadable
}

public struct BrowserSessionDiscoveryIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(browser.rawValue):\(kind.rawValue):\(area)" }
    public let browser: BrowserCookieSource
    public let kind: BrowserSessionDiscoveryIssueKind
    public let area: String

    public init(browser: BrowserCookieSource, kind: BrowserSessionDiscoveryIssueKind, area: String) {
        self.browser = browser
        self.kind = kind
        self.area = area
    }

    public var message: String {
        switch kind {
        case .enumerationPermissionDenied:
            "macOS denied ClipBox permission to enumerate \(area). This is different from there being no stores."
        case .fileReadPermissionDenied:
            "ClipBox found \(area), but macOS denied reading its cookie file."
        case .unsupportedFormat:
            "ClipBox found \(area), but its Safari cookie file is not a supported binarycookies format."
        case .metadataPermissionDenied:
            "macOS denied access to Safari's local profile metadata. Stores remain selectable, but profile names cannot be matched."
        case .metadataUnreadable:
            "Safari's local profile metadata could not be read reliably. Stores remain selectable without guessed names."
        }
    }
}

public struct BrowserSessionDiscoveryReport: Sendable {
    public let sessions: [BrowserSession]
    public let labels: [String: String]
    public let issues: [BrowserSessionDiscoveryIssue]

    public init(sessions: [BrowserSession], labels: [String: String], issues: [BrowserSessionDiscoveryIssue]) {
        self.sessions = sessions
        self.labels = labels
        self.issues = issues
    }

    public var discoveredSafariStoreCount: Int {
        sessions.lazy.filter { $0.browser == .safari && $0.profile != nil }.count
    }
}

public enum XSessionIdentityEvidence: String, Codable, Equatable, Sendable {
    case cookieClaim
    case serverVerified
}

public struct XSessionIdentity: Codable, Equatable, Sendable {
    public let userID: String
    public let handle: String?
    public let evidence: XSessionIdentityEvidence

    public init(userID: String, handle: String?, evidence: XSessionIdentityEvidence) {
        self.userID = userID
        self.handle = handle
        self.evidence = evidence
    }
}

public enum BrowserSessionDiscovery {
    /// Display-only metadata. Never include these labels in preferences or diagnostics.
    public static func profileLabels(
        for sessions: [BrowserSession],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        report(home: home, limitingTo: sessions).labels
    }

    public static func report(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BrowserSessionDiscoveryReport {
        report(home: home, limitingTo: nil)
    }

    private static func report(home: URL, limitingTo requestedSessions: [BrowserSession]?) -> BrowserSessionDiscoveryReport {
        var caches: [URL: [String: [String: Any]]] = [:]
        var labels: [String: String] = [:]
        var issues: [BrowserSessionDiscoveryIssue] = []
        let roots: [(BrowserCookieSource, String)] = [
            (.chrome, "Google/Chrome"), (.firefox, "Firefox/Profiles"),
            (.brave, "BraveSoftware/Brave-Browser"), (.edge, "Microsoft Edge"),
            (.chromium, "Chromium")
        ]
        let support = home.appendingPathComponent("Library/Application Support")
        var sessions: [BrowserSession] = []

        for (browser, relativePath) in roots {
            let root = support.appendingPathComponent(relativePath)
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
            } catch {
                if !isMissing(error), permissionDenied(error) {
                    issues.append(.init(browser: browser, kind: .enumerationPermissionDenied, area: "\(browser.displayName) profiles"))
                }
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if browser != .firefox, child.lastPathComponent != "Default", !child.lastPathComponent.hasPrefix("Profile ") { continue }
                sessions.append(BrowserSession(browser: browser, profile: child.path))
            }
        }

        let safariLibrary = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
        let defaults = [home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            safariLibrary.appendingPathComponent("Cookies/Cookies.binarycookies")]
        for (index, file) in defaults.enumerated() {
            switch probeSafariCookieFile(file) {
            case .readable:
                sessions.append(BrowserSession(browser: .safari, profile: file.path))
            case .permissionDenied:
                issues.append(.init(browser: .safari, kind: .fileReadPermissionDenied,
                    area: index == 0 ? "Safari legacy cookie store" : "Safari default cookie store"))
            case .unsupportedFormat:
                issues.append(.init(browser: .safari, kind: .unsupportedFormat,
                    area: index == 0 ? "Safari legacy cookie store" : "Safari default cookie store"))
            case .missing, .unreadable:
                break
            }
        }

        let storeRoot = safariLibrary.appendingPathComponent("WebKit/WebsiteDataStore")
        do {
            let stores = try FileManager.default.contentsOfDirectory(at: storeRoot,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for store in stores.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? store.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let file = store.appendingPathComponent("Cookies/Cookies.binarycookies")
                switch probeSafariCookieFile(file) {
                case .readable:
                    sessions.append(BrowserSession(browser: .safari, profile: file.path))
                case .permissionDenied:
                    issues.append(.init(browser: .safari, kind: .fileReadPermissionDenied, area: "a Safari profile store"))
                case .unsupportedFormat:
                    issues.append(.init(browser: .safari, kind: .unsupportedFormat, area: "a Safari profile store"))
                case .missing, .unreadable:
                    break
                }
            }
        } catch {
            if !isMissing(error), permissionDenied(error) {
                issues.append(.init(browser: .safari, kind: .enumerationPermissionDenied, area: "Safari profile stores"))
            }
        }

        if !sessions.contains(where: { $0.browser == .safari }) {
            sessions.append(BrowserSession(browser: .safari))
        }

        if let requestedSessions {
            sessions = requestedSessions
            issues = []
        }

        for session in sessions {
            guard session.browser != .safari, session.browser != .firefox,
                  let profile = session.profile else { continue }
            let directory = URL(fileURLWithPath: profile)
            let stateURL = directory.deletingLastPathComponent().appendingPathComponent("Local State")
            if caches[stateURL] == nil {
                let data = try? Data(contentsOf: stateURL)
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let profileInfo = json?["profile"] as? [String: Any]
                caches[stateURL] = profileInfo?["info_cache"] as? [String: [String: Any]] ?? [:]
            }
            guard let info = caches[stateURL]?[directory.lastPathComponent] else { continue }
            func clean(_ key: String) -> String? {
                guard let value = info[key] as? String else { return nil }
                let text = value.components(separatedBy: .controlCharacters).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : String(text.prefix(160))
            }
            let name = clean("name") ?? directory.lastPathComponent
            let email = clean("user_name")
            labels[session.id] = [name, email == name ? nil : email, "(\(directory.lastPathComponent))"]
                .compactMap { $0 }.joined(separator: " · ")
        }

        let safariProfileMetadata = safariProfileNames(safariLibrary: safariLibrary)
        if let issueKind = safariProfileMetadata.issueKind,
           !issues.contains(where: { $0.browser == .safari && $0.kind == issueKind }) {
            issues.append(.init(browser: .safari, kind: issueKind, area: "Safari profile metadata"))
        }
        var unidentifiedSafariStoreIndex = 0
        for session in sessions where session.browser == .safari {
            guard let path = session.profile else {
                labels[session.id] = "Safari · Automatic legacy store"
                continue
            }
            let url = URL(fileURLWithPath: path)
            if path.contains("/WebKit/WebsiteDataStore/") {
                let storeID = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased()
                if let profileName = safariProfileMetadata.names[storeID] {
                    labels[session.id] = "Safari · \(profileName)"
                } else {
                    unidentifiedSafariStoreIndex += 1
                    labels[session.id] = "Safari · Unidentified store \(unidentifiedSafariStoreIndex)"
                }
            } else {
                let defaultName = safariProfileMetadata.names["defaultprofile"] ?? "Default profile"
                labels[session.id] = "Safari · \(defaultName)"
            }
        }

        return BrowserSessionDiscoveryReport(sessions: sessions, labels: labels, issues: issues)
    }

    /// Compatibility helper for callers that only need selectable sessions.
    public static func sessions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserSession] {
        report(home: home).sessions
    }

    private enum SafariCookieProbe {
        case readable
        case missing
        case permissionDenied
        case unsupportedFormat
        case unreadable
    }

    private struct SafariProfileMetadata {
        let names: [String: String]
        let issueKind: BrowserSessionDiscoveryIssueKind?
    }

    /// Safari stores profile records in SafariTabs.db. Only rows explicitly
    /// marked as profile records are considered; ordinary page/tab titles are
    /// never used as profile names. The profile record's external UUID is the
    /// key used by matching WebsiteDataStore directories.
    private static func safariProfileNames(safariLibrary: URL) -> SafariProfileMetadata {
        let databaseURL = safariLibrary.appendingPathComponent("Safari/SafariTabs.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return SafariProfileMetadata(names: [:], issueKind: nil)
        }

        do {
            let handle = try FileHandle(forReadingFrom: databaseURL)
            try? handle.close()
        } catch {
            return SafariProfileMetadata(
                names: [:],
                issueKind: permissionDenied(error) ? .metadataPermissionDenied : .metadataUnreadable
            )
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return SafariProfileMetadata(names: [:], issueKind: .metadataUnreadable)
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT title, external_uuid
        FROM bookmarks
        WHERE type = 1 AND subtype = 2 AND external_uuid IS NOT NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return SafariProfileMetadata(names: [:], issueKind: .metadataUnreadable)
        }
        defer { sqlite3_finalize(statement) }

        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let uuidValue = sqlite3_column_text(statement, 1) else { continue }
            let uuid = String(cString: uuidValue).lowercased()
            guard !uuid.isEmpty else { continue }

            let rawTitle = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let title = rawTitle?
                .components(separatedBy: .controlCharacters).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                names[uuid] = String(title.prefix(160))
            } else if uuid == "defaultprofile" {
                names[uuid] = "Default profile"
            }
        }
        return SafariProfileMetadata(names: names, issueKind: nil)
    }

    private static func probeSafariCookieFile(_ url: URL) -> SafariCookieProbe {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 4) ?? Data()
            return signature == Data("cook".utf8) ? .readable : .unsupportedFormat
        } catch {
            if isMissing(error) { return .missing }
            if permissionDenied(error) { return .permissionDenied }
            return .unreadable
        }
    }

    private static func permissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) { return true }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue { return true }
        return false
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        if nsError.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(nsError.code) { return true }
        return false
    }
}

public struct BrowserSessionCheck: Sendable, Identifiable {
    public var id: String { session.id }
    public let session: BrowserSession
    public let connected: Bool
    public let message: String
    public let identity: XSessionIdentity?
    public let failureKind: BrowserSessionCheckFailureKind?
    public let checkedAt: Date

    public init(
        session: BrowserSession,
        connected: Bool,
        message: String,
        identity: XSessionIdentity? = nil,
        failureKind: BrowserSessionCheckFailureKind? = nil,
        checkedAt: Date = Date()
    ) {
        self.session = session
        self.connected = connected
        self.message = message
        self.identity = identity
        self.failureKind = failureKind
        self.checkedAt = checkedAt
    }
}

public enum BrowserSessionCheckFailureKind: String, Sendable {
    case noAuthentication
    case accountMismatch
    case runtimeError
}
