# Native macOS app

ClipBox is macOS-only for the current product direction.

The GUI is implemented with SwiftUI and uses AppKit where direct macOS integration is useful. Shared archive/downloader logic lives in `ClipBoxCore`, and the `clipbox` CLI consumes the same core.

During the foundation phase the SwiftUI executable can be built and launched through Swift Package Manager:

```sh
swift run ClipBoxApp
```

The current macOS Command Line Tools installation is sufficient for `swift build` and running the core/CLI/SwiftUI executable. Full Xcode is required for the local XCTest suite and for the conventional signed/notarized `.app` distribution target that will be added once the core download workflow is stable.

The current development UI can inspect URLs, preview extracted formats, choose and persist a download destination, trigger best-quality downloads, show recent archive history, and preview/sync the built-in YouTube and X collections when their extraction dependencies are available.

## Development app bundle

`tools/package-app.sh` builds the SwiftPM release executable and wraps it in a conventional `ClipBox.app` bundle with an ad-hoc local signature. This is intended for local development and is not a substitute for Developer ID signing/notarization.

`tools/install-dev.sh` installs the app to `~/Applications/ClipBox.app` and copies the CLI binary into ClipBox's Application Support directory, then places a `clipbox` symlink in a writable command directory already on `PATH` when possible.

`tools/uninstall-dev.sh` removes only the development app/CLI installation. It deliberately preserves archive history, preferences, backups, and private adapters.
