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

    func testXCollectionSyncUsesMediaIDsAndPreservesMultipleVideosFromOnePost() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fakeGalleryDl = temp.appendingPathComponent("gallery-dl")
        try fakeGalleryDlScript.write(to: fakeGalleryDl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGalleryDl.path
        )

        let fakeCurl = temp.appendingPathComponent("curl")
        try fakeCurlScript.write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCurl.path
        )

        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("x-collections.sqlite3"))
        let firstVideo = MediaMetadata(
            site: "twitter",
            mediaID: "9001",
            sourceID: "7001",
            inputURL: "https://x.com/ExampleUser/status/7001",
            webpageURL: "https://x.com/ExampleUser/status/7001",
            title: "Two videos in one post",
            creator: "ExampleUser",
            uploadDate: "20260908",
            width: 1280,
            height: 720,
            formatID: "gallery-dl-direct-2176000"
        )
        try await store.record(
            media: firstVideo,
            status: .downloaded,
            outputPath: "/Volumes/Archive/@ExampleUser 2026-09-08 [7001] [9001] [1280x720].mp4"
        )

        let galleryClient = GalleryDlClient(executableURL: fakeGalleryDl)
        let directDownloader = DirectMediaDownloader(executableURL: fakeCurl)
        let service = try CollectionSyncService(
            archive: store,
            galleryDl: galleryClient,
            directDownloader: directDownloader
        )

        let preview = try await service.scan(
            collection: .xBookmarks,
            cookiesFromBrowser: .safari,
            limit: 100
        )
        XCTAssertEqual(preview.items.count, 3)
        XCTAssertEqual(preview.unarchivedCount, 2)
        XCTAssertTrue(preview.items.first { $0.item.mediaID == "9001" }?.alreadyDownloaded == true)
        XCTAssertTrue(preview.items.first { $0.item.mediaID == "9002" }?.alreadyDownloaded == false)
        XCTAssertEqual(preview.items.first { $0.item.mediaID == "9002" }?.item.sourceID, "7001")

        let result = try await service.sync(
            collection: .xBookmarks,
            cookiesFromBrowser: .safari,
            outputDirectory: temp,
            limit: 100
        )
        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.unarchived, 2)
        XCTAssertEqual(result.downloaded, 2)
        XCTAssertEqual(result.skippedAlreadyArchived, 1)
        XCTAssertEqual(result.failed, 0)

        let secondVideoDownloaded = try await store.downloaded(
            identity: ArchiveIdentity(site: "twitter", mediaID: "9002")
        )
        let thirdVideoDownloaded = try await store.downloaded(
            identity: ArchiveIdentity(site: "twitter", mediaID: "9003")
        )
        XCTAssertTrue(secondVideoDownloaded)
        XCTAssertTrue(thirdVideoDownloaded)

        let secondRecord = try await store.record(
            identity: ArchiveIdentity(site: "twitter", mediaID: "9002")
        )
        XCTAssertEqual(secondRecord?.sourceID, "7001")
        XCTAssertTrue(secondRecord?.outputPath?.contains("[7001] [9002] [1280x720].mp4") == true)

        let secondSync = try await service.sync(
            collection: .xBookmarks,
            cookiesFromBrowser: .safari,
            outputDirectory: temp,
            limit: 100
        )
        XCTAssertEqual(secondSync.downloaded, 0)
        XCTAssertEqual(secondSync.skippedAlreadyArchived, 3)
    }

    func testGalleryDlXLikesRequiresAccountName() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeGalleryDl = temp.appendingPathComponent("gallery-dl")
        try fakeGalleryDlScript.write(to: fakeGalleryDl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGalleryDl.path
        )

        let client = GalleryDlClient(executableURL: fakeGalleryDl)
        do {
            _ = try await client.scanCollection(
                .xLikes,
                cookiesFromBrowser: .safari,
                limit: 10
            )
            XCTFail("Expected X Likes without an account name to fail")
        } catch let error as GalleryDlError {
            guard case .missingAccountName = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHistoryExchangePreservesLargeIDsAndSpreadsheetTextSafety() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceStore = try ArchiveStore(databaseURL: temp.appendingPathComponent("exchange-source.sqlite3"))
        let media = MediaMetadata(
            site: "twitter",
            mediaID: "1965423400123456789",
            sourceID: "1965423456789012345",
            inputURL: "https://x.com/ExampleUser/status/1965423456789012345",
            webpageURL: "https://x.com/ExampleUser/status/1965423456789012345",
            title: "=HYPERLINK(\"https://example.invalid\",\"not a formula\")",
            creator: "ExampleUser",
            uploadDate: "20260908",
            width: 1920,
            height: 1080,
            formatID: "http-2176"
        )
        try await sourceStore.record(
            media: media,
            status: .downloaded,
            outputPath: "/Volumes/Archive/Example [1965423400123456789].mp4"
        )

        let exchange = try HistoryExchangeService(archive: sourceStore)
        let csvURL = temp.appendingPathComponent("history.csv")
        let jsonlURL = temp.appendingPathComponent("history.jsonl")
        let xlsxURL = temp.appendingPathComponent("history.xlsx")

        let csvResult = try await exchange.export(to: csvURL, format: .csv)
        let jsonlResult = try await exchange.export(to: jsonlURL, format: .jsonl)
        let xlsxResult = try await exchange.export(to: xlsxURL, format: .xlsx)
        XCTAssertEqual(csvResult.recordCount, 1)
        XCTAssertEqual(jsonlResult.recordCount, 1)
        XCTAssertEqual(xlsxResult.recordCount, 1)

        let csvText = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csvText.contains("1965423400123456789"))
        XCTAssertTrue(csvText.contains("'=HYPERLINK"))

        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let sheetResult = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-p", xlsxURL.path, "xl/worksheets/sheet1.xml"]
        )
        XCTAssertEqual(sheetResult.exitCode, 0)
        XCTAssertTrue(sheetResult.stdout.contains("t=\"inlineStr\""))
        XCTAssertTrue(sheetResult.stdout.contains("1965423400123456789"))

        let csvStore = try ArchiveStore(databaseURL: temp.appendingPathComponent("csv-import.sqlite3"))
        let csvImporter = try HistoryExchangeService(archive: csvStore)
        let csvImport = try await csvImporter.importHistory(from: csvURL)
        XCTAssertEqual(csvImport.recordsAdded, 1)
        let csvRecord = try await csvStore.record(
            identity: ArchiveIdentity(site: "twitter", mediaID: "1965423400123456789")
        )
        XCTAssertEqual(csvRecord?.sourceID, "1965423456789012345")
        XCTAssertEqual(csvRecord?.title, "=HYPERLINK(\"https://example.invalid\",\"not a formula\")")

        let jsonStore = try ArchiveStore(databaseURL: temp.appendingPathComponent("json-import.sqlite3"))
        let jsonImporter = try HistoryExchangeService(archive: jsonStore)
        let jsonImport = try await jsonImporter.importHistory(from: jsonlURL)
        XCTAssertEqual(jsonImport.recordsAdded, 1)
        let jsonRecord = try await jsonStore.record(
            identity: ArchiveIdentity(site: "twitter", mediaID: "1965423400123456789")
        )
        XCTAssertEqual(jsonRecord?.mediaID, "1965423400123456789")
        XCTAssertEqual(jsonRecord?.status, .downloaded)
    }

    func testPrivateAdapterScaffoldLivesInExternalRuntimeDirectory() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let adapterRoot = temp.appendingPathComponent("adapters", isDirectory: true)
        let manager = PrivateAdapterManager(rootDirectory: adapterRoot)

        let directory = try await manager.initialize(id: "ai-test-adapter")
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, adapterRoot.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("adapter.json").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("adapter.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AGENT_INSTRUCTIONS.md").path))

        let manifest = try await manager.manifest(id: "ai-test-adapter")
        XCTAssertEqual(manifest.protocolVersion, 1)
        XCTAssertEqual(manifest.id, "ai-test-adapter")
        XCTAssertEqual(manifest.collections.first?.id, "favorites")

        let doctor = try await manager.doctor(id: "ai-test-adapter")
        XCTAssertFalse(doctor.ok)
        XCTAssertTrue(doctor.message?.contains("not implemented") == true)
    }

    func testPrivateAdapterSyncUsesAdapterNamespaceAndSkipsSecondRun() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let adapterRoot = temp.appendingPathComponent("adapters", isDirectory: true)
        let manager = PrivateAdapterManager(rootDirectory: adapterRoot)
        let adapterDirectory = try await manager.initialize(id: "synthetic-private")

        let adapterExecutable = adapterDirectory.appendingPathComponent("adapter.py")
        try privateAdapterTestScript.write(to: adapterExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: adapterExecutable.path
        )

        let fakeCurl = temp.appendingPathComponent("curl")
        try fakeCurlScript.write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCurl.path
        )

        let store = try ArchiveStore(databaseURL: temp.appendingPathComponent("private.sqlite3"))
        let service = try PrivateAdapterSyncService(
            manager: manager,
            archive: store,
            directDownloader: DirectMediaDownloader(executableURL: fakeCurl)
        )

        let preview = try await service.scan(
            adapterID: "synthetic-private",
            collection: "favorites",
            browser: .safari,
            limit: 100
        )
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(preview.unarchivedCount, 2)

        let firstSync = try await service.sync(
            adapterID: "synthetic-private",
            collection: "favorites",
            browser: .safari,
            outputDirectory: temp,
            limit: 100
        )
        XCTAssertEqual(firstSync.downloaded, 2)
        XCTAssertEqual(firstSync.skippedAlreadyArchived, 0)
        XCTAssertEqual(firstSync.failed, 0)

        let customRecord = try await store.record(
            identity: ArchiveIdentity(site: "custom:synthetic-private", mediaID: "private-media-001")
        )
        XCTAssertEqual(customRecord?.status, .downloaded)
        XCTAssertEqual(customRecord?.sourceID, "private-post-001")

        let secondSync = try await service.sync(
            adapterID: "synthetic-private",
            collection: "favorites",
            browser: .safari,
            outputDirectory: temp,
            limit: 100
        )
        XCTAssertEqual(secondSync.downloaded, 0)
        XCTAssertEqual(secondSync.skippedAlreadyArchived, 2)
    }

    func testPrivateAdapterRejectsExecutableSymlinkOutsideAdapterDirectory() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let adapterRoot = temp.appendingPathComponent("adapters", isDirectory: true)
        let manager = PrivateAdapterManager(rootDirectory: adapterRoot)
        let adapterDirectory = try await manager.initialize(id: "symlink-test")

        let outsideExecutable = temp.appendingPathComponent("outside-adapter.sh")
        try "#!/bin/sh\necho '{}'\n".write(
            to: outsideExecutable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: outsideExecutable.path
        )

        let linkedExecutable = adapterDirectory.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(
            at: linkedExecutable,
            withDestinationURL: outsideExecutable
        )

        let manifest = PrivateAdapterManifest(
            id: "symlink-test",
            displayName: "Symlink Test",
            executable: "outside-link",
            collections: [
                PrivateAdapterCollectionDefinition(id: "favorites", displayName: "Favorites")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: adapterDirectory.appendingPathComponent("adapter.json"),
            options: .atomic
        )

        do {
            _ = try await manager.doctor(id: "symlink-test")
            XCTFail("Expected adapter executable symlink escape to be rejected")
        } catch let error as PrivateAdapterError {
            guard case .unsafeExecutablePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

    private var fakeGalleryDlScript: String {
        """
        #!/bin/sh
        case " $* " in
          *" --version "*)
            echo "1.32.11-test"
            exit 0
            ;;
          *)
            cat <<'JSON'
        [
          [2,{"tweet_id":7001,"content":"Two videos in one post","date":"2026-09-08 10:00:00","author":{"name":"ExampleUser"},"count":2}],
          [3,"https://video.twimg.com/ext_tw_video/9001/pu/vid/1280x720/example-one.mp4",{"tweet_id":7001,"content":"Two videos in one post","date":"2026-09-08 10:00:00","author":{"name":"ExampleUser"},"num":1,"type":"video","extension":"mp4","width":1280,"height":720,"bitrate":2176000}],
          [3,"https://video.twimg.com/ext_tw_video/9002/pu/vid/1280x720/example-two.mp4",{"tweet_id":7001,"content":"Two videos in one post","date":"2026-09-08 10:00:00","author":{"name":"ExampleUser"},"num":2,"type":"video","extension":"mp4","width":1280,"height":720,"bitrate":2176000}],
          [2,{"tweet_id":7002,"content":"Another video post","date":"2026-09-08 11:00:00","author":{"name":"AnotherUser"},"count":1}],
          [3,"https://video.twimg.com/amplify_video/9003/vid/avc1/1920x1080/example-three.mp4",{"tweet_id":7002,"content":"Another video post","date":"2026-09-08 11:00:00","author":{"name":"AnotherUser"},"num":1,"type":"video","extension":"mp4","width":1920,"height":1080,"bitrate":5000000}]
        ]
        JSON
            exit 0
            ;;
        esac
        """
    }

    private var fakeCurlScript: String {
        """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            output="$1"
          fi
          shift
        done
        if [ -z "$output" ]; then
          echo "missing --output" >&2
          exit 2
        fi
        printf 'synthetic mp4 data' > "$output"
        exit 0
        """
    }

    private var privateAdapterTestScript: String {
        """
        #!/usr/bin/env python3
        import json
        import sys

        request = json.load(sys.stdin)
        if request.get("command") == "doctor":
            json.dump({"protocolVersion": 1, "ok": True, "message": "Ready"}, sys.stdout)
            raise SystemExit(0)

        if request.get("command") == "scan":
            json.dump({
                "protocolVersion": 1,
                "items": [
                    {
                        "mediaID": "private-media-001",
                        "sourceID": "private-post-001",
                        "sourceURL": "https://media.example.invalid/watch/private-post-001",
                        "title": "Synthetic private video one",
                        "creator": "ExampleCreator",
                        "publishedAt": "2026-09-08T12:00:00Z",
                        "extensionName": "mp4",
                        "width": 1920,
                        "height": 1080,
                        "bitrate": 5000000,
                        "download": {
                            "strategy": "direct",
                            "url": "https://cdn.example.invalid/video/private-media-001.mp4"
                        }
                    },
                    {
                        "mediaID": "private-media-002",
                        "sourceID": "private-post-002",
                        "sourceURL": "https://media.example.invalid/watch/private-post-002",
                        "title": "Synthetic private video two",
                        "creator": "ExampleCreator",
                        "publishedAt": "2026-09-08T13:00:00Z",
                        "extensionName": "mp4",
                        "width": 1280,
                        "height": 720,
                        "download": {
                            "strategy": "direct",
                            "url": "https://cdn.example.invalid/video/private-media-002.mp4"
                        }
                    }
                ]
            }, sys.stdout)
            raise SystemExit(0)

        raise SystemExit(2)
        """
    }
}
