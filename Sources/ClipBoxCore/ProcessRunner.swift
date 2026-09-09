import Foundation
import Darwin

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
    case timedOut
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .launchFailed: "Could not launch the external tool. Check its installation and permissions."
        case .timedOut: "The external tool timed out. Check the connection and retry with a smaller scan."
        case .outputLimitExceeded: "The scan exceeded the memory limit. Retry with a smaller scan range."
        }
    }
}

// Process, pipe buffers and cancellation are shared only under these locks.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var failure: ProcessRunnerError?

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func stop(_ failure: ProcessRunnerError? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        self.failure = failure
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if self.process === process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        if let failure { throw failure }
        if stopped { throw CancellationError() }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining))
        return chunk.count <= remaining
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ProcessRunner {
    static func runAsync(
        executable: URL, arguments: [String], standardInput: Data? = nil,
        timeout: TimeInterval = 300
    ) async throws -> ProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try run(
                            executable: executable, arguments: arguments,
                            standardInput: standardInput, timeout: timeout, control: control
                        ))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.stop() }
    }

    static func run(
        executable: URL, arguments: [String],
        environment: [String: String]? = nil, standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: environment,
                standardInput: standardInput, timeout: timeout, control: ProcessControl())
    }

    private static func run(
        executable: URL, arguments: [String],
        environment: [String: String]? = nil, standardInput: Data? = nil,
        timeout: TimeInterval?, control: ProcessControl
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        do { try control.start(process) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProcessRunnerError.launchFailed("launch failed") }

        let watchdog = DispatchWorkItem { control.stop(.timedOut) }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }
        defer { watchdog.cancel() }

        let group = DispatchGroup()
        let stdout = PipeCapture(), stderr = PipeCapture()
        for (pipe, capture, limit, required) in [
            (output, stdout, 256 * 1024 * 1024, true),
            (errors, stderr, 1024 * 1024, false)
        ] {
            group.enter()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForReading.close(); group.leave() }
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    if !capture.append(chunk, limit: limit), required { control.stop(.outputLimitExceeded) }
                }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { try? input.fileHandleForWriting.close(); group.leave() }
            if let standardInput { try? input.fileHandleForWriting.write(contentsOf: standardInput) }
        }
        process.waitUntilExit()
        group.wait()
        try control.finish()
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout.text, stderr: stderr.text)
    }
}
