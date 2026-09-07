# Roadmap

## Phase 0 - Foundation

- [x] Public/private data boundary
- [x] Privacy-focused Git ignore rules and pre-commit audit scaffold
- [x] Native Swift core/CLI/SwiftUI workspace skeleton
- [x] Download filename policy
- [x] Portable archive/history design
- [x] AI-agent-oriented custom adapter specification

## Phase 1 - Core archive engine

- [x] SQLite archive schema and initial migration
- [x] Stable archive identity (`site + canonical media ID`)
- [x] Download status transitions (`downloading`, `downloaded`, `failed`)
- [x] Default macOS Downloads/ClipBox directory discovery
- [x] Human-readable output template with stable media ID
- [x] Format inventory and best-quality selection through the extraction engine
- [ ] Versioned schema migration framework beyond schema version 1
- [ ] Rich filename-template customization UI/CLI

## Phase 2 - CLI

- [x] `clipbox download <url>`
- [x] `clipbox formats <url>`
- [x] `clipbox scan <source>` for initial YouTube authenticated collections
- [x] `clipbox sync <site> <collection>` for initial YouTube authenticated collections
- [x] `clipbox history ...` (initial recent-history view)
- [x] `clipbox backup ...`
- [x] `clipbox status`, `paths`, and output-folder configuration
- [x] `--json` for current machine-readable commands
- [x] `--output` and `--force` for URL downloads
- [x] `--dry-run`, `--limit`, and `--all` for current collection sync
- [ ] Published-date filters and richer collection range policies

## Phase 3 - Public adapters

- [x] Generic/public URL extraction path through yt-dlp
- [x] X public URL support through yt-dlp
- [x] Initial X Likes/Bookmarks integration through gallery-dl and locally read browser cookies
- [x] YouTube URL support
- [x] YouTube Liked/Watch Later integration through locally read browser cookies

## Phase 4 - Private/custom adapter system

- [x] External private adapter discovery and executable loading
- [ ] Declarative site profiles for simpler sites
- [x] Programmatic JSON executable protocol for complex sites
- [x] `clipbox adapter init`, `list`, and `path`
- [x] `clipbox adapter scan` and `sync`
- [x] `clipbox adapter doctor`
- [x] Native Private Adapters GUI for scaffold/doctor/preview/sync
- [x] AI-agent guide and machine-readable manifest schema
- [ ] Optional declarative profile generator for adapters that do not need custom code

## Phase 5 - Native macOS GUI

- [x] Shared-core integration
- [x] Initial native SwiftUI window and output-folder picker
- [x] Functional URL analysis/download view
- [x] Initial YouTube and X collection preview/synchronization view
- [x] Persisted output location picker
- [x] Best-quality default and format inventory preview
- [x] Basic progress, error, and archive-history views
- [ ] Manual quality selection and collection range controls
- [ ] Download cancellation and failed-item retry actions
- [x] Backup/restore UI

## Phase 6 - Portability and storage

- [x] `.clipboxbackup` creation and restore
- [x] Merge archive histories from multiple computers without downgrading downloaded records
- [x] JSONL/CSV/XLSX export
- [x] Safe JSONL/CSV merge import with identifiers treated as text
- [ ] XLSX merge import after validating edited-workbook string/shared-string handling
- [ ] External storage awareness

## Phase 7 - macOS distribution

- [ ] Xcode application target
- [ ] App icon and application metadata
- [ ] Code signing
- [ ] Hardened Runtime and sandbox/entitlement review
- [ ] Notarized `.app` / DMG release pipeline
