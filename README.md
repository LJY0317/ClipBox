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

## Current development features

- SQLite archive history stored outside the repository in the user's Application Support directory.
- Duplicate detection by `site + canonical media ID`, independent of whether the downloaded file still exists locally.
- Persistent default download-folder preference, initially `~/Downloads/ClipBox`.
- `yt-dlp`-backed public URL inspection and best-quality download orchestration without ClipBox intentionally re-encoding video.
- `ffmpeg` and `yt-dlp` dependency diagnostics.
- CLI commands for status, format inspection, URL download, recent history, paths, and output-folder configuration.
- SwiftUI download screen with URL analysis, available-format preview, output-folder selection, download status, and archive history.
- Portable `.clipboxbackup` history creation and merge restore from both the CLI and macOS Settings UI.
- YouTube Liked Videos and Watch Later preview/sync using a user-selected local browser session; already-downloaded media is skipped from the SQLite archive even if its file has moved elsewhere.
- X Likes and Bookmarks preview/sync through `gallery-dl`, with each native video tracked by its media ID so multi-video posts remain separate archive items.
- Human-readable history export to XLSX/CSV/JSONL, plus merge import from CSV/JSONL. XLSX identifiers are emitted as text cells to preserve long platform IDs exactly.
- AI-agent-friendly private adapter scaffolds and a JSON executable protocol. Site-specific adapter files live only under ClipBox's Application Support directory and can be scanned/synced from both the CLI and native GUI.

`yt-dlp`, `gallery-dl`, and `ffmpeg` are currently external runtime dependencies. ClipBox detects them in `PATH` and common Homebrew locations. A future packaging phase will decide whether the release app should bundle/manage these dependencies or continue to use user-installed copies.

For Homebrew-based development:

```sh
brew install yt-dlp gallery-dl ffmpeg
```

## Development

ClipBox currently uses Swift Package Manager:

```sh
swift build
swift run clipbox status
swift run clipbox paths
swift run clipbox backup create
swift run clipbox scan youtube liked --browser safari --limit 100
swift run clipbox sync youtube watch-later --browser safari --dry-run
swift run clipbox scan x bookmarks --browser safari --limit 100
swift run clipbox sync x likes --username '<handle>' --browser safari --dry-run
swift run clipbox history export "$HOME/Downloads/ClipBox History.xlsx"
swift run clipbox history import "$HOME/Downloads/ClipBox History.csv"
swift run clipbox adapter init my-private-adapter
swift run clipbox adapter doctor my-private-adapter
swift run ClipBoxApp
```

Private adapter customization is intentionally local. `clipbox adapter init` creates `adapter.json`, `adapter.py`, and AI-agent instructions outside the Git checkout. See [Adapter architecture](docs/adapter-spec.md) and [Private adapter protocol](docs/private-adapter-protocol.md).

Authenticated collection commands pass only the selected browser name to the extraction tool's browser-cookie support. ClipBox does not export browser cookies into its archive database or public repository. The X Likes handle is supplied at runtime and is not persisted by the current built-in collection UI/CLI.

From another working directory, provide the package path explicitly:

```sh
swift run --package-path "$HOME/LJY Projects/ClipBox" clipbox status
swift run --package-path "$HOME/LJY Projects/ClipBox" ClipBoxApp
```

For isolated development/automation runs, `CLIPBOX_DATA_DIR` and `CLIPBOX_DOWNLOAD_DIR` can redirect runtime state and downloaded files without changing the normal macOS locations. `CLIPBOX_YTDLP_PATH`, `CLIPBOX_GALLERYDL_PATH`, `CLIPBOX_FFMPEG_PATH`, and `CLIPBOX_CURL_PATH` can inject explicit executable paths for testing or future application packaging.

The macOS Command Line Tools are enough to build the current core, CLI, and SwiftUI executable. Full Xcode is required on a developer Mac for the local XCTest suite and will also be required later for the conventional signed/notarized `.app` release workflow. GitHub CI runs the test suite on a macOS/Xcode runner.

The default media destination is `~/Downloads/ClipBox` as resolved through macOS system directory APIs. Private runtime data and custom adapters live under the user's Application Support directory, outside the Git checkout.

See [ROADMAP.md](ROADMAP.md) for planned implementation phases.

## License

MIT. See [LICENSE](LICENSE).
