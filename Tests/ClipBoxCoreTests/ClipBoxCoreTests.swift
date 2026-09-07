import XCTest
@testable import ClipBoxCore

final class ClipBoxCoreTests: XCTestCase {
    func testArchiveIdentityPreservesLargeIDsAsStrings() {
        let identity = ArchiveIdentity(
            site: "example",
            mediaID: "001234567890123456789"
        )

        XCTAssertEqual(identity.site, "example")
        XCTAssertEqual(identity.mediaID, "001234567890123456789")
    }

    func testFilenameSanitizerPreservesSpaces() {
        XCTAssertEqual(
            FilenameSanitizer.sanitize("A readable title [abc123]"),
            "A readable title [abc123]"
        )
    }

    func testFilenameSanitizerReplacesUnsafeCharacters() {
        XCTAssertEqual(
            FilenameSanitizer.sanitize("A/B:C?D*E"),
            "A_B_C_D_E"
        )
    }

    func testDefaultDownloadDirectoryEndsInClipBox() {
        XCTAssertEqual(
            ClipBoxPaths.defaultDownloadDirectory.lastPathComponent,
            "ClipBox"
        )
    }
}
