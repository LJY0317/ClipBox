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
