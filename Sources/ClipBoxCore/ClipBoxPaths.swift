import Foundation

public enum ClipBoxPaths {
    public static let applicationName = "ClipBox"

    public static var defaultDownloadDirectory: URL {
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        return downloads.appendingPathComponent(applicationName, isDirectory: true)
    }

    public static var applicationSupportDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport.appendingPathComponent(applicationName, isDirectory: true)
    }

    public static var archiveDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("archive", isDirectory: true)
    }

    public static var archiveDatabaseURL: URL {
        archiveDirectory.appendingPathComponent("history.sqlite3", isDirectory: false)
    }

    public static var preferencesFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    public static var adaptersDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("adapters", isDirectory: true)
    }

    public static var profilesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    public static var privacyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("privacy", isDirectory: true)
    }

    public static func ensureApplicationSupportDirectories() throws {
        let directories = [
            applicationSupportDirectory,
            archiveDirectory,
            adaptersDirectory,
            profilesDirectory,
            privacyDirectory,
        ]

        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    public static func ensureDownloadDirectory(_ directory: URL? = nil) throws -> URL {
        let resolved = directory ?? defaultDownloadDirectory
        try FileManager.default.createDirectory(
            at: resolved,
            withIntermediateDirectories: true
        )
        return resolved
    }
}
