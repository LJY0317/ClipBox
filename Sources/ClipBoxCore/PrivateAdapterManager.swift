import Foundation

public enum PrivateAdapterError: Error, LocalizedError, Sendable {
    case invalidID(String)
    case alreadyExists(String)
    case notFound(String)
    case invalidManifest(String)
    case unsafeExecutablePath(String)
    case executableUnavailable(String)
    case unsupportedProtocol(Int)
    case collectionNotDeclared(String)
    case runtimeFailed(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let id):
            "Invalid private adapter ID `\(id)`. Use letters, numbers, dot, underscore, or hyphen."
        case .alreadyExists(let id):
            "Private adapter `\(id)` already exists."
        case .notFound(let id):
            "Private adapter `\(id)` was not found."
        case .invalidManifest(let message):
            "Private adapter manifest is invalid: \(message)"
        case .unsafeExecutablePath(let value):
            "Adapter executable must stay inside its private adapter directory: \(value)"
        case .executableUnavailable(let value):
            "Adapter executable is missing or not executable: \(value)"
        case .unsupportedProtocol(let version):
            "Private adapter protocol version \(version) is not supported by this ClipBox build."
        case .collectionNotDeclared(let collection):
            "The adapter does not declare collection `\(collection)`."
        case .runtimeFailed(let message):
            "Private adapter execution failed: \(message)"
        case .malformedResponse(let message):
            "Private adapter returned invalid JSON: \(message)"
        }
    }
}

