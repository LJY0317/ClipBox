# Download history portability

ClipBox treats download history as independent from the current location of downloaded media files.

SQLite is the authoritative local archive database. Stable IDs are stored as text.

The canonical migration format will use the `.clipboxbackup` extension. It is intended to be a versioned, self-describing archive that can be restored or merged on another computer. This backup/restore layer is the next portability implementation phase; the live SQLite archive is already in use.

CSV, JSONL, and XLSX export/import are planned for interoperability. Platform IDs must be treated as strings so spreadsheet numeric precision cannot corrupt long identifiers.

The recommended full-fidelity migration path remains `.clipboxbackup`.
