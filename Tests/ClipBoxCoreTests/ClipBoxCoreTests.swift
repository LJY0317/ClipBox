import Foundation
import XCTest
@testable import ClipBoxCore

final class ClipBoxCoreTests: XCTestCase {
    func testArchiveIdentityPreservesLargeNumericLookingIDsAsStrings() {
        let identity = ArchiveIdentity(
            site: "example",
            mediaID: "1965423400123456789"
        )

        XCTAssertEqual(identity.mediaID, "1965423400123456789")
    }

    func testFilenameSanitizerPreservesSpacesAndReplacesUnsafeCharacters() {
        XCTAssertEqual(
            FilenameSanitizer.sanitize("A readable title [abc123]"),
            "A readable title [abc123]"
        )
        XCTAssertEqual(
            FilenameSanitizer.sanitize("A/B:C?D*E"),
            "A_B_C_D_E"
        )
    }

    func testPreferencesDefaultToDownloadsClipBox() {
        let preferences = ClipBoxPreferences()
        XCTAssertEqual(
            preferences.resolvedOutputDirectory.lastPathComponent,
            "ClipBox"
        )
    }

    func testArchiveStoreRecordsAndFindsDownloadedMediaWithoutCheckingFilePresence() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("history.sqlite3"))
        let media = makeMedia()

        try await store.record(
            media: media,
            status: .downloaded,
            outputPath: "/Volumes/Offline Archive/Fake Video [1965423400123456789].mp4"
        )

        let isDownloaded = try await store.downloaded(identity: media.archiveIdentity)
        XCTAssertTrue(isDownloaded)
        let record = try await store.record(identity: media.archiveIdentity)
        XCTAssertEqual(record?.mediaID, "1965423400123456789")
        XCTAssertEqual(record?.status, .downloaded)
        XCTAssertEqual(record?.outputPath, "/Volumes/Offline Archive/Fake Video [1965423400123456789].mp4")
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testYtDlpClientParsesFormatsAndServiceSkipsSecondDownload() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fakeYtDlp = temp.appendingPathComponent("yt-dlp")
        try fakeYtDlpScript.write(to: fakeYtDlp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeYtDlp.path
        )

        let client = YtDlpClient(executableURL: fakeYtDlp)
        let media = try await client.inspect(url: "https://media.example.invalid/watch/123")
        XCTAssertEqual(media.site, "exampleextractor")
        XCTAssertEqual(media.mediaID, "1965423400123456789")
        XCTAssertEqual(media.formats.first?.resolutionDescription, "1920x1080")

        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("archive.sqlite3"))
        let service = try ClipBoxService(archive: store, ytDlp: client)

        let first = try await service.download(
            url: "https://media.example.invalid/watch/123",
            outputDirectory: temp
        )
        guard case .downloaded(_, let firstPath) = first else {
            return XCTFail("Expected first request to download")
        }
        XCTAssertTrue(firstPath.contains("Fake Video"))

        let second = try await service.download(
            url: "https://media.example.invalid/watch/123",
            outputDirectory: temp
        )
        guard case .skippedAlreadyArchived(_, let previousPath) = second else {
            return XCTFail("Expected second request to be skipped")
        }
        XCTAssertEqual(previousPath, firstPath)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBoxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMedia() -> MediaMetadata {
        MediaMetadata(
            site: "exampleextractor",
            mediaID: "1965423400123456789",
            sourceID: "post-123",
            inputURL: "https://media.example.invalid/watch/123",
            webpageURL: "https://media.example.invalid/watch/123",
            title: "Fake Video",
            creator: "Example Creator",
            uploadDate: "20260908",
            width: 1920,
            height: 1080,
            fps: 30,
            videoCodec: "h264",
            audioCodec: "aac",
            formatID: "1080"
        )
    }

    private var fakeYtDlpScript: String {
        """
        #!/bin/sh
        case " $* " in
          *" --version "*)
            echo "2026.09.08-test"
            exit 0
            ;;
          *" --dump-single-json "*)
            cat <<'JSON'
        {"id":"1965423400123456789","display_id":"post-123","extractor_key":"ExampleExtractor","webpage_url":"https://media.example.invalid/watch/123","title":"Fake Video","uploader":"Example Creator","upload_date":"20260908","duration":42.5,"width":1920,"height":1080,"fps":30,"vcodec":"h264","acodec":"aac","format_id":"1080","formats":[{"format_id":"360","ext":"mp4","width":640,"height":360,"fps":30,"tbr":800,"vcodec":"h264","acodec":"aac"},{"format_id":"1080","ext":"mp4","width":1920,"height":1080,"fps":30,"tbr":5000,"vcodec":"h264","acodec":"aac"}]}
        JSON
            exit 0
            ;;
          *" --print "*)
            echo "/tmp/Fake Video [1965423400123456789].mp4"
            exit 0
            ;;
        esac
        echo "unsupported fake yt-dlp invocation" >&2
        exit 2
        """
    }
}
