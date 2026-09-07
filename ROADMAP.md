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
- [ ] X public URL support
- [ ] X collection integration where feasible with user-authorized local authentication
- [x] YouTube URL support
- [x] YouTube Liked/Watch Later integration through locally read browser cookies

## Phase 4 - Private/custom adapter system

- [ ] External adapter discovery and loading
- [ ] Declarative site profiles for simpler sites
- [ ] Programmatic adapter SDK for complex sites
- [ ] `clipbox adapter init`
- [ ] `clipbox adapter test`
- [ ] `clipbox adapter doctor`
- [ ] AI-agent guide and machine-readable adapter schema

## Phase 5 - Native macOS GUI

- [x] Shared-core integration
- [x] Initial native SwiftUI window and output-folder picker
- [x] Functional URL analysis/download view
- [x] Initial YouTube collection preview/synchronization view
- [x] Persisted output location picker
- [x] Best-quality default and format inventory preview
- [x] Basic progress, error, and archive-history views
- [ ] Manual quality selection and collection range controls
- [ ] Download cancellation and failed-item retry actions
- [x] Backup/restore UI

## Phase 6 - Portability and storage

- [x] `.clipboxbackup` creation and restore
- [x] Merge archive histories from multiple computers without downgrading downloaded records
- [ ] JSONL/CSV/XLSX export
- [ ] Safe CSV/XLSX import with identifiers treated as text
- [ ] External storage awareness

## Phase 7 - macOS distribution

- [ ] Xcode application target
- [ ] App icon and application metadata
- [ ] Code signing
- [ ] Hardened Runtime and sandbox/entitlement review
- [ ] Notarized `.app` / DMG release pipeline
