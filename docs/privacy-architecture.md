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

For authenticated built-in collections, ClipBox stores the selected browser type only as an in-memory execution choice. The extraction tool reads that browser's existing cookies directly when invoked. Cookie values are not copied into the archive database, examples, logs intended for publication, or source-controlled configuration.

Protection layers: keep private data outside the checkout; ignore common secret/runtime patterns; scan staged files against the private denylist; scan tracked files and Git history before publication; redact diagnostics before sharing.

If private data ever reaches a public commit, deleting it in a later commit is not sufficient because Git history and already-published copies may retain it.
