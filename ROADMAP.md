# Roadmap

## Phase 0 - Foundation

- [x] Public/private data boundary
- [x] Privacy-focused Git ignore rules and pre-commit audit scaffold
- [x] Native Swift core/CLI/SwiftUI workspace skeleton
- [x] Download filename policy
- [x] Portable archive/history design
- [x] AI-agent-oriented custom adapter specification

## Phase 1 - Core archive engine

- [ ] SQLite archive schema and migrations
- [ ] Stable archive identity (`site + canonical media ID`)
- [ ] Download job model and status transitions
- [x] Default macOS Downloads/ClipBox directory discovery
- [ ] Output path templating and sanitization
- [ ] Format inventory and quality-selection model

## Phase 2 - CLI

- [ ] `clipbox download <url>`
- [ ] `clipbox formats <url>`
- [ ] `clipbox scan <source>`
- [ ] `clipbox sync <site> <collection>`
- [ ] `clipbox history ...`
- [ ] `clipbox backup ...`
- [ ] `--json`, `--dry-run`, `--output`, date/range options

## Phase 3 - Public adapters

- [ ] Generic URL/media adapter
- [ ] X public URL support
- [ ] X collection integration where feasible with user-authorized local authentication
- [ ] YouTube URL support
- [ ] YouTube collection integration where feasible with user-authorized local authentication

## Phase 4 - Private/custom adapter system

- [ ] External adapter discovery and loading
- [ ] Declarative site profiles for simpler sites
- [ ] Programmatic adapter SDK for complex sites
- [ ] `clipbox adapter init`
- [ ] `clipbox adapter test`
- [ ] `clipbox adapter doctor`
- [ ] AI-agent guide and machine-readable adapter schema

## Phase 5 - Native macOS GUI

- [ ] Shared-core integration
- [x] Initial native SwiftUI window and output-folder picker
- [ ] Functional URL download view
- [ ] Collection synchronization view
- [ ] Output location picker
- [ ] Quality/range controls
- [ ] Progress, history, failure, and retry views
- [ ] Backup/restore UI

## Phase 6 - Portability and storage

- [ ] `.clipboxbackup` creation and restore
- [ ] Merge archive histories from multiple computers
- [ ] JSONL/CSV/XLSX export
- [ ] Safe CSV/XLSX import with identifiers treated as text
- [ ] External storage awareness

## Phase 7 - macOS distribution

- [ ] Xcode application target
- [ ] App icon and application metadata
- [ ] Code signing
- [ ] Hardened Runtime and sandbox/entitlement review
- [ ] Notarized `.app` / DMG release pipeline
