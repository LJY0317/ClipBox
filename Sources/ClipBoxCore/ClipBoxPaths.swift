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
}
