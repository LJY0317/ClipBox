# Architecture

ClipBox is currently a macOS-only Swift application with one shared core and two first-class frontends.

```text
                  ClipBoxCore
        +-------------------------------+
        | adapters / downloader         |
        | archive DB / filters          |
        | format selection / queue      |
        | backup/import/export          |
        +---------------+---------------+
                        |
               application API
              +---------+---------+
              |                   |
             CLI                 GUI
              |                   |
         AI / scripts          humans
```

The GUI is native SwiftUI with selective AppKit integration. The CLI and GUI import the same Swift core rather than calling each other.

The default output root is the macOS Downloads directory with a `ClipBox` child directory. It is discovered through `FileManager` system directory APIs rather than hardcoded home paths.

Configuration precedence is planned as application default, user default, site override, collection override, then current job/CLI override.

The authoritative duplicate check is the archive database, preferably `site + canonical media ID`. Files may be renamed or moved without losing archive history.

## Current extraction-engine boundary

The shared core invokes `yt-dlp` as an external extraction/download engine for public URL support. ClipBox owns the surrounding product behavior: stable archive identity, duplicate decisions, persistent output preferences, archive records, and the GUI/CLI contracts.

The core locates `yt-dlp` and `ffmpeg` through `PATH` and common macOS package-manager locations. Missing dependencies are reported explicitly rather than failing silently.

Downloads currently request `bestvideo*+bestaudio/best`. `ffmpeg` is used by the underlying extraction flow when separate streams need to be merged/remuxed; ClipBox does not intentionally request video re-encoding.
