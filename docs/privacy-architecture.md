# Privacy architecture

The strongest privacy rule in ClipBox is that personal/custom site information should not enter the public Git repository in the first place. `.gitignore` is a secondary safety measure, not the primary boundary.

The public repository may contain source, public adapters, generic adapter interfaces, documentation, synthetic fixtures, and examples using reserved placeholder domains.

It must not contain personal/custom site domains or URLs, private adapters/profiles, cookies, session exports, authentication tokens, personal download history, personal storage paths, or unredacted private diagnostics.

Runtime and private adapter data belongs in the operating system's application-data/configuration location, outside the Git checkout:

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

Protection layers: keep private data outside the checkout; ignore common secret/runtime patterns; scan staged files against the private denylist; scan tracked files and Git history before publication; redact diagnostics before sharing.

If private data ever reaches a public commit, deleting it in a later commit is not sufficient because Git history and already-published copies may retain it.
