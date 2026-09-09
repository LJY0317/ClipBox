import XCTest
import SQLite3
@testable import ClipBoxCore

final class BrowserSessionTests: XCTestCase, @unchecked Sendable {
    func testProfileConfigurationIsStructuredAndDomainScoped() throws {
        let session = BrowserSession(browser: .chrome, profile: "Profile 1\"; example")
        let option = try session.galleryCookieOption()
        let encoded = String(option.dropFirst("extractor.twitter.cookies=".count))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [Any])
        XCTAssertEqual(value[0] as? String, "chrome")
        XCTAssertEqual(value[1] as? String, session.profile)
        XCTAssertEqual(value[4] as? String, ".x.com")
        XCTAssertThrowsError(try BrowserSession(browser: .safari, profile: "Personal").galleryCookieOption())
        XCTAssertThrowsError(try BrowserSession(browser: .chrome, container: "Work").galleryCookieOption())
    }

    func testLegacyPreferencesDecodeWithoutSessionFields() throws {
        let preferences = try JSONDecoder().decode(ClipBoxPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(preferences.xAccountHandle)
        XCTAssertNil(preferences.xBrowserSession)
        let selected = ClipBoxPreferences(xAccountHandle: "ExampleUser", xBrowserSession: .init(browser: .firefox, profile: "example.default", container: "Personal"))
        XCTAssertEqual(try JSONDecoder().decode(ClipBoxPreferences.self, from: JSONEncoder().encode(selected)), selected)
    }

    func testInvalidHandlesCannotConstructOtherURLs() {
        for handle in ["", "abc/../home", "user?query", "éxample", String(repeating: "a", count: 16)] {
            XCTAssertNil(BuiltInCollection.xLikes.collectionURL(accountName: handle))
        }
        XCTAssertEqual(BuiltInCollection.normalizedAccountName(" @Example_123 "), "Example_123")
    }

    func testCookiePermissionErrorIsNotMisreportedAsMissingSession() {
        let error = GalleryDlClient.classifyError("cookies: Operation not permitted\nAuthRequired", browser: .safari)
        guard case .browserCookieAccessFailed = error else { return XCTFail("Wrong error category") }
        XCTAssertTrue(error?.localizedDescription.contains("macOS denied") == true)
        XCTAssertFalse(error?.localizedDescription.contains("No usable X session") == true)
    }

    func testSafariProfileNamesComeFromProfileRecordsNotUUIDFragments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let safariLibrary = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
        let databaseURL = safariLibrary.appendingPathComponent("Safari/SafariTabs.db")
        let namedStoreID = "11111111-2222-3333-4444-555555555555"
        let unknownStoreID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        let schema = "CREATE TABLE bookmarks (type INTEGER, subtype INTEGER, title TEXT, external_uuid TEXT);"
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        let rows = """
        INSERT INTO bookmarks(type, subtype, title, external_uuid) VALUES
          (1, 2, 'Work', '\(namedStoreID)'),
          (0, 0, 'A page title that must be ignored', '\(unknownStoreID)');
        """
        XCTAssertEqual(sqlite3_exec(database, rows, nil, nil, nil), SQLITE_OK)

        for storeID in [namedStoreID, unknownStoreID] {
            let cookieURL = safariLibrary
                .appendingPathComponent("WebKit/WebsiteDataStore/\(storeID)/Cookies/Cookies.binarycookies")
            try FileManager.default.createDirectory(at: cookieURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("cook".utf8).write(to: cookieURL)
        }

        let report = BrowserSessionDiscovery.report(home: root)
        let safari = report.sessions.filter { $0.browser == .safari && $0.profile != nil }
        let labels = safari.compactMap { report.labels[$0.id] }
        XCTAssertTrue(labels.contains("Safari · Work"))
        XCTAssertTrue(labels.contains("Safari · Unidentified store 1"))
        XCTAssertFalse(labels.contains { $0.contains("11111111") || $0.contains("AAAAAAAA") })
        XCTAssertFalse(labels.contains { $0.contains("A page title that must be ignored") })
    }

    func testRateLimitAndExpiredSessionDoNotEchoRawTokens() {
        for message in ["429 auth_token=synthetic-secret", "Could not authenticate you ct0=synthetic-secret"] {
            let error = GalleryDlClient.classifyError(message, browser: .chrome)
            XCTAssertNotNil(error)
            XCTAssertFalse(error?.localizedDescription.contains("synthetic-secret") == true)
        }
    }

    func testHTTPAndSecurityFailuresAreDistinct() {
        guard case .rateLimited(let delay) = GalleryDlClient.classifyError("HTTP 429 Retry-After: 37", browser: .chrome) else {
            return XCTFail("Expected rate limit")
        }
        XCTAssertEqual(delay, 37)
        guard case .securityChallenge = GalleryDlClient.classifyError("additional verification challenge_required", browser: .chrome) else {
            return XCTFail("Expected security challenge")
        }
        guard case .accessDenied = GalleryDlClient.classifyError("HTTP 403 Forbidden", browser: .chrome) else {
            return XCTFail("Expected generic access denied")
        }
        guard case .sessionExpired = GalleryDlClient.classifyError("HTTP 401 Could not authenticate", browser: .chrome) else {
            return XCTFail("Expected expired session")
        }
    }

    func testSafariMissingStoreAndEnumerationDenialAreNotEquivalent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = BrowserSessionDiscovery.report(home: root)
        XCTAssertTrue(empty.issues.filter { $0.browser == .safari }.isEmpty)
        XCTAssertEqual(empty.discoveredSafariStoreCount, 0)

        let storeRoot = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeRoot.path) }
        let denied = BrowserSessionDiscovery.report(home: root)
        XCTAssertTrue(denied.issues.contains { $0.kind == .enumerationPermissionDenied && $0.browser == .safari })
    }

    func testCrossProcessStyleLockAndPersistentCooldownContainNoSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = BrowserSession(browser: .chrome, profile: "/synthetic/Profile 1")
        let scope = XWorkScope(session: session)
        let first = try XWorkCoordinator.acquire(scope: scope, directory: directory)
        XCTAssertThrowsError(try XWorkCoordinator.acquire(scope: scope, directory: directory)) { error in
            guard case XWorkCoordinatorError.busy = error else { return XCTFail("Expected busy lock") }
        }
        withExtendedLifetime(first) { }
        let until = Date().addingTimeInterval(120)
        try XWorkCoordinator.setCooldown(scope: scope, until: until, reason: "synthetic rate limit", directory: directory)
        XCTAssertGreaterThan(XWorkCoordinator.cooldownRemaining(scope: scope, directory: directory) ?? 0, 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(text.contains("Profile 1"))
        XCTAssertFalse(text.contains("auth_token"))
        XCTAssertFalse(text.contains("ct0"))
    }

    func testProcessDrainsBothPipesAndDoesNotDeadlock() throws {
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/awk"), arguments: [
            "BEGIN { for (i=0;i<20000;i++) { print \"out\"; print \"err\" > \"/dev/stderr\" } }"
        ], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 80000)
        XCTAssertEqual(result.stderr.utf8.count, 80000)
    }

    func testProcessInputUsesPipe() throws {
        let data = Data(repeating: 65, count: 200000)
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: data, timeout: 10)
        XCTAssertEqual(result.stdout.utf8.count, data.count)
    }

    func testPageCursorControlChannelIsRemovedBeforeDiagnostics() {
        let syntheticCursor = "synthetic-opaque-cursor"
        let stderr = "CLIPBOX_SCAN {\"collection\":\"Bookmarks\",\"pages\":1,\"entries\":50,\"lastPageEntries\":50,\"stop\":\"stopped_with_next_cursor\"}\nCLIPBOX_PAGESTATE {\"collection\":\"Bookmarks\",\"nextCursor\":\"\(syntheticCursor)\"}\n"
        XCTAssertEqual(GalleryBridge.pageStates(stderr).first?.nextCursor, syntheticCursor)
        XCTAssertFalse(GalleryBridge.stderrWithoutPrivatePageState(stderr).contains(syntheticCursor))
        XCTAssertEqual(GalleryBridge.diagnostics(stderr).first?.pages, 1)
    }

    func testAsyncProcessTimeoutAndCancellation() async throws {
        let input = Data("async-pipe".utf8)
        let echoed = try await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: input, timeout: 10
        )
        XCTAssertEqual(echoed.stdout, "async-pipe")
        do {
            _ = try await ProcessRunner.runAsync(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch ProcessRunnerError.timedOut { }
        let task = Task { try await ProcessRunner.runAsync(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
