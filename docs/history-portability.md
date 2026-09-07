# Download history portability

ClipBox treats download history as independent from the current location of downloaded media files.

SQLite is the authoritative local archive database. Stable IDs are stored as text.

The canonical migration format uses the `.clipboxbackup` extension. It is a ZIP-compatible, versioned, self-describing archive containing:

```text
manifest.json
history.sqlite3
history.jsonl
preferences.json
```

The SQLite file is created with SQLite's online backup API rather than copying a live WAL database directly. `manifest.json` records the backup format/schema versions and expected record count. Restore extracts to a temporary directory, validates the manifest and SQLite database, verifies the record count, then merges records into the current archive.

Merge is deliberately non-destructive. An incoming failed/discovered record cannot downgrade an item already known to have downloaded successfully, and an existing output path is retained when possible. This allows histories from multiple Macs to be combined safely.

Preferences are included for portability but are not restored by default because an old Mac's external-drive path may not exist on the new Mac. CLI/GUI restore can opt into restoring the saved download-folder preference.

CSV, JSONL, and XLSX export/import are planned for interoperability. Platform IDs must be treated as strings so spreadsheet numeric precision cannot corrupt long identifiers.

The recommended full-fidelity migration path remains `.clipboxbackup`.
