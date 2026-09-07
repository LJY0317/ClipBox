# Native macOS app

ClipBox is macOS-only for the current product direction.

The GUI is implemented with SwiftUI and uses AppKit where direct macOS integration is useful. Shared archive/downloader logic lives in `ClipBoxCore`, and the `clipbox` CLI consumes the same core.

During the foundation phase the SwiftUI executable can be built and launched through Swift Package Manager:

```sh
swift run ClipBoxApp
```

The current macOS Command Line Tools installation is sufficient for `swift build` and running the core/CLI/SwiftUI executable. Full Xcode is required for the local XCTest suite and for the conventional signed/notarized `.app` distribution target that will be added once the core download workflow is stable.
