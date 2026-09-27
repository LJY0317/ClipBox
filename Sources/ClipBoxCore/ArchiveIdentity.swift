import Foundation

/// Stable identity used by ClipBox's archive layer.
///
/// A filename is intentionally not part of this identity. Downloaded files can
/// be renamed or moved to another disk while the archive record remains valid.
public struct ArchiveIdentity: Hashable, Sendable {
    public let site: String
    public let mediaID: String

    public init(site: String, mediaID: String) {
        self.site = site
        self.mediaID = mediaID
    }
}
