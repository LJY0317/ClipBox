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
- X Likes and Bookmarks preview/sync through `gallery-dl`, with photos, videos, and animated media selectable independently. Normal X Preview is incremental: it requests one real timeline page at a time (up to about 50 posts per selected collection) and resumes from the opaque continuation cursor only when the user asks for another page. The native UI can scan Likes + Bookmarks together, collapse overlapping entries by canonical media ID, download one file, and still record both collection memberships. Media that exists in only one collection remains included in the union.
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
swift run clipbox scan x bookmarks --media-types videos,photos,animated --browser chrome --profile "Profile 1" --limit 100
swift run clipbox sync x likes --username '<handle>' --media-types videos,photos --browser chrome --profile "Profile 1" --dry-run
swift run clipbox sync x all --username '<handle>' --media-types videos,photos,animated --browser chrome --profile "Profile 1" --dry-run
swift run clipbox history export "$HOME/Downloads/ClipBox History.xlsx"
swift run clipbox history import "$HOME/Downloads/ClipBox History.csv"
swift run clipbox adapter init my-private-adapter
swift run clipbox adapter doctor my-private-adapter
swift run ClipBoxApp
```

Private adapter customization is intentionally local. `clipbox adapter init` creates `adapter.json`, `adapter.py`, and AI-agent instructions outside the Git checkout. See [Adapter architecture](docs/adapter-spec.md) and [Private adapter protocol](docs/private-adapter-protocol.md).

Authenticated X collection commands pass the selected browser and profile to gallery-dl. ClipBox does not export cookies or store session tokens. The GUI remembers a verified profile and optionally the Likes handle in local preferences; these never belong in the public repository.

Built-in collection media types default to Videos + Photos + Animated media. The native Collections UI exposes them as checkboxes, and the CLI can override them with `--media-types`. X photos use gallery-dl's original-size image URL when available; X animated GIF-style media is kept in the MP4 form served by X rather than being re-encoded into a GIF.

For X, the native Collections UI defaults to selecting both Likes and Bookmarks. ClipBox treats the selected collections as a union for downloading: the same `site + media ID` is downloaded once even if it appears in both collections, while the SQLite membership table separately records that it was seen in Likes, Bookmarks, or both. The CLI exposes the same behavior as `clipbox scan x all` and `clipbox sync x all`.

Incremental X Preview keeps continuation cursors in process memory only; cursors are not written to preferences, snapshots, diagnostics, or logs. The timeline response already contains a representative media/poster image URL. ClipBox derives a small `pbs.twimg.com` thumbnail URL from that metadata without a post-detail request, then lazily downloads only thumbnails for rows SwiftUI brings into view. Thumbnail requests use an ephemeral, cookie-free URL session, a memory-only cache, and at most three connections per image host. Profile avatars and engagement counters are intentionally not fetched separately because they add little value to archive verification.

From another working directory, provide the package path explicitly:

```sh
swift run --package-path "$HOME/LJY Projects/ClipBox" clipbox status
swift run --package-path "$HOME/LJY Projects/ClipBox" ClipBoxApp
```

For a normal local development install without `swift run`:

```sh
tools/install-dev.sh
clipbox status
clipbox gui
```

The installer puts a native app at `~/Applications/ClipBox.app` and a persistent CLI binary under ClipBox's Application Support directory, then links `clipbox` into a writable command directory already on `PATH` when possible. If the local `ClipBox Local Development Code Signing` identity exists, packaging uses that stable identity; otherwise it falls back to ad-hoc signing. You can create the local-only identity with `/bin/sh tools/setup-local-signing.sh`. Its private key stays in the user's login Keychain and its trust is limited to the user `codeSign` policy. This is for repeated local development installs only, not Developer ID signing, notarization, or public distribution.

If `CLIPBOX_CODESIGN_IDENTITY` is explicitly set, packaging requires that identity to exist and fails instead of silently falling back to ad-hoc signing.

`tools/uninstall-dev.sh` removes only that development app/CLI installation; it deliberately preserves archive history, preferences, backups, and private adapters.

For isolated development/automation runs, `CLIPBOX_DATA_DIR` and `CLIPBOX_DOWNLOAD_DIR` can redirect runtime state and downloaded files without changing the normal macOS locations. `CLIPBOX_YTDLP_PATH`, `CLIPBOX_GALLERYDL_PATH`, `CLIPBOX_FFMPEG_PATH`, and `CLIPBOX_CURL_PATH` can inject explicit executable paths for testing or future application packaging.

The macOS Command Line Tools are enough to build the current core, CLI, and SwiftUI executable. Full Xcode is required on a developer Mac for the local XCTest suite and will also be required later for the conventional signed/notarized `.app` release workflow. GitHub CI runs the test suite on a macOS/Xcode runner.

The default media destination is `~/Downloads/ClipBox` as resolved through macOS system directory APIs. Private runtime data and custom adapters live under the user's Application Support directory, outside the Git checkout.

See [ROADMAP.md](ROADMAP.md) for planned implementation phases.

## License

MIT. See [LICENSE](LICENSE).

### X connection troubleshooting

Use a signed-in Chrome, Firefox or Brave **profile**, then test it in Collections. A handle identifies the Likes timeline; it does not authenticate. Safari can select discovered WebKit cookie stores with a Python-based gallery-dl installation; use Test connection to find the signed-in store. See [X browser sessions and architecture](docs/x-browser-sessions.md).

```sh
clipbox session list
clipbox session check --browser chrome --profile "Profile 1"
clipbox scan x all --username ExampleUser --browser chrome --profile "Profile 1" --limit 100
clipbox sync x all --username ExampleUser --browser chrome --profile "Profile 1" --all
```

Choose the profile containing your own X session. The first full import and periodic full scans discover older collection entries; bounded scans cover only the selected newest range. Archive identity prevents repeat downloads while retaining both Likes and Bookmarks membership. Collection membership means “observed in this collection”; it does not prove that the item remains liked/bookmarked today.
