import ClipBoxCore
import Foundation

private let version = "0.1.0"

private func printHelp() {
    print("ClipBox \(version)")
    print("")
    print("Native macOS media download and archive toolkit.")
    print("")
    print("Usage:")
    print("  clipbox --version")
    print("  clipbox paths")
    print("  clipbox help")
    print("")
    print("Download, sync, history, backup, and adapter commands will be added incrementally.")
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--version", "-V", "version":
    print("ClipBox \(version)")
case "paths":
    print("downloads\t\(ClipBoxPaths.defaultDownloadDirectory.path)")
    print("application-support\t\(ClipBoxPaths.applicationSupportDirectory.path)")
case "help", "--help", "-h", nil:
    printHelp()
default:
    fputs("Unknown command: \(arguments[0])\n", stderr)
    printHelp()
    exit(2)
}
