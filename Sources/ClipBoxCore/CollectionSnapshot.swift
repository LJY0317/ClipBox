import CryptoKit
import Foundation

public struct CollectionObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { collection.rawValue + ":" + mediaID }
    public let collection: BuiltInCollection
    public let position: Int
    public let mediaID: String
    public let postID: String
    public let sourceURL: String
    public let title: String?
    public let type: MediaAssetType
    public let publishedAt: String?
    public let bookmarkedAt: String?
    public let downloaded: Bool
}

public struct CollectionSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let limit: Int?
    public let collections: [BuiltInCollection]
    public let mediaTypes: MediaTypeSelection
    public let entries: [CollectionObservation]
    public let diagnostics: [CollectionDiagnostic]

    public init(result: CollectionBatchScanResult, limit: Int?, mediaTypes: MediaTypeSelection) {
        capturedAt = Date()
        self.limit = limit
        collections = result.collections
        self.mediaTypes = mediaTypes
        diagnostics = result.diagnostics ?? []
        let downloaded = Set(result.items.filter(\.alreadyDownloaded).map { $0.item.archiveIdentity })
        var observations: [CollectionObservation] = []
        for collection in result.collections {
            let items = result.collectionItems?.filter { $0.collectionName == collection.collectionName && $0.site == collection.site }
                ?? result.items.filter { $0.collections.contains(collection) }.map(\.item)
            var positions: [String: Int] = [:]
            for item in items {
                let post = item.sourceID ?? item.mediaID
                if positions[post] == nil { positions[post] = positions.count + 1 }
                observations.append(CollectionObservation(collection: collection, position: positions[post]!,
                    mediaID: item.mediaID, postID: post, sourceURL: item.sourceURL, title: item.title,
                    type: item.mediaType, publishedAt: item.publishedAt, bookmarkedAt: item.bookmarkedAt,
                    downloaded: downloaded.contains(item.archiveIdentity)))
            }
        }
        entries = observations
    }
}

public struct CollectionComparison: Sendable {
    public let current: CollectionSnapshot
    public let previousDate: Date?
    public let added: Int
    public let notReturned: [CollectionObservation]
    public init(current: CollectionSnapshot, previousDate: Date?, added: Int, notReturned: [CollectionObservation]) {
        self.current = current
        self.previousDate = previousDate
        self.added = added
        self.notReturned = notReturned
    }
}

/// Local observation history, separate from download history. Does not contain cookies,
/// direct media URLs or tokens. A route/handle scope is NOT a verified account identity.
public actor CollectionSnapshotStore {
    public static let shared = CollectionSnapshotStore()
    private let directory: URL
    public init(directory: URL = ClipBoxPaths.applicationSupportDirectory.appendingPathComponent("scans")) {
        self.directory = directory
    }

    public func record(_ snapshot: CollectionSnapshot, session: BrowserSession, handle: String) throws -> CollectionComparison {
        let fields = [session.id, handle.lowercased(), snapshot.limit.map(String.init) ?? "all",
            snapshot.collections.map(\.rawValue).sorted().joined(separator: ","),
            snapshot.mediaTypes.types.map(\.rawValue).sorted().joined(separator: ",")]
        let scopeData = try JSONEncoder().encode(fields)
        let key = SHA256.hash(data: scopeData).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let latest = directory.appendingPathComponent(key + ".json")
        let previous: CollectionSnapshot?
        if FileManager.default.fileExists(atPath: latest.path) {
            previous = try JSONDecoder().decode(CollectionSnapshot.self, from: Data(contentsOf: latest))
        } else { previous = nil }
        let currentIDs = Set(snapshot.entries.map(\.id))
        let previousIDs = Set(previous?.entries.map(\.id) ?? [])
        let missing = previous?.entries.filter { !currentIDs.contains($0.id) } ?? []
        // Keep the prior snapshot too; missing entries are never treated as deletion.
        if let previous { try write(previous, to: directory.appendingPathComponent(key + "-previous.json")) }
        try write(snapshot, to: latest)
        return CollectionComparison(current: snapshot, previousDate: previous?.capturedAt,
            added: currentIDs.subtracting(previousIDs).count, notReturned: missing)
    }

    private func write(_ snapshot: CollectionSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
