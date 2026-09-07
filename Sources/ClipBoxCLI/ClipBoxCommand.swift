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
            guard let url = arguments.first else {
                throw CLIError.missingArgument("Usage: clipbox formats <url> [--json]")
            }
            let service = try ClipBoxService()
            let media = try await service.inspect(url: url)
            if wantsJSON {
                try printJSON(media)
            } else {
                printFormats(media)
            }

        case "download":
            try await runDownload(arguments: arguments, json: wantsJSON)

        case "history":
            try await runHistory(arguments: arguments, json: wantsJSON)

        case "backup":
            try await runBackup(arguments: arguments, json: wantsJSON)

        case "config":
            try runConfig(arguments: arguments, json: wantsJSON)

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CLIError.invalidArgument("Unknown command: \(command). Run `clipbox help` for usage.")
        }
    }

    private static func runDownload(arguments: [String], json: Bool) async throws {
        var arguments = arguments
        let force = removeFlag("--force", from: &arguments)
        let output = try removeOption("--output", from: &arguments)
        guard let url = arguments.first else {
            throw CLIError.missingArgument("Usage: clipbox download <url> [--output <folder>] [--force] [--json]")
        }

        let outputURL = output.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        let service = try ClipBoxService()
        let outcome = try await service.download(url: url, outputDirectory: outputURL, force: force)

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

    private static func runHistory(arguments: [String], json: Bool) async throws {
        var arguments = arguments
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
        print("  clipbox paths [--json]")
        print("  clipbox formats <url> [--json]")
        print("  clipbox download <url> [--output <folder>] [--force] [--json]")
        print("  clipbox history [--limit <n>] [--json]")
        print("  clipbox backup create [file.clipboxbackup] [--json]")
        print("  clipbox backup restore <file.clipboxbackup> [--restore-preferences] [--json]")
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

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
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
