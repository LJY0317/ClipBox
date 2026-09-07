import ClipBoxCore
import Foundation

private let clipBoxVersion = "0.2.0-dev"

private enum CLIError: Error, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let message), .invalidArgument(let message):
            message
        }
    }
}

@main
struct ClipBoxCommand {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("clipbox: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let wantsJSON = removeFlag("--json", from: &arguments)
        let command = arguments.first ?? "help"
        if !arguments.isEmpty {
            arguments.removeFirst()
        }

        switch command {
        case "--version", "-V", "version":
            print("ClipBox \(clipBoxVersion)")

        case "paths":
            try printPaths(json: wantsJSON)

        case "gui":
            try launchGUI()

        case "status":
            let service = try ClipBoxService()
            let dependencies = await service.dependencyStatus()
            let historyCount = try await service.historyCount()
            if wantsJSON {
                try printJSON(StatusPayload(dependencies: dependencies, historyCount: historyCount))
            } else {
                printStatus(dependencies: dependencies, historyCount: historyCount)
            }

        case "formats":
            try await runFormats(arguments: arguments, json: wantsJSON)

        case "download":
            try await runDownload(arguments: arguments, json: wantsJSON)

        case "scan":
            try await runCollectionScan(arguments: arguments, json: wantsJSON)

        case "sync":
            try await runCollectionSync(arguments: arguments, json: wantsJSON)

        case "history":
            try await runHistory(arguments: arguments, json: wantsJSON)

        case "backup":
            try await runBackup(arguments: arguments, json: wantsJSON)

        case "adapter":
            try await runAdapter(arguments: arguments, json: wantsJSON)

        case "config":
            try runConfig(arguments: arguments, json: wantsJSON)

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CLIError.invalidArgument("Unknown command: \(command). Run `clipbox help` for usage.")
        }
    }

    private static func runAdapter(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        let subcommand = arguments.first ?? "list"
        if !arguments.isEmpty {
            arguments.removeFirst()
        }

        switch subcommand {
        case "init":
            guard let id = arguments.first else {
                throw CLIError.missingArgument("Usage: clipbox adapter init <id>")
            }
            let manager = PrivateAdapterManager()
            let directory = try await manager.initialize(id: id)
            print("Private adapter scaffold created")
            print("  id\t\(id)")
            print("  path\t\(directory.path)")
            print("  next\tAsk an AI coding agent to customize adapter.py using docs/private-adapter-protocol.md")

        case "list":
            let manager = PrivateAdapterManager()
            let manifests = try await manager.list()
            if json {
                try printJSON(manifests)
            } else if manifests.isEmpty {
                print("No private adapters installed.")
            } else {
                for manifest in manifests {
                    let collections = manifest.collections.map(\.id).joined(separator: ",")
                    print("\(manifest.id)\t\(manifest.displayName)\t\(collections)")
                }
            }

        case "path":
            guard let id = arguments.first else {
                throw CLIError.missingArgument("Usage: clipbox adapter path <id>")
            }
            let manager = PrivateAdapterManager()
            print(try await manager.directory(id: id).path)

        case "doctor":
            guard let id = arguments.first else {
                throw CLIError.missingArgument("Usage: clipbox adapter doctor <id> [--json]")
            }
            let manager = PrivateAdapterManager()
            let response = try await manager.doctor(id: id)
            if json {
                try printJSON(response)
            } else {
                print("adapter\t\(id)")
                print("ok\t\(response.ok ? "yes" : "no")")
                if let message = response.message {
                    print("message\t\(message)")
                }
            }

        case "scan", "sync":
            try await runPrivateAdapterCollection(
                subcommand: subcommand,
                arguments: arguments,
                json: json
            )

        default:
            throw CLIError.invalidArgument("Unknown adapter command: \(subcommand)")
        }
    }

