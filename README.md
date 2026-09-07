# ClipBox

ClipBox is an open-source native macOS media download and archive toolkit built with Swift and SwiftUI around a shared core with CLI and GUI frontends.

Its core idea is simple: download media once, remember it permanently, and keep that history portable even when the files themselves move to external storage.

## Principles

- Native macOS application using SwiftUI, with AppKit integration where useful.
- One shared Swift core for CLI and GUI.
- Incremental sync: skip media already archived, even if the files are no longer on the current computer.
- Portable download-history backup and restore between computers.
- User-selectable download destinations, defaulting to macOS Downloads under `ClipBox/`.
- Public adapters may live in this repository; personal/custom site adapters and profiles must live outside the repository.
- Cookies, session material, personal download history, private site URLs, and private adapters are never intended to be committed.
- AI-agent-friendly adapter specifications and machine-readable CLI output are first-class design goals.

## Planned interfaces

- `clipbox` CLI for people, scripts, and AI agents.
- Native SwiftUI macOS GUI for interactive use.

## Development

ClipBox currently uses Swift Package Manager:

```sh
swift build
swift run clipbox paths
swift run ClipBoxApp
```

The macOS Command Line Tools are enough to build the current core, CLI, and SwiftUI executable. Full Xcode is required on a developer Mac for the local XCTest suite and will also be required later for the conventional signed/notarized `.app` release workflow. GitHub CI runs the test suite on a macOS/Xcode runner.

The default media destination is `~/Downloads/ClipBox` as resolved through macOS system directory APIs. Private runtime data and custom adapters live under the user's Application Support directory, outside the Git checkout.

See [ROADMAP.md](ROADMAP.md) for planned implementation phases.

## License

MIT. See [LICENSE](LICENSE).
