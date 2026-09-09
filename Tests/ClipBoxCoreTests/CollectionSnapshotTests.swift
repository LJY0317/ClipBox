import XCTest
@testable import ClipBoxCore

final class CollectionSnapshotTests: XCTestCase, @unchecked Sendable {
    private func snapshot(_ ids: [String], limit: Int? = nil) -> CollectionSnapshot {
        let items = ids.map { id in CollectionItem(site: "twitter", collectionName: "likes", mediaID: id,
            sourceID: id, sourceURL: "https://example.invalid/status/" + id,
            directMediaURL: "https://example.invalid/media?token=synthetic-secret") }
        var result = CollectionBatchScanResult(collections: [.xLikes], items: [], scannedOccurrences: items.count)
        result.collectionItems = items
        return CollectionSnapshot(result: result, limit: limit, mediaTypes: .all)
    }

    func testSnapshotPreservesReturnedOrderAndExcludesDownloadCredentials() throws {
        let value = snapshot(["30", "10", "20"])
        XCTAssertEqual(value.entries.map(\.postID), ["30", "10", "20"])
        XCTAssertEqual(value.entries.map(\.position), [1, 2, 3])
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-secret"))
        XCTAssertFalse(encoded.contains("directMediaURL"))
    }

    func testComparisonDoesNotMixScopeOrCallMissingItemsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CollectionSnapshotStore(directory: directory)
        let session = BrowserSession(browser: .chrome, profile: "synthetic")
        _ = try await store.record(snapshot(["1", "2"]), session: session, handle: "example")
        let comparison = try await store.record(snapshot(["2", "3"]), session: session, handle: "example")
        XCTAssertEqual(comparison.added, 1)
        XCTAssertEqual(comparison.notReturned.map(\.postID), ["1"])
        let limited = try await store.record(snapshot(["2"], limit: 100), session: session, handle: "example")
        XCTAssertNil(limited.previousDate)
        let otherAccount = try await store.record(snapshot(["2"]), session: session, handle: "other")
        XCTAssertNil(otherAccount.previousDate)
    }

    func testDiagnosticParserIgnoresAllOtherOutput() {
        let input = "Private server body omitted\nCLIPBOX_SCAN {\"collection\":\"Likes\",\"pages\":5,\"entries\":147,\"lastPageEntries\":0,\"stop\":\"repeated_cursor\"}\n"
        let diagnostics = GalleryBridge.diagnostics(input)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.pages, 5)
        XCTAssertEqual(diagnostics.first?.stop, "repeated_cursor")
    }

    func testExecutionPlanReuseRequiresSameOwnerSettingsAndFreshness() {
        let session = BrowserSession(browser: .chrome, profile: "/synthetic/Profile")
        let context = CollectionExecutionContext(collections: [.xLikes, .xBookmarks], accountName: "example",
            session: session, mediaTypes: .all, limit: 100, ownerID: "424242")
        let result = CollectionBatchScanResult(collections: [.xLikes, .xBookmarks], items: [], scannedOccurrences: 0)
        let data = CollectionBatchScanData(result: result, membershipItems: [])
        var cache = CollectionExecutionPlanCache(lifetime: 600)
        let now = Date()
        cache.store(context: context, data: data, now: now)
        XCTAssertNotNil(cache.reusableData(context: context, now: now.addingTimeInterval(30)))

        let otherOwner = CollectionExecutionContext(collections: context.collections, accountName: context.accountName,
            session: context.session, mediaTypes: context.mediaTypes, limit: context.limit, ownerID: "777777")
        XCTAssertNil(cache.reusableData(context: otherOwner, now: now.addingTimeInterval(30)))
        let otherLimit = CollectionExecutionContext(collections: context.collections, accountName: context.accountName,
            session: context.session, mediaTypes: context.mediaTypes, limit: 500, ownerID: context.ownerID)
        XCTAssertNil(cache.reusableData(context: otherLimit, now: now.addingTimeInterval(30)))
        XCTAssertNil(cache.reusableData(context: context, now: now.addingTimeInterval(601)))
    }
}