    private static func runPrivateAdapterCollection(
        subcommand: String,
        arguments: [String],
        json: Bool
    ) async throws {
        guard arguments.count >= 2 else {
            throw CLIError.missingArgument(
                "Usage: clipbox adapter \(subcommand) <id> <collection> [--browser safari] [--limit <n>|--all] [--dry-run] [--output <folder>] [--json]"
            )
        }
        let adapterID = arguments[0]
        let collection = arguments[1]
        var remaining = Array(arguments.dropFirst(2))
        let all = removeFlag("--all", from: &remaining)
        let dryRun = subcommand == "sync" && removeFlag("--dry-run", from: &remaining)
        let rawBrowser = try removeOption("--browser", from: &remaining) ?? BrowserCookieSource.safari.rawValue
        guard let browser = try parseBrowser(rawBrowser) else {
            throw CLIError.invalidArgument("A browser source is required.")
        }
        let rawLimit = try removeOption("--limit", from: &remaining)
        let output = subcommand == "sync" ? try removeOption("--output", from: &remaining) : nil
        if all, rawLimit != nil {
            throw CLIError.invalidArgument("Use either --all or --limit, not both.")
        }
        let limit: Int?
        if all {
            limit = nil
        } else if let rawLimit {
            guard let parsed = Int(rawLimit), parsed > 0 else {
                throw CLIError.invalidArgument("--limit must be a positive integer")
            }
            limit = parsed
        } else {
            limit = 100
        }
        guard remaining.isEmpty else {
            throw CLIError.invalidArgument("Unexpected adapter arguments: \(remaining.joined(separator: " "))")
        }

        let service = try PrivateAdapterSyncService()
        if subcommand == "scan" {
            let result = try await service.scan(
                adapterID: adapterID,
                collection: collection,
                browser: browser,
                limit: limit
            )
            if json {
                try printJSON(result)
            } else {
                print("adapter\t\(adapterID)")
                print("collection\t\(collection)")
                print("scanned\t\(result.items.count)")
                print("unarchived\t\(result.unarchivedCount)")
                for item in result.items {
                    let state = item.alreadyDownloaded ? "archived" : (item.previouslySeen ? "seen" : "new")
                    print("\(state)\t\(item.item.mediaID)\t\(item.item.title ?? "(untitled)")")
                }
            }
            return
        }

        let outputURL = output.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }
        let result = try await service.sync(
            adapterID: adapterID,
            collection: collection,
            browser: browser,
            outputDirectory: outputURL,
            limit: limit,
            dryRun: dryRun
        )
        if json {
            try printJSON(result)
        } else {
            print("adapter\t\(adapterID)")
            print("collection\t\(collection)")
            print("scanned\t\(result.scanned)")
            print("unarchived\t\(result.unarchived)")
            print("downloaded\t\(result.downloaded)")
            print("skipped-archived\t\(result.skippedAlreadyArchived)")
            print("failed\t\(result.failed)")
            print("dry-run\t\(result.dryRun ? "yes" : "no")")
            for failure in result.failures {
                print("failure\t\(failure.mediaID)\t\(failure.error)")
            }
        }
    }

    private static func runFormats(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        let browser = try parseBrowser(try removeOption("--browser", from: &arguments))
        guard let url = arguments.first else {
            throw CLIError.missingArgument("Usage: clipbox formats <url> [--browser <browser>] [--json]")
        }
        let service = try ClipBoxService()
        let media = try await service.inspect(url: url, cookiesFromBrowser: browser)
        if json {
            try printJSON(media)
        } else {
            printFormats(media)
        }
    }

    private static func runDownload(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        let force = removeFlag("--force", from: &arguments)
        let output = try removeOption("--output", from: &arguments)
        let browser = try parseBrowser(try removeOption("--browser", from: &arguments))
        guard let url = arguments.first else {
            throw CLIError.missingArgument("Usage: clipbox download <url> [--output <folder>] [--browser <browser>] [--force] [--json]")
        }

        let outputURL = output.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        let service = try ClipBoxService()
        let outcome = try await service.download(
            url: url,
            outputDirectory: outputURL,
            force: force,
            cookiesFromBrowser: browser
        )

        if json {
            try printJSON(outcome)
            return
        }

        switch outcome {
        case .downloaded(let media, let outputPath):
            print("Downloaded")
            print("  title\t\(media.title ?? "(untitled)")")
            print("  id\t\(media.site):\(media.mediaID)")
            print("  file\t\(outputPath)")
        case .skippedAlreadyArchived(let media, let previousPath):
            print("Skipped: already archived")
            print("  title\t\(media.title ?? "(untitled)")")
            print("  id\t\(media.site):\(media.mediaID)")
            if let previousPath {
                print("  previous-file\t\(previousPath)")
            }
        }
    }

    private static func runCollectionScan(arguments: [String], json: Bool) async throws {
        let options = try parseCollectionOptions(arguments: arguments, allowDryRun: false)
        let service = try CollectionSyncService()
        let result = try await service.scan(
            collection: options.collection,
            accountName: options.accountName,
            cookiesFromBrowser: options.browser,
            limit: options.limit
        )

        if json {
            try printJSON(result)
            return
        }

        print(options.collection.displayName)
        print("scanned\t\(result.items.count)")
        print("unarchived\t\(result.unarchivedCount)")
        print("")
        for item in result.items {
            let state = item.alreadyDownloaded ? "archived" : (item.previouslySeen ? "seen" : "new")
            print("\(state)\t\(item.item.mediaID)\t\(item.item.title ?? "(untitled)")")
        }
    }

    private static func runCollectionSync(arguments: [String], json: Bool) async throws {
        let options = try parseCollectionOptions(arguments: arguments, allowDryRun: true)
        let outputURL = options.output.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }
        let service = try CollectionSyncService()
        let result = try await service.sync(
            collection: options.collection,
            accountName: options.accountName,
            cookiesFromBrowser: options.browser,
            outputDirectory: outputURL,
            limit: options.limit,
            dryRun: options.dryRun
        )

        if json {
            try printJSON(result)
            return
        }

        print("\(options.collection.displayName) \(result.dryRun ? "preview" : "sync")")
        print("  scanned\t\(result.scanned)")
        print("  unarchived\t\(result.unarchived)")
        print("  downloaded\t\(result.downloaded)")
        print("  skipped-archived\t\(result.skippedAlreadyArchived)")
        print("  failed\t\(result.failed)")
        if result.dryRun {
            print("  note\tDry run: no collection checkpoint or downloads were written.")
        }
        for failure in result.failures {
            print("  failure\t\(failure.mediaID)\t\(failure.error)")
        }
    }

    private static func runHistory(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        if let subcommand = arguments.first, subcommand == "export" || subcommand == "import" {
            arguments.removeFirst()
            try await runHistoryExchange(
                subcommand: subcommand,
                arguments: arguments,
                json: json
            )
            return
        }

        let rawLimit = try removeOption("--limit", from: &arguments)
        let limit = try rawLimit.map {
            guard let parsed = Int($0), parsed > 0 else {
                throw CLIError.invalidArgument("--limit must be a positive integer")
            }
            return parsed
        } ?? 50

        let service = try ClipBoxService()
        let records = try await service.recentHistory(limit: limit)
        if json {
            try printJSON(records)
            return
        }

        if records.isEmpty {
            print("No archive history yet.")
            return
        }

        for record in records {
            let title = record.title ?? "(untitled)"
            let timestamp = record.downloadedAt ?? record.firstSeenAt
            print("\(timestamp)\t\(record.status.rawValue)\t\(record.site):\(record.mediaID)\t\(title)")
        }
    }

    private static func runHistoryExchange(
        subcommand: String,
        arguments: [String],
        json: Bool
    ) async throws {
        var arguments = arguments
        let rawFormat = try removeOption("--format", from: &arguments)
        let format: HistoryExchangeFormat?
        if let rawFormat {
            guard let parsed = HistoryExchangeFormat(rawValue: rawFormat.lowercased()) else {
                throw CLIError.invalidArgument("--format must be jsonl, csv, or xlsx")
            }
            format = parsed
        } else {
            format = nil
        }

        guard let path = arguments.first else {
            throw CLIError.missingArgument(
                "Usage: clipbox history \(subcommand) <file> [--format <jsonl|csv|xlsx>] [--json]"
            )
        }
        guard arguments.count == 1 else {
            throw CLIError.invalidArgument("Unexpected history \(subcommand) arguments: \(arguments.dropFirst().joined(separator: " "))")
        }

        let fileURL = URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: false
        )
        let service = try HistoryExchangeService()

        switch subcommand {
        case "export":
            let result = try await service.export(to: fileURL, format: format)
            if json {
                try printJSON(result)
            } else {
                print("History exported")
                print("  format\t\(result.format.rawValue)")
                print("  records\t\(result.recordCount)")
                print("  file\t\(result.path)")
            }
        case "import":
            let result = try await service.importHistory(from: fileURL, format: format)
            if json {
                try printJSON(result)
            } else {
                print("History imported by merge")
                print("  format\t\(result.format.rawValue)")
                print("  processed\t\(result.recordsProcessed)")
                print("  newly-added\t\(result.recordsAdded)")
                print("  final-records\t\(result.finalRecordCount)")
            }
        default:
            throw CLIError.invalidArgument("Unknown history exchange command: \(subcommand)")
        }
    }

    private static func runBackup(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        let subcommand = arguments.first ?? "create"
        if !arguments.isEmpty {
            arguments.removeFirst()
        }

        switch subcommand {
        case "create":
            let destination = arguments.first.map {
                URL(
                    fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                    isDirectory: false
                )
            }
            let service = try BackupService()
            let result = try await service.createBackup(at: destination)
            if json {
                try printJSON(result)
            } else {
                print("Backup created")
                print("  records\t\(result.recordCount)")
                print("  file\t\(result.path)")
            }

        case "restore":
            let restorePreferences = removeFlag("--restore-preferences", from: &arguments)
            guard let source = arguments.first else {
                throw CLIError.missingArgument(
                    "Usage: clipbox backup restore <file.clipboxbackup> [--restore-preferences] [--json]"
                )
            }
            let sourceURL = URL(
                fileURLWithPath: NSString(string: source).expandingTildeInPath,
                isDirectory: false
            )
            let service = try BackupService()
            let result = try await service.restoreBackup(
                from: sourceURL,
                restorePreferences: restorePreferences
            )
            if json {
                try printJSON(result)
            } else {
                print("Backup restored by merge")
                print("  backup-records\t\(result.backupRecordCount)")
                print("  processed\t\(result.recordsProcessed)")
                print("  newly-added\t\(result.recordsAdded)")
                print("  final-records\t\(result.finalRecordCount)")
                print("  preferences-restored\t\(result.preferencesRestored ? "yes" : "no")")
            }

        default:
            throw CLIError.invalidArgument("Unknown backup command: \(subcommand)")
        }
    }

    private static func runConfig(arguments: [String], json: Bool) throws {
        let subcommand = arguments.first ?? "show"
        switch subcommand {
        case "show":
            let preferences = try ClipBoxPreferencesStore.load()
            if json {
                try printJSON(preferences)
            } else {
                print("output\t\(preferences.resolvedOutputDirectory.path)")
            }

        case "output":
            guard arguments.count >= 2 else {
                throw CLIError.missingArgument("Usage: clipbox config output <folder|default>")
            }
            let value = arguments[1]
            var preferences = try ClipBoxPreferencesStore.load()
            if value == "default" {
                preferences.outputDirectoryPath = nil
            } else {
                preferences.outputDirectoryPath = NSString(string: value).expandingTildeInPath
            }
            try ClipBoxPreferencesStore.save(preferences)
            print(preferences.resolvedOutputDirectory.path)

        default:
            throw CLIError.invalidArgument("Unknown config command: \(subcommand)")
        }
    }

    private static func printPaths(json: Bool) throws {
        let payload = PathsPayload(
            downloads: ClipBoxPaths.defaultDownloadDirectory.path,
            applicationSupport: ClipBoxPaths.applicationSupportDirectory.path,
            archiveDatabase: ClipBoxPaths.archiveDatabaseURL.path,
            adapters: ClipBoxPaths.adaptersDirectory.path
        )
        if json {
            try printJSON(payload)
        } else {
            print("downloads\t\(payload.downloads)")
            print("application-support\t\(payload.applicationSupport)")
            print("archive-database\t\(payload.archiveDatabase)")
            print("adapters\t\(payload.adapters)")
        }
    }

    private static func printStatus(dependencies: ClipBoxDependencyStatus, historyCount: Int) {
        print("ClipBox \(clipBoxVersion)")
        print("archive-records\t\(historyCount)")
        print("yt-dlp\t\(dependencies.ytDlp.isAvailable ? "available" : "missing")\(dependencies.ytDlp.version.map { " (\($0))" } ?? "")")
        print("ffmpeg\t\(dependencies.ffmpeg.isAvailable ? "available" : "missing")\(dependencies.ffmpeg.version.map { " (\($0))" } ?? "")")
        print("gallery-dl\t\(dependencies.galleryDl.isAvailable ? "available" : "missing")\(dependencies.galleryDl.version.map { " (\($0))" } ?? "")")
        print("sqlite\t\(dependencies.sqliteVersion)")
        if !dependencies.ytDlp.isAvailable {
            print("")
            print("Install yt-dlp before downloading, for example: brew install yt-dlp")
        }
    }

    private static func printFormats(_ media: MediaMetadata) {
        print(media.title ?? "(untitled)")
        print("site\t\(media.site)")
        print("id\t\(media.mediaID)")
        print("")
        print("format\tresolution\tfps\tbitrate\text\tvideo\taudio")
        for format in media.formats {
            let bitrate = format.totalBitrateKbps.map { String(format: "%.0f kbps", $0) } ?? "-"
            let fps = format.fps.map { String(format: "%.2g", $0) } ?? "-"
            print("\(format.formatID)\t\(format.resolutionDescription)\t\(fps)\t\(bitrate)\t\(format.extensionName ?? "-")\t\(format.videoCodec ?? "-")\t\(format.audioCodec ?? "-")")
        }
    }

    private static func printHelp() {
        print("ClipBox \(clipBoxVersion)")
        print("")
        print("Native macOS media download and archive toolkit.")
        print("")
        print("Usage:")
        print("  clipbox status [--json]")
        print("  clipbox gui")
        print("  clipbox paths [--json]")
        print("  clipbox formats <url> [--browser <browser>] [--json]")
        print("  clipbox download <url> [--output <folder>] [--browser <browser>] [--force] [--json]")
        print("  clipbox scan youtube <liked|watch-later> [--browser safari] [--limit <n>|--all] [--json]")
        print("  clipbox sync youtube <liked|watch-later> [--browser safari] [--limit <n>|--all] [--dry-run] [--output <folder>] [--json]")
        print("  clipbox scan x bookmarks [--browser safari] [--limit <n>|--all] [--json]")
        print("  clipbox scan x likes --username <handle> [--browser safari] [--limit <n>|--all] [--json]")
        print("  clipbox sync x <bookmarks|likes> [--username <handle>] [--browser safari] [--limit <n>|--all] [--dry-run] [--output <folder>] [--json]")
        print("  clipbox history [--limit <n>] [--json]")
        print("  clipbox history export <file.{jsonl|csv|xlsx}> [--format <format>] [--json]")
        print("  clipbox history import <file.{jsonl|csv}> [--format <format>] [--json]")
        print("  clipbox backup create [file.clipboxbackup] [--json]")
        print("  clipbox backup restore <file.clipboxbackup> [--restore-preferences] [--json]")
        print("  clipbox adapter init <id>")
        print("  clipbox adapter list [--json]")
        print("  clipbox adapter path <id>")
        print("  clipbox adapter doctor <id> [--json]")
        print("  clipbox adapter scan <id> <collection> [--browser safari] [--limit <n>|--all] [--json]")
        print("  clipbox adapter sync <id> <collection> [--browser safari] [--limit <n>|--all] [--dry-run] [--output <folder>] [--json]")
        print("  clipbox config show [--json]")
        print("  clipbox config output <folder|default>")
        print("  clipbox --version")
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else {
            return false
        }
        arguments.remove(at: index)
        return true
    }

    private static func removeOption(_ option: String, from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw CLIError.missingArgument("\(option) requires a value")
        }
        let value = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: index)
        return value
    }

    private static func parseBrowser(_ rawValue: String?) throws -> BrowserCookieSource? {
        guard let rawValue else { return nil }
        guard let browser = BrowserCookieSource(rawValue: rawValue.lowercased()) else {
            let supported = BrowserCookieSource.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.invalidArgument("Unsupported browser `\(rawValue)`. Supported: \(supported)")
        }
        return browser
    }

    private static func parseCollectionOptions(
        arguments: [String],
        allowDryRun: Bool
    ) throws -> CollectionCommandOptions {
        guard arguments.count >= 2,
              let collection = BuiltInCollection.resolve(
                site: arguments[0],
                collection: arguments[1]
              ) else {
            throw CLIError.missingArgument(
                "Collection must be `youtube liked` or `youtube watch-later`."
            )
        }

        var remaining = Array(arguments.dropFirst(2))
        let all = removeFlag("--all", from: &remaining)
        let dryRun = allowDryRun && removeFlag("--dry-run", from: &remaining)
        let rawBrowser = try removeOption("--browser", from: &remaining) ?? BrowserCookieSource.safari.rawValue
        guard let browser = try parseBrowser(rawBrowser) else {
            throw CLIError.invalidArgument("A browser cookie source is required for authenticated collections.")
        }
        let rawLimit = try removeOption("--limit", from: &remaining)
        let accountName = try removeOption("--username", from: &remaining)
        let output = allowDryRun ? try removeOption("--output", from: &remaining) : nil

        if collection.requiresAccountName,
           accountName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw CLIError.missingArgument("X Likes requires --username <handle>.")
        }

        if all, rawLimit != nil {
            throw CLIError.invalidArgument("Use either --all or --limit, not both.")
        }
        let limit: Int?
        if all {
            limit = nil
        } else if let rawLimit {
            guard let parsed = Int(rawLimit), parsed > 0 else {
                throw CLIError.invalidArgument("--limit must be a positive integer")
            }
            limit = parsed
        } else {
            limit = 100
        }

        if !remaining.isEmpty {
            throw CLIError.invalidArgument("Unexpected arguments: \(remaining.joined(separator: " "))")
        }

        return CollectionCommandOptions(
            collection: collection,
            browser: browser,
            accountName: accountName,
            limit: limit,
            dryRun: dryRun,
            output: output
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func launchGUI() throws {
        let environment = ProcessInfo.processInfo.environment
        let appDirectory = environment["CLIPBOX_APP_INSTALL_DIR"]
            .map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .path
        let appURL = URL(fileURLWithPath: appDirectory, isDirectory: true)
            .appendingPathComponent("ClipBox.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CLIError.invalidArgument(
                "ClipBox.app is not installed at \(appURL.path). Run tools/install-dev.sh from the source checkout first."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.invalidArgument("macOS could not open \(appURL.path)")
        }
    }
}

private struct StatusPayload: Codable {
    let dependencies: ClipBoxDependencyStatus
    let historyCount: Int
}

private struct PathsPayload: Codable {
    let downloads: String
    let applicationSupport: String
    let archiveDatabase: String
    let adapters: String
}

private struct CollectionCommandOptions {
    let collection: BuiltInCollection
    let browser: BrowserCookieSource
    let accountName: String?
    let limit: Int?
    let dryRun: Bool
    let output: String?
}
