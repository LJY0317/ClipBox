import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            "Could not launch external process: \(message)"
        }
    }
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
