import CryptoKit
import Darwin
import Foundation

public enum CollectionWorkCoordinatorError: Error, LocalizedError, Sendable {
    case busy(site: String)

    public var errorDescription: String? {
        switch self {
        case .busy(let site):
            let displaySite = site == "instagram" ? "Instagram" : site == "twitter" ? "X" : site
            return "Another ClipBox \(displaySite) operation is already using this browser session. Wait for it to finish instead of starting a duplicate scan or sync."
        }
    }
}

public struct CollectionWorkScope: Hashable, Sendable {
    public let site: String
    public let ownerID: String?
    public let session: BrowserSession

    public init(site: String, ownerID: String? = nil, session: BrowserSession) {
        self.site = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.ownerID = ownerID?.isEmpty == false ? ownerID : nil
        self.session = session
    }

    fileprivate var key: String {
        let owner = ownerID.map { "owner:\($0)" } ?? "session:\(session.id)"
        let raw = "site:\(site)|\(owner)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public final class CollectionWorkLease: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum CollectionWorkCoordinator {
    public static func acquire(
        scope: CollectionWorkScope,
        directory: URL = ClipBoxPaths.applicationSupportDirectory.appendingPathComponent("coordination", isDirectory: true)
    ) throws -> CollectionWorkLease {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = directory.appendingPathComponent("collection-\(scope.key).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CollectionWorkCoordinatorError.busy(site: scope.site)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CollectionWorkCoordinatorError.busy(site: scope.site)
        }
        return CollectionWorkLease(descriptor: descriptor)
    }
}

public enum XWorkCoordinatorError: Error, LocalizedError, Sendable {
    case busy
    case cooldown(until: Date, reason: String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            "Another ClipBox X operation is already using this browser session or verified X account. Wait for it to finish instead of starting a second scan."
        case .cooldown(let until, let reason):
            "X requests are paused until \(until.formatted(date: .abbreviated, time: .standard)) after \(reason). Retry remains disabled during this cooldown."
        }
    }
}

public struct XWorkScope: Hashable, Sendable {
    public let ownerID: String?
    public let session: BrowserSession

    public init(ownerID: String? = nil, session: BrowserSession) {
        self.ownerID = ownerID?.isEmpty == false ? ownerID : nil
        self.session = session
    }

    fileprivate var key: String {
        let raw = ownerID.map { "owner:\($0)" } ?? "session:\(session.id)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public final class XWorkLease: @unchecked Sendable {
    private let lease: CollectionWorkLease
    fileprivate init(lease: CollectionWorkLease) { self.lease = lease }
}

private struct XCooldownState: Codable {
    let until: Date
    let reason: String
}

public enum XWorkCoordinator {
    public static func acquire(
        scope: XWorkScope,
        now: Date = Date(),
        directory: URL = ClipBoxPaths.applicationSupportDirectory.appendingPathComponent("coordination", isDirectory: true)
    ) throws -> XWorkLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if let cooldown = try cooldown(scope: scope, now: now, directory: directory) {
            throw XWorkCoordinatorError.cooldown(until: cooldown.until, reason: cooldown.reason)
        }
        do {
            return XWorkLease(lease: try CollectionWorkCoordinator.acquire(
                scope: CollectionWorkScope(site: "twitter", ownerID: scope.ownerID, session: scope.session),
                directory: directory
            ))
        } catch CollectionWorkCoordinatorError.busy {
            throw XWorkCoordinatorError.busy
        }
    }

    public static func setCooldown(
        scope: XWorkScope,
        until: Date,
        reason: String,
        directory: URL = ClipBoxPaths.applicationSupportDirectory.appendingPathComponent("coordination", isDirectory: true)
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let state = XCooldownState(until: until, reason: String(reason.prefix(120)))
        let data = try JSONEncoder().encode(state)
        let url = directory.appendingPathComponent("x-\(scope.key).cooldown.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func cooldownRemaining(
        scope: XWorkScope,
        now: Date = Date(),
        directory: URL = ClipBoxPaths.applicationSupportDirectory.appendingPathComponent("coordination", isDirectory: true)
    ) -> TimeInterval? {
        guard let state = try? cooldown(scope: scope, now: now, directory: directory) else { return nil }
        return max(0, state.until.timeIntervalSince(now))
    }

    private static func cooldown(
        scope: XWorkScope,
        now: Date,
        directory: URL
    ) throws -> XCooldownState? {
        let url = directory.appendingPathComponent("x-\(scope.key).cooldown.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(XCooldownState.self, from: Data(contentsOf: url))
        if state.until <= now {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return state
    }
}
