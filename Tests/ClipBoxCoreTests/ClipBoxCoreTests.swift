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

    func testPortableBackupRestoresHistoryIntoAnotherDatabaseByMerge() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceStore = try ArchiveStore(databaseURL: temp.appendingPathComponent("source.sqlite3"))
        let media = makeMedia()
        try await sourceStore.record(
            media: media,
            status: .downloaded,
            outputPath: "/Volumes/Old Mac Archive/Fake Video [1965423400123456789].mp4"
        )
        _ = try await sourceStore.recordCollectionItems([
            CollectionItem(
                site: "youtube",
                collectionName: "liked",
                mediaID: media.mediaID,
                sourceURL: media.webpageURL ?? media.inputURL,
                title: media.title,
                creator: media.creator
            )
        ])

        let backupURL = temp.appendingPathComponent("portable.clipboxbackup")
        let sourceBackupService = try BackupService(archive: sourceStore)
        let created = try await sourceBackupService.createBackup(at: backupURL)
        XCTAssertEqual(created.recordCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

        let destinationStore = try ArchiveStore(databaseURL: temp.appendingPathComponent("destination.sqlite3"))
        let destinationBackupService = try BackupService(archive: destinationStore)
        let restored = try await destinationBackupService.restoreBackup(from: backupURL)

        XCTAssertEqual(restored.backupRecordCount, 1)
        XCTAssertEqual(restored.recordsProcessed, 1)
        XCTAssertEqual(restored.recordsAdded, 1)
        XCTAssertEqual(restored.finalRecordCount, 1)
        XCTAssertFalse(restored.preferencesRestored)

        let restoredRecord = try await destinationStore.record(identity: media.archiveIdentity)
        XCTAssertEqual(restoredRecord?.status, .downloaded)
        XCTAssertEqual(
            restoredRecord?.outputPath,
            "/Volumes/Old Mac Archive/Fake Video [1965423400123456789].mp4"
        )
        let membershipCount = try await destinationStore.collectionCount(
            site: "youtube",
            collectionName: "liked"
        )
        XCTAssertEqual(membershipCount, 1)
    }

    func testArchiveImportDoesNotDowngradeExistingDownloadedRecord() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("history.sqlite3"))
        let media = makeMedia()

        try await store.record(
            media: media,
            status: .downloaded,
            outputPath: "/Current/Archive/Fake Video.mp4"
        )

        let failedIncoming = ArchiveRecord(
            site: media.site,
            mediaID: media.mediaID,
            sourceID: media.sourceID,
            sourceURL: media.webpageURL,
            creator: media.creator,
            title: "Older Backup Title",
            publishedAt: media.uploadDate,
            firstSeenAt: "2026-01-01T00:00:00Z",
            downloadedAt: nil,
            status: .failed,
            lastError: "old backup failure"
        )

        _ = try await store.importRecords([failedIncoming])
        let merged = try await store.record(identity: media.archiveIdentity)
        XCTAssertEqual(merged?.status, .downloaded)
        XCTAssertEqual(merged?.outputPath, "/Current/Archive/Fake Video.mp4")
        XCTAssertNil(merged?.lastError)
    }

    func testYouTubeCollectionSyncDownloadsOnlyUnarchivedItems() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fakeYtDlp = temp.appendingPathComponent("yt-dlp")
        try fakeYtDlpScript.write(to: fakeYtDlp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeYtDlp.path
        )

        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("collections.sqlite3"))
        let alreadyArchived = MediaMetadata(
            site: "youtube",
            mediaID: "old123",
            inputURL: "https://www.youtube.com/watch?v=old123",
            webpageURL: "https://www.youtube.com/watch?v=old123",
            title: "Already Archived"
        )
        try await store.record(
            media: alreadyArchived,
            status: .downloaded,
            outputPath: "/Volumes/Archive/Already Archived [old123].mp4"
        )

        let client = YtDlpClient(executableURL: fakeYtDlp)
        let service = try CollectionSyncService(archive: store, ytDlp: client)

        let preview = try await service.scan(
            collection: .youtubeLiked,
            cookiesFromBrowser: .safari,
            limit: 100
        )
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(preview.unarchivedCount, 1)
        XCTAssertTrue(preview.items.first { $0.item.mediaID == "old123" }?.alreadyDownloaded == true)
        XCTAssertTrue(preview.items.first { $0.item.mediaID == "new456" }?.alreadyDownloaded == false)

        let result = try await service.sync(
            collection: .youtubeLiked,
            cookiesFromBrowser: .safari,
            outputDirectory: temp,
            limit: 100
        )
        XCTAssertEqual(result.scanned, 2)
        XCTAssertEqual(result.unarchived, 1)
        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(result.skippedAlreadyArchived, 1)
        XCTAssertEqual(result.failed, 0)

        let collectionCount = try await store.collectionCount(site: "youtube", collectionName: "liked")
        XCTAssertEqual(collectionCount, 2)
        let newDownloaded = try await store.downloaded(
            identity: ArchiveIdentity(site: "youtube", mediaID: "new456")
        )
        XCTAssertTrue(newDownloaded)
        let archiveCount = try await store.count()
        XCTAssertEqual(archiveCount, 2)
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
          *" :ytfav "*)
            cat <<'JSON'
        {"id":"LL","title":"Liked videos","entries":[{"id":"old123","url":"https://www.youtube.com/watch?v=old123","title":"Already Archived"},{"id":"new456","url":"https://www.youtube.com/watch?v=new456","title":"Brand New Video"}]}
        JSON
            exit 0
            ;;
          *" --dump-single-json "*"new456"*)
            cat <<'JSON'
        {"id":"new456","display_id":"new456","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=new456","title":"Brand New Video","uploader":"Example Creator","upload_date":"20260908","duration":10,"width":1280,"height":720,"fps":30,"vcodec":"h264","acodec":"aac","format_id":"720","formats":[{"format_id":"720","ext":"mp4","width":1280,"height":720,"fps":30,"tbr":2500,"vcodec":"h264","acodec":"aac"}]}
        JSON
            exit 0
            ;;
          *" --dump-single-json "*"old123"*)
            cat <<'JSON'
        {"id":"old123","display_id":"old123","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=old123","title":"Already Archived","uploader":"Example Creator","upload_date":"20260907","duration":10,"width":640,"height":360,"fps":30,"vcodec":"h264","acodec":"aac","format_id":"360","formats":[{"format_id":"360","ext":"mp4","width":640,"height":360,"fps":30,"tbr":800,"vcodec":"h264","acodec":"aac"}]}
        JSON
            exit 0
            ;;
          *" --dump-single-json "*)
            cat <<'JSON'
        {"id":"1965423400123456789","display_id":"post-123","extractor_key":"ExampleExtractor","webpage_url":"https://media.example.invalid/watch/123","title":"Fake Video","uploader":"Example Creator","upload_date":"20260908","duration":42.5,"width":1920,"height":1080,"fps":30,"vcodec":"h264","acodec":"aac","format_id":"1080","formats":[{"format_id":"360","ext":"mp4","width":640,"height":360,"fps":30,"tbr":800,"vcodec":"h264","acodec":"aac"},{"format_id":"1080","ext":"mp4","width":1920,"height":1080,"fps":30,"tbr":5000,"vcodec":"h264","acodec":"aac"}]}
        JSON
            exit 0
            ;;
          *" --print "*)
            case " $* " in
              *"new456"*) echo "/tmp/Brand New Video [new456].mp4" ;;
              *"old123"*) echo "/tmp/Already Archived [old123].mp4" ;;
              *) echo "/tmp/Fake Video [1965423400123456789].mp4" ;;
            esac
            exit 0
            ;;
        esac
        echo "unsupported fake yt-dlp invocation" >&2
        exit 2
        """
    }
}
