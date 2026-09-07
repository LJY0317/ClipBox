# Architecture

ClipBox uses one shared core with multiple first-class frontends.

```text
                  clipbox-core
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

The default output root is the operating system's Downloads directory with a `ClipBox` child directory. It must be discovered through platform directory APIs rather than hardcoded home paths.

Configuration precedence is planned as application default, user default, site override, collection override, then current job/CLI override.

The authoritative duplicate check is the archive database, preferably `site + canonical media ID`. Files may be renamed or moved without losing archive history.
