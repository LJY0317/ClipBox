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

The implemented exchange formats are:

- **XLSX export:** intended for Excel/manual review. Every cell is written as an OpenXML inline string, including `media_id` and `source_id`, so identifiers longer than Excel's numeric precision are not rounded.
- **CSV export/import:** intended for broad interoperability. Export quotes all fields, includes a UTF-8 BOM, and prefixes formula-looking values so untrusted titles/metadata cannot execute as spreadsheet formulas when opened. ClipBox reverses only that protection marker when re-importing its CSV.
- **JSONL export/import:** intended for machine-readable interchange while preserving IDs and metadata without spreadsheet interpretation.

CSV and JSONL imports merge through the same archive rules as backup restore rather than replacing the current database. XLSX import is intentionally not enabled yet: spreadsheet software may rewrite string cells into shared-string or numeric cells, and ClipBox should explicitly validate those cases before accepting edited workbooks.

The recommended full-fidelity migration path remains `.clipboxbackup`.