public actor PrivateAdapterManager {
    public nonisolated let rootDirectory: URL

    public init(rootDirectory: URL = ClipBoxPaths.adaptersDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func list() throws -> [PrivateAdapterManifest] {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var manifests: [PrivateAdapterManifest] = []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let manifestURL = directory.appendingPathComponent("adapter.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            if let manifest = try? decodeManifest(at: manifestURL) {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    @discardableResult
    public func initialize(id: String) throws -> URL {
        guard Self.isValidAdapterID(id) else {
            throw PrivateAdapterError.invalidID(id)
        }
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw PrivateAdapterError.alreadyExists(id)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = PrivateAdapterManifest(
            id: id,
            displayName: "Private Adapter \(id)",
            executable: "adapter.py",
            collections: [
                PrivateAdapterCollectionDefinition(id: "favorites", displayName: "Favorites")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("adapter.json"),
            options: .atomic
        )

        let executableURL = directory.appendingPathComponent("adapter.py")
        try Self.scaffoldPython.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        try Self.scaffoldAgentInstructions.write(
            to: directory.appendingPathComponent("AGENT_INSTRUCTIONS.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    public func manifest(id: String) throws -> PrivateAdapterManifest {
        let directory = try adapterDirectory(id: id)
        let manifest = try decodeManifest(at: directory.appendingPathComponent("adapter.json"))
        guard manifest.id == id else {
            throw PrivateAdapterError.invalidManifest(
                "manifest id `\(manifest.id)` does not match directory id `\(id)`"
            )
        }
        return manifest
    }

    public func directory(id: String) throws -> URL {
        try adapterDirectory(id: id)
    }

    public func doctor(id: String) throws -> PrivateAdapterDoctorResponse {
        let manifest = try manifest(id: id)
        let executable = try executableURL(manifest: manifest)
        let request = PrivateAdapterRequest(command: .doctor)
        let data = try invoke(executable: executable, adapterID: id, request: request)
        do {
            let response = try JSONDecoder().decode(PrivateAdapterDoctorResponse.self, from: data)
            guard response.protocolVersion == 1 else {
                throw PrivateAdapterError.unsupportedProtocol(response.protocolVersion)
            }
            return response
        } catch let error as PrivateAdapterError {
            throw error
        } catch {
            throw PrivateAdapterError.malformedResponse(error.localizedDescription)
        }
    }

    public func scan(
        id: String,
        collection: String,
        browser: BrowserCookieSource,
        limit: Int? = 100
    ) throws -> PrivateAdapterScanResponse {
        let manifest = try manifest(id: id)
        guard manifest.collections.contains(where: { $0.id == collection }) else {
            throw PrivateAdapterError.collectionNotDeclared(collection)
        }
        let executable = try executableURL(manifest: manifest)
        let request = PrivateAdapterRequest(
            command: .scan,
            collection: collection,
            browser: browser.rawValue,
            limit: limit
        )
        let data = try invoke(executable: executable, adapterID: id, request: request)
        do {
            let response = try JSONDecoder().decode(PrivateAdapterScanResponse.self, from: data)
            guard response.protocolVersion == 1 else {
                throw PrivateAdapterError.unsupportedProtocol(response.protocolVersion)
            }
            return response
        } catch let error as PrivateAdapterError {
            throw error
        } catch {
            throw PrivateAdapterError.malformedResponse(error.localizedDescription)
        }
    }

    private func adapterDirectory(id: String) throws -> URL {
        guard Self.isValidAdapterID(id) else {
            throw PrivateAdapterError.invalidID(id)
        }
        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw PrivateAdapterError.notFound(id)
        }
        return directory
    }

    private func decodeManifest(at url: URL) throws -> PrivateAdapterManifest {
        let manifest: PrivateAdapterManifest
        do {
            manifest = try JSONDecoder().decode(
                PrivateAdapterManifest.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw PrivateAdapterError.invalidManifest(error.localizedDescription)
        }
        guard manifest.protocolVersion == 1 else {
            throw PrivateAdapterError.unsupportedProtocol(manifest.protocolVersion)
        }
        guard Self.isValidAdapterID(manifest.id) else {
            throw PrivateAdapterError.invalidManifest("invalid id `\(manifest.id)`")
        }
        guard !manifest.executable.isEmpty else {
            throw PrivateAdapterError.invalidManifest("executable must not be empty")
        }
        return manifest
    }

    private func executableURL(manifest: PrivateAdapterManifest) throws -> URL {
        guard !manifest.executable.hasPrefix("/") else {
            throw PrivateAdapterError.unsafeExecutablePath(manifest.executable)
        }

        let directory = try adapterDirectory(id: manifest.id)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = directory
            .appendingPathComponent(manifest.executable, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directoryPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(directoryPrefix) else {
            throw PrivateAdapterError.unsafeExecutablePath(manifest.executable)
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw PrivateAdapterError.executableUnavailable(candidate.path)
        }
        return candidate
    }

    private func invoke(
        executable: URL,
        adapterID: String,
        request: PrivateAdapterRequest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = try encoder.encode(request)
        var environment = ProcessInfo.processInfo.environment
        environment["CLIPBOX_PRIVATE_ADAPTER_ID"] = adapterID
        environment["CLIPBOX_PRIVATE_ADAPTER_DIR"] = executable.deletingLastPathComponent().path

        let result = try ProcessRunner.run(
            executable: executable,
            arguments: [],
            environment: environment,
            standardInput: input
        )
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw PrivateAdapterError.runtimeFailed(
                message.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
            )
        }
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw PrivateAdapterError.malformedResponse("empty stdout")
        }
        return data
    }

    private static func isValidAdapterID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let scaffoldPython = #"""
    #!/usr/bin/env python3
    """Private ClipBox adapter scaffold.

    This file lives outside the public Git repository. Ask an AI coding agent to
    customize it for a site you are authorized to access. Keep stdout reserved
    for the JSON protocol response; diagnostics may be written to stderr.
    """

    import json
    import sys


    def main():
        request = json.load(sys.stdin)
        command = request.get("command")

        if command == "doctor":
            json.dump({
                "protocolVersion": 1,
                "ok": False,
                "message": "Adapter scaffold is not implemented yet. Customize adapter.py with an AI agent."
            }, sys.stdout)
            return

        if command == "scan":
            # Replace this empty response with normalized media items. Use only
            # local runtime data here; do not copy private site details into the
            # public ClipBox repository.
            json.dump({"protocolVersion": 1, "items": []}, sys.stdout)
            return

        raise SystemExit("unsupported ClipBox adapter command")


    if __name__ == "__main__":
        main()
    """#

    private static let scaffoldAgentInstructions = #"""
    # Private ClipBox adapter instructions

    This directory is private runtime data and is intentionally outside the public ClipBox Git repository.

    When asking an AI coding agent to customize this adapter:

    1. Keep all site-specific domains, endpoints, selectors, cookies, account data, and fixtures inside this private adapter directory or other private runtime locations.
    2. Do not copy private site details into the public ClipBox repository, its docs, tests, issues, commits, or logs intended for publication.
    3. Read the public `docs/private-adapter-protocol.md` specification from the ClipBox source repository.
    4. Preserve stdout exclusively for the JSON protocol. Send diagnostics to stderr and avoid printing cookies/tokens.
    5. Prefer stable site media IDs. Return a direct media URL for already-selected downloadable media, or use the `yt-dlp` strategy for a page/HLS URL that yt-dlp can process without bypassing DRM/access controls.
    6. Validate with `clipbox adapter doctor <id>` and `clipbox adapter scan <id> <collection>` before syncing.
    """#
}
