# Privacy architecture

The strongest privacy rule in ClipBox is that personal/custom site information should not enter the public Git repository in the first place. `.gitignore` is a secondary safety measure, not the primary boundary.

The public repository may contain source, public adapters, generic adapter interfaces, documentation, synthetic fixtures, and examples using reserved placeholder domains.

It must not contain personal/custom site domains or URLs, private adapters/profiles, cookies, session exports, authentication tokens, personal download history, personal storage paths, or unredacted private diagnostics.

Runtime and private adapter data belongs in the user's macOS Application Support/configuration location, outside the Git checkout:

```text
ClipBox user data/
├── config/
├── archive/history.sqlite3
├── adapters/
├── profiles/
├── privacy/denylist.txt
└── logs/
```

`privacy/denylist.txt` is private and may list hostnames or strings that must never occur in staged or published source. The privacy checker reads it from outside the repository.

For authenticated X collections, ClipBox remembers a verified browser/profile selection and optionally the account handle in its local preferences (mode 0600). These are non-secret local preferences and may be present in a user-requested preferences backup. “Forget” removes them. No session tokens or cookies are stored there.

The gallery-dl adapter reads browser cookies at runtime. It ignores external gallery-dl configuration, scopes Chromium/Firefox cookie reads to `.x.com`, disables cookie export and persistent gallery-dl caching, and does not print raw extraction failures. Likes and Bookmarks share one process and its in-memory cookie cache. Process stdin/stdout/stderr use concurrently drained memory pipes, not temporary text files. The process arguments contain no cookie values.

Safari collection support reads the selected Safari website-data cookie store in place at runtime. The packaged macOS app declares `NSAppDataUsageDescription` so macOS can explain this other-application-data access when needed. ClipBox does not require or instruct users to enable Full Disk Access for normal operation; Safari-specific access is a separate permission path, while ordinary downloads continue to use normal user-selected/files-and-folders access. Safari login data is not copied into ClipBox preferences or an exported cookie file.

This describes ClipBox's own behavior, not a guarantee that the browser or upstream extractor never writes credentials. gallery-dl can fall back to a temporary copy of a browser cookie database; Firefox databases can contain plaintext cookies. See [X browser sessions](x-browser-sessions.md) for limitations and alternatives. Diagnostic exports must not include raw tool traffic, browser databases, full preferences, account handles, profile paths, or signed media URLs.

Private adapter source is also runtime data rather than repository content. `clipbox adapter init` creates adapters below ClipBox's Application Support directory, and the adapter executable is constrained to that adapter's private directory even after resolving symlinks. ClipBox communicates with it through a versioned JSON stdin/stdout protocol; public protocol examples use only reserved `example.invalid` domains.

Protection layers: keep private data outside the checkout; ignore common secret/runtime patterns; scan staged files against the private denylist; scan tracked files and Git history before publication; redact diagnostics before sharing.

If private data ever reaches a public commit, deleting it in a later commit is not sufficient because Git history and already-published copies may retain it.

Collection comparison snapshots are local private history: returned order, original post links, media IDs and dates only. They omit direct media URLs and credentials, use mode 0600 and are scoped by a hash of the browser route, entered handle and scan settings. Page diagnostics include counts and coarse termination conditions only, never cursor values or raw responses. Safari store discovery is limited to Safari-owned locations.
